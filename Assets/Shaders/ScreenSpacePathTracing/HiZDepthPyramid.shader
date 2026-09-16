Shader "Hidden/Universal Render Pipeline/HiZ Depth Pyramid"
{
    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" }
        ZWrite Off ZTest Always Cull Off

        HLSLINCLUDE
        #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"
        #include "Packages/com.unity.render-pipelines.core/Runtime/Utilities/Blit.hlsl"
        #include "./PathTracingConfig.hlsl" // MARCHING_THICKNESS, HIZ_MAX_MIPS
        #include "./PathTracingInput.hlsl"  // _CameraDepthAttachment / _CameraBackDepthTexture + samplers, _HiZMip* (unused here)

        // Init: xy/zw = real (unpadded, resolution-scaled) build size / reciprocal.
        // Downsample: xy/zw = size / reciprocal of the level being READ (mip N-1).
        float4 _SrcMipInfo;
        // Init: xy/zw = padded power-of-two mip0 canvas size / reciprocal.
        // Downsample: xy/zw = size / reciprocal of the level being WRITTEN (mip N).
        float4 _DstMipInfo;

        float NoOccluderDepth()
        {
            return (UNITY_REVERSED_Z) ? 0.0 : 1.0;
        }

        // Inverse of URP's LinearEyeDepth(depth, zBufferParam) = 1 / (zBufferParam.z * depth + zBufferParam.w).
        float RawDepthFromLinearEyeDepth(float linearEyeDepth, float4 zBufferParam)
        {
            return (rcp(max(linearEyeDepth, 1e-4)) - zBufferParam.w) / zBufferParam.z;
        }

        float2 InitFrag(Varyings input) : SV_Target
        {
            uint2 pixel = (uint2)(input.texcoord * _DstMipInfo.xy);
            uint2 realSize = (uint2)_SrcMipInfo.xy;

            if (pixel.x >= realSize.x || pixel.y >= realSize.y)
            {
                float sentinel = NoOccluderDepth();
                return float2(sentinel, sentinel);
            }

            float2 uv = (pixel + 0.5) * _SrcMipInfo.zw;
            float dFront = SAMPLE_TEXTURE2D_X_LOD(_CameraDepthAttachment, sampler_CameraDepthAttachment, uv, 0).r;

            float dBack;
        #if defined(_HIZ_HAS_BACKFACE)
            dBack = SAMPLE_TEXTURE2D_X_LOD(_CameraBackDepthTexture, sampler_CameraBackDepthTexture, uv, 0).r;
        #else
            // No real back-face pass this frame (Accurate Thickness == Disable): synthesize a finite
            // fallback thickness matching RayMarching's own MARCHING_THICKNESS heuristic, so behavior
            // stays consistent with the naive ray marching path in this mode.
            if (dFront == UNITY_RAW_FAR_CLIP_VALUE)
            {
                dBack = NoOccluderDepth();
            }
            else
            {
                float frontLinear = LinearEyeDepth(dFront, _ZBufferParams);
                dBack = RawDepthFromLinearEyeDepth(frontLinear + MARCHING_THICKNESS, _ZBufferParams);
            }
        #endif
            return float2(dBack, dFront);
        }

        float2 SampleSrcTexel(uint2 texel)
        {
            float2 uv = (texel + 0.5) * _SrcMipInfo.zw;
            return SAMPLE_TEXTURE2D_LOD(_BlitTexture, my_point_clamp_sampler, uv, 0).rg;
        }

        float2 DownsampleFrag(Varyings input) : SV_Target
        {
            uint2 dstSize = (uint2)_DstMipInfo.xy;
            uint2 dstTexel = min((uint2)(input.texcoord * dstSize), dstSize - 1);
            uint2 baseTexel = dstTexel * 2;

            // The base canvas is power-of-two and every level exactly halves the previous one,
            // so this plain 2x2 tap is always fully in-bounds - no clamping or guard taps needed.
            float2 r00 = SampleSrcTexel(baseTexel + uint2(0, 0));
            float2 r10 = SampleSrcTexel(baseTexel + uint2(1, 0));
            float2 r01 = SampleSrcTexel(baseTexel + uint2(0, 1));
            float2 r11 = SampleSrcTexel(baseTexel + uint2(1, 1));

        #if UNITY_REVERSED_Z
            float farthestBack = min(min(r00.x, r10.x), min(r01.x, r11.x));
            float nearestFront = max(max(r00.y, r10.y), max(r01.y, r11.y));
        #else
            float farthestBack = max(max(r00.x, r10.x), max(r01.x, r11.x));
            float nearestFront = min(min(r00.y, r10.y), min(r01.y, r11.y));
        #endif
            return float2(farthestBack, nearestFront);
        }
        ENDHLSL

        Pass
        {
            Name "Init"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment InitFrag
            #pragma multi_compile_local_fragment _ _HIZ_HAS_BACKFACE
            ENDHLSL
        }

        Pass
        {
            Name "Downsample"

            HLSLPROGRAM
            #pragma vertex Vert
            #pragma fragment DownsampleFrag
            ENDHLSL
        }
    }
}
