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
    texture2d<float> videoTex [[texture(0)]],
    texture2d<float> lut1Tex [[texture(1)]],
    texture2d<float> lut2Tex [[texture(2)]],
    texture2d<float> weightTex [[texture(3)]],
    sampler s [[sampler(0)]]
) {
    // Modo 2: Dual Fisheye crudo (las 2 circunferencias originales)
    if (u.mode == 2) {
        float2 uv = float2(in.ndc.x * 0.5 + 0.5, 0.5 - in.ndc.y * 0.5);
        return videoTex.sample(s, uv);
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
        col1 = videoTex.sample(s, uv1);
    }
    if (w1 < 0.999) {
        float2 uv2 = lut2Tex.sample(s, eqUV).rg;
        col2 = videoTex.sample(s, uv2);
    }

    return mix(col2, col1, w1);
}
