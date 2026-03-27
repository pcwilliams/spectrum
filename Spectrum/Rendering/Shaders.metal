// Spectrum — Metal Shaders
//
// Simple pass-through vertex/fragment pipeline shared by all four
// visualisation modes. The CPU builds coloured vertices each frame;
// the GPU just positions and interpolates colours.
//
// IMPORTANT: Vertex struct uses non-packed float2/float4 to match Swift's
// SIMD2<Float>/SIMD4<Float> alignment (32-byte stride). Using packed types
// would give a 24-byte stride, causing garbled rendering from misaligned
// vertex reads. See MetalRenderer.SpectrumVertex for the Swift counterpart.

#include <metal_stdlib>
using namespace metal;

// Must match Swift's SpectrumVertex layout exactly:
// SIMD2<Float> (8 bytes) + 8 bytes padding + SIMD4<Float> (16 bytes) = 32 bytes
struct Vertex {
    float2 position;  // NDC coordinates (-1...+1)
    float4 color;     // RGBA, alpha-blended
};

struct VertexOut {
    float4 position [[position]];  // Clip-space position for rasteriser
    float4 color;                  // Interpolated across triangle
};

// Vertex shader: expands 2D position to clip space (z=0, w=1)
vertex VertexOut vertex_main(const device Vertex* vertices [[buffer(0)]],
                              uint vid [[vertex_id]]) {
    VertexOut out;
    out.position = float4(float2(vertices[vid].position), 0.0, 1.0);
    out.color = float4(vertices[vid].color);
    return out;
}

// Fragment shader: outputs the interpolated vertex colour directly.
// Alpha blending is enabled in the pipeline descriptor (source-over).
fragment float4 fragment_main(VertexOut in [[stage_in]]) {
    return in.color;
}
