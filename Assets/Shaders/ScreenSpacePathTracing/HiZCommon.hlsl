#ifndef URP_SCREEN_SPACE_PATH_TRACING_HIZ_COMMON_HLSL
#define URP_SCREEN_SPACE_PATH_TRACING_HIZ_COMMON_HLSL

// Hi-Z depth pyramid.
// Each texel stores float2(x = back-face raw device depth bound, y = front-face raw device depth bound)
// of its footprint: "x" is reduced towards the farthest possible exit depth in the cell,
// "y" towards the nearest possible entry depth. Every mip is a separate texture (not a real
// mip chain), because HLSL cannot dynamically index separate texture bindings.
TEXTURE2D(_HiZMip0);
TEXTURE2D(_HiZMip1);
TEXTURE2D(_HiZMip2);
TEXTURE2D(_HiZMip3);
TEXTURE2D(_HiZMip4);
TEXTURE2D(_HiZMip5);
TEXTURE2D(_HiZMip6);
TEXTURE2D(_HiZMip7);
TEXTURE2D(_HiZMip8);
TEXTURE2D(_HiZMip9);
TEXTURE2D(_HiZMip10);
TEXTURE2D(_HiZMip11);

float  _HiZLevelCount;              // Levels actually built this frame (<= HIZ_MAX_MIPS).
float4 _HiZMipInfo[HIZ_MAX_MIPS];   // xy = resolution (texels), zw = 1 / resolution, per mip.
float4 _HiZScreenSize;              // Real (unpadded, scale-applied) pyramid build resolution. xy = size, zw = 1 / size.
float  _HiZMaxSteps;                // Maximum Hi-Z traversal iterations (further clamped by HIZ_MAX_ITER).
float  _HiZMaxDistance;             // Maximum world-space ray distance (in meters) traced via Hi-Z.

// Samples a given Hi-Z pyramid level. Returns (back, front) raw device depth bounds.
float2 SampleHiZLevel(float2 uv, int level)
{
    float4 texel;
    if      (level == 0)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip0,  my_point_clamp_sampler, uv, 0);
    else if (level == 1)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip1,  my_point_clamp_sampler, uv, 0);
    else if (level == 2)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip2,  my_point_clamp_sampler, uv, 0);
    else if (level == 3)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip3,  my_point_clamp_sampler, uv, 0);
    else if (level == 4)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip4,  my_point_clamp_sampler, uv, 0);
    else if (level == 5)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip5,  my_point_clamp_sampler, uv, 0);
    else if (level == 6)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip6,  my_point_clamp_sampler, uv, 0);
    else if (level == 7)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip7,  my_point_clamp_sampler, uv, 0);
    else if (level == 8)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip8,  my_point_clamp_sampler, uv, 0);
    else if (level == 9)  texel = SAMPLE_TEXTURE2D_LOD(_HiZMip9,  my_point_clamp_sampler, uv, 0);
    else if (level == 10) texel = SAMPLE_TEXTURE2D_LOD(_HiZMip10, my_point_clamp_sampler, uv, 0);
    else                   texel = SAMPLE_TEXTURE2D_LOD(_HiZMip11, my_point_clamp_sampler, uv, 0);
    return texel.rg;
}

#endif
