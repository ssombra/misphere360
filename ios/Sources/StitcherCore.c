#include "StitcherCore.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <dispatch/dispatch.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ImageIO/ImageIO.h>
#include <CoreFoundation/CoreFoundation.h>

#define GW 512
#define GH 256
#define GN (GW * GH)

typedef struct {
    float u1[GN];
    float v1[GN];
    float u2[GN];
    float v2[GN];
    float w1[GN];     // 1.0 = Lens 1 only, 0.0 = Lens 2 only
    float cw[GN];     // wide weight for low-freq color compensation
} LutData;

static inline void sample_bilinear(const uint8_t *buf, int W, int H, float u, float v, float *out_rgb) {
    if (u < 0.0f) u = 0.0f;
    if (u > (float)(W - 1)) u = (float)(W - 1);
    if (v < 0.0f) v = 0.0f;
    if (v > (float)(H - 1)) v = (float)(H - 1);

    int x0 = (int)floorf(u);
    int y0 = (int)floorf(v);
    int x1 = (x0 + 1 < W) ? x0 + 1 : x0;
    int y1 = (y0 + 1 < H) ? y0 + 1 : y0;
    float fx = u - (float)x0;
    float fy = v - (float)y0;

    const uint8_t *p00 = &buf[(y0 * W + x0) * 4];
    const uint8_t *p10 = &buf[(y0 * W + x1) * 4];
    const uint8_t *p01 = &buf[(y1 * W + x0) * 4];
    const uint8_t *p11 = &buf[(y1 * W + x1) * 4];

    float w00 = (1.0f - fx) * (1.0f - fy);
    float w10 = fx * (1.0f - fy);
    float w01 = (1.0f - fx) * fy;
    float w11 = fx * fy;

    out_rgb[0] = w00 * p00[0] + w10 * p10[0] + w01 * p01[0] + w11 * p11[0];
    out_rgb[1] = w00 * p00[1] + w10 * p10[1] + w01 * p01[1] + w11 * p11[1];
    out_rgb[2] = w00 * p00[2] + w10 * p10[2] + w01 * p01[2] + w11 * p11[2];
}

int stitch_dual_fisheye_c(const char *in_jpg_path, const char *lut_bin_path, const char *out_jpg_path) {
    if (!in_jpg_path || !lut_bin_path || !out_jpg_path) return -1;

    FILE *lf = fopen(lut_bin_path, "rb");
    if (!lf) {
        fprintf(stderr, "StitcherCore: No se pudo abrir LUT: %s\n", lut_bin_path);
        return -2;
    }
    LutData *lut = (LutData *)malloc(sizeof(LutData));
    if (!lut) {
        fclose(lf);
        return -3;
    }
    if (fread(lut, sizeof(LutData), 1, lf) != 1) {
        fprintf(stderr, "StitcherCore: Tamaño inválido de tabla LUT\n");
        free(lut);
        fclose(lf);
        return -4;
    }
    fclose(lf);

    CFURLRef in_url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)in_jpg_path, strlen(in_jpg_path), false);
    if (!in_url) { free(lut); return -5; }
    CGImageSourceRef src = CGImageSourceCreateWithURL(in_url, NULL);
    CFRelease(in_url);
    if (!src) { free(lut); return -6; }

    CGImageRef in_img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!in_img) { free(lut); return -7; }

    int W = (int)CGImageGetWidth(in_img);
    int H = (int)CGImageGetHeight(in_img);
    if (W <= 0 || H <= 0) {
        CGImageRelease(in_img);
        free(lut);
        return -8;
    }

    uint8_t *in_buf = (uint8_t *)malloc((size_t)W * H * 4);
    if (!in_buf) {
        CGImageRelease(in_img);
        free(lut);
        return -9;
    }

    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(in_buf, W, H, 8, W * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), in_img);
    CGContextRelease(ctx);
    CGImageRelease(in_img);

    // Calcular diferencia de color/exposición únicamente en la línea media óptica (0.46 <= cw <= 0.54)
    float *diff_r = (float *)calloc(GN, sizeof(float));
    float *diff_g = (float *)calloc(GN, sizeof(float));
    float *diff_b = (float *)calloc(GN, sizeof(float));
    float *diff_m = (float *)calloc(GN, sizeof(float));

    for (int gy = 0; gy < GH; gy++) {
        for (int gx = 0; gx < GW; gx++) {
            int k = gy * GW + gx;
            float s = lut->cw[k];
            if (lut->u1[k] >= 0.0f && lut->u2[k] >= 0.0f && s >= 0.46f && s <= 0.54f) {
                float c1[3] = {0, 0, 0}, c2[3] = {0, 0, 0};
                for (int dy = -2; dy <= 2; dy += 2) {
                    for (int dx = -2; dx <= 2; dx += 2) {
                        float t1[3], t2[3];
                        sample_bilinear(in_buf, W, H, lut->u1[k] + dx, lut->v1[k] + dy, t1);
                        sample_bilinear(in_buf, W, H, lut->u2[k] + dx, lut->v2[k] + dy, t2);
                        for (int c = 0; c < 3; c++) { c1[c] += t1[c]; c2[c] += t2[c]; }
                    }
                }
                for (int c = 0; c < 3; c++) { c1[c] /= 9.0f; c2[c] /= 9.0f; }
                float dr = c1[0] - c2[0];
                float dg = c1[1] - c2[1];
                float db = c1[2] - c2[2];
                if (dr > 35.0f) dr = 35.0f; if (dr < -35.0f) dr = -35.0f;
                if (dg > 35.0f) dg = 35.0f; if (dg < -35.0f) dg = -35.0f;
                if (db > 35.0f) db = 35.0f; if (db < -35.0f) db = -35.0f;
                diff_r[k] = dr;
                diff_g[k] = dg;
                diff_b[k] = db;
                diff_m[k] = 1.0f;
            }
        }
    }

    float *tmp_r = (float *)calloc(GN, sizeof(float));
    float *tmp_g = (float *)calloc(GN, sizeof(float));
    float *tmp_b = (float *)calloc(GN, sizeof(float));
    float *tmp_m = (float *)calloc(GN, sizeof(float));

    for (int iter = 0; iter < 90; iter++) {
        for (int gy = 0; gy < GH; gy++) {
            int y_up = (gy > 0) ? gy - 1 : 0;
            int y_dn = (gy + 1 < GH) ? gy + 1 : GH - 1;
            for (int gx = 0; gx < GW; gx++) {
                int x_lt = (gx - 1 + GW) % GW;
                int x_rt = (gx + 1) % GW;
                float sr = 0, sg = 0, sb = 0, sm = 0;
                int idxs[9] = {
                    y_up * GW + x_lt, y_up * GW + gx, y_up * GW + x_rt,
                    gy   * GW + x_lt, gy   * GW + gx, gy   * GW + x_rt,
                    y_dn * GW + x_lt, y_dn * GW + gx, y_dn * GW + x_rt
                };
                for (int i = 0; i < 9; i++) {
                    int nb = idxs[i];
                    float w = diff_m[nb];
                    if (w > 0.0f) {
                        sr += diff_r[nb] * w;
                        sg += diff_g[nb] * w;
                        sb += diff_b[nb] * w;
                        sm += w;
                    }
                }
                int k = gy * GW + gx;
                if (sm > 0.0f) {
                    tmp_r[k] = sr / sm;
                    tmp_g[k] = sg / sm;
                    tmp_b[k] = sb / sm;
                    tmp_m[k] = 1.0f;
                }
            }
        }
        for (int k = 0; k < GN; k++) {
            float s = lut->cw[k];
            float dist_from_seam = fabsf(s - 0.5f) * 2.0f;
            float decay = 1.0f - 0.015f * dist_from_seam;
            diff_r[k] = tmp_r[k] * decay;
            diff_g[k] = tmp_g[k] * decay;
            diff_b[k] = tmp_b[k] * decay;
            diff_m[k] = tmp_m[k];
        }
    }

    uint8_t *out_buf = (uint8_t *)malloc((size_t)W * H * 4);
    if (!out_buf) {
        free(in_buf); free(lut);
        free(diff_r); free(diff_g); free(diff_b); free(diff_m);
        free(tmp_r); free(tmp_g); free(tmp_b); free(tmp_m);
        return -10;
    }

    dispatch_apply(H, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t Y) {
        float gy_f = ((float)Y / (float)(H - 1)) * (float)(GH - 1);
        int gy0 = (int)floorf(gy_f);
        int gy1 = (gy0 + 1 < GH) ? gy0 + 1 : gy0;
        float fy = gy_f - (float)gy0;

        uint8_t *row_out = &out_buf[Y * W * 4];

        for (int X = 0; X < W; X++) {
            float gx_f = ((float)X / (float)W) * (float)GW;
            int gx0 = ((int)floorf(gx_f)) % GW;
            int gx1 = (gx0 + 1) % GW;
            float fx = gx_f - floorf(gx_f);

            int k00 = gy0 * GW + gx0;
            int k10 = gy0 * GW + gx1;
            int k01 = gy1 * GW + gx0;
            int k11 = gy1 * GW + gx1;

            float bw00 = (1.0f - fx) * (1.0f - fy);
            float bw10 = fx * (1.0f - fy);
            float bw01 = (1.0f - fx) * fy;
            float bw11 = fx * fy;

            float w1 = bw00 * lut->w1[k00] + bw10 * lut->w1[k10] + bw01 * lut->w1[k01] + bw11 * lut->w1[k11];
            float cw = bw00 * lut->cw[k00] + bw10 * lut->cw[k10] + bw01 * lut->cw[k01] + bw11 * lut->cw[k11];

            float dr = bw00 * diff_r[k00] + bw10 * diff_r[k10] + bw01 * diff_r[k01] + bw11 * diff_r[k11];
            float dg = bw00 * diff_g[k00] + bw10 * diff_g[k10] + bw01 * diff_g[k01] + bw11 * diff_g[k11];
            float db = bw00 * diff_b[k00] + bw10 * diff_b[k10] + bw01 * diff_b[k01] + bw11 * diff_b[k11];

            float rgb1[3] = {0, 0, 0};
            float rgb2[3] = {0, 0, 0};

            if (w1 > 0.0001f) {
                float u1 = bw00 * lut->u1[k00] + bw10 * lut->u1[k10] + bw01 * lut->u1[k01] + bw11 * lut->w1[k11];
                float v1 = bw00 * lut->v1[k00] + bw10 * lut->v1[k10] + bw01 * lut->v1[k01] + bw11 * lut->v1[k11];
                sample_bilinear(in_buf, W, H, u1, v1, rgb1);
                rgb1[0] -= (1.0f - cw) * dr;
                rgb1[1] -= (1.0f - cw) * dg;
                rgb1[2] -= (1.0f - cw) * db;
            }

            if (w1 < 0.9999f) {
                float u2 = bw00 * lut->u2[k00] + bw10 * lut->u2[k10] + bw01 * lut->u2[k01] + bw11 * lut->u2[k11];
                float v2 = bw00 * lut->v2[k00] + bw10 * lut->v2[k10] + bw01 * lut->v2[k01] + bw11 * lut->v2[k11];
                sample_bilinear(in_buf, W, H, u2, v2, rgb2);
                rgb2[0] += cw * dr;
                rgb2[1] += cw * dg;
                rgb2[2] += cw * db;
            }

            for (int c = 0; c < 3; c++) {
                float val = w1 * rgb1[c] + (1.0f - w1) * rgb2[c];
                if (val < 0.0f) val = 0.0f;
                if (val > 255.0f) val = 255.0f;
                row_out[X * 4 + c] = (uint8_t)(val + 0.5f);
            }
            row_out[X * 4 + 3] = 255;
        }
    });

    CGContextRef out_ctx = CGBitmapContextCreate(out_buf, W, H, 8, W * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGImageRef out_img = CGBitmapContextCreateImage(out_ctx);
    CFURLRef out_url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)out_jpg_path, strlen(out_jpg_path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(out_url, CFSTR("public.jpeg"), 1, NULL);

    float quality = 0.93f;
    CFNumberRef q_num = CFNumberCreate(NULL, kCFNumberFloatType, &quality);
    const void *keys[1] = { kCGImageDestinationLossyCompressionQuality };
    const void *vals[1] = { q_num };
    CFDictionaryRef opts = CFDictionaryCreate(NULL, keys, vals, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CGImageDestinationAddImage(dest, out_img, opts);
    CGImageDestinationFinalize(dest);

    CFRelease(opts);
    CFRelease(q_num);
    CFRelease(dest);
    CFRelease(out_url);
    CGImageRelease(out_img);
    CGContextRelease(out_ctx);
    CGColorSpaceRelease(cs);

    free(in_buf);
    free(out_buf);
    free(lut);
    free(diff_r); free(diff_g); free(diff_b); free(diff_m);
    free(tmp_r); free(tmp_g); free(tmp_b); free(tmp_m);
    return 0;
}
