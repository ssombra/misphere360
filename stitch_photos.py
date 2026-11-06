#!/usr/bin/env python3
"""
Cosidor 360° (Dual-Fisheye a Equirrectangular 6912x3456) para Xiaomi Mi Sphere 360 (MADV QJXJ01FJ).
Usa las 8 tablas LUT de calibración de fábrica de 16 bits (512x256) incrustadas al final de cada JPG,
aplica compensación suave de exposición en la costura, conserva el bloque EXIF original corregido
e inyecta el bloque XMP GPano oficial para que Google Fotos, Facebook y Apple Fotos la reconozcan como 360°.
"""

from __future__ import annotations

import math
import os
import re
import struct
import subprocess
import tempfile
import zlib
from collections import deque
from datetime import datetime
from pathlib import Path

DESCARGAS_DIR = Path(__file__).parent / "Descargas"
CORE_BIN = Path(__file__).parent / "misphere_stitch_core"
CACHED_LUT_BIN = Path(__file__).parent / "factory_lut_cached.bin"

C_SOURCE = r"""
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

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "Usage: %s <input.jpg> <lut.bin> <output_raw.jpg>\n", argv[0]);
        return 1;
    }
    const char *in_path = argv[1];
    const char *lut_path = argv[2];
    const char *out_path = argv[3];

    FILE *lf = fopen(lut_path, "rb");
    if (!lf) { fprintf(stderr, "Cannot open LUT\n"); return 1; }
    LutData *lut = malloc(sizeof(LutData));
    if (fread(lut, sizeof(LutData), 1, lf) != 1) {
        fprintf(stderr, "Invalid LUT size\n");
        fclose(lf);
        return 1;
    }
    fclose(lf);

    CFURLRef in_url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)in_path, strlen(in_path), false);
    CGImageSourceRef src = CGImageSourceCreateWithURL(in_url, NULL);
    CFRelease(in_url);
    if (!src) { fprintf(stderr, "Cannot open input image\n"); return 1; }
    CGImageRef in_img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!in_img) { fprintf(stderr, "Cannot decode input image\n"); return 1; }

    int W = (int)CGImageGetWidth(in_img);
    int H = (int)CGImageGetHeight(in_img);
    uint8_t *in_buf = malloc((size_t)W * H * 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(in_buf, W, H, 8, W * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), in_img);
    CGContextRelease(ctx);
    CGImageRelease(in_img);

    // Calcular diferencia de color/exposición únicamente en la línea media óptica (0.46 <= cw <= 0.54)
    // donde ambas lentes están a exactamente 90° (mismo radio óptico, lejos del borde negro del lente)
    float *diff_r = calloc(GN, sizeof(float));
    float *diff_g = calloc(GN, sizeof(float));
    float *diff_b = calloc(GN, sizeof(float));
    float *diff_m = calloc(GN, sizeof(float));

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
                // Limitar diferencias extremas por paralaje local
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

    // Difundir y suavizar ampliamente el campo de compensación de exposición en la malla 512x256
    float *tmp_r = calloc(GN, sizeof(float));
    float *tmp_g = calloc(GN, sizeof(float));
    float *tmp_b = calloc(GN, sizeof(float));
    float *tmp_m = calloc(GN, sizeof(float));

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
        // Atenuar gradualmente hacia el centro de cada lente (lejos de la costura)
        for (int k = 0; k < GN; k++) {
            float s = lut->cw[k];
            float dist_from_seam = fabsf(s - 0.5f) * 2.0f; // 0 en costura, 1 lejos de costura
            float decay = 1.0f - 0.015f * dist_from_seam;
            diff_r[k] = tmp_r[k] * decay;
            diff_g[k] = tmp_g[k] * decay;
            diff_b[k] = tmp_b[k] * decay;
            diff_m[k] = tmp_m[k];
        }
    }

    uint8_t *out_buf = malloc((size_t)W * H * 4);

    // Renderizar imagen equirrectangular 6912x3456 en paralelo usando todos los núcleos de CPU
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
                float u1 = bw00 * lut->u1[k00] + bw10 * lut->u1[k10] + bw01 * lut->u1[k01] + bw11 * lut->u1[k11];
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

    // Codificar JPEG de alta calidad (0.93) con ImageIO
    CGContextRef out_ctx = CGBitmapContextCreate(out_buf, W, H, 8, W * 4, cs, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrder32Big);
    CGImageRef out_img = CGBitmapContextCreateImage(out_ctx);
    CFURLRef out_url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)out_path, strlen(out_path), false);
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
"""


def compile_stitch_core():
    if CORE_BIN.exists():
        return
    with tempfile.NamedTemporaryFile(suffix=".c", mode="w", delete=False) as tf:
        tf.write(C_SOURCE)
        c_path = tf.name
    try:
        subprocess.run(
            [
                "clang",
                "-O3",
                "-framework", "CoreGraphics",
                "-framework", "ImageIO",
                "-framework", "CoreFoundation",
                c_path,
                "-o", str(CORE_BIN),
            ],
            check=True,
        )
    finally:
        Path(c_path).unlink(missing_ok=True)


def decode_png_16bit(png_bytes: bytes) -> tuple[int, int, tuple]:
    idx = 8
    idat = bytearray()
    w = h = 0
    while idx < len(png_bytes):
        length = struct.unpack(">I", png_bytes[idx:idx+4])[0]
        ctype = png_bytes[idx+4:idx+8]
        chunk = png_bytes[idx+8:idx+8+length]
        if ctype == b"IHDR":
            w, h = struct.unpack(">II", chunk[:8])
        elif ctype == b"IDAT":
            idat.extend(chunk)
        elif ctype == b"IEND":
            break
        idx += 12 + length
    raw = zlib.decompress(bytes(idat))
    stride = w * 2
    recon = bytearray(w * h * 2)
    for y in range(h):
        ft = raw[y * (stride + 1)]
        row = bytearray(raw[y * (stride + 1) + 1 : (y + 1) * (stride + 1)])
        prev = recon[(y - 1) * stride : y * stride] if y > 0 else bytes(stride)
        for x in range(stride):
            a = row[x - 2] if x >= 2 else 0
            b = prev[x]
            c = prev[x - 2] if x >= 2 else 0
            if ft == 1:
                row[x] = (row[x] + a) & 0xFF
            elif ft == 2:
                row[x] = (row[x] + b) & 0xFF
            elif ft == 3:
                row[x] = (row[x] + ((a + b) >> 1)) & 0xFF
            elif ft == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                row[x] = (row[x] + pr) & 0xFF
        recon[y * stride : (y + 1) * stride] = row
    return w, h, struct.unpack(f">{w * h}H", recon)


def compute_grid_distances(valid_mask: list[bool], w: int = 512, h: int = 256) -> list[float]:
    """Calcula la distancia en celdas desde cada punto válido hasta el borde inválido más cercano."""
    dist = [0.0 if not v else 1e9 for v in valid_mask]
    q = deque()
    for y in range(h):
        for x in range(w):
            k = y * w + x
            if not valid_mask[k]:
                q.append((x, y))
    while q:
        x, y = q.popleft()
        d = dist[y * w + x]
        for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
            nx = (x + dx) % w
            ny = y + dy
            if 0 <= ny < h:
                nk = ny * w + nx
                if dist[nk] > d + 1.0:
                    dist[nk] = d + 1.0
                    q.append((nx, ny))
    return dist


def fill_invalid_neighbors(arr: list[float], valid_mask: list[bool], w: int = 512, h: int = 256) -> list[float]:
    """Extiende las coordenadas válidas 2 celdas hacia afuera para evitar saltos en la interpolación bilineal."""
    res = list(arr)
    mask = list(valid_mask)
    for _ in range(3):
        next_res = list(res)
        next_mask = list(mask)
        for y in range(h):
            for x in range(w):
                k = y * w + x
                if not mask[k]:
                    vals = []
                    for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                        nx = (x + dx) % w
                        ny = y + dy
                        if 0 <= ny < h and mask[ny * w + nx]:
                            vals.append(res[ny * w + nx])
                    if vals:
                        next_res[k] = sum(vals) / len(vals)
                        next_mask[k] = True
        res, mask = next_res, next_mask
    return res


def find_lut_base(jpg_bytes: bytes) -> int | None:
    """Busca la tabla de 64 bytes + 8 PNGs al final del archivo JPG sin importar su tamaño total."""
    search_start = max(0, len(jpg_bytes) - 900000)
    m = re.search(rb"\x89PNG\r\n\x1a\n", jpg_bytes[search_start:])
    if not m:
        return None
    base = search_start + m.start() - 64
    return base if base >= 0 else None


def build_lut_binary(jpg_bytes: bytes) -> bytes:
    """Extrae las 8 tablas PNG de 16 bits del final del archivo JPG y genera el struct LutData binario."""
    base = find_lut_base(jpg_bytes)
    if base is None:
        raise RuntimeError("No se encontraron las tablas LUT de fábrica en el archivo JPG.")
    entries = struct.unpack("<16I", jpg_bytes[base : base + 64])

    maps = []
    for i in range(8):
        off, sz = entries[2 * i], entries[2 * i + 1]
        _, _, vals = decode_png_16bit(jpg_bytes[base + off : base + off + sz])
        maps.append(vals)

    GW, GH = 512, 256
    GN = GW * GH

    v1_mask = [(maps[0][k] > 0 or maps[2][k] > 0) for k in range(GN)]
    v2_mask = [(maps[4][k] > 0 or maps[6][k] > 0) for k in range(GN)]

    # Lens 1 = hemisferio derecho (+3456), Lens 2 = hemisferio izquierdo (+0)
    u1 = [((maps[0][k] + maps[1][k] / 1000.0) * 2.0 + 3456.0) if v1_mask[k] else -1.0 for k in range(GN)]
    v1 = [((maps[2][k] + maps[3][k] / 1000.0) * 2.0) if v1_mask[k] else -1.0 for k in range(GN)]
    u2 = [((maps[4][k] + maps[5][k] / 1000.0) * 2.0) if v2_mask[k] else -1.0 for k in range(GN)]
    v2 = [((maps[6][k] + maps[7][k] / 1000.0) * 2.0) if v2_mask[k] else -1.0 for k in range(GN)]

    d1 = compute_grid_distances(v1_mask, GW, GH)
    d2 = compute_grid_distances(v2_mask, GW, GH)

    w1 = [0.0] * GN
    cw = [0.0] * GN
    for k in range(GN):
        if v1_mask[k] and not v2_mask[k]:
            w1[k] = 1.0
            cw[k] = 1.0
        elif v2_mask[k] and not v1_mask[k]:
            w1[k] = 0.0
            cw[k] = 0.0
        elif v1_mask[k] and v2_mask[k]:
            s = d1[k] / (d1[k] + d2[k] + 1e-6)
            cw[k] = s
            # Transición suave centrada en s=0.5 sobre una banda estrecha [0.40, 0.60] para evitar doble imagen (ghosting)
            t = (s - 0.40) / 0.20
            if t <= 0.0:
                w1[k] = 0.0
            elif t >= 1.0:
                w1[k] = 1.0
            else:
                w1[k] = t * t * (3.0 - 2.0 * t)

    # Extender coordenadas 2 celdas más allá del borde para interpolación bilineal limpia
    u1_ext = fill_invalid_neighbors(u1, v1_mask, GW, GH)
    v1_ext = fill_invalid_neighbors(v1, v1_mask, GW, GH)
    u2_ext = fill_invalid_neighbors(u2, v2_mask, GW, GH)
    v2_ext = fill_invalid_neighbors(v2, v2_mask, GW, GH)

    return struct.pack(f"<{GN}f{GN}f{GN}f{GN}f{GN}f{GN}f", *u1_ext, *v1_ext, *u2_ext, *v2_ext, *w1, *cw)


def extract_original_exif_app1(jpg_bytes: bytes) -> bytes:
    """Extrae el segmento APP1 (Exif) original de la foto para preservar fecha, cámara y giroscopio."""
    if jpg_bytes[:2] != b"\xff\xd8":
        return b""
    idx = 2
    while idx < len(jpg_bytes) - 4:
        if jpg_bytes[idx] != 0xFF:
            break
        marker = jpg_bytes[idx + 1]
        if marker == 0xDA:
            break
        length = struct.unpack(">H", jpg_bytes[idx + 2 : idx + 4])[0]
        seg = jpg_bytes[idx : idx + 2 + length]
        if marker == 0xE1 and seg[4:10] == b"Exif\x00\x00":
            return seg
        idx += 2 + length
    return b""


def parse_jpeg_dimensions_and_mode(jpg_bytes: bytes) -> dict:
    """
    Analiza la cabecera JPEG y EXIF para determinar:
    - Dimensiones reales (width, height)
    - Si ya cuenta con metadatos XMP GPano (has_gpano)
    - Si es una foto de 2 esferas sin coser (is_dual_fisheye=True, EXIF 0xA300 == 0x59000000)
      o si ya viene cocida 360 en cámara (is_dual_fisheye=False, EXIF 0xA300 == 0).
    """
    width, height = 6912, 3456
    has_gpano = b"http://ns.google.com/photos/1.0/panorama/" in jpg_bytes[:65536]
    lut_base = find_lut_base(jpg_bytes)
    has_lut_trailer = lut_base is not None

    if jpg_bytes[:2] == b"\xff\xd8":
        idx = 2
        while idx < len(jpg_bytes) - 9:
            if jpg_bytes[idx] != 0xFF:
                idx += 1
                continue
            marker = jpg_bytes[idx + 1]
            if marker == 0xDA:  # SOS
                break
            if marker in (0xD8, 0xD9) or (0xD0 <= marker <= 0xD7):
                idx += 2
                continue
            length = struct.unpack(">H", jpg_bytes[idx + 2 : idx + 4])[0]
            if marker in (0xC0, 0xC1, 0xC2):
                height, width = struct.unpack(">HH", jpg_bytes[idx + 5 : idx + 9])
                break
            idx += 2 + length

    # Leer etiquetas EXIF 0xA300 (FileSource) y 0xA301 (SceneType) donde Xiaomi Mi Sphere
    # marca 0x59000000 ('Y') cuando son 2 esferas sin coser y 0x00000000 cuando ya está cocida en cámara.
    a300_val = None
    exif_seg = extract_original_exif_app1(jpg_bytes)
    if len(exif_seg) > 18:
        try:
            tiff = exif_seg[10:]
            endian = "<" if tiff[:2] == b"II" else ">"
            ifd0_off = struct.unpack(endian + "I", tiff[4:8])[0]
            n0 = struct.unpack(endian + "H", tiff[ifd0_off : ifd0_off + 2])[0]
            exif_off = 0
            for i in range(n0):
                ent = tiff[ifd0_off + 2 + i * 12 : ifd0_off + 14 + i * 12]
                tag, _, _, val = struct.unpack(endian + "HHII", ent)
                if tag == 0x8769:
                    exif_off = val
                    break
            if exif_off:
                ne = struct.unpack(endian + "H", tiff[exif_off : exif_off + 2])[0]
                for i in range(ne):
                    ent = tiff[exif_off + 2 + i * 12 : exif_off + 14 + i * 12]
                    tag, _, _, val = struct.unpack(endian + "HHII", ent)
                    if tag == 0xA300:
                        a300_val = val
                        break
        except Exception:
            pass

    if has_gpano:
        is_dual_fisheye = False
        mode = "already_360"
    elif a300_val is not None:
        is_dual_fisheye = (a300_val != 0)
        mode = "dual_fisheye" if is_dual_fisheye else "in_camera_stitched"
    else:
        # Fallback: solo las de 6912x3456 con tabla LUT y sin GPano que no tengan a300==0
        is_dual_fisheye = (width == 6912 and height == 3456 and has_lut_trailer)
        mode = "dual_fisheye" if is_dual_fisheye else "in_camera_stitched"

    return {
        "width": width,
        "height": height,
        "has_gpano": has_gpano,
        "has_lut_trailer": has_lut_trailer,
        "lut_base": lut_base,
        "is_dual_fisheye": is_dual_fisheye,
        "mode": mode,
    }


def clear_dual_fisheye_exif_flag(exif_seg: bytes) -> bytes:
    """Limpia las banderas 0xA300/0xA301 en el bloque EXIF de salida para indicar que ya está cosida."""
    if len(exif_seg) <= 18:
        return exif_seg
    try:
        buf = bytearray(exif_seg)
        tiff_start = 10
        endian = "<" if buf[tiff_start : tiff_start + 2] == b"II" else ">"
        ifd0_off = struct.unpack(endian + "I", buf[tiff_start + 4 : tiff_start + 8])[0]
        n0 = struct.unpack(endian + "H", buf[tiff_start + ifd0_off : tiff_start + ifd0_off + 2])[0]
        exif_off = 0
        for i in range(n0):
            pos = tiff_start + ifd0_off + 2 + i * 12
            tag, _, _, val = struct.unpack(endian + "HHII", buf[pos : pos + 12])
            if tag == 0x8769:
                exif_off = val
                break
        if exif_off:
            ne = struct.unpack(endian + "H", buf[tiff_start + exif_off : tiff_start + exif_off + 2])[0]
            for i in range(ne):
                pos = tiff_start + exif_off + 2 + i * 12
                tag, typ, cnt, _ = struct.unpack(endian + "HHII", buf[pos : pos + 12])
                if tag in (0xA300, 0xA301):
                    struct.pack_into(endian + "HHII", buf, pos, tag, typ, cnt, 0)
        return bytes(buf)
    except Exception:
        return exif_seg


def build_gpano_xmp_app1(width: int = 6912, height: int = 3456) -> bytes:
    """Construye el segmento APP1 XMP con las etiquetas GPano estándar para Google Fotos, Facebook y Apple Fotos."""
    xmp_xml = f"""<?xpacket begin="\ufeff" id="W5M0MpCehiHzreSzNTczkc9d"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="MiSphere 360 Stitcher">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description rdf:about=""
      xmlns:GPano="http://ns.google.com/photos/1.0/panorama/">
      <GPano:UsePanoramaViewer>True</GPano:UsePanoramaViewer>
      <GPano:ProjectionType>equirectangular</GPano:ProjectionType>
      <GPano:FullPanoWidthPixels>{width}</GPano:FullPanoWidthPixels>
      <GPano:FullPanoHeightPixels>{height}</GPano:FullPanoHeightPixels>
      <GPano:CroppedAreaImageWidthPixels>{width}</GPano:CroppedAreaImageWidthPixels>
      <GPano:CroppedAreaImageHeightPixels>{height}</GPano:CroppedAreaImageHeightPixels>
      <GPano:CroppedAreaLeftPixels>0</GPano:CroppedAreaLeftPixels>
      <GPano:CroppedAreaTopPixels>0</GPano:CroppedAreaTopPixels>
      <GPano:StitchingSoftware>MiSphere 360 Native Stitcher</GPano:StitchingSoftware>
    </rdf:Description>
  </rdf:RDF>
</x:xmpmeta>
<?xpacket end="w"?>"""
    payload = b"http://ns.adobe.com/xap/1.0/\x00" + xmp_xml.encode("utf-8")
    return b"\xff\xe1" + struct.unpack(">2s", struct.pack(">H", len(payload) + 2))[0] + payload


def inject_exif_and_xmp(rendered_jpg: bytes, orig_exif_seg: bytes, xmp_seg: bytes) -> bytes:
    """Inyecta el EXIF original corregido y el XMP GPano justo después del marcador SOI/APP0."""
    idx = 2
    app0_segments = []
    other_segments = []
    while idx < len(rendered_jpg) - 4:
        if rendered_jpg[idx] != 0xFF:
            break
        marker = rendered_jpg[idx + 1]
        if marker in (0xDB, 0xC0, 0xC4, 0xDA):
            break
        length = struct.unpack(">H", rendered_jpg[idx + 2 : idx + 4])[0]
        seg = rendered_jpg[idx : idx + 2 + length]
        if marker == 0xE0:
            app0_segments.append(seg)
        elif marker != 0xE1:
            other_segments.append(seg)
        idx += 2 + length

    clean_exif = clear_dual_fisheye_exif_flag(orig_exif_seg)
    return (
        b"\xff\xd8"
        + b"".join(app0_segments)
        + clean_exif
        + xmp_seg
        + b"".join(other_segments)
        + rendered_jpg[idx:]
    )


def copy_file_timestamps(src_file: Path, dst_file: Path):
    st = src_file.stat()
    os.utime(dst_file, (st.st_atime, st.st_mtime))
    dt = datetime.fromtimestamp(st.st_mtime)
    touch_str = dt.strftime("%Y%m%d%H%M.%S")
    subprocess.run(["touch", "-t", touch_str, str(dst_file)], check=False)


_GLOBAL_LUT_CACHE: dict[bytes, Path] = {}
WEBGL_LUT_BIN = Path(__file__).parent / "factory_lut_webgl.bin"


def get_webgl_lut_bytes() -> bytes:
    """
    Devuelve un bloque binario compacto (512x256x9 = 1,179,648 bytes) con las tablas LUT de fábrica
    normalizadas a 16 bits para que el shader WebGL en el navegador pueda coser el video en vivo
    (rtsp://192.168.42.1/live) a 60 FPS usando la calibración óptica exacta de esta cámara:
      - Bloque 1 (524,288 B): RGBA8 para Lente 1 (R,G = u1_16bit, B,A = v1_16bit)
      - Bloque 2 (524,288 B): RGBA8 para Lente 2 (R,G = u2_16bit, B,A = v2_16bit)
      - Bloque 3 (131,072 B): Luminance8 para peso de mezcla w1 (0..255)
    """
    if WEBGL_LUT_BIN.exists() and WEBGL_LUT_BIN.stat().st_size == 512 * 256 * 9:
        return WEBGL_LUT_BIN.read_bytes()

    lut_file = CACHED_LUT_BIN
    if not lut_file.exists() or lut_file.stat().st_size != 512 * 256 * 6 * 4:
        # Buscar cualquier JPG en Descargas/ que tenga el tráiler LUT de fábrica
        found_jpg = None
        if DESCARGAS_DIR.exists():
            for p in DESCARGAS_DIR.rglob("*.JPG"):
                if not p.name.upper().endswith("_360.JPG"):
                    raw = p.read_bytes()
                    if find_lut_base(raw) is not None:
                        found_jpg = raw
                        break
        if found_jpg is None:
            raise RuntimeError("No se encontró ninguna foto con tabla LUT para inicializar el visor 360° en vivo.")
        lut_file.write_bytes(build_lut_binary(found_jpg))

    raw_lut = lut_file.read_bytes()
    GN = 512 * 256
    floats = struct.unpack(f"<{GN * 6}f", raw_lut)
    u1_arr = floats[0 : GN]
    v1_arr = floats[GN : 2 * GN]
    u2_arr = floats[2 * GN : 3 * GN]
    v2_arr = floats[3 * GN : 4 * GN]
    w1_arr = floats[4 * GN : 5 * GN]

    lut1_rgba = bytearray(GN * 4)
    lut2_rgba = bytearray(GN * 4)
    w1_u8 = bytearray(GN)

    for k in range(GN):
        u1n = max(0.0, min(1.0, u1_arr[k] / 6912.0)) if u1_arr[k] >= 0.0 else 0.0
        v1n = max(0.0, min(1.0, v1_arr[k] / 3456.0)) if v1_arr[k] >= 0.0 else 0.0
        u2n = max(0.0, min(1.0, u2_arr[k] / 6912.0)) if u2_arr[k] >= 0.0 else 0.0
        v2n = max(0.0, min(1.0, v2_arr[k] / 3456.0)) if v2_arr[k] >= 0.0 else 0.0

        u1_16 = int(u1n * 65535.0 + 0.5)
        v1_16 = int(v1n * 65535.0 + 0.5)
        u2_16 = int(u2n * 65535.0 + 0.5)
        v2_16 = int(v2n * 65535.0 + 0.5)

        idx4 = k * 4
        lut1_rgba[idx4] = (u1_16 >> 8) & 0xFF
        lut1_rgba[idx4 + 1] = u1_16 & 0xFF
        lut1_rgba[idx4 + 2] = (v1_16 >> 8) & 0xFF
        lut1_rgba[idx4 + 3] = v1_16 & 0xFF

        lut2_rgba[idx4] = (u2_16 >> 8) & 0xFF
        lut2_rgba[idx4 + 1] = u2_16 & 0xFF
        lut2_rgba[idx4 + 2] = (v2_16 >> 8) & 0xFF
        lut2_rgba[idx4 + 3] = v2_16 & 0xFF

        w1_u8[k] = int(max(0.0, min(1.0, w1_arr[k])) * 255.0 + 0.5)

    out_bytes = bytes(lut1_rgba) + bytes(lut2_rgba) + bytes(w1_u8)
    try:
        WEBGL_LUT_BIN.write_bytes(out_bytes)
    except Exception:
        pass
    return out_bytes


def process_photo_bytes(jpg_bytes: bytes, cached_lut: dict | None = None) -> tuple[bytes, dict]:
    """
    Procesa los bytes de un JPG de la cámara Mi Sphere:
    - Si es de 2 esferas (dual_fisheye): la cose ópticamente en C, nivela la exposición de la costura,
      conserva su EXIF original e inyecta XMP GPano.
    - Si ya viene "Cocida 360 en cámara" (in_camera_stitched): NO vuelve a deformar la imagen;
      elimina sin pérdida de calidad el tráiler de 790 KB (si existe), conserva el EXIF original
      e inyecta el bloque XMP GPano con sus dimensiones exactas (6912x3456 o 3456x1728).
    """
    if cached_lut is None:
        cached_lut = _GLOBAL_LUT_CACHE

    info = parse_jpeg_dimensions_and_mode(jpg_bytes)
    width, height = info["width"], info["height"]
    mode = info["mode"]

    if mode == "already_360":
        return jpg_bytes, info

    orig_exif = extract_original_exif_app1(jpg_bytes)
    xmp_seg = build_gpano_xmp_app1(width, height)

    if mode == "in_camera_stitched":
        # Recortar el tráiler de tablas PNG al final (después de 0xFFD9) sin recomprimir el JPEG
        clean_jpg = jpg_bytes[: info["lut_base"]] if info["lut_base"] is not None else jpg_bytes
        final_bytes = inject_exif_and_xmp(clean_jpg, orig_exif, xmp_seg)
        return final_bytes, info

    # Modo dual_fisheye: coser ópticamente usando la tabla LUT de fábrica
    compile_stitch_core()
    base = info["lut_base"]
    if base is None:
        raise RuntimeError("La foto es de 2 esferas pero no contiene las tablas LUT de calibración.")
    hdr64 = jpg_bytes[base : base + 64]

    if hdr64 not in cached_lut or not cached_lut[hdr64].exists():
        lut_bytes = build_lut_binary(jpg_bytes)
        lut_file = CACHED_LUT_BIN
        lut_file.write_bytes(lut_bytes)
        cached_lut[hdr64] = lut_file

    lut_file = cached_lut[hdr64]

    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf_in, \
         tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf_out:
        in_tmp = Path(tf_in.name)
        out_tmp = Path(tf_out.name)
        in_tmp.write_bytes(jpg_bytes)

    try:
        subprocess.run([str(CORE_BIN), str(in_tmp), str(lut_file), str(out_tmp)], check=True)
        rendered_bytes = out_tmp.read_bytes()
    finally:
        in_tmp.unlink(missing_ok=True)
        out_tmp.unlink(missing_ok=True)

    final_bytes = inject_exif_and_xmp(rendered_bytes, orig_exif, xmp_seg)
    return final_bytes, info


def stitch_single_photo(in_path: Path, out_path: Path, cached_lut: dict | None = None) -> dict:
    """Procesa un archivo en disco (cosido completo si son 2 esferas, o inyección XMP sin pérdida si ya viene cosida)."""
    if cached_lut is None:
        cached_lut = _GLOBAL_LUT_CACHE

    jpg_bytes = in_path.read_bytes()
    info = parse_jpeg_dimensions_and_mode(jpg_bytes)
    width, height = info["width"], info["height"]
    mode = info["mode"]

    if mode == "already_360":
        if in_path.resolve() != out_path.resolve():
            out_path.write_bytes(jpg_bytes)
            copy_file_timestamps(in_path, out_path)
        return info

    orig_exif = extract_original_exif_app1(jpg_bytes)
    xmp_seg = build_gpano_xmp_app1(width, height)

    if mode == "in_camera_stitched":
        clean_jpg = jpg_bytes[: info["lut_base"]] if info["lut_base"] is not None else jpg_bytes
        final_bytes = inject_exif_and_xmp(clean_jpg, orig_exif, xmp_seg)
        out_path.write_bytes(final_bytes)
        copy_file_timestamps(in_path, out_path)
        return info

    # Modo dual_fisheye
    compile_stitch_core()
    base = info["lut_base"]
    if base is None:
        raise RuntimeError(f"Sin tabla LUT en {in_path.name}")
    hdr64 = jpg_bytes[base : base + 64]

    if hdr64 not in cached_lut or not cached_lut[hdr64].exists():
        lut_bytes = build_lut_binary(jpg_bytes)
        lut_file = CACHED_LUT_BIN
        lut_file.write_bytes(lut_bytes)
        cached_lut[hdr64] = lut_file

    lut_file = cached_lut[hdr64]

    with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tf:
        raw_out = Path(tf.name)

    try:
        subprocess.run([str(CORE_BIN), str(in_path), str(lut_file), str(raw_out)], check=True)
        rendered_bytes = raw_out.read_bytes()
    finally:
        raw_out.unlink(missing_ok=True)

    final_bytes = inject_exif_and_xmp(rendered_bytes, orig_exif, xmp_seg)
    out_path.write_bytes(final_bytes)
    copy_file_timestamps(in_path, out_path)
    return info


if __name__ == "__main__":
    import sys
    import time

    compile_stitch_core()
    cached = {}
    if len(sys.argv) > 1:
        inp = Path(sys.argv[1])
        outp = inp.with_name(inp.stem + "_360.JPG")
        info = stitch_single_photo(inp, outp, cached)
        print(f"Procesada ({info['mode']}, {info['width']}x{info['height']}): {outp}")
    else:
        t0 = time.time()
        total = 0
        for folder in sorted(DESCARGAS_DIR.iterdir()):
            if not folder.is_dir():
                continue
            src_files = [
                f for f in sorted(folder.glob("*.JPG")) + sorted(folder.glob("*.jpg"))
                if not f.name.upper().endswith("_360.JPG")
            ]
            if not src_files:
                continue
            print(f"\n🌐 Procesando carpeta {folder.name} ({len(src_files)} fotos):")
            for f in src_files:
                out_f = f.with_name(f.stem + "_360.JPG")
                t_start = time.time()
                info = stitch_single_photo(f, out_f, cached)
                dt_s = time.time() - t_start
                total += 1
                print(f"  ✅ {f.name} [{info['mode']}] --> {out_f.name} ({dt_s:.2f}s)")
        print(f"\n🎉 ¡{total} fotos 360° procesadas con EXIF + XMP GPano en {time.time() - t0:.1f}s!")
