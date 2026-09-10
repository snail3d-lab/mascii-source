#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    uint2 outputSize;
    uint2 cellGrid;
    float  flicker;
    float  brightness;
    float  vignette;
    float  time;
    uint   colorMode;   // 0 = B&W, 1 = Snail 3D lime
    float2 pad;
};

// 12-step neutral grayscale (B&W tier)
constant half3 g_gray[12] = {
    half3(0.000, 0.000, 0.000),
    half3(0.055, 0.055, 0.059),
    half3(0.118, 0.118, 0.125),
    half3(0.196, 0.196, 0.212),
    half3(0.294, 0.294, 0.314),
    half3(0.408, 0.408, 0.431),
    half3(0.537, 0.537, 0.565),
    half3(0.667, 0.667, 0.718),
    half3(0.784, 0.784, 0.816),
    half3(0.878, 0.878, 0.902),
    half3(0.949, 0.949, 0.965),
    half3(1.000, 1.000, 1.000),
};

// Snail 3D signature: black -> deep spring green -> bright lime.
// The palette itself IS the brand gradient, so glyphs near the top of
// the luminance range glow lime while shadows stay true black.
constant half3 g_snail[12] = {
    half3(0.020, 0.060, 0.030),
    half3(0.040, 0.140, 0.050),
    half3(0.090, 0.250, 0.080),
    half3(0.160, 0.380, 0.120),
    half3(0.250, 0.520, 0.170),
    half3(0.340, 0.650, 0.220),
    half3(0.440, 0.770, 0.280),
    half3(0.550, 0.880, 0.350),
    half3(0.670, 0.950, 0.430),
    half3(0.780, 0.990, 0.550),
    half3(0.890, 1.000, 0.700),
    half3(1.000, 1.000, 0.860),
};

constexpr sampler clamped(filter::nearest, address::clamp_to_edge);

kernel void ascii_fragment(uint2 gid [[thread_position_in_grid]],
                           constant Uniforms &u [[buffer(0)]],
                           texture2d<half> cellTex [[texture(0)]],
                           texture2d<half> glyphAtlas [[texture(1)]],
                           texture2d<half> colorCellTex [[texture(2)]],
                           texture2d<half, access::write> outTex [[texture(3)]])
{
    if (gid.x >= u.outputSize.x || gid.y >= u.outputSize.y) return;

    float2 cellPx = float2(u.outputSize) / float2(u.cellGrid);
    uint2 cell = gid / uint2(cellPx + 0.5);
    cell.x = min(cell.x, u.cellGrid.x - 1);
    cell.y = min(cell.y, u.cellGrid.y - 1);

    float2 uv = (float2(cell) + 0.5) / float2(u.cellGrid);
    half lum = cellTex.sample(clamped, uv).r;

    uint cidx = uint(clamp(lum * 11.0, 0.0, 11.0));
    half3 pal = (u.colorMode == 1u) ? g_snail[cidx] : g_gray[cidx];

    float2 inCell = float2(gid) - float2(cell) * cellPx;
    float2 norm = inCell / cellPx;

    float2 atlasUV = (float2(cidx, 0) + norm) * float2(1.0 / 12.0, 1.0);
    half glyph = glyphAtlas.sample(clamped, atlasUV).r;

    half3 col = glyph * pal * half(u.flicker * u.brightness);

    // Color tier only: add the source frame's own color, gently desaturated,
    // so color video actually colors the ASCII.
    if (u.colorMode == 1u) {
        half3 src = colorCellTex.sample(clamped, uv).rgb;
        half luma = dot(src, half3(0.299, 0.587, 0.114));
        half3 colored = mix(luma, src, 0.65);
        col = mix(col, glyph * colored * half(u.flicker * u.brightness), 0.85);
    }

    float2 p = (float2(gid) + 0.5) / float2(u.outputSize);
    float2 d = p - 0.5;
    float vig = 1.0 - u.vignette * (dot(d, d) * 4.0);
    col *= half(vig);

    float g = fract(sin(dot(float2(gid) + u.time * 61.0, float2(12.9898, 78.233))) * 43758.5453);
    col += half((g - 0.5) * 0.02);

    outTex.write(half4(col, 1.0), gid);
}
