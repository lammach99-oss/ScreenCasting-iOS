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
// Fragment Shader: Hardware Zero-Copy NV12 YUV -> RGB Color Conversion
fragment float4 yuvFragmentShader(VertexOutput in [[stage_in]],
                                  texture2d<float> yTexture [[texture(0)]],
                                  texture2d<float> uvTexture [[texture(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);

    float y = yTexture.sample(textureSampler, in.texCoord).r;
    float2 uv = uvTexture.sample(textureSampler, in.texCoord).rg - float2(0.5, 0.5);

    // BT.709 YCbCr full-range to RGB conversion
    float r = y + 1.5748 * uv.y;
    float g = y - 0.1873 * uv.x - 0.4681 * uv.y;
    float b = y + 1.8556 * uv.x;

    return float4(saturate(r), saturate(g), saturate(b), 1.0);
}
