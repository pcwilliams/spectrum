// Spectrum — Metal Shaders
//
// Simple pass-through vertex/fragment pipeline shared by four of the five
// visualisation modes (Bars, Curve, Circular, Spectrogram).
// Surface mode uses a separate 3D pipeline below. The CPU builds coloured vertices each frame;
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

// --- 3D Surface Pipeline ---
//
// Separate vertex/fragment pair for the 3D surface visualisation mode.
// Uses a model-view-projection matrix for 3D→clip-space transformation
// and a directional light for surface shading.

// Must match Swift's SurfaceVertex layout:
// SIMD3<Float> (16 bytes) + SIMD3<Float> (16 bytes) + SIMD4<Float> (16 bytes) = 48 bytes
struct SurfaceVertexIn {
    float3 position;   // 3D world position
    float3 normal;     // Surface normal for lighting
    float4 color;      // RGBA with alpha for depth fade
};

// Must match Swift's SurfaceUniforms layout:
// simd_float4x4 (64 bytes) + SIMD4<Float> (16 bytes) = 80 bytes
struct SurfaceUniforms {
    float4x4 mvpMatrix;
    float4 lightDirectionAndAmbient;  // xyz = normalised light direction, w = ambient intensity
};

struct SurfaceVertexOut {
    float4 position [[position]];
    float4 color;
    float3 normal;
};

vertex SurfaceVertexOut surface_vertex(
    const device SurfaceVertexIn* vertices [[buffer(0)]],
    constant SurfaceUniforms& uniforms [[buffer(1)]],
    uint vid [[vertex_id]])
{
    SurfaceVertexOut out;
    out.position = uniforms.mvpMatrix * float4(vertices[vid].position, 1.0);
    out.color = vertices[vid].color;
    out.normal = vertices[vid].normal;
    return out;
}

fragment float4 surface_fragment(
    SurfaceVertexOut in [[stage_in]],
    constant SurfaceUniforms& uniforms [[buffer(1)]])
{
    float3 N = normalize(in.normal);
    float3 L = uniforms.lightDirectionAndAmbient.xyz;
    float ambient = uniforms.lightDirectionAndAmbient.w;
    float NdotL = max(dot(N, L), 0.0);
    float lighting = ambient + (1.0 - ambient) * NdotL;
    return float4(in.color.rgb * lighting, in.color.a);
}
