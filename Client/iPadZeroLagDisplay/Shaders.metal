#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float2 texCoord;
};

// Vertex Shader
vertex VertexOutput yuvVertexShader(uint vertexID [[vertex_id]],
                                    constant float2& aspectScale [[buffer(0)]]) {
    // Full-screen quad triangle strip: (-1, -1), (1, -1), (-1, 1), (1, 1)
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };

    const float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };

    VertexOutput out;
    out.position = float4(positions[vertexID] * aspectScale, 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Fragment Shader: Hardware Zero-Copy NV12 YUV -> RGB Color Conversion (FP16 Fast Path)
fragment half4 yuvFragmentShader(VertexOutput in [[stage_in]],
                                 texture2d<half> yTexture [[texture(0)]],
                                 texture2d<half> uvTexture [[texture(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    half y = yTexture.sample(textureSampler, in.texCoord).r;
    half2 uv = uvTexture.sample(textureSampler, in.texCoord).rg - half2(0.5h, 0.5h);

    // BT.709 YCbCr full-range to RGB conversion in FP16
    half r = y + 1.5748h * uv.y;
    half g = y - 0.1873h * uv.x - 0.4681h * uv.y;
    half b = y + 1.8556h * uv.x;

    return half4(saturate(r), saturate(g), saturate(b), 1.0h);
}

