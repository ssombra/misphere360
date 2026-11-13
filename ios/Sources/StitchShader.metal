#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 ndc;
};

struct Uniforms {
    int mode;           // 0 = 360° interactivo, 1 = panorama equirrectangular, 2 = dual fisheye crudo
    float yaw;          // Ángulo azimut horizontal (radianes)
    float pitch;        // Ángulo de elevación vertical (radianes)
    float tanHalfFov;   // tan(fov / 2)
    float aspect;       // Relación de aspecto (ancho / alto)
};

// Conversión ultra-rápida por hardware YUV (NV12 BT.601 Video Range) a RGB
inline float4 sampleYUV(texture2d<float> yTex, texture2d<float> uvTex, sampler s, float2 uv) {
    float y = yTex.sample(s, uv).r;
    float2 uvVal = uvTex.sample(s, uv).rg;

    // Fórmula estándar BT.601 Video Range
    float y_adj = (y - (16.0 / 255.0)) * 1.16438356;
    float u_adj = uvVal.x - (128.0 / 255.0);
    float v_adj = uvVal.y - (128.0 / 255.0);

    float r = y_adj + 1.59602678 * v_adj;
    float g = y_adj - 0.39176229 * u_adj - 0.81296764 * v_adj;
    float b = y_adj + 2.01723214 * u_adj;

    return float4(clamp(float3(r, g, b), 0.0, 1.0), 1.0);
}

// Vértice que cubre toda la pantalla usando 2 triángulos (6 vértices)
vertex VertexOut stitchVertexShader(uint vertexID [[vertex_id]]) {
    const float2 positions[6] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2(-1.0,  1.0),
        float2( 1.0, -1.0),
        float2( 1.0,  1.0)
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.ndc = positions[vertexID];
    return out;
}

fragment float4 stitchFragmentShader(
    VertexOut in [[stage_in]],
    constant Uniforms &u [[buffer(0)]],
    texture2d<float> yTex [[texture(0)]],
    texture2d<float> uvTex [[texture(1)]],
    texture2d<float> lut1Tex [[texture(2)]],
    texture2d<float> lut2Tex [[texture(3)]],
    texture2d<float> weightTex [[texture(4)]],
    sampler s [[sampler(0)]]
) {
    // Modo 2: Dual Fisheye crudo (las 2 circunferencias originales)
    if (u.mode == 2) {
        float2 uv = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
        return sampleYUV(yTex, uvTex, s, uv);
    }

    float2 eqUV;

    if (u.mode == 1) {
        // Modo 1: Panorama Equirrectangular 360° plano
        eqUV = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
    } else {
        // Modo 0: Esfera 360° Interactiva con proyección de perspectiva
        const float PI = 3.14159265358979323846;
        float3 dir = normalize(float3(in.ndc.x * u.tanHalfFov * u.aspect, in.ndc.y * u.tanHalfFov, -1.0));

        // Rotación de cabeceo (Pitch)
        float cp = cos(u.pitch);
        float sp = sin(u.pitch);
        float3 d1 = float3(dir.x, dir.y * cp - dir.z * sp, dir.y * sp + dir.z * cp);

        // Rotación de guiñada (Yaw)
        float cy = cos(u.yaw);
        float sy = sin(u.yaw);
        float3 worldDir = float3(d1.x * cy - d1.z * sy, d1.y, d1.x * sy + d1.z * cy);

        float lon = atan2(worldDir.x, -worldDir.z);
        float lat = asin(clamp(worldDir.y, -1.0, 1.0));

        float uCoord = fract(lon / (2.0 * PI) + 0.5);
        float vCoord = clamp(0.5 - lat / PI, 0.0, 1.0);
        eqUV = float2(uCoord, vCoord);
    }

    // Muestreo óptico con las tablas LUT calibradas de fábrica
    float w1 = weightTex.sample(s, eqUV).r;
    float4 col1 = float4(0.0);
    float4 col2 = float4(0.0);

    if (w1 > 0.001) {
        float2 uv1 = lut1Tex.sample(s, eqUV).rg;
        col1 = sampleYUV(yTex, uvTex, s, uv1);
    }
    if (w1 < 0.999) {
        float2 uv2 = lut2Tex.sample(s, eqUV).rg;
        col2 = sampleYUV(yTex, uvTex, s, uv2);
    }

    return mix(col2, col1, w1);
}
