using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Experimental.Rendering;

#if UNITY_6000_0_OR_NEWER
using UnityEngine.Rendering.RenderGraphModule;
#endif

// Builds a Hi-Z min/max depth pyramid consumed by "HiZTracing()" in PathTracing.hlsl.
// Each pyramid texel stores (back-face raw depth bound, front-face raw depth bound) of
// its footprint, built from the existing "_CameraDepthAttachment" (front) and
// "_CameraBackDepthTexture" (back, published by BackfaceDepthPass) via fullscreen-triangle
// draws, one Init draw for mip 0 and one Downsample draw per further mip - mirroring the
// technique (not the code) of a proven working Hi-Z SSR implementation, adapted to this
// project's existing Blitter-based pass conventions.
public class HiZPyramidPass : ScriptableRenderPass
{
    // Must match HIZ_MAX_MIPS in PathTracingConfig.hlsl and the "_HiZMipInfo" array size.
    public const int HiZMaxMips = 12;

    private const int HiZInitPassIndex = 0;
    private const int HiZDownsamplePassIndex = 1;

    const string m_ProfilerTag = "Hi-Z Depth Pyramid";
    private readonly ProfilingSampler m_ProfilingSampler = new ProfilingSampler(m_ProfilerTag);

    public Material m_HiZMaterial;
    public int maxMipLevel = 8;
    public float pyramidResolutionScale = 1f;
    public float maxSteps = 32f;
    public float maxDistance = 50f;
    public bool hasBackfaceDepth;

    private readonly RTHandle[] m_MipHandles = new RTHandle[HiZMaxMips];
    private readonly Vector4[] m_MipInfos = new Vector4[HiZMaxMips];
    private Vector4 m_RealSizeInfo;
    private int m_LevelCount;

    // "_CameraDepthAttachment" is not a true global in this project - PathTracingPass only
    // ever sets it as a material-scoped override on its own material (see PathTracingPass'
    // OnCameraSetup/ExecutePass). Our Init pass uses a separate material, so it must bind
    // the same handle onto m_HiZMaterial itself to see the same depth data.
    private static readonly int _CameraDepthAttachmentId = Shader.PropertyToID("_CameraDepthAttachment");

    private static readonly int[] HiZMipTexIds = BuildMipTexIds();
    private static readonly int _HiZMipInfoId = Shader.PropertyToID("_HiZMipInfo");
    private static readonly int _HiZLevelCountId = Shader.PropertyToID("_HiZLevelCount");
    private static readonly int _HiZScreenSizeId = Shader.PropertyToID("_HiZScreenSize");
    private static readonly int _HiZMaxStepsId = Shader.PropertyToID("_HiZMaxSteps");
    private static readonly int _HiZMaxDistanceId = Shader.PropertyToID("_HiZMaxDistance");
    private static readonly int _SrcMipInfoId = Shader.PropertyToID("_SrcMipInfo");
    private static readonly int _DstMipInfoId = Shader.PropertyToID("_DstMipInfo");
    private static readonly int _BlitTextureId = Shader.PropertyToID("_BlitTexture");
    private static readonly int _BlitScaleBiasId = Shader.PropertyToID("_BlitScaleBias");
    private static readonly MaterialPropertyBlock s_PyramidPropertyBlock = new MaterialPropertyBlock();

    private static int[] BuildMipTexIds()
    {
        int[] ids = new int[HiZMaxMips];
        for (int i = 0; i < HiZMaxMips; i++)
            ids[i] = Shader.PropertyToID($"_HiZMip{i}");
        return ids;
    }

    private static GraphicsFormat GetHiZFormat()
    {
    #if UNITY_2023_2_OR_NEWER
        if (SystemInfo.IsFormatSupported(GraphicsFormat.R32G32_SFloat, GraphicsFormatUsage.Render))
            return GraphicsFormat.R32G32_SFloat;
    #else
        if (SystemInfo.IsFormatSupported(GraphicsFormat.R32G32_SFloat, FormatUsage.Render))
            return GraphicsFormat.R32G32_SFloat;
    #endif
        return GraphicsFormat.R16G16_SFloat;
    }

    private static int ComputeLevelCount(int width, int height, int maxLevels)
    {
        int maxDim = Mathf.Max(width, height);
        int levels = Mathf.FloorToInt(Mathf.Log(maxDim, 2)) + 1;
        return Mathf.Clamp(levels, 1, maxLevels);
    }

    // Computes the real (resolution-scaled) build size, the power-of-two padded base
    // canvas size, and the clamped mip level count for this frame. Shared by both the
    // legacy and Render Graph paths so their sizing can never drift apart.
    private void ComputeSizing(RenderTextureDescriptor cameraDesc, out int baseWidth, out int baseHeight)
    {
        int realWidth = Mathf.Max(1, Mathf.RoundToInt(cameraDesc.width * pyramidResolutionScale));
        int realHeight = Mathf.Max(1, Mathf.RoundToInt(cameraDesc.height * pyramidResolutionScale));
        m_RealSizeInfo = new Vector4(realWidth, realHeight, 1f / realWidth, 1f / realHeight);

        baseWidth = Mathf.NextPowerOfTwo(realWidth);
        baseHeight = Mathf.NextPowerOfTwo(realHeight);

        int clampedMaxLevel = Mathf.Clamp(maxMipLevel, 1, HiZMaxMips);
        m_LevelCount = ComputeLevelCount(baseWidth, baseHeight, clampedMaxLevel);
    }

    #region Non Render Graph Pass
    public override void OnCameraSetup(CommandBuffer cmd, ref RenderingData renderingData)
    {
        m_HiZMaterial.SetTexture(_CameraDepthAttachmentId, renderingData.cameraData.renderer.cameraDepthTargetHandle);

        ComputeSizing(renderingData.cameraData.cameraTargetDescriptor, out int baseWidth, out int baseHeight);
        GraphicsFormat format = GetHiZFormat();

        int w = baseWidth, h = baseHeight;
        for (int i = 0; i < m_LevelCount; i++)
        {
            m_MipInfos[i] = new Vector4(w, h, 1f / w, 1f / h);

            var desc = new RenderTextureDescriptor(w, h, format, 0)
            {
                msaaSamples = 1,
                useMipMap = false,
            };
            RenderingUtils.ReAllocateIfNeeded(ref m_MipHandles[i], desc, FilterMode.Point, TextureWrapMode.Clamp, name: $"_HiZPyramid_Mip{i}");

            w = Mathf.Max(1, w / 2);
            h = Mathf.Max(1, h / 2);
        }

        // Release levels no longer needed if maxMipLevel/resolution changed since last frame.
        for (int i = m_LevelCount; i < HiZMaxMips; i++)
        {
            m_MipHandles[i]?.Release();
            m_MipHandles[i] = null;
            m_MipInfos[i] = Vector4.zero;
        }

        ConfigureInput(ScriptableRenderPassInput.Depth);
    }

    public override void Execute(ScriptableRenderContext context, ref RenderingData renderingData)
    {
        CommandBuffer cmd = CommandBufferPool.Get();
        using (new ProfilingScope(cmd, m_ProfilingSampler))
        {
            CoreUtils.SetKeyword(m_HiZMaterial, "_HIZ_HAS_BACKFACE", hasBackfaceDepth);

            for (int i = 0; i < m_LevelCount; i++)
            {
                s_PyramidPropertyBlock.Clear();
                s_PyramidPropertyBlock.SetVector(_BlitScaleBiasId, new Vector4(1f, 1f, 0f, 0f));
                s_PyramidPropertyBlock.SetVector(_DstMipInfoId, m_MipInfos[i]);

                cmd.SetRenderTarget(m_MipHandles[i]);
                if (i == 0)
                {
                    s_PyramidPropertyBlock.SetVector(_SrcMipInfoId, m_RealSizeInfo);
                    cmd.DrawProcedural(Matrix4x4.identity, m_HiZMaterial, HiZInitPassIndex, MeshTopology.Triangles, 3, 1, s_PyramidPropertyBlock);
                }
                else
                {
                    s_PyramidPropertyBlock.SetVector(_SrcMipInfoId, m_MipInfos[i - 1]);
                    s_PyramidPropertyBlock.SetTexture(_BlitTextureId, m_MipHandles[i - 1]);
                    cmd.DrawProcedural(Matrix4x4.identity, m_HiZMaterial, HiZDownsamplePassIndex, MeshTopology.Triangles, 3, 1, s_PyramidPropertyBlock);
                }
            }

            for (int i = 0; i < m_LevelCount; i++)
                cmd.SetGlobalTexture(HiZMipTexIds[i], m_MipHandles[i]);

            cmd.SetGlobalVectorArray(_HiZMipInfoId, m_MipInfos);
            cmd.SetGlobalFloat(_HiZLevelCountId, m_LevelCount);
            cmd.SetGlobalVector(_HiZScreenSizeId, m_RealSizeInfo);
            cmd.SetGlobalFloat(_HiZMaxStepsId, maxSteps);
            cmd.SetGlobalFloat(_HiZMaxDistanceId, maxDistance);
        }
        context.ExecuteCommandBuffer(cmd);
        cmd.Clear();
        CommandBufferPool.Release(cmd);
    }
    #endregion

#if UNITY_6000_0_OR_NEWER
    #region Render Graph Pass
    private class InitPassData
    {
        internal Material material;
        internal Vector4 srcMipInfo;
        internal Vector4 dstMipInfo;
        internal bool hasBackfaceDepth;
        internal TextureHandle cameraDepthTargetHandle;
    }

    private class DownsamplePassData
    {
        internal Material material;
        internal Vector4 srcMipInfo;
        internal Vector4 dstMipInfo;
        internal TextureHandle srcMip;
    }

    static void ExecuteInitPass(InitPassData data, RasterGraphContext context)
    {
        CoreUtils.SetKeyword(data.material, "_HIZ_HAS_BACKFACE", data.hasBackfaceDepth);
        // "_CameraDepthAttachment" is not a true global in this project (see field comment
        // above) - bind it onto our own material the same way PathTracingPass binds it onto
        // its own, matching handles read through UniversalResourceData.activeDepthTexture.
        data.material.SetTexture(_CameraDepthAttachmentId, data.cameraDepthTargetHandle);

        s_PyramidPropertyBlock.Clear();
        s_PyramidPropertyBlock.SetVector(_BlitScaleBiasId, new Vector4(1f, 1f, 0f, 0f));
        s_PyramidPropertyBlock.SetVector(_SrcMipInfoId, data.srcMipInfo);
        s_PyramidPropertyBlock.SetVector(_DstMipInfoId, data.dstMipInfo);
        context.cmd.DrawProcedural(Matrix4x4.identity, data.material, HiZInitPassIndex, MeshTopology.Triangles, 3, 1, s_PyramidPropertyBlock);
    }

    static void ExecuteDownsamplePass(DownsamplePassData data, RasterGraphContext context)
    {
        s_PyramidPropertyBlock.Clear();
        s_PyramidPropertyBlock.SetVector(_BlitScaleBiasId, new Vector4(1f, 1f, 0f, 0f));
        s_PyramidPropertyBlock.SetVector(_SrcMipInfoId, data.srcMipInfo);
        s_PyramidPropertyBlock.SetVector(_DstMipInfoId, data.dstMipInfo);
        s_PyramidPropertyBlock.SetTexture(_BlitTextureId, data.srcMip);
        context.cmd.DrawProcedural(Matrix4x4.identity, data.material, HiZDownsamplePassIndex, MeshTopology.Triangles, 3, 1, s_PyramidPropertyBlock);
    }

    public override void RecordRenderGraph(RenderGraph renderGraph, ContextContainer frameData)
    {
        UniversalCameraData cameraData = frameData.Get<UniversalCameraData>();

        ComputeSizing(cameraData.cameraTargetDescriptor, out int baseWidth, out int baseHeight);
        GraphicsFormat format = GetHiZFormat();

        TextureHandle[] mips = new TextureHandle[m_LevelCount];

        int w = baseWidth, h = baseHeight;
        for (int i = 0; i < m_LevelCount; i++)
        {
            m_MipInfos[i] = new Vector4(w, h, 1f / w, 1f / h);

            var texDesc = new TextureDesc(w, h)
            {
                name = $"_HiZPyramid_Mip{i}",
                colorFormat = format,
                filterMode = FilterMode.Point,
                wrapMode = TextureWrapMode.Clamp,
                clearBuffer = false,
                useMipMap = false
            };
            mips[i] = renderGraph.CreateTexture(texDesc);

            if (i == 0)
            {
                UniversalResourceData resourceData = frameData.Get<UniversalResourceData>();

                using (var builder = renderGraph.AddRasterRenderPass<InitPassData>("HiZ Pyramid Init", out var passData))
                {
                    passData.material = m_HiZMaterial;
                    passData.srcMipInfo = m_RealSizeInfo;
                    passData.dstMipInfo = m_MipInfos[0];
                    passData.hasBackfaceDepth = hasBackfaceDepth;
                    passData.cameraDepthTargetHandle = resourceData.activeDepthTexture;

                    builder.UseTexture(passData.cameraDepthTargetHandle, AccessFlags.Read);
                    builder.SetRenderAttachment(mips[0], 0);
                    builder.SetGlobalTextureAfterPass(mips[0], HiZMipTexIds[0]);
                    builder.SetRenderFunc((InitPassData data, RasterGraphContext ctx) => ExecuteInitPass(data, ctx));
                }
            }
            else
            {
                using (var builder = renderGraph.AddRasterRenderPass<DownsamplePassData>($"HiZ Pyramid Mip {i}", out var passData))
                {
                    passData.material = m_HiZMaterial;
                    passData.srcMipInfo = m_MipInfos[i - 1];
                    passData.dstMipInfo = m_MipInfos[i];
                    passData.srcMip = mips[i - 1];

                    builder.UseTexture(mips[i - 1], AccessFlags.Read);
                    builder.SetRenderAttachment(mips[i], 0);
                    builder.SetGlobalTextureAfterPass(mips[i], HiZMipTexIds[i]);
                    builder.SetRenderFunc((DownsamplePassData data, RasterGraphContext ctx) => ExecuteDownsamplePass(data, ctx));
                }
            }

            w = Mathf.Max(1, w / 2);
            h = Mathf.Max(1, h / 2);
        }

        for (int i = m_LevelCount; i < HiZMaxMips; i++)
            m_MipInfos[i] = Vector4.zero;

        // Plain scalar/vector globals carry no GPU resource-lifetime concerns (unlike the
        // per-mip textures above, which must be published via SetGlobalTextureAfterPass so
        // Render Graph knows to keep their pooled resource alive), so they can be set
        // directly here rather than via a dedicated pass.
        Shader.SetGlobalVectorArray(_HiZMipInfoId, m_MipInfos);
        Shader.SetGlobalFloat(_HiZLevelCountId, m_LevelCount);
        Shader.SetGlobalVector(_HiZScreenSizeId, m_RealSizeInfo);
        Shader.SetGlobalFloat(_HiZMaxStepsId, maxSteps);
        Shader.SetGlobalFloat(_HiZMaxDistanceId, maxDistance);
    }
    #endregion
#endif

    #region Shared
    public void Dispose()
    {
        for (int i = 0; i < HiZMaxMips; i++)
        {
            m_MipHandles[i]?.Release();
            m_MipHandles[i] = null;
        }
    }
    #endregion
}
