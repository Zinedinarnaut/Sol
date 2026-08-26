#nullable enable

using System;
using System.Buffers;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace Ryujinx.Headless;

internal static unsafe class SolMetalNativeBridge
{
    private const uint AbiVersion = 2;
    private const uint ValidationAll = (1u << 15) - 1;
    private const uint NativeTextureClearRegion = 1u << 0;
    private const uint NativeTextureClearRawColorBits = 1u << 1;
    private const uint NativePresentFlipX = 1u << 0;
    private const uint NativePresentFlipY = 1u << 1;
    private const int DeviceNameCapacity = 256;
    private const int ErrorCapacity = 512;
    private const int BootstrapTextureWidth = 640;
    private const int BootstrapTextureHeight = 360;

    private static readonly Lazy<LoadResult> Loaded = new(
        Load,
        LazyThreadSafetyMode.ExecutionAndPublication
    );

    internal sealed class ProbeResult
    {
        public required bool Success { get; init; }
        public required bool Playable { get; init; }
        public required uint AbiVersion { get; init; }
        public string? DeviceName { get; init; }
        public uint AppleGpuFamily { get; init; }
        public uint ArgumentBufferTier { get; init; }
        public bool HasUnifiedMemory { get; init; }
        public bool SupportsBcTextureCompression { get; init; }
        public bool SupportsRayTracing { get; init; }
        public bool SupportsBinaryArchives { get; init; }
        public bool SupportsLayeredVertexOutput { get; init; }
        public bool SpirvTranslationReady { get; init; }
        public bool BufferResourcesReady { get; init; }
        public bool TextureResourcesReady { get; init; }
        public bool SamplerResourcesReady { get; init; }
        public bool ComputePipelinesReady { get; init; }
        public bool RenderPipelinesReady { get; init; }
        public bool RenderBindingsReady { get; init; }
        public bool IndexedDrawingReady { get; init; }
        public bool DepthStencilReady { get; init; }
        public bool BlendingReady { get; init; }
        public bool RasterizerStateReady { get; init; }
        public bool TimelineSynchronizationReady { get; init; }
        public ulong RecommendedWorkingSetBytes { get; init; }
        public uint TestsRun { get; init; }
        public uint TestsPassed { get; init; }
        public ulong BytesVerified { get; init; }
        public uint ShaderCacheHits { get; init; }
        public uint ShaderCacheMisses { get; init; }
        public uint BinaryArchivesCreated { get; init; }
        public double GpuMilliseconds { get; init; }
        public string? OutputSignature { get; init; }
        public string? Failure { get; init; }
    }

    public static ProbeResult Probe()
    {
        LoadResult loaded = Loaded.Value;
        if (loaded.Api is null)
        {
            return Failed(loaded.Error ?? "SolMetal could not be loaded.");
        }

        Api api = loaded.Api;
        IntPtr context = IntPtr.Zero;

        try
        {
            NativeStatus status = api.ContextCreate(&context);
            if (status != NativeStatus.Ok || context == IntPtr.Zero)
            {
                return Failed($"Context creation failed: {api.StatusText(status)}");
            }

            NativeCapabilities capabilities = default;
            capabilities.StructSize = (uint)sizeof(NativeCapabilities);
            status = api.ContextQueryCapabilities(context, &capabilities);
            if (status != NativeStatus.Ok)
            {
                return Failed($"Capability query failed: {api.StatusText(status)}");
            }
            if (capabilities.AbiVersion != AbiVersion)
            {
                return Failed(
                    $"SolMetal returned ABI {capabilities.AbiVersion}; Sol Engine requires ABI {AbiVersion}."
                );
            }

            NativeValidationReport report = default;
            report.StructSize = (uint)sizeof(NativeValidationReport);
            status = api.ContextRunValidation(
                context,
                ValidationAll,
                1,
                &report
            );
            if (status != NativeStatus.Ok ||
                report.TestsRun != report.TestsPassed ||
                report.ShaderCacheHits == 0 ||
                report.ShaderCacheMisses == 0 ||
                report.BinaryArchivesCreated != 1)
            {
                string detail = ReadUtf8(report.LastError, ErrorCapacity);
                return Failed(
                    string.IsNullOrWhiteSpace(detail)
                        ? $"Validation failed: {api.StatusText(status)}"
                        : detail
                );
            }

            return new ProbeResult
            {
                Success = true,
                // SolMetal is a validated native foundation, not yet a full
                // implementation of Ryujinx.Graphics.GAL.IRenderer.
                Playable = false,
                AbiVersion = capabilities.AbiVersion,
                DeviceName = ReadUtf8(capabilities.DeviceName, DeviceNameCapacity),
                AppleGpuFamily = capabilities.AppleGpuFamily,
                ArgumentBufferTier = capabilities.ArgumentBufferTier,
                HasUnifiedMemory = capabilities.HasUnifiedMemory != 0,
                SupportsBcTextureCompression =
                    capabilities.SupportsBcTextureCompression != 0,
                SupportsRayTracing = capabilities.SupportsRayTracing != 0,
                SupportsBinaryArchives = capabilities.SupportsBinaryArchives != 0,
                SupportsLayeredVertexOutput =
                    capabilities.SupportsLayeredVertexOutput != 0,
                SpirvTranslationReady =
                    (report.CompletedFlags & (1u << 7)) != 0,
                BufferResourcesReady =
                    (report.CompletedFlags & (1u << 8)) != 0,
                TextureResourcesReady =
                    (report.CompletedFlags & (1u << 9)) != 0,
                SamplerResourcesReady =
                    (report.CompletedFlags & (1u << 10)) != 0,
                ComputePipelinesReady =
                    (report.CompletedFlags & (1u << 10)) != 0,
                RenderPipelinesReady =
                    (report.CompletedFlags & (1u << 11)) != 0,
                RenderBindingsReady =
                    (report.CompletedFlags & (1u << 12)) != 0,
                IndexedDrawingReady =
                    (report.CompletedFlags & (1u << 12)) != 0,
                DepthStencilReady =
                    (report.CompletedFlags & (1u << 13)) != 0,
                BlendingReady =
                    (report.CompletedFlags & (1u << 13)) != 0,
                RasterizerStateReady =
                    (report.CompletedFlags & (1u << 11)) != 0,
                TimelineSynchronizationReady =
                    (report.CompletedFlags & (1u << 14)) != 0,
                RecommendedWorkingSetBytes = capabilities.RecommendedMaxWorkingSetSize,
                TestsRun = report.TestsRun,
                TestsPassed = report.TestsPassed,
                BytesVerified = report.BytesVerified,
                ShaderCacheHits = report.ShaderCacheHits,
                ShaderCacheMisses = report.ShaderCacheMisses,
                BinaryArchivesCreated = report.BinaryArchivesCreated,
                GpuMilliseconds = report.GpuTimeNanoseconds / 1_000_000.0,
                OutputSignature = report.OutputSignature.ToString("x16"),
            };
        }
        catch (Exception exception)
        {
            return Failed($"SolMetal probe failed safely: {exception.Message}");
        }
        finally
        {
            if (context != IntPtr.Zero)
            {
                api.ContextDestroy(context);
            }
        }
    }

    public static bool TryPresentBootstrapFrame(
        nint metalLayer,
        int pixelWidth,
        int pixelHeight,
        out string? failure
    )
    {
        failure = null;
        LoadResult loaded = Loaded.Value;
        if (loaded.Api is null)
        {
            failure = loaded.Error ?? "SolMetal could not be loaded.";
            return false;
        }
        if (metalLayer == 0 || pixelWidth <= 0 || pixelHeight <= 0)
        {
            failure = "The SolMetal bootstrap frame received an invalid surface.";
            return false;
        }

        Api api = loaded.Api;
        IntPtr context = IntPtr.Zero;
        IntPtr texture = IntPtr.Zero;
        try
        {
            NativeStatus status = api.ContextCreate(&context);
            if (status != NativeStatus.Ok || context == IntPtr.Zero)
            {
                failure = $"Context creation failed: {api.StatusText(status)}";
                return false;
            }

            NativeTextureDescriptor textureDescriptor = default;
            textureDescriptor.StructSize = (uint)sizeof(NativeTextureDescriptor);
            textureDescriptor.AbiVersion = AbiVersion;
            textureDescriptor.Width = BootstrapTextureWidth;
            textureDescriptor.Height = BootstrapTextureHeight;
            textureDescriptor.PixelFormat = NativeTexturePixelFormat.Bgra8Unorm;
            textureDescriptor.StorageMode = NativeBufferStorageMode.Private;
            textureDescriptor.Usage = NativeTextureUsage.Sampled;
            status = api.TextureCreate(context, &textureDescriptor, &texture);
            if (status != NativeStatus.Ok || texture == IntPtr.Zero)
            {
                failure = $"Bootstrap texture creation failed: {api.StatusText(status)}";
                return false;
            }

            byte[] pixels = BuildBootstrapPixels();
            fixed (byte* source = pixels)
            {
                status = api.TextureUpload(
                    context,
                    texture,
                    source,
                    BootstrapTextureWidth * 4u,
                    checked((ulong)pixels.LongLength)
                );
            }
            if (status != NativeStatus.Ok)
            {
                failure = $"Bootstrap texture upload failed: {api.StatusText(status)}";
                return false;
            }

            NativePresentTextureDescriptor presentDescriptor = default;
            presentDescriptor.StructSize =
                (uint)sizeof(NativePresentTextureDescriptor);
            presentDescriptor.AbiVersion = AbiVersion;
            presentDescriptor.SourceTexture = texture;
            // AppKit can settle a resize between Swift's surface measurement
            // and this call. Zero asks SolMetal to use the actual drawable
            // dimensions it acquires instead of racing that layout update.
            presentDescriptor.PixelWidth = 0;
            presentDescriptor.PixelHeight = 0;
            presentDescriptor.Filter = NativeSamplerFilter.Linear;
            status = api.PresentTexture(
                context,
                metalLayer,
                &presentDescriptor
            );
            if (status != NativeStatus.Ok)
            {
                failure = $"Bootstrap presentation failed: {api.StatusText(status)}";
                return false;
            }
            return true;
        }
        catch (Exception exception)
        {
            failure = $"SolMetal bootstrap failed safely: {exception.Message}";
            return false;
        }
        finally
        {
            if (texture != IntPtr.Zero)
            {
                api.TextureDestroy(texture);
            }
            if (context != IntPtr.Zero)
            {
                api.ContextDestroy(context);
            }
        }
    }

    internal static bool TryCreateGalSession(
        out IGalSession? session,
        out string? failure
    )
    {
        session = null;
        failure = null;
        LoadResult loaded = Loaded.Value;
        if (loaded.Api is null)
        {
            failure = loaded.Error ?? "SolMetal could not be loaded.";
            return false;
        }

        Api api = loaded.Api;
        IntPtr context = IntPtr.Zero;
        try
        {
            NativeStatus status = api.ContextCreate(&context);
            if (status != NativeStatus.Ok || context == IntPtr.Zero)
            {
                failure = $"Context creation failed: {api.StatusText(status)}";
                return false;
            }

            NativeCapabilities capabilities = default;
            capabilities.StructSize = (uint)sizeof(NativeCapabilities);
            status = api.ContextQueryCapabilities(context, &capabilities);
            if (status != NativeStatus.Ok || capabilities.AbiVersion != AbiVersion)
            {
                failure = $"Capability query failed: {api.StatusText(status)}";
                return false;
            }

            session = new GalSession(
                api,
                context,
                ReadUtf8(capabilities.DeviceName, DeviceNameCapacity),
                capabilities.RecommendedMaxWorkingSetSize,
                capabilities.MaxBufferLength,
                capabilities.MaxThreadsPerThreadgroup,
                capabilities.ArgumentBufferTier,
                capabilities.SupportsBcTextureCompression != 0,
                capabilities.SupportsLayeredVertexOutput != 0
            );
            context = IntPtr.Zero;
            return true;
        }
        catch (Exception exception)
        {
            failure = $"SolMetal GAL session failed safely: {exception.Message}";
            return false;
        }
        finally
        {
            if (context != IntPtr.Zero)
            {
                api.ContextDestroy(context);
            }
        }
    }

    internal interface IGalSession : IDisposable
    {
        string DeviceName { get; }
        ulong RecommendedWorkingSetBytes { get; }
        ulong MaxBufferLength { get; }
        uint MaxThreadsPerThreadgroup { get; }
        uint ArgumentBufferTier { get; }
        bool SupportsBcTextureCompression { get; }
        bool SupportsLayeredVertexOutput { get; }
        bool SupportsDepth32ProbeReadback { get; }
        bool SupportsDepthStencilReadback { get; }

        IntPtr CreateBuffer(int size, bool deviceLocal);
        void DestroyBuffer(IntPtr buffer);
        void UploadBuffer(IntPtr buffer, int offset, ReadOnlySpan<byte> data);
        void DownloadBuffer(IntPtr buffer, int offset, Span<byte> data);
        void CopyBuffer(
            IntPtr source,
            int sourceOffset,
            IntPtr destination,
            int destinationOffset,
            int size
        );
        void FillBuffer(IntPtr buffer, int offset, int size, uint value);
        void ExpandQuadIndices(
            IntPtr source,
            int sourceOffset,
            GalIndexType sourceIndexType,
            int quadCount,
            IntPtr destination,
            int destinationOffset
        );
        IntPtr CreateTexture(
            int width,
            int height,
            GalTextureType type,
            int depthOrArrayLength,
            int mipmapLevelCount,
            int sampleCount,
            GalTextureFormat format,
            GalTextureSwizzle red,
            GalTextureSwizzle green,
            GalTextureSwizzle blue,
            GalTextureSwizzle alpha,
            bool depthStencil
        );
        IntPtr CreateBufferTexture(
            IntPtr buffer,
            int offset,
            int size,
            int width,
            GalTextureFormat format,
            GalTextureSwizzle red,
            GalTextureSwizzle green,
            GalTextureSwizzle blue,
            GalTextureSwizzle alpha
        );
        IntPtr CreateTextureView(
            IntPtr source,
            GalTextureFormat format,
            GalTextureSwizzle red,
            GalTextureSwizzle green,
            GalTextureSwizzle blue,
            GalTextureSwizzle alpha,
            GalTextureType type,
            int firstLevel,
            int levelCount,
            int firstSlice,
            int sliceCount
        );
        void DestroyTexture(IntPtr texture);
        void UploadTexture(
            IntPtr texture,
            ReadOnlySpan<byte> data,
            int bytesPerRow
        );
        void DownloadTexture(IntPtr texture, Span<byte> data, int bytesPerRow);
        void DownloadDepth32Probe(
            IntPtr texture,
            Span<byte> data,
            int bytesPerRow
        );
        void DownloadDepthStencilSubresource(
            IntPtr texture,
            int sourceSlice,
            int sourceLevel,
            Span<byte> data,
            int bytesPerRow
        );
        void CopyTextureToBuffer(
            IntPtr texture,
            int sourceSlice,
            int sourceLevel,
            IntPtr destination,
            int destinationOffset,
            int destinationSize,
            int destinationBytesPerRow
        );
        void CopyTexture(IntPtr source, IntPtr destination);
        void CopyTextureSubresource(
            IntPtr source,
            IntPtr destination,
            int sourceSlice,
            int destinationSlice,
            int sourceLevel,
            int destinationLevel,
            int width,
            int height
        );
        void CopyDepth32ToR32Float(
            IntPtr source,
            IntPtr destination,
            int sourceSlice,
            int destinationSlice,
            int sourceLevel,
            int destinationLevel,
            int width,
            int height
        );
        void CopyR32FloatToDepth32(
            IntPtr source,
            IntPtr destination,
            int sourceSlice,
            int destinationSlice,
            int sourceLevel,
            int destinationLevel,
            int width,
            int height
        );
        void ClearColorTexture(
            IntPtr texture,
            int firstSlice,
            int sliceCount,
            uint componentMask,
            int clearX,
            int clearY,
            int clearWidth,
            int clearHeight,
            double red,
            double green,
            double blue,
            double alpha,
            uint redBits,
            uint greenBits,
            uint blueBits,
            uint alphaBits
        );
        void ClearDepthStencilTexture(
            IntPtr texture,
            int firstSlice,
            int sliceCount,
            bool depthMask,
            int stencilMask,
            int clearX,
            int clearY,
            int clearWidth,
            int clearHeight,
            double depth,
            uint stencil
        );
        void BlitTexture(
            IntPtr source,
            IntPtr destination,
            int sourceSlice,
            int sourceLevel,
            int destinationSlice,
            int destinationLevel,
            int sourceX1,
            int sourceY1,
            int sourceX2,
            int sourceY2,
            int destinationX1,
            int destinationY1,
            int destinationX2,
            int destinationY2,
            bool linearFilter
        );
        void PresentTexture(
            nint metalLayer,
            IntPtr texture,
            int sourceLeft,
            int sourceTop,
            int sourceRight,
            int sourceBottom,
            float aspectRatioX,
            float aspectRatioY,
            bool flipX,
            bool flipY
        );
        IntPtr CreateSampler(GalSamplerDescriptor descriptor);
        void DestroySampler(IntPtr sampler);
        GalRenderProgramHandle CreateRenderProgram(
            ReadOnlySpan<byte> vertexSpirv,
            ReadOnlySpan<byte> fragmentSpirv,
            ReadOnlySpan<GalSpirvResourceBinding> vertexResourceBindings,
            ReadOnlySpan<GalSpirvResourceBinding> fragmentResourceBindings,
            uint vertexArgumentBufferSetMask = 0,
            uint fragmentArgumentBufferSetMask = 0
        );
        GalRenderProgramHandle CreateRenderProgramWithoutPointSize(
            GalRenderProgramHandle baseProgram,
            ReadOnlySpan<byte> vertexSpirv,
            ReadOnlySpan<GalSpirvResourceBinding> vertexResourceBindings,
            uint vertexArgumentBufferSetMask = 0
        );
        string CopyShaderMsl(IntPtr translation);
        void DestroyRenderProgram(GalRenderProgramHandle program);
        IntPtr CreateComputePipeline(
            ReadOnlySpan<byte> computeSpirv,
            ReadOnlySpan<GalSpirvResourceBinding> resourceBindings
        );
        void DestroyComputePipeline(IntPtr pipeline);
        void DispatchCompute(
            IntPtr pipeline,
            uint threadCountX,
            uint threadCountY,
            uint threadCountZ,
            uint threadgroupSizeX,
            uint threadgroupSizeY,
            uint threadgroupSizeZ,
            GalStageBindings bindings
        );
        IntPtr CreateRenderPipeline(
            GalRenderProgramHandle program,
            GalRenderPipelineState state,
            ReadOnlySpan<GalVertexBufferLayout> vertexBufferLayouts,
            ReadOnlySpan<GalVertexAttribute> vertexAttributes
        );
        void DestroyRenderPipeline(IntPtr pipeline);
        void Draw(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndexBinding? indexBinding
        );
        void DrawIndirect(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndirectBinding indirectBinding,
            GalIndexBinding? indexBinding
        );
        void DrawIndirectCount(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndirectBinding indirectBinding,
            GalIndirectCountBinding countBinding,
            GalIndexBinding? indexBinding
        );
        ulong DrawWithVisibility(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndexBinding? indexBinding
        );
        IntPtr CreateVisibilityQuery();
        void DestroyVisibilityQuery(IntPtr query);
        void DrawWithVisibilityQuery(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndexBinding? indexBinding,
            IntPtr query
        );
        ulong ResolveVisibilityQuery(IntPtr query);
        void MemoryBarrier();
        ulong SubmitTimeline();
        TimelineSnapshot QueryTimeline();
        RuntimeBatchSnapshot? QueryRuntimeBatch();
        bool WaitTimeline(ulong value, TimeSpan timeout);
        bool WaitIdle(TimeSpan timeout);
    }

    internal enum GalTextureFormat : int
    {
        Rgba8Unorm = 1,
        Bgra8Unorm = 2,
        R32Uint = 3,
        Rgba16Float = 4,
        Depth32Float = 5,
        Depth32FloatStencil8 = 6,
        R8Unorm = 7,
        Rg8Unorm = 8,
        R16Unorm = 9,
        Rg16Unorm = 10,
        R16Float = 11,
        Rg16Float = 12,
        R32Float = 13,
        Rg32Float = 14,
        Rgba32Float = 15,
        Rgba8Srgb = 16,
        Bgra8Srgb = 17,
        R32Sint = 18,
        Rg16Snorm = 19,
        R8Uint = 20,
        Rg11B10Float = 21,
        D24UnormStencil8 = 22,
        Bc1RgbaUnorm = 23,
        Bc1RgbaSrgb = 24,
        Bc2RgbaUnorm = 25,
        Bc2RgbaSrgb = 26,
        Bc3RgbaUnorm = 27,
        Bc3RgbaSrgb = 28,
        Bc4RUnorm = 29,
        Bc4RSnorm = 30,
        Bc5RgUnorm = 31,
        Bc5RgSnorm = 32,
        Bc6hRgbFloat = 33,
        Bc6hRgbUfloat = 34,
        Bc7RgbaUnorm = 35,
        Bc7RgbaSrgb = 36,
        Rgb10A2Unorm = 37,
        Rgb10A2Uint = 38,
        Rgb9E5Float = 39,
        Bgr10A2Unorm = 40,
        Rgba32Uint = 41,
        Depth16Unorm = 42,
        Rgba16Uint = 43,
        Rgba16Unorm = 44,
    }

    internal enum GalTextureType : int
    {
        Texture2D = 1,
        Texture2DArray = 2,
        Texture3D = 3,
        TextureCube = 4,
        TextureCubeArray = 5,
        TextureBuffer = 6,
    }

    internal enum GalTextureSwizzle : int
    {
        Zero = 0,
        One = 1,
        Red = 2,
        Green = 3,
        Blue = 4,
        Alpha = 5,
    }

    internal enum GalSamplerFilter : int
    {
        Nearest = 1,
        Linear = 2,
    }

    internal enum GalSamplerMipFilter : int
    {
        NotMipmapped = 1,
        Nearest = 2,
        Linear = 3,
    }

    internal enum GalSamplerAddressMode : int
    {
        ClampToEdge = 1,
        Repeat = 2,
        MirrorRepeat = 3,
        ClampToZero = 4,
        ClampToBorder = 5,
    }

    internal enum GalSamplerBorderColor : int
    {
        TransparentBlack = 0,
        OpaqueBlack = 1,
        OpaqueWhite = 2,
    }

    internal readonly record struct GalSamplerDescriptor(
        GalSamplerFilter MinFilter,
        GalSamplerFilter MagFilter,
        GalSamplerMipFilter MipFilter,
        GalSamplerAddressMode AddressU,
        GalSamplerAddressMode AddressV,
        GalSamplerAddressMode AddressW,
        uint MaxAnisotropy,
        float MinLod,
        float MaxLod,
        GalSamplerBorderColor BorderColor,
        bool CompareEnabled,
        GalCompareFunction CompareFunction,
        float LodBias
    );

    internal readonly record struct GalSpirvResourceBinding(
        uint DescriptorSet,
        uint Binding,
        uint MetalBuffer,
        uint MetalTexture,
        uint MetalSampler,
        uint ArraySize
    );

    internal enum GalVertexFormat : int
    {
        Float = 1,
        Float2 = 2,
        Float3 = 3,
        Float4 = 4,
        Half2 = 5,
        Half4 = 6,
        Uchar4Normalized = 7,
        Char4Normalized = 8,
        Ushort2Normalized = 9,
        Ushort4Normalized = 10,
        Uint = 11,
        Uint2 = 12,
        Uint4 = 13,
        Int1010102Normalized = 14,
        Uint1010102Normalized = 15,
        Uchar2Normalized = 16,
        Char2Normalized = 17,
        Uchar3Normalized = 18,
        Char3Normalized = 19,
        Uchar2 = 20,
        Uchar3 = 21,
        Uchar4 = 22,
        Char2 = 23,
        Char3 = 24,
        Char4 = 25,
        Ushort2 = 26,
        Ushort3 = 27,
        Ushort4 = 28,
        Short2 = 29,
        Short3 = 30,
        Short4 = 31,
        Short2Normalized = 32,
        Short3Normalized = 33,
        Short4Normalized = 34,
        Half3 = 35,
        Int = 36,
        Int2 = 37,
        Int3 = 38,
        Int4 = 39,
        Uint3 = 40,
        Uchar = 41,
        Char = 42,
        UcharNormalized = 43,
        CharNormalized = 44,
        Ushort = 45,
        Short = 46,
        UshortNormalized = 47,
        ShortNormalized = 48,
        Half = 49,
        FloatRg11B10 = 50,
        FloatRgb9E5 = 51,
        Ushort3Normalized = 52,
    }

    internal enum GalVertexStepFunction : int
    {
        PerVertex = 1,
        PerInstance = 2,
        Constant = 3,
    }

    internal enum GalIndexType : int
    {
        Uint16 = 1,
        Uint32 = 2,
        Uint8 = 3,
    }

    internal readonly record struct GalVertexBufferLayout(
        uint BufferIndex,
        uint Stride,
        GalVertexStepFunction StepFunction,
        uint StepRate
    );

    internal readonly record struct GalVertexAttribute(
        uint Location,
        uint BufferIndex,
        GalVertexFormat Format,
        uint Offset
    );

    internal readonly record struct GalBufferBinding(
        uint Index,
        IntPtr Buffer,
        ulong Offset,
        uint ArgumentBuffer = 0
    );

    internal readonly record struct GalTextureBinding(
        uint Index,
        IntPtr Texture,
        uint ArgumentBuffer = 0
    );
    internal readonly record struct GalSamplerBinding(
        uint Index,
        IntPtr Sampler,
        uint ArgumentBuffer = 0
    );

    internal readonly record struct GalStageBindings(
        GalBufferBinding[] Buffers,
        GalTextureBinding[] Textures,
        GalSamplerBinding[] Samplers
    )
    {
        public static GalStageBindings Empty { get; } = new([], [], []);
    }

    internal readonly record struct GalIndexBinding(
        IntPtr Buffer,
        ulong Offset,
        GalIndexType Type,
        int BaseVertex,
        uint BaseInstance
    );

    internal readonly record struct GalIndirectBinding(
        IntPtr Buffer,
        ulong Offset,
        ulong Size
    );

    internal readonly record struct GalIndirectCountBinding(
        IntPtr Buffer,
        ulong Offset,
        ulong Size,
        uint MaxDrawCount,
        uint Stride
    );

    internal enum GalPrimitiveType : int
    {
        Point = 1,
        Line = 2,
        LineStrip = 3,
        Triangle = 4,
        TriangleStrip = 5,
    }

    internal enum GalPrimitiveTopologyClass : int
    {
        Unspecified = 0,
        Point = 1,
        Line = 2,
        Triangle = 3,
    }

    internal enum GalRenderLoadAction : int
    {
        DontCare = 1,
        Load = 2,
        Clear = 3,
    }

    internal enum GalRenderStoreAction : int
    {
        DontCare = 1,
        Store = 2,
    }

    internal enum GalCompareFunction : int
    {
        Never = 1,
        Less = 2,
        Equal = 3,
        LessEqual = 4,
        Greater = 5,
        NotEqual = 6,
        GreaterEqual = 7,
        Always = 8,
    }

    internal enum GalStencilOperation : int
    {
        Keep = 1,
        Zero = 2,
        Replace = 3,
        IncrementClamp = 4,
        DecrementClamp = 5,
        Invert = 6,
        IncrementWrap = 7,
        DecrementWrap = 8,
    }

    internal enum GalBlendOperation : int
    {
        Add = 1,
        Subtract = 2,
        ReverseSubtract = 3,
        Min = 4,
        Max = 5,
    }

    internal enum GalBlendFactor : int
    {
        Zero = 1,
        One = 2,
        SourceColor = 3,
        OneMinusSourceColor = 4,
        SourceAlpha = 5,
        OneMinusSourceAlpha = 6,
        DestinationColor = 7,
        OneMinusDestinationColor = 8,
        DestinationAlpha = 9,
        OneMinusDestinationAlpha = 10,
        SourceAlphaSaturated = 11,
        Source1Color = 12,
        OneMinusSource1Color = 13,
        Source1Alpha = 14,
        OneMinusSource1Alpha = 15,
        BlendColor = 16,
        OneMinusBlendColor = 17,
        BlendAlpha = 18,
        OneMinusBlendAlpha = 19,
    }

    internal enum GalFrontFaceWinding : int
    {
        Clockwise = 1,
        CounterClockwise = 2,
    }

    internal enum GalCullMode : int
    {
        None = 1,
        Front = 2,
        Back = 3,
        FrontAndBack = 4,
    }

    internal enum GalTriangleFillMode : int
    {
        Fill = 1,
        Lines = 2,
    }

    internal enum GalDepthClipMode : int
    {
        Clip = 1,
        Clamp = 2,
    }

    internal readonly record struct GalBlendState(
        bool Enabled,
        GalBlendOperation RgbOperation,
        GalBlendOperation AlphaOperation,
        GalBlendFactor SourceRgbFactor,
        GalBlendFactor DestinationRgbFactor,
        GalBlendFactor SourceAlphaFactor,
        GalBlendFactor DestinationAlphaFactor
    );

    internal readonly record struct GalStencilFaceState(
        GalCompareFunction CompareFunction,
        GalStencilOperation StencilFailureOperation,
        GalStencilOperation DepthFailureOperation,
        GalStencilOperation PassOperation,
        uint ReadMask,
        uint WriteMask
    );

    internal readonly record struct GalDepthStencilState(
        GalCompareFunction DepthCompareFunction,
        bool DepthWriteEnabled,
        bool StencilEnabled,
        GalStencilFaceState FrontFace,
        GalStencilFaceState BackFace
    );

    internal readonly record struct GalRenderPipelineState(
        GalRenderColorAttachmentState[] ColorAttachments,
        GalTextureFormat DepthStencilFormat,
        GalDepthStencilState DepthStencil,
        bool AlphaToCoverageEnabled,
        bool AlphaToCoverageDitherEnabled,
        bool AlphaToOneEnabled,
        GalPrimitiveTopologyClass InputPrimitiveTopology
    );

    internal readonly record struct GalRenderColorAttachmentState(
        uint AttachmentIndex,
        GalTextureFormat PixelFormat,
        uint ColorWriteMask,
        GalBlendState Blend
    );

    internal readonly record struct GalRenderColorTarget(
        uint AttachmentIndex,
        IntPtr Texture,
        GalRenderLoadAction LoadAction,
        GalRenderStoreAction StoreAction,
        double ClearRed,
        double ClearGreen,
        double ClearBlue,
        double ClearAlpha
    );

    internal readonly record struct GalRenderPassState(
        IntPtr DepthStencilTarget,
        GalRenderLoadAction DepthLoadAction,
        GalRenderStoreAction DepthStoreAction,
        GalRenderLoadAction StencilLoadAction,
        GalRenderStoreAction StencilStoreAction,
        double ClearDepth,
        uint ClearStencil,
        uint StencilReferenceFront,
        uint StencilReferenceBack
    );

    internal readonly record struct GalRasterizerState(
        GalFrontFaceWinding FrontFace,
        GalCullMode CullMode,
        GalTriangleFillMode TriangleFillMode,
        GalDepthClipMode DepthClipMode,
        float DepthBias,
        float DepthBiasSlopeScale,
        float DepthBiasClamp
    );

    internal readonly record struct GalRenderDrawState(
        GalPrimitiveType PrimitiveType,
        uint ColorAttachmentIndex,
        GalRenderLoadAction ColorLoadAction,
        GalRenderStoreAction ColorStoreAction,
        uint VertexStart,
        uint VertexCount,
        uint InstanceCount,
        uint BaseInstance,
        double ClearRed,
        double ClearGreen,
        double ClearBlue,
        double ClearAlpha,
        double ViewportX,
        double ViewportY,
        double ViewportWidth,
        double ViewportHeight,
        double ViewportNearZ,
        double ViewportFarZ,
        uint ScissorX,
        uint ScissorY,
        uint ScissorWidth,
        uint ScissorHeight,
        float BlendRed,
        float BlendGreen,
        float BlendBlue,
        float BlendAlpha,
        GalRenderPassState? RenderPass,
        GalRasterizerState Rasterizer
    );

    internal sealed class GalRenderProgramHandle
    {
        internal IntPtr VertexTranslation;
        internal IntPtr FragmentTranslation;
        internal readonly bool VertexWritesPointSize;
        internal readonly bool OwnsVertexTranslation;
        internal readonly bool OwnsFragmentTranslation;

        internal GalRenderProgramHandle(
            IntPtr vertex,
            IntPtr fragment,
            bool vertexWritesPointSize,
            bool ownsVertexTranslation = true,
            bool ownsFragmentTranslation = true
        )
        {
            VertexTranslation = vertex;
            FragmentTranslation = fragment;
            VertexWritesPointSize = vertexWritesPointSize;
            OwnsVertexTranslation = ownsVertexTranslation;
            OwnsFragmentTranslation = ownsFragmentTranslation;
        }
    }

    private sealed class GalSession : IGalSession
    {
        private readonly Api _api;
        private IntPtr _context;

        public string DeviceName { get; }
        public ulong RecommendedWorkingSetBytes { get; }
        public ulong MaxBufferLength { get; }
        public uint MaxThreadsPerThreadgroup { get; }
        public uint ArgumentBufferTier { get; }
        public bool SupportsBcTextureCompression { get; }
        public bool SupportsLayeredVertexOutput { get; }
        public bool SupportsDepth32ProbeReadback =>
            _api.TextureProbeDownloadDepth32 is not null;
        public bool SupportsDepthStencilReadback =>
            _api.TextureDownloadDepthStencilSubresource is not null;

        public GalSession(
            Api api,
            IntPtr context,
            string deviceName,
            ulong recommendedWorkingSetBytes,
            ulong maxBufferLength,
            uint maxThreadsPerThreadgroup,
            uint argumentBufferTier,
            bool supportsBcTextureCompression,
            bool supportsLayeredVertexOutput
        )
        {
            _api = api;
            _context = context;
            DeviceName = deviceName;
            RecommendedWorkingSetBytes = recommendedWorkingSetBytes;
            MaxBufferLength = maxBufferLength;
            MaxThreadsPerThreadgroup = maxThreadsPerThreadgroup;
            ArgumentBufferTier = argumentBufferTier;
            SupportsBcTextureCompression = supportsBcTextureCompression;
            SupportsLayeredVertexOutput = supportsLayeredVertexOutput;
        }

        public IntPtr CreateBuffer(int size, bool deviceLocal)
        {
            if (size <= 0 || (ulong)size > MaxBufferLength)
            {
                throw new ArgumentOutOfRangeException(nameof(size));
            }

            NativeBufferDescriptor descriptor = default;
            descriptor.StructSize = (uint)sizeof(NativeBufferDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.Size = (ulong)size;
            descriptor.StorageMode = deviceLocal
                ? NativeBufferStorageMode.Private
                : NativeBufferStorageMode.Shared;
            IntPtr buffer = IntPtr.Zero;
            NativeStatus status = _api.BufferCreate(
                RequireContext(),
                &descriptor,
                &buffer
            );
            ThrowIfFailed(status, "buffer creation");
            if (buffer == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "SolMetal returned no buffer after successful creation."
                );
            }
            return buffer;
        }

        public void DestroyBuffer(IntPtr buffer)
        {
            if (buffer != IntPtr.Zero)
            {
                _api.BufferDestroy(buffer);
            }
        }

        public void UploadBuffer(
            IntPtr buffer,
            int offset,
            ReadOnlySpan<byte> data
        )
        {
            if (buffer == IntPtr.Zero || offset < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(offset));
            }
            fixed (byte* source = data)
            {
                NativeStatus status = _api.BufferUpload(
                    RequireContext(),
                    buffer,
                    (ulong)offset,
                    source,
                    (ulong)data.Length
                );
                ThrowIfFailed(status, "buffer upload");
            }
        }

        public void DownloadBuffer(IntPtr buffer, int offset, Span<byte> data)
        {
            if (buffer == IntPtr.Zero || offset < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(offset));
            }
            fixed (byte* destination = data)
            {
                NativeStatus status = _api.BufferDownload(
                    RequireContext(),
                    buffer,
                    (ulong)offset,
                    destination,
                    (ulong)data.Length
                );
                ThrowIfFailed(status, "buffer download");
            }
        }

        public void CopyBuffer(
            IntPtr source,
            int sourceOffset,
            IntPtr destination,
            int destinationOffset,
            int size
        )
        {
            if (source == IntPtr.Zero || destination == IntPtr.Zero ||
                sourceOffset < 0 || destinationOffset < 0 || size < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(size));
            }
            NativeStatus status = _api.BufferCopy(
                RequireContext(),
                source,
                (ulong)sourceOffset,
                destination,
                (ulong)destinationOffset,
                (ulong)size
            );
            ThrowIfFailed(status, "buffer copy");
        }

        public void FillBuffer(IntPtr buffer, int offset, int size, uint value)
        {
            if (buffer == IntPtr.Zero || offset < 0 || size < 0 ||
                (offset & 3) != 0 || (size & 3) != 0)
            {
                throw new ArgumentOutOfRangeException(nameof(size));
            }
            NativeStatus status = _api.BufferFillU32(
                RequireContext(),
                buffer,
                (ulong)offset,
                (ulong)size,
                value
            );
            ThrowIfFailed(status, "buffer fill");
        }

        public void ExpandQuadIndices(
            IntPtr source,
            int sourceOffset,
            GalIndexType sourceIndexType,
            int quadCount,
            IntPtr destination,
            int destinationOffset
        )
        {
            if (source == IntPtr.Zero || destination == IntPtr.Zero ||
                sourceOffset < 0 || destinationOffset < 0 || quadCount < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(quadCount));
            }
            NativeStatus status = _api.BufferExpandQuadIndices(
                RequireContext(),
                source,
                (ulong)sourceOffset,
                sourceIndexType,
                checked((uint)quadCount),
                destination,
                (ulong)destinationOffset
            );
            ThrowIfFailed(status, "quad index expansion");
        }

        public IntPtr CreateTexture(
            int width,
            int height,
            GalTextureType type,
            int depthOrArrayLength,
            int mipmapLevelCount,
            int sampleCount,
            GalTextureFormat format,
            GalTextureSwizzle red,
            GalTextureSwizzle green,
            GalTextureSwizzle blue,
            GalTextureSwizzle alpha,
            bool depthStencil
        )
        {
            if (width <= 0 || height <= 0 || depthOrArrayLength <= 0 ||
                mipmapLevelCount <= 0 || sampleCount <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(width));
            }
            NativeTextureDescriptor descriptor = default;
            descriptor.StructSize = (uint)sizeof(NativeTextureDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.Width = (uint)width;
            descriptor.Height = (uint)height;
            descriptor.PixelFormat = (NativeTexturePixelFormat)format;
            descriptor.StorageMode = NativeBufferStorageMode.Private;
            descriptor.Usage = depthStencil
                ? NativeTextureUsage.RenderTarget | NativeTextureUsage.Sampled
                : IsBlockCompressed(format)
                    ? NativeTextureUsage.Sampled
                    : NativeTextureUsage.All;
            descriptor.TextureType = type;
            descriptor.DepthOrArrayLength = checked((uint)depthOrArrayLength);
            descriptor.MipmapLevelCount = checked((uint)mipmapLevelCount);
            descriptor.SampleCount = checked((uint)sampleCount);
            descriptor.SwizzleR = red;
            descriptor.SwizzleG = green;
            descriptor.SwizzleB = blue;
            descriptor.SwizzleA = alpha;
            IntPtr texture = IntPtr.Zero;
            NativeStatus status = _api.TextureCreate(
                RequireContext(),
                &descriptor,
                &texture
            );
            ThrowIfFailed(status, "texture creation");
            if (texture == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "SolMetal returned no texture after successful creation."
                );
            }
            return texture;
        }

        private static bool IsBlockCompressed(GalTextureFormat format) =>
            format is GalTextureFormat.Bc1RgbaUnorm or
                GalTextureFormat.Bc1RgbaSrgb or
                GalTextureFormat.Bc2RgbaUnorm or
                GalTextureFormat.Bc2RgbaSrgb or
                GalTextureFormat.Bc3RgbaUnorm or
                GalTextureFormat.Bc3RgbaSrgb or
                GalTextureFormat.Bc4RUnorm or
                GalTextureFormat.Bc4RSnorm or
                GalTextureFormat.Bc5RgUnorm or
                GalTextureFormat.Bc5RgSnorm or
                GalTextureFormat.Bc6hRgbFloat or
                GalTextureFormat.Bc6hRgbUfloat or
                GalTextureFormat.Bc7RgbaUnorm or
                GalTextureFormat.Bc7RgbaSrgb;

        public IntPtr CreateBufferTexture(
            IntPtr buffer,
            int offset,
            int size,
            int width,
            GalTextureFormat format,
            GalTextureSwizzle red,
            GalTextureSwizzle green,
            GalTextureSwizzle blue,
            GalTextureSwizzle alpha
        )
        {
            if (buffer == IntPtr.Zero || offset < 0 || size <= 0 || width <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(size));
            }
            NativeTextureDescriptor descriptor = default;
            descriptor.StructSize = (uint)sizeof(NativeTextureDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.Width = checked((uint)width);
            descriptor.Height = 1;
            descriptor.PixelFormat = (NativeTexturePixelFormat)format;
            descriptor.StorageMode = NativeBufferStorageMode.Private;
            descriptor.Usage =
                NativeTextureUsage.Sampled | NativeTextureUsage.Storage;
            descriptor.TextureType = GalTextureType.TextureBuffer;
            descriptor.DepthOrArrayLength = 1;
            descriptor.MipmapLevelCount = 1;
            descriptor.SampleCount = 1;
            descriptor.SwizzleR = red;
            descriptor.SwizzleG = green;
            descriptor.SwizzleB = blue;
            descriptor.SwizzleA = alpha;
            IntPtr texture = IntPtr.Zero;
            NativeStatus status = _api.TextureCreateBufferView(
                RequireContext(),
                buffer,
                checked((ulong)offset),
                checked((ulong)size),
                &descriptor,
                &texture
            );
            ThrowIfFailed(status, "texture-buffer view creation");
            if (texture == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "SolMetal returned no texture-buffer view after successful creation."
                );
            }
            return texture;
        }

        public IntPtr CreateTextureView(
            IntPtr source,
            GalTextureFormat format,
            GalTextureSwizzle red,
            GalTextureSwizzle green,
            GalTextureSwizzle blue,
            GalTextureSwizzle alpha,
            GalTextureType type,
            int firstLevel,
            int levelCount,
            int firstSlice,
            int sliceCount
        )
        {
            if (source == IntPtr.Zero || firstLevel < 0 || levelCount <= 0 ||
                firstSlice < 0 || sliceCount <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(firstLevel));
            }
            NativeTextureViewDescriptor descriptor = default;
            descriptor.StructSize = (uint)sizeof(NativeTextureViewDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.PixelFormat = format;
            descriptor.SwizzleR = red;
            descriptor.SwizzleG = green;
            descriptor.SwizzleB = blue;
            descriptor.SwizzleA = alpha;
            descriptor.TextureType = type;
            descriptor.FirstLevel = checked((uint)firstLevel);
            descriptor.LevelCount = checked((uint)levelCount);
            descriptor.FirstSlice = checked((uint)firstSlice);
            descriptor.SliceCount = checked((uint)sliceCount);
            IntPtr texture = IntPtr.Zero;
            NativeStatus status = _api.TextureCreateView(
                RequireContext(),
                source,
                &descriptor,
                &texture
            );
            ThrowIfFailed(status, "texture view creation");
            if (texture == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "SolMetal returned no texture view after successful creation."
                );
            }
            return texture;
        }

        public void DestroyTexture(IntPtr texture)
        {
            if (texture != IntPtr.Zero)
            {
                _api.TextureDestroy(texture);
            }
        }

        public void UploadTexture(
            IntPtr texture,
            ReadOnlySpan<byte> data,
            int bytesPerRow
        )
        {
            if (texture == IntPtr.Zero || bytesPerRow <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(bytesPerRow));
            }
            fixed (byte* source = data)
            {
                NativeStatus status = _api.TextureUpload(
                    RequireContext(),
                    texture,
                    source,
                    (ulong)bytesPerRow,
                    (ulong)data.Length
                );
                ThrowIfFailed(status, "texture upload");
            }
        }

        public void DownloadTexture(
            IntPtr texture,
            Span<byte> data,
            int bytesPerRow
        )
        {
            if (texture == IntPtr.Zero || bytesPerRow <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(bytesPerRow));
            }
            fixed (byte* destination = data)
            {
                NativeStatus status = _api.TextureDownload(
                    RequireContext(),
                    texture,
                    destination,
                    (ulong)bytesPerRow,
                    (ulong)data.Length
                );
                ThrowIfFailed(status, "texture download");
            }
        }

        public void DownloadDepth32Probe(
            IntPtr texture,
            Span<byte> data,
            int bytesPerRow
        )
        {
            if (texture == IntPtr.Zero || bytesPerRow <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(bytesPerRow));
            }
            TextureDownloadDelegate? download =
                _api.TextureProbeDownloadDepth32;
            if (download is null)
            {
                throw new NotSupportedException(
                    "This SolMetal library does not provide diagnostic D32 readback."
                );
            }
            fixed (byte* destination = data)
            {
                NativeStatus status = download(
                    RequireContext(),
                    texture,
                    destination,
                    (ulong)bytesPerRow,
                    (ulong)data.Length
                );
                ThrowIfFailed(status, "diagnostic D32 texture download");
            }
        }

        public void DownloadDepthStencilSubresource(
            IntPtr texture,
            int sourceSlice,
            int sourceLevel,
            Span<byte> data,
            int bytesPerRow
        )
        {
            if (texture == IntPtr.Zero || sourceSlice < 0 ||
                sourceLevel < 0 || bytesPerRow <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(sourceSlice));
            }
            TextureDownloadDepthStencilSubresourceDelegate? download =
                _api.TextureDownloadDepthStencilSubresource;
            if (download is null)
            {
                throw new NotSupportedException(
                    "This SolMetal library does not provide depth/stencil subresource readback."
                );
            }
            fixed (byte* destination = data)
            {
                NativeStatus status = download(
                    RequireContext(),
                    texture,
                    checked((uint)sourceSlice),
                    checked((uint)sourceLevel),
                    destination,
                    checked((ulong)bytesPerRow),
                    checked((ulong)data.Length)
                );
                ThrowIfFailed(status, "depth/stencil texture download");
            }
        }

        public void CopyTextureToBuffer(
            IntPtr texture,
            int sourceSlice,
            int sourceLevel,
            IntPtr destination,
            int destinationOffset,
            int destinationSize,
            int destinationBytesPerRow
        )
        {
            if (texture == IntPtr.Zero || destination == IntPtr.Zero ||
                sourceSlice < 0 || sourceLevel < 0 ||
                destinationOffset < 0 || destinationSize <= 0 ||
                destinationBytesPerRow <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(sourceSlice));
            }
            NativeStatus status = _api.TextureCopyToBuffer(
                RequireContext(),
                texture,
                checked((uint)sourceSlice),
                checked((uint)sourceLevel),
                destination,
                checked((ulong)destinationOffset),
                checked((ulong)destinationSize),
                checked((ulong)destinationBytesPerRow)
            );
            ThrowIfFailed(status, "texture-to-buffer copy");
        }

        public void CopyTexture(IntPtr source, IntPtr destination)
        {
            NativeStatus status = _api.TextureCopy(
                RequireContext(),
                source,
                destination
            );
            ThrowIfFailed(status, "texture copy");
        }

        public void CopyTextureSubresource(
            IntPtr source,
            IntPtr destination,
            int sourceSlice,
            int destinationSlice,
            int sourceLevel,
            int destinationLevel,
            int width,
            int height
        )
        {
            if (source == IntPtr.Zero || destination == IntPtr.Zero ||
                sourceSlice < 0 || destinationSlice < 0 || sourceLevel < 0 ||
                destinationLevel < 0 || width <= 0 || height <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(sourceSlice));
            }
            NativeTextureCopyDescriptor descriptor = default;
            descriptor.StructSize = (uint)sizeof(NativeTextureCopyDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.SourceSlice = checked((uint)sourceSlice);
            descriptor.DestinationSlice = checked((uint)destinationSlice);
            descriptor.SourceLevel = checked((uint)sourceLevel);
            descriptor.DestinationLevel = checked((uint)destinationLevel);
            descriptor.Width = checked((uint)width);
            descriptor.Height = checked((uint)height);
            NativeStatus status = _api.TextureCopySubresource(
                RequireContext(),
                source,
                destination,
                &descriptor
            );
            ThrowIfFailed(status, "texture subresource copy");
        }

        public void CopyDepth32ToR32Float(
            IntPtr source,
            IntPtr destination,
            int sourceSlice,
            int destinationSlice,
            int sourceLevel,
            int destinationLevel,
            int width,
            int height
        )
        {
            if (source == IntPtr.Zero || destination == IntPtr.Zero ||
                sourceSlice < 0 || destinationSlice < 0 || sourceLevel < 0 ||
                destinationLevel < 0 || width <= 0 || height <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(sourceSlice));
            }
            if (_api.TextureProbeDownloadDepth32 is null)
            {
                throw new NotSupportedException(
                    "This SolMetal library does not provide D32Float transfer readback."
                );
            }

            int bytesPerRow = checked(width * sizeof(float));
            int requiredBytes = checked(bytesPerRow * height);
            byte[] transfer = ArrayPool<byte>.Shared.Rent(requiredBytes);
            IntPtr sourceView = IntPtr.Zero;
            IntPtr destinationView = IntPtr.Zero;
            try
            {
                sourceView = CreateTextureView(
                    source,
                    GalTextureFormat.Depth32Float,
                    GalTextureSwizzle.Red,
                    GalTextureSwizzle.Green,
                    GalTextureSwizzle.Blue,
                    GalTextureSwizzle.Alpha,
                    GalTextureType.Texture2D,
                    sourceLevel,
                    1,
                    sourceSlice,
                    1
                );
                destinationView = CreateTextureView(
                    destination,
                    GalTextureFormat.R32Float,
                    GalTextureSwizzle.Red,
                    GalTextureSwizzle.Green,
                    GalTextureSwizzle.Blue,
                    GalTextureSwizzle.Alpha,
                    GalTextureType.Texture2D,
                    destinationLevel,
                    1,
                    destinationSlice,
                    1
                );
                Span<byte> transferBytes = transfer.AsSpan(0, requiredBytes);
                DownloadDepth32Probe(sourceView, transferBytes, bytesPerRow);
                UploadTexture(destinationView, transferBytes, bytesPerRow);
            }
            finally
            {
                DestroyTexture(destinationView);
                DestroyTexture(sourceView);
                ArrayPool<byte>.Shared.Return(transfer);
            }
        }

        public void CopyR32FloatToDepth32(
            IntPtr source,
            IntPtr destination,
            int sourceSlice,
            int destinationSlice,
            int sourceLevel,
            int destinationLevel,
            int width,
            int height
        )
        {
            if (source == IntPtr.Zero || destination == IntPtr.Zero ||
                sourceSlice < 0 || destinationSlice < 0 || sourceLevel < 0 ||
                destinationLevel < 0 || width <= 0 || height <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(sourceSlice));
            }
            if (_api.TextureCopyR32FloatToDepth32 is null)
            {
                throw new NotSupportedException(
                    "This SolMetal library does not provide GPU R32Float-to-D32Float conversion."
                );
            }
            NativeTextureCopyDescriptor descriptor = default;
            descriptor.StructSize = (uint)sizeof(NativeTextureCopyDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.SourceSlice = checked((uint)sourceSlice);
            descriptor.DestinationSlice = checked((uint)destinationSlice);
            descriptor.SourceLevel = checked((uint)sourceLevel);
            descriptor.DestinationLevel = checked((uint)destinationLevel);
            descriptor.Width = checked((uint)width);
            descriptor.Height = checked((uint)height);
            NativeStatus status = _api.TextureCopyR32FloatToDepth32(
                RequireContext(),
                source,
                destination,
                &descriptor
            );
            ThrowIfFailed(status, "R32Float-to-D32Float texture copy");
        }

        public void ClearColorTexture(
            IntPtr texture,
            int firstSlice,
            int sliceCount,
            uint componentMask,
            int clearX,
            int clearY,
            int clearWidth,
            int clearHeight,
            double red,
            double green,
            double blue,
            double alpha,
            uint redBits,
            uint greenBits,
            uint blueBits,
            uint alphaBits
        )
        {
            if (texture == IntPtr.Zero || firstSlice < 0 || sliceCount <= 0 ||
                clearX < 0 || clearY < 0 || clearWidth <= 0 ||
                clearHeight <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(firstSlice));
            }
            NativeTextureClearColorDescriptor descriptor = default;
            descriptor.StructSize =
                (uint)sizeof(NativeTextureClearColorDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.FirstSlice = checked((uint)firstSlice);
            descriptor.SliceCount = checked((uint)sliceCount);
            descriptor.ComponentMask = componentMask;
            descriptor.Flags =
                NativeTextureClearRegion | NativeTextureClearRawColorBits;
            descriptor.ClearRed = red;
            descriptor.ClearGreen = green;
            descriptor.ClearBlue = blue;
            descriptor.ClearAlpha = alpha;
            descriptor.ClearX = checked((uint)clearX);
            descriptor.ClearY = checked((uint)clearY);
            descriptor.ClearWidth = checked((uint)clearWidth);
            descriptor.ClearHeight = checked((uint)clearHeight);
            descriptor.ClearRedBits = redBits;
            descriptor.ClearGreenBits = greenBits;
            descriptor.ClearBlueBits = blueBits;
            descriptor.ClearAlphaBits = alphaBits;
            NativeStatus status = _api.TextureClearColor(
                RequireContext(),
                texture,
                &descriptor
            );
            ThrowIfFailed(status, "texture color clear");
        }

        public void ClearDepthStencilTexture(
            IntPtr texture,
            int firstSlice,
            int sliceCount,
            bool depthMask,
            int stencilMask,
            int clearX,
            int clearY,
            int clearWidth,
            int clearHeight,
            double depth,
            uint stencil
        )
        {
            if (texture == IntPtr.Zero || firstSlice < 0 || sliceCount <= 0 ||
                clearX < 0 || clearY < 0 || clearWidth <= 0 ||
                clearHeight <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(firstSlice));
            }
            NativeTextureClearDepthStencilDescriptor descriptor = default;
            descriptor.StructSize =
                (uint)sizeof(NativeTextureClearDepthStencilDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.FirstSlice = checked((uint)firstSlice);
            descriptor.SliceCount = checked((uint)sliceCount);
            descriptor.DepthMask = depthMask ? 1u : 0u;
            descriptor.StencilMask = unchecked((uint)stencilMask);
            descriptor.ClearDepth = depth;
            descriptor.ClearStencil = stencil;
            descriptor.Flags = NativeTextureClearRegion;
            descriptor.ClearX = checked((uint)clearX);
            descriptor.ClearY = checked((uint)clearY);
            descriptor.ClearWidth = checked((uint)clearWidth);
            descriptor.ClearHeight = checked((uint)clearHeight);
            NativeStatus status = _api.TextureClearDepthStencil(
                RequireContext(),
                texture,
                &descriptor
            );
            ThrowIfFailed(status, "texture depth/stencil clear");
        }

        public void BlitTexture(
            IntPtr source,
            IntPtr destination,
            int sourceSlice,
            int sourceLevel,
            int destinationSlice,
            int destinationLevel,
            int sourceX1,
            int sourceY1,
            int sourceX2,
            int sourceY2,
            int destinationX1,
            int destinationY1,
            int destinationX2,
            int destinationY2,
            bool linearFilter
        )
        {
            NativeTextureBlitDescriptor descriptor = default;
            descriptor.StructSize = (uint)sizeof(NativeTextureBlitDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.SourceSlice = checked((uint)sourceSlice);
            descriptor.SourceLevel = checked((uint)sourceLevel);
            descriptor.DestinationSlice = checked((uint)destinationSlice);
            descriptor.DestinationLevel = checked((uint)destinationLevel);
            descriptor.SourceX1 = sourceX1;
            descriptor.SourceY1 = sourceY1;
            descriptor.SourceX2 = sourceX2;
            descriptor.SourceY2 = sourceY2;
            descriptor.DestinationX1 = destinationX1;
            descriptor.DestinationY1 = destinationY1;
            descriptor.DestinationX2 = destinationX2;
            descriptor.DestinationY2 = destinationY2;
            descriptor.LinearFilter = linearFilter ? 1u : 0u;
            NativeStatus status = _api.TextureBlit(
                RequireContext(),
                source,
                destination,
                &descriptor
            );
            ThrowIfFailed(status, "texture blit");
        }

        public void PresentTexture(
            nint metalLayer,
            IntPtr texture,
            int sourceLeft,
            int sourceTop,
            int sourceRight,
            int sourceBottom,
            float aspectRatioX,
            float aspectRatioY,
            bool flipX,
            bool flipY
        )
        {
            if (metalLayer == 0 || texture == IntPtr.Zero)
            {
                throw new ArgumentException(
                    "SolMetal presentation requires a Metal layer and texture."
                );
            }
            NativePresentTextureDescriptor descriptor = default;
            descriptor.StructSize = (uint)sizeof(NativePresentTextureDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.SourceTexture = texture;
            descriptor.Filter = NativeSamplerFilter.Linear;
            descriptor.SourceLeft = sourceLeft;
            descriptor.SourceTop = sourceTop;
            descriptor.SourceRight = sourceRight;
            descriptor.SourceBottom = sourceBottom;
            descriptor.AspectRatioX = aspectRatioX;
            descriptor.AspectRatioY = aspectRatioY;
            descriptor.Flags =
                (flipX ? NativePresentFlipX : 0u) |
                (flipY ? NativePresentFlipY : 0u);
            NativeStatus status = _api.PresentTexture(
                RequireContext(),
                metalLayer,
                &descriptor
            );
            ThrowIfFailed(status, "texture presentation");
        }

        public IntPtr CreateSampler(GalSamplerDescriptor descriptor)
        {
            NativeSamplerDescriptor native = default;
            native.StructSize = (uint)sizeof(NativeSamplerDescriptor);
            native.AbiVersion = AbiVersion;
            native.MinFilter = descriptor.MinFilter;
            native.MagFilter = descriptor.MagFilter;
            native.MipFilter = descriptor.MipFilter;
            native.AddressU = descriptor.AddressU;
            native.AddressV = descriptor.AddressV;
            native.AddressW = descriptor.AddressW;
            native.MaxAnisotropy = descriptor.MaxAnisotropy;
            native.LodMinClamp = descriptor.MinLod;
            native.LodMaxClamp = descriptor.MaxLod;
            native.BorderColor = descriptor.BorderColor;
            native.CompareEnabled = descriptor.CompareEnabled ? 1u : 0u;
            native.CompareFunction = descriptor.CompareFunction;
            native.LodBias = descriptor.LodBias;
            IntPtr sampler = IntPtr.Zero;
            NativeStatus status = _api.SamplerCreate(
                RequireContext(),
                &native,
                &sampler
            );
            ThrowIfFailed(status, "sampler creation");
            if (sampler == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "SolMetal returned no sampler after successful creation."
                );
            }
            return sampler;
        }

        public void DestroySampler(IntPtr sampler)
        {
            if (sampler != IntPtr.Zero)
            {
                _api.SamplerDestroy(sampler);
            }
        }

        public GalRenderProgramHandle CreateRenderProgram(
            ReadOnlySpan<byte> vertexSpirv,
            ReadOnlySpan<byte> fragmentSpirv,
            ReadOnlySpan<GalSpirvResourceBinding> vertexResourceBindings,
            ReadOnlySpan<GalSpirvResourceBinding> fragmentResourceBindings,
            uint vertexArgumentBufferSetMask = 0,
            uint fragmentArgumentBufferSetMask = 0
        )
        {
            IntPtr vertex = IntPtr.Zero;
            IntPtr fragment = IntPtr.Zero;
            try
            {
                vertex = TranslateShader(
                    vertexSpirv,
                    NativeShaderStage.Vertex,
                    vertexResourceBindings,
                    vertexArgumentBufferSetMask,
                    disablePointSizeBuiltin: false,
                    out bool vertexWritesPointSize
                );
                fragment = TranslateShader(
                    fragmentSpirv,
                    NativeShaderStage.Fragment,
                    fragmentResourceBindings,
                    fragmentArgumentBufferSetMask,
                    disablePointSizeBuiltin: false,
                    out _
                );
                GalRenderProgramHandle program = new(
                    vertex,
                    fragment,
                    vertexWritesPointSize
                );
                vertex = IntPtr.Zero;
                fragment = IntPtr.Zero;
                return program;
            }
            finally
            {
                if (fragment != IntPtr.Zero)
                {
                    _api.ShaderTranslationDestroy(fragment);
                }
                if (vertex != IntPtr.Zero)
                {
                    _api.ShaderTranslationDestroy(vertex);
                }
            }
        }

        public GalRenderProgramHandle CreateRenderProgramWithoutPointSize(
            GalRenderProgramHandle baseProgram,
            ReadOnlySpan<byte> vertexSpirv,
            ReadOnlySpan<GalSpirvResourceBinding> vertexResourceBindings,
            uint vertexArgumentBufferSetMask = 0
        )
        {
            if (baseProgram.FragmentTranslation == IntPtr.Zero)
            {
                throw new ObjectDisposedException(nameof(baseProgram));
            }
            IntPtr vertex = IntPtr.Zero;
            try
            {
                vertex = TranslateShader(
                    vertexSpirv,
                    NativeShaderStage.Vertex,
                    vertexResourceBindings,
                    vertexArgumentBufferSetMask,
                    disablePointSizeBuiltin: true,
                    out _
                );
                GalRenderProgramHandle variant = new(
                    vertex,
                    baseProgram.FragmentTranslation,
                    vertexWritesPointSize: false,
                    ownsVertexTranslation: true,
                    ownsFragmentTranslation: false
                );
                vertex = IntPtr.Zero;
                return variant;
            }
            finally
            {
                if (vertex != IntPtr.Zero)
                {
                    _api.ShaderTranslationDestroy(vertex);
                }
            }
        }

        public string CopyShaderMsl(IntPtr translation)
        {
            if (translation == IntPtr.Zero)
            {
                throw new ArgumentNullException(nameof(translation));
            }
            ulong requiredSize = 0;
            NativeStatus sizeStatus = _api.ShaderTranslationCopyMsl(
                translation,
                null,
                0,
                &requiredSize
            );
            if (sizeStatus != NativeStatus.OutputTooSmall &&
                sizeStatus != NativeStatus.Ok)
            {
                ThrowIfFailed(sizeStatus, "translated MSL size query");
            }
            const ulong MaximumDiagnosticMslBytes = 16 * 1024 * 1024;
            if (requiredSize is 0 or > MaximumDiagnosticMslBytes ||
                requiredSize > int.MaxValue)
            {
                throw new InvalidOperationException(
                    $"SolMetal returned an invalid translated MSL size of " +
                    $"{requiredSize} bytes."
                );
            }
            byte[] utf8 = new byte[(int)requiredSize];
            fixed (byte* destination = utf8)
            {
                NativeStatus status = _api.ShaderTranslationCopyMsl(
                    translation,
                    destination,
                    requiredSize,
                    &requiredSize
                );
                ThrowIfFailed(status, "translated MSL copy");
            }
            int length = Array.IndexOf(utf8, (byte)0);
            if (length < 0)
            {
                length = utf8.Length;
            }
            return System.Text.Encoding.UTF8.GetString(utf8, 0, length);
        }

        public void DestroyRenderProgram(GalRenderProgramHandle program)
        {
            IntPtr fragment = Interlocked.Exchange(
                ref program.FragmentTranslation,
                IntPtr.Zero
            );
            IntPtr vertex = Interlocked.Exchange(
                ref program.VertexTranslation,
                IntPtr.Zero
            );
            if (fragment != IntPtr.Zero && program.OwnsFragmentTranslation)
            {
                _api.ShaderTranslationDestroy(fragment);
            }
            if (vertex != IntPtr.Zero && program.OwnsVertexTranslation)
            {
                _api.ShaderTranslationDestroy(vertex);
            }
        }

        public IntPtr CreateComputePipeline(
            ReadOnlySpan<byte> computeSpirv,
            ReadOnlySpan<GalSpirvResourceBinding> resourceBindings
        )
        {
            IntPtr translation = IntPtr.Zero;
            try
            {
                translation = TranslateShader(
                    computeSpirv,
                    NativeShaderStage.Compute,
                    resourceBindings,
                    0,
                    disablePointSizeBuiltin: false,
                    out _
                );
                IntPtr pipeline = IntPtr.Zero;
                NativeStatus status = _api.ComputePipelineCreate(
                    RequireContext(),
                    translation,
                    &pipeline
                );
                ThrowIfFailed(status, "compute pipeline creation");
                if (pipeline == IntPtr.Zero)
                {
                    throw new InvalidOperationException(
                        "SolMetal returned no compute pipeline after successful creation."
                    );
                }
                return pipeline;
            }
            finally
            {
                if (translation != IntPtr.Zero)
                {
                    _api.ShaderTranslationDestroy(translation);
                }
            }
        }

        public void DestroyComputePipeline(IntPtr pipeline)
        {
            if (pipeline != IntPtr.Zero)
            {
                _api.ComputePipelineDestroy(pipeline);
            }
        }

        public void DispatchCompute(
            IntPtr pipeline,
            uint threadCountX,
            uint threadCountY,
            uint threadCountZ,
            uint threadgroupSizeX,
            uint threadgroupSizeY,
            uint threadgroupSizeZ,
            GalStageBindings bindings
        )
        {
            const int MaximumStackBindings = 64;
            Span<NativeBufferBinding> nativeBuffers =
                bindings.Buffers.Length <= MaximumStackBindings
                    ? stackalloc NativeBufferBinding[bindings.Buffers.Length]
                    : new NativeBufferBinding[bindings.Buffers.Length];
            Span<NativeTextureBinding> nativeTextures =
                bindings.Textures.Length <= MaximumStackBindings
                    ? stackalloc NativeTextureBinding[bindings.Textures.Length]
                    : new NativeTextureBinding[bindings.Textures.Length];
            Span<NativeSamplerBinding> nativeSamplers =
                bindings.Samplers.Length <= MaximumStackBindings
                    ? stackalloc NativeSamplerBinding[bindings.Samplers.Length]
                    : new NativeSamplerBinding[bindings.Samplers.Length];
            ConvertBufferBindings(bindings.Buffers, nativeBuffers);
            ConvertTextureBindings(bindings.Textures, nativeTextures);
            ConvertSamplerBindings(bindings.Samplers, nativeSamplers);
            fixed (NativeBufferBinding* buffers = nativeBuffers)
            fixed (NativeTextureBinding* textures = nativeTextures)
            fixed (NativeSamplerBinding* samplers = nativeSamplers)
            {
                NativeComputeDispatchDescriptor descriptor = default;
                descriptor.StructSize =
                    (uint)sizeof(NativeComputeDispatchDescriptor);
                descriptor.AbiVersion = AbiVersion;
                descriptor.ThreadCountX = threadCountX;
                descriptor.ThreadCountY = threadCountY;
                descriptor.ThreadCountZ = threadCountZ;
                descriptor.ThreadgroupSizeX = threadgroupSizeX;
                descriptor.ThreadgroupSizeY = threadgroupSizeY;
                descriptor.ThreadgroupSizeZ = threadgroupSizeZ;
                descriptor.BufferBindingCount = (uint)nativeBuffers.Length;
                descriptor.TextureBindingCount = (uint)nativeTextures.Length;
                descriptor.SamplerBindingCount = (uint)nativeSamplers.Length;
                descriptor.BufferBindings = (IntPtr)buffers;
                descriptor.TextureBindings = (IntPtr)textures;
                descriptor.SamplerBindings = (IntPtr)samplers;
                NativeStatus status = _api.ComputeDispatch(
                    RequireContext(),
                    pipeline,
                    &descriptor
                );
                ThrowIfFailed(status, "compute dispatch");
            }
        }

        public IntPtr CreateRenderPipeline(
            GalRenderProgramHandle program,
            GalRenderPipelineState state,
            ReadOnlySpan<GalVertexBufferLayout> vertexBufferLayouts,
            ReadOnlySpan<GalVertexAttribute> vertexAttributes
        )
        {
            if (program.VertexTranslation == IntPtr.Zero ||
                program.FragmentTranslation == IntPtr.Zero)
            {
                throw new ObjectDisposedException(nameof(program));
            }
            if (state.ColorAttachments is null ||
                state.ColorAttachments.Length > 8)
            {
                throw new ArgumentException(
                    "SolMetal supports up to eight color attachments.",
                    nameof(state)
                );
            }
            NativeRenderPipelineMrtDescriptor descriptor = default;
            descriptor.StructSize =
                (uint)sizeof(NativeRenderPipelineMrtDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.VertexTranslation = program.VertexTranslation;
            descriptor.FragmentTranslation = program.FragmentTranslation;
            descriptor.ColorAttachmentCount =
                checked((uint)state.ColorAttachments.Length);
            descriptor.DepthStencilFormat = state.DepthStencilFormat;
            descriptor.DepthStencil = CreateNativeDepthStencil(
                state.DepthStencil
            );
            descriptor.AlphaToCoverageEnabled =
                state.AlphaToCoverageEnabled ? 1u : 0u;
            descriptor.AlphaToCoverageDitherEnabled =
                state.AlphaToCoverageDitherEnabled ? 1u : 0u;
            descriptor.AlphaToOneEnabled = state.AlphaToOneEnabled ? 1u : 0u;
            descriptor.InputPrimitiveTopology = state.InputPrimitiveTopology;
            NativeRenderColorAttachmentDescriptor[] nativeColors =
                new NativeRenderColorAttachmentDescriptor[
                    state.ColorAttachments.Length
                ];
            for (int index = 0; index < nativeColors.Length; index++)
            {
                GalRenderColorAttachmentState source =
                    state.ColorAttachments[index];
                nativeColors[index] = new NativeRenderColorAttachmentDescriptor
                {
                    AttachmentIndex = source.AttachmentIndex,
                    PixelFormat = source.PixelFormat,
                    ColorWriteMask = source.ColorWriteMask,
                    Blend = CreateNativeBlend(source.Blend),
                };
            }
            Span<NativeVertexBufferLayout> nativeLayouts =
                vertexBufferLayouts.Length <= 32
                    ? stackalloc NativeVertexBufferLayout[vertexBufferLayouts.Length]
                    : new NativeVertexBufferLayout[vertexBufferLayouts.Length];
            for (int index = 0; index < vertexBufferLayouts.Length; index++)
            {
                GalVertexBufferLayout source = vertexBufferLayouts[index];
                nativeLayouts[index] = new NativeVertexBufferLayout
                {
                    BufferIndex = source.BufferIndex,
                    Stride = source.Stride,
                    StepFunction = source.StepFunction,
                    StepRate = source.StepRate,
                };
            }

            Span<NativeVertexAttribute> nativeAttributes =
                vertexAttributes.Length <= 32
                    ? stackalloc NativeVertexAttribute[vertexAttributes.Length]
                    : new NativeVertexAttribute[vertexAttributes.Length];
            for (int index = 0; index < vertexAttributes.Length; index++)
            {
                GalVertexAttribute source = vertexAttributes[index];
                nativeAttributes[index] = new NativeVertexAttribute
                {
                    Location = source.Location,
                    BufferIndex = source.BufferIndex,
                    Format = source.Format,
                    Offset = source.Offset,
                };
            }

            IntPtr pipeline = IntPtr.Zero;
            NativeStatus status;
            fixed (NativeRenderColorAttachmentDescriptor* colors = nativeColors)
            fixed (NativeVertexBufferLayout* layouts = nativeLayouts)
            fixed (NativeVertexAttribute* attributes = nativeAttributes)
            {
                descriptor.ColorAttachments = (IntPtr)colors;
                status = _api.RenderPipelineCreateMrt(
                    RequireContext(),
                    &descriptor,
                    layouts,
                    (uint)nativeLayouts.Length,
                    attributes,
                    (uint)nativeAttributes.Length,
                    &pipeline
                );
            }
            string colorSummary = string.Join(
                ",",
                state.ColorAttachments.Select(color =>
                    $"{color.AttachmentIndex}:{color.PixelFormat}/0x{color.ColorWriteMask:x}"
                )
            );
            ThrowIfFailed(
                status,
                $"render pipeline creation (colors=[{colorSummary}], " +
                $"depth={state.DepthStencilFormat}, layouts={vertexBufferLayouts.Length}, " +
                $"attributes={vertexAttributes.Length}, " +
                $"topology={state.InputPrimitiveTopology})"
            );
            if (pipeline == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "SolMetal returned no render pipeline after successful creation."
                );
            }
            return pipeline;
        }

        public void DestroyRenderPipeline(IntPtr pipeline)
        {
            if (pipeline != IntPtr.Zero)
            {
                _api.RenderPipelineDestroy(pipeline);
            }
        }

        public void Draw(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndexBinding? indexBinding
        ) => _ = DrawCore(
            pipeline,
            colorTargets,
            state,
            vertexBindings,
            fragmentBindings,
            indexBinding,
            collectVisibility: false
        );

        public void DrawIndirect(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndirectBinding indirectBinding,
            GalIndexBinding? indexBinding
        ) => _ = DrawCore(
            pipeline,
            colorTargets,
            state,
            vertexBindings,
            fragmentBindings,
            indexBinding,
            collectVisibility: false,
            indirectBinding: indirectBinding
        );

        public void DrawIndirectCount(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndirectBinding indirectBinding,
            GalIndirectCountBinding countBinding,
            GalIndexBinding? indexBinding
        ) => _ = DrawCore(
            pipeline,
            colorTargets,
            state,
            vertexBindings,
            fragmentBindings,
            indexBinding,
            collectVisibility: false,
            indirectBinding: indirectBinding,
            indirectCountBinding: countBinding
        );

        public ulong DrawWithVisibility(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndexBinding? indexBinding
        ) => DrawCore(
            pipeline,
            colorTargets,
            state,
            vertexBindings,
            fragmentBindings,
            indexBinding,
            collectVisibility: true
        );

        public IntPtr CreateVisibilityQuery()
        {
            IntPtr query = IntPtr.Zero;
            NativeStatus status = _api.VisibilityQueryCreate(
                RequireContext(),
                &query
            );
            ThrowIfFailed(status, "visibility-query creation");
            if (query == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "SolMetal returned no visibility query after successful creation."
                );
            }
            return query;
        }

        public void DestroyVisibilityQuery(IntPtr query)
        {
            if (query != IntPtr.Zero)
            {
                _api.VisibilityQueryDestroy(query);
            }
        }

        public void DrawWithVisibilityQuery(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndexBinding? indexBinding,
            IntPtr query
        )
        {
            if (query == IntPtr.Zero)
            {
                throw new ArgumentNullException(nameof(query));
            }
            _ = DrawCore(
                pipeline,
                colorTargets,
                state,
                vertexBindings,
                fragmentBindings,
                indexBinding,
                collectVisibility: false,
                visibilityQuery: query
            );
        }

        public ulong ResolveVisibilityQuery(IntPtr query)
        {
            if (query == IntPtr.Zero)
            {
                throw new ArgumentNullException(nameof(query));
            }
            ulong visibleSamples = 0;
            NativeStatus status = _api.VisibilityQueryResolve(
                RequireContext(),
                query,
                &visibleSamples
            );
            ThrowIfFailed(status, "visibility-query resolution");
            return visibleSamples;
        }

        private ulong DrawCore(
            IntPtr pipeline,
            ReadOnlySpan<GalRenderColorTarget> colorTargets,
            GalRenderDrawState state,
            GalStageBindings vertexBindings,
            GalStageBindings fragmentBindings,
            GalIndexBinding? indexBinding,
            bool collectVisibility,
            IntPtr visibilityQuery = default,
            GalIndirectBinding? indirectBinding = default,
            GalIndirectCountBinding? indirectCountBinding = default
        )
        {
            if (indirectCountBinding.HasValue && !indirectBinding.HasValue)
            {
                throw new ArgumentException(
                    "An indirect count requires an indirect command stream."
                );
            }
            if (indirectBinding.HasValue &&
                (collectVisibility || visibilityQuery != IntPtr.Zero))
            {
                throw new ArgumentException(
                    "An indirect draw cannot use SolMetal's diagnostic visibility path."
                );
            }
            if (collectVisibility && visibilityQuery != IntPtr.Zero)
            {
                throw new ArgumentException(
                    "A render draw cannot use synchronous and asynchronous visibility together."
                );
            }
            if (colorTargets.Length > 8)
            {
                throw new ArgumentException(
                    "SolMetal supports up to eight live color targets.",
                    nameof(colorTargets)
                );
            }
            NativeRenderDrawDescriptor descriptor = default;
            descriptor.StructSize = (uint)sizeof(NativeRenderDrawDescriptor);
            descriptor.AbiVersion = AbiVersion;
            descriptor.PrimitiveType = state.PrimitiveType;
            descriptor.VertexStart = state.VertexStart;
            descriptor.VertexCount = state.VertexCount;
            descriptor.InstanceCount = state.InstanceCount;
            descriptor.BaseInstance = state.BaseInstance;
            descriptor.ViewportX = state.ViewportX;
            descriptor.ViewportY = state.ViewportY;
            descriptor.ViewportWidth = state.ViewportWidth;
            descriptor.ViewportHeight = state.ViewportHeight;
            descriptor.ViewportNearZ = state.ViewportNearZ;
            descriptor.ViewportFarZ = state.ViewportFarZ;
            descriptor.ScissorX = state.ScissorX;
            descriptor.ScissorY = state.ScissorY;
            descriptor.ScissorWidth = state.ScissorWidth;
            descriptor.ScissorHeight = state.ScissorHeight;
            descriptor.BlendRed = state.BlendRed;
            descriptor.BlendGreen = state.BlendGreen;
            descriptor.BlendBlue = state.BlendBlue;
            descriptor.BlendAlpha = state.BlendAlpha;
            Span<NativeRenderColorTargetBinding> nativeColorTargets =
                stackalloc NativeRenderColorTargetBinding[colorTargets.Length];
            for (int index = 0; index < colorTargets.Length; index++)
            {
                GalRenderColorTarget source = colorTargets[index];
                nativeColorTargets[index] = new NativeRenderColorTargetBinding
                {
                    AttachmentIndex = source.AttachmentIndex,
                    Texture = source.Texture,
                    LoadAction = source.LoadAction,
                    StoreAction = source.StoreAction,
                    ClearRed = source.ClearRed,
                    ClearGreen = source.ClearGreen,
                    ClearBlue = source.ClearBlue,
                    ClearAlpha = source.ClearAlpha,
                };
            }
            const int MaximumStackBindings = 64;
            Span<NativeBufferBinding> nativeVertexBuffers =
                vertexBindings.Buffers.Length <= MaximumStackBindings
                    ? stackalloc NativeBufferBinding[vertexBindings.Buffers.Length]
                    : new NativeBufferBinding[vertexBindings.Buffers.Length];
            Span<NativeTextureBinding> nativeVertexTextures =
                vertexBindings.Textures.Length <= MaximumStackBindings
                    ? stackalloc NativeTextureBinding[vertexBindings.Textures.Length]
                    : new NativeTextureBinding[vertexBindings.Textures.Length];
            Span<NativeSamplerBinding> nativeVertexSamplers =
                vertexBindings.Samplers.Length <= MaximumStackBindings
                    ? stackalloc NativeSamplerBinding[vertexBindings.Samplers.Length]
                    : new NativeSamplerBinding[vertexBindings.Samplers.Length];
            Span<NativeBufferBinding> nativeFragmentBuffers =
                fragmentBindings.Buffers.Length <= MaximumStackBindings
                    ? stackalloc NativeBufferBinding[fragmentBindings.Buffers.Length]
                    : new NativeBufferBinding[fragmentBindings.Buffers.Length];
            Span<NativeTextureBinding> nativeFragmentTextures =
                fragmentBindings.Textures.Length <= MaximumStackBindings
                    ? stackalloc NativeTextureBinding[fragmentBindings.Textures.Length]
                    : new NativeTextureBinding[fragmentBindings.Textures.Length];
            Span<NativeSamplerBinding> nativeFragmentSamplers =
                fragmentBindings.Samplers.Length <= MaximumStackBindings
                    ? stackalloc NativeSamplerBinding[fragmentBindings.Samplers.Length]
                    : new NativeSamplerBinding[fragmentBindings.Samplers.Length];
            ConvertBufferBindings(vertexBindings.Buffers, nativeVertexBuffers);
            ConvertTextureBindings(vertexBindings.Textures, nativeVertexTextures);
            ConvertSamplerBindings(vertexBindings.Samplers, nativeVertexSamplers);
            ConvertBufferBindings(fragmentBindings.Buffers, nativeFragmentBuffers);
            ConvertTextureBindings(fragmentBindings.Textures, nativeFragmentTextures);
            ConvertSamplerBindings(fragmentBindings.Samplers, nativeFragmentSamplers);

            fixed (NativeRenderColorTargetBinding* nativeColors = nativeColorTargets)
            fixed (NativeBufferBinding* vertexBuffers = nativeVertexBuffers)
            fixed (NativeTextureBinding* vertexTextures = nativeVertexTextures)
            fixed (NativeSamplerBinding* vertexSamplers = nativeVertexSamplers)
            fixed (NativeBufferBinding* fragmentBuffers = nativeFragmentBuffers)
            fixed (NativeTextureBinding* fragmentTextures = nativeFragmentTextures)
            fixed (NativeSamplerBinding* fragmentSamplers = nativeFragmentSamplers)
            {
                NativeRenderStageBindings nativeVertexBindings = CreateStageBindings(
                    nativeVertexBuffers.Length,
                    nativeVertexTextures.Length,
                    nativeVertexSamplers.Length,
                    vertexBuffers,
                    vertexTextures,
                    vertexSamplers
                );
                NativeRenderStageBindings nativeFragmentBindings = CreateStageBindings(
                    nativeFragmentBuffers.Length,
                    nativeFragmentTextures.Length,
                    nativeFragmentSamplers.Length,
                    fragmentBuffers,
                    fragmentTextures,
                    fragmentSamplers
                );
                NativeStatus status;
                NativeRenderPassState nativePass = default;
                NativeRenderPassState* nativePassPointer = null;
                if (state.RenderPass is GalRenderPassState renderPass)
                {
                    nativePass.StructSize = (uint)sizeof(NativeRenderPassState);
                    nativePass.AbiVersion = AbiVersion;
                    nativePass.DepthStencilTarget = renderPass.DepthStencilTarget;
                    nativePass.DepthLoadAction = renderPass.DepthLoadAction;
                    nativePass.DepthStoreAction = renderPass.DepthStoreAction;
                    nativePass.StencilLoadAction = renderPass.StencilLoadAction;
                    nativePass.StencilStoreAction = renderPass.StencilStoreAction;
                    nativePass.ClearDepth = renderPass.ClearDepth;
                    nativePass.ClearStencil = renderPass.ClearStencil;
                    nativePass.StencilReferenceFront =
                        renderPass.StencilReferenceFront;
                    nativePass.StencilReferenceBack =
                        renderPass.StencilReferenceBack;
                    nativePassPointer = &nativePass;
                }
                NativeRasterizerState nativeRasterizer = default;
                nativeRasterizer.StructSize =
                    (uint)sizeof(NativeRasterizerState);
                nativeRasterizer.AbiVersion = AbiVersion;
                nativeRasterizer.FrontFace = state.Rasterizer.FrontFace;
                nativeRasterizer.CullMode = state.Rasterizer.CullMode;
                nativeRasterizer.TriangleFillMode =
                    state.Rasterizer.TriangleFillMode;
                nativeRasterizer.DepthClipMode =
                    state.Rasterizer.DepthClipMode;
                nativeRasterizer.DepthBias = state.Rasterizer.DepthBias;
                nativeRasterizer.DepthBiasSlopeScale =
                    state.Rasterizer.DepthBiasSlopeScale;
                nativeRasterizer.DepthBiasClamp =
                    state.Rasterizer.DepthBiasClamp;
                NativeRenderIndexBinding nativeIndex = default;
                NativeRenderIndexBinding* nativeIndexPointer = null;
                if (indexBinding is GalIndexBinding indexed)
                {
                    nativeIndex.StructSize = (uint)sizeof(NativeRenderIndexBinding);
                    nativeIndex.AbiVersion = AbiVersion;
                    nativeIndex.Buffer = indexed.Buffer;
                    nativeIndex.Offset = indexed.Offset;
                    nativeIndex.IndexType = indexed.Type;
                    nativeIndex.BaseVertex = indexed.BaseVertex;
                    nativeIndex.BaseInstance = indexed.BaseInstance;
                    nativeIndexPointer = &nativeIndex;
                }
                NativeRenderIndirectBinding nativeIndirect = default;
                NativeRenderIndirectBinding* nativeIndirectPointer = null;
                if (indirectBinding is GalIndirectBinding indirect)
                {
                    nativeIndirect.StructSize =
                        (uint)sizeof(NativeRenderIndirectBinding);
                    nativeIndirect.AbiVersion = AbiVersion;
                    nativeIndirect.Buffer = indirect.Buffer;
                    nativeIndirect.Offset = indirect.Offset;
                    nativeIndirect.Size = indirect.Size;
                    nativeIndirectPointer = &nativeIndirect;
                }
                NativeRenderIndirectCountBinding nativeIndirectCount = default;
                NativeRenderIndirectCountBinding* nativeIndirectCountPointer = null;
                if (indirectCountBinding is GalIndirectCountBinding count)
                {
                    nativeIndirectCount.StructSize =
                        (uint)sizeof(NativeRenderIndirectCountBinding);
                    nativeIndirectCount.AbiVersion = AbiVersion;
                    nativeIndirectCount.Buffer = count.Buffer;
                    nativeIndirectCount.Offset = count.Offset;
                    nativeIndirectCount.Size = count.Size;
                    nativeIndirectCount.MaxDrawCount = count.MaxDrawCount;
                    nativeIndirectCount.Stride = count.Stride;
                    nativeIndirectCountPointer = &nativeIndirectCount;
                }
                ulong visibleSamples = 0;
                status = nativeIndirectCountPointer != null
                    ? _api.RenderDrawMrtRasterizedIndirectCount(
                        RequireContext(),
                        pipeline,
                        &descriptor,
                        nativeColors,
                        checked((uint)nativeColorTargets.Length),
                        nativeIndirectPointer,
                        nativeIndirectCountPointer,
                        nativeIndexPointer,
                        &nativeVertexBindings,
                        &nativeFragmentBindings,
                        nativePassPointer,
                        &nativeRasterizer
                    )
                    : nativeIndirectPointer != null
                    ? _api.RenderDrawMrtRasterizedIndirect(
                        RequireContext(),
                        pipeline,
                        &descriptor,
                        nativeColors,
                        checked((uint)nativeColorTargets.Length),
                        nativeIndirectPointer,
                        nativeIndexPointer,
                        &nativeVertexBindings,
                        &nativeFragmentBindings,
                        nativePassPointer,
                        &nativeRasterizer
                    )
                    : visibilityQuery != IntPtr.Zero
                    ? _api.RenderDrawMrtRasterizedQuery(
                        RequireContext(),
                        pipeline,
                        &descriptor,
                        nativeColors,
                        checked((uint)nativeColorTargets.Length),
                        nativeIndexPointer,
                        &nativeVertexBindings,
                        &nativeFragmentBindings,
                        nativePassPointer,
                        &nativeRasterizer,
                        visibilityQuery
                    )
                    : collectVisibility
                    ? _api.RenderDrawMrtRasterizedVisibility(
                        RequireContext(),
                        pipeline,
                        &descriptor,
                        nativeColors,
                        checked((uint)nativeColorTargets.Length),
                        nativeIndexPointer,
                        &nativeVertexBindings,
                        &nativeFragmentBindings,
                        nativePassPointer,
                        &nativeRasterizer,
                        &visibleSamples
                    )
                    : _api.RenderDrawMrtRasterized(
                        RequireContext(),
                        pipeline,
                        &descriptor,
                        nativeColors,
                        checked((uint)nativeColorTargets.Length),
                        nativeIndexPointer,
                        &nativeVertexBindings,
                        &nativeFragmentBindings,
                        nativePassPointer,
                        &nativeRasterizer
                    );
                ThrowIfFailed(
                    status,
                    (indirectCountBinding.HasValue ? "counted indirect " :
                        indirectBinding.HasValue ? "indirect " : "") +
                    (indexBinding.HasValue ? "indexed render draw" : "render draw")
                );
                return visibleSamples;
            }
        }

        private static NativeBlendDescriptor CreateNativeBlend(
            GalBlendState state
        ) => new()
        {
            Enabled = state.Enabled ? 1u : 0u,
            RgbOperation = state.RgbOperation,
            AlphaOperation = state.AlphaOperation,
            SourceRgbFactor = state.SourceRgbFactor,
            DestinationRgbFactor = state.DestinationRgbFactor,
            SourceAlphaFactor = state.SourceAlphaFactor,
            DestinationAlphaFactor = state.DestinationAlphaFactor,
        };

        private static NativeStencilFaceDescriptor CreateNativeStencilFace(
            GalStencilFaceState state
        ) => new()
        {
            CompareFunction = state.CompareFunction,
            StencilFailureOperation = state.StencilFailureOperation,
            DepthFailureOperation = state.DepthFailureOperation,
            PassOperation = state.PassOperation,
            ReadMask = state.ReadMask,
            WriteMask = state.WriteMask,
        };

        private static NativeDepthStencilDescriptor CreateNativeDepthStencil(
            GalDepthStencilState state
        ) => new()
        {
            DepthCompareFunction = state.DepthCompareFunction,
            DepthWriteEnabled = state.DepthWriteEnabled ? 1u : 0u,
            StencilEnabled = state.StencilEnabled ? 1u : 0u,
            FrontFace = CreateNativeStencilFace(state.FrontFace),
            BackFace = CreateNativeStencilFace(state.BackFace),
        };

        private IntPtr TranslateShader(
            ReadOnlySpan<byte> spirv,
            NativeShaderStage stage,
            ReadOnlySpan<GalSpirvResourceBinding> resourceBindings,
            uint argumentBufferSetMask,
            bool disablePointSizeBuiltin,
            out bool writesPointSize
        )
        {
            writesPointSize = false;
            if (spirv.Length < 20 || spirv.Length % sizeof(uint) != 0)
            {
                throw new ArgumentException(
                    "SPIR-V must be a non-empty 32-bit word stream.",
                    nameof(spirv)
                );
            }
            Span<NativeSpirvResourceBinding> nativeBindings =
                resourceBindings.Length <= 64
                    ? stackalloc NativeSpirvResourceBinding[resourceBindings.Length]
                    : new NativeSpirvResourceBinding[resourceBindings.Length];
            for (int index = 0; index < resourceBindings.Length; index++)
            {
                GalSpirvResourceBinding source = resourceBindings[index];
                nativeBindings[index] = new NativeSpirvResourceBinding
                {
                    DescriptorSet = source.DescriptorSet,
                    Binding = source.Binding,
                    MetalBuffer = source.MetalBuffer,
                    MetalTexture = source.MetalTexture,
                    MetalSampler = source.MetalSampler,
                    ResourceArraySize = source.ArraySize,
                };
            }

            NativeSpirvTranslationOptions options = default;
            options.StructSize = (uint)sizeof(NativeSpirvTranslationOptions);
            options.AbiVersion = AbiVersion;
            options.Stage = stage;
            options.MslVersion = 30100;
            options.EnableArgumentBuffers = argumentBufferSetMask == 0 ? 0u : 1u;
            bool flipVertexY =
                stage == NativeShaderStage.Vertex &&
                Environment.GetEnvironmentVariable(
                    "SOL_METAL_DEBUG_DISABLE_SHADER_Y_FLIP"
                ) != "1";
            options.FlipVertexY = flipVertexY ? 1u : 0u;
            options.ResourceBindingCount = (uint)nativeBindings.Length;
            options.ArgumentBufferSetMask = argumentBufferSetMask;
            options.DisablePointSizeBuiltin =
                disablePointSizeBuiltin ? 1u : 0u;
            NativeSpirvTranslationReport report = default;
            report.StructSize = (uint)sizeof(NativeSpirvTranslationReport);
            IntPtr translation = IntPtr.Zero;
            fixed (byte* bytes = spirv)
            fixed (NativeSpirvResourceBinding* bindings = nativeBindings)
            {
                options.ResourceBindings = (IntPtr)bindings;
                NativeStatus status = _api.TranslateSpirv(
                    RequireContext(),
                    (uint*)bytes,
                    (ulong)(spirv.Length / sizeof(uint)),
                    &options,
                    &report,
                    &translation
                );
                ThrowIfFailed(status, $"{stage.ToString().ToLowerInvariant()} shader translation");
            }
            writesPointSize = report.WritesPointSize != 0;
            if (translation == IntPtr.Zero)
            {
                throw new InvalidOperationException(
                    "SolMetal returned no translated shader after successful compilation."
                );
            }
            return translation;
        }

        private static void ConvertBufferBindings(
            ReadOnlySpan<GalBufferBinding> bindings,
            Span<NativeBufferBinding> result
        )
        {
            if (result.Length != bindings.Length)
            {
                throw new ArgumentException("Native buffer binding span has the wrong length.");
            }
            for (int index = 0; index < bindings.Length; index++)
            {
                result[index] = new NativeBufferBinding
                {
                    Index = bindings[index].Index,
                    ArgumentBuffer = bindings[index].ArgumentBuffer,
                    Buffer = bindings[index].Buffer,
                    Offset = bindings[index].Offset,
                };
            }
        }

        private static void ConvertTextureBindings(
            ReadOnlySpan<GalTextureBinding> bindings,
            Span<NativeTextureBinding> result
        )
        {
            if (result.Length != bindings.Length)
            {
                throw new ArgumentException("Native texture binding span has the wrong length.");
            }
            for (int index = 0; index < bindings.Length; index++)
            {
                result[index] = new NativeTextureBinding
                {
                    Index = bindings[index].Index,
                    ArgumentBuffer = bindings[index].ArgumentBuffer,
                    Texture = bindings[index].Texture,
                };
            }
        }

        private static void ConvertSamplerBindings(
            ReadOnlySpan<GalSamplerBinding> bindings,
            Span<NativeSamplerBinding> result
        )
        {
            if (result.Length != bindings.Length)
            {
                throw new ArgumentException("Native sampler binding span has the wrong length.");
            }
            for (int index = 0; index < bindings.Length; index++)
            {
                result[index] = new NativeSamplerBinding
                {
                    Index = bindings[index].Index,
                    ArgumentBuffer = bindings[index].ArgumentBuffer,
                    Sampler = bindings[index].Sampler,
                };
            }
        }

        private static NativeRenderStageBindings CreateStageBindings(
            int bufferCount,
            int textureCount,
            int samplerCount,
            NativeBufferBinding* buffers,
            NativeTextureBinding* textures,
            NativeSamplerBinding* samplers
        )
        {
            NativeRenderStageBindings result = default;
            result.StructSize = (uint)sizeof(NativeRenderStageBindings);
            result.AbiVersion = AbiVersion;
            result.BufferBindingCount = (uint)bufferCount;
            result.TextureBindingCount = (uint)textureCount;
            result.SamplerBindingCount = (uint)samplerCount;
            result.BufferBindings = (IntPtr)buffers;
            result.TextureBindings = (IntPtr)textures;
            result.SamplerBindings = (IntPtr)samplers;
            return result;
        }

        public ulong SubmitTimeline()
        {
            ulong value = 0;
            NativeStatus status = _api.TimelineSubmit(RequireContext(), &value);
            ThrowIfFailed(status, "timeline submission");
            if (value == 0)
            {
                throw new InvalidOperationException(
                    "SolMetal returned an invalid zero timeline value."
                );
            }
            return value;
        }

        public void MemoryBarrier()
        {
            NativeStatus status = _api.MemoryBarrier(RequireContext());
            ThrowIfFailed(status, "memory barrier");
        }

        public TimelineSnapshot QueryTimeline()
        {
            NativeTimelineReport report = default;
            report.StructSize = (uint)sizeof(NativeTimelineReport);
            NativeStatus status = _api.TimelineQuery(RequireContext(), &report);
            ThrowIfFailed(status, "timeline query");
            return new TimelineSnapshot(
                report.LatestSubmittedValue,
                report.LatestCompletedValue,
                report.FirstFailedValue,
                report.LastStatus == NativeStatus.Ok,
                report.DrawRenderPassCount,
                report.BatchedDrawCount,
                report.DrawCommandBufferCount,
                report.DrawBoundaryFlushCount,
                report.MaximumDrawBatchSize,
                report.PendingDrawCount
            );
        }

        public RuntimeBatchSnapshot? QueryRuntimeBatch()
        {
            RuntimeBatchQueryDelegate? query = _api.RuntimeBatchQuery;
            if (query is null)
            {
                return null;
            }

            NativeRuntimeBatchReport report = default;
            report.StructSize = (uint)sizeof(NativeRuntimeBatchReport);
            NativeStatus status = query(RequireContext(), &report);
            if (status == NativeStatus.IncompatibleAbi)
            {
                // The telemetry API is optional and independently versioned.
                // An older compatible renderer must remain usable even when
                // it cannot populate this newer report layout.
                return null;
            }
            ThrowIfFailed(status, "runtime batch telemetry query");
            if (report.AbiVersion != AbiVersion)
            {
                return null;
            }
            return new RuntimeBatchSnapshot(
                report.DirectMutationBatchingEnabled != 0,
                report.MutationEncoderLimit,
                report.MutationTransientByteLimit,
                report.BatchedDrawCount,
                report.DrawCommandBufferCount,
                report.DrawRenderPassCount,
                report.BorrowedMutationCount,
                report.BorrowedMutationEncoderCount,
                report.BorrowedMutationTransientBytes,
                report.StandaloneMutationCount,
                report.DiscardedPendingCommandBufferCount,
                report.DiscardedPendingDrawCount,
                report.MaximumDrawBatchSize,
                report.MaximumMutationCount,
                report.MaximumMutationEncoderCount,
                report.MaximumMutationTransientBytes,
                report.PendingDrawCount,
                report.PendingMutationCount,
                report.PendingMutationEncoderCount,
                report.PendingMutationTransientBytes,
                report.FlushReasonCounts[0],
                report.FlushReasonCounts[1],
                report.FlushReasonCounts[2],
                report.FlushReasonCounts[3],
                report.FlushReasonCounts[4],
                report.FlushReasonCounts[5],
                report.FlushReasonCounts[6],
                report.FlushReasonCounts[7]
            );
        }

        public bool WaitTimeline(ulong value, TimeSpan timeout)
        {
            ulong timeoutNanoseconds = timeout == Timeout.InfiniteTimeSpan
                ? ulong.MaxValue
                : checked((ulong)Math.Max(0, timeout.TotalNanoseconds));
            NativeStatus status = _api.TimelineWait(
                RequireContext(),
                value,
                timeoutNanoseconds
            );
            if (status == NativeStatus.TimedOut)
            {
                return false;
            }
            ThrowIfFailed(status, "timeline wait");
            return true;
        }

        public bool WaitIdle(TimeSpan timeout)
        {
            ulong timeoutNanoseconds = timeout == Timeout.InfiniteTimeSpan
                ? ulong.MaxValue
                : checked((ulong)Math.Max(0, timeout.TotalNanoseconds));
            NativeStatus status = _api.WaitIdle(RequireContext(), timeoutNanoseconds);
            if (status == NativeStatus.TimedOut)
            {
                return false;
            }
            ThrowIfFailed(status, "queue idle wait");
            return true;
        }

        private IntPtr RequireContext()
        {
            IntPtr context = _context;
            return context != IntPtr.Zero
                ? context
                : throw new ObjectDisposedException(nameof(GalSession));
        }

        private void ThrowIfFailed(NativeStatus status, string operation)
        {
            if (status != NativeStatus.Ok)
            {
                string detail = LastErrorText();
                throw new InvalidOperationException(
                    $"SolMetal {operation} failed: {_api.StatusText(status)}" +
                    (string.IsNullOrWhiteSpace(detail) ? "" : $" ({detail})")
                );
            }
        }

        private string LastErrorText()
        {
            IntPtr context = _context;
            if (context == IntPtr.Zero)
            {
                return string.Empty;
            }
            Span<byte> bytes = stackalloc byte[512];
            fixed (byte* destination = bytes)
            {
                NativeStatus status = _api.ContextCopyLastError(
                    context,
                    destination,
                    (ulong)bytes.Length
                );
                return status == NativeStatus.Ok
                    ? Marshal.PtrToStringUTF8((IntPtr)destination) ??
                        string.Empty
                    : string.Empty;
            }
        }

        public void Dispose()
        {
            IntPtr context = Interlocked.Exchange(ref _context, IntPtr.Zero);
            if (context == IntPtr.Zero)
            {
                return;
            }

            // Timeline markers are non-blocking. Bound teardown so a lost GPU
            // cannot indefinitely hang Stop; the native completion handlers
            // retain their context safely if the deadline is missed.
            _ = _api.WaitIdle(context, 5_000_000_000);
            _api.ContextDestroy(context);
        }
    }

    internal readonly record struct TimelineSnapshot(
        ulong LatestSubmitted,
        ulong LatestCompleted,
        ulong FirstFailed,
        bool Healthy,
        uint DrawRenderPassCount,
        ulong BatchedDrawCount,
        ulong DrawCommandBufferCount,
        ulong DrawBoundaryFlushCount,
        uint MaximumDrawBatchSize,
        uint PendingDrawCount
    );

    internal readonly record struct RuntimeBatchSnapshot(
        bool DirectMutationBatchingEnabled,
        uint MutationEncoderLimit,
        ulong MutationTransientByteLimit,
        ulong BatchedDrawCount,
        ulong DrawCommandBufferCount,
        ulong DrawRenderPassCount,
        ulong BorrowedMutationCount,
        ulong BorrowedMutationEncoderCount,
        ulong BorrowedMutationTransientBytes,
        ulong StandaloneMutationCount,
        ulong DiscardedPendingCommandBufferCount,
        ulong DiscardedPendingDrawCount,
        uint MaximumDrawBatchSize,
        uint MaximumMutationCount,
        uint MaximumMutationEncoderCount,
        ulong MaximumMutationTransientBytes,
        uint PendingDrawCount,
        uint PendingMutationCount,
        uint PendingMutationEncoderCount,
        ulong PendingMutationTransientBytes,
        ulong DrawLimitFlushCount,
        ulong OrderedSubmissionFlushCount,
        ulong SynchronousSubmissionFlushCount,
        ulong TimelineFlushCount,
        ulong ContextDestroyFlushCount,
        ulong MutationEncoderLimitFlushCount,
        ulong MutationTransientLimitFlushCount,
        ulong ReservedFlushCount
    );

    private static byte[] BuildBootstrapPixels()
    {
        byte[] pixels = new byte[
            BootstrapTextureWidth * BootstrapTextureHeight * 4
        ];
        double centerX = (BootstrapTextureWidth - 1) * 0.5;
        double centerY = (BootstrapTextureHeight - 1) * 0.46;
        double radius = Math.Min(BootstrapTextureWidth, BootstrapTextureHeight) * 0.72;

        for (int y = 0; y < BootstrapTextureHeight; y++)
        {
            for (int x = 0; x < BootstrapTextureWidth; x++)
            {
                double dx = x - centerX;
                double dy = y - centerY;
                double glow = Math.Max(0.0, 1.0 - Math.Sqrt(dx * dx + dy * dy) / radius);
                double horizon = 1.0 - (double)y / (BootstrapTextureHeight - 1);
                int offset = (y * BootstrapTextureWidth + x) * 4;

                pixels[offset + 0] = (byte)Math.Clamp(22 + 74 * glow, 0, 255);
                pixels[offset + 1] = (byte)Math.Clamp(15 + 48 * glow + 11 * horizon, 0, 255);
                pixels[offset + 2] = (byte)Math.Clamp(10 + 28 * glow + 9 * horizon, 0, 255);
                pixels[offset + 3] = 255;
            }
        }
        return pixels;
    }

    private static ProbeResult Failed(string message) => new()
    {
        Success = false,
        Playable = false,
        AbiVersion = AbiVersion,
        Failure = message,
    };

    private static LoadResult Load()
    {
        List<string> failures = [];

        foreach (string candidate in CandidatePaths())
        {
            try
            {
                if (!NativeLibrary.TryLoad(candidate, out IntPtr handle))
                {
                    failures.Add($"{candidate}: load rejected");
                    continue;
                }

                try
                {
                    IntPtr abiAddress = NativeLibrary.GetExport(
                        handle,
                        "sol_metal_abi_version"
                    );
                    AbiVersionDelegate abiVersion =
                        Marshal.GetDelegateForFunctionPointer<AbiVersionDelegate>(
                            abiAddress
                        );
                    uint version = abiVersion();
                    if (version != AbiVersion)
                    {
                        NativeLibrary.Free(handle);
                        failures.Add(
                            $"{candidate}: ABI {version} is incompatible with ABI {AbiVersion}"
                        );
                        continue;
                    }
                    Api api = new(handle);
                    return new LoadResult(api, null);
                }
                catch
                {
                    NativeLibrary.Free(handle);
                    throw;
                }
            }
            catch (Exception exception)
            {
                failures.Add($"{candidate}: {exception.Message}");
            }
        }

        return new LoadResult(
            null,
            failures.Count == 0
                ? "SolMetal is not installed in this build."
                : "SolMetal is unavailable because no compatible ABI v2 library could be loaded."
        );
    }

    private static IEnumerable<string> CandidatePaths()
    {
        string? overridePath = Environment.GetEnvironmentVariable(
            "SOL_METAL_LIBRARY_PATH"
        );
        string contentsFrameworks = Path.GetFullPath(
            Path.Combine(AppContext.BaseDirectory, "..", "..", "Frameworks", "SolMetal.dylib")
        );
        string adjacent = Path.Combine(AppContext.BaseDirectory, "SolMetal.dylib");

        return new[] { overridePath, contentsFrameworks, adjacent, "SolMetal.dylib" }
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Select(path => path!)
            .Distinct(StringComparer.Ordinal);
    }

    private static string ReadUtf8(byte* bytes, int capacity)
    {
        int length = 0;
        while (length < capacity && bytes[length] != 0)
        {
            length++;
        }
        return length == 0
            ? string.Empty
            : Marshal.PtrToStringUTF8((IntPtr)bytes, length) ?? string.Empty;
    }

    private sealed record LoadResult(Api? Api, string? Error);

    private sealed class Api
    {
        public readonly AbiVersionDelegate AbiVersion;
        public readonly StatusStringDelegate StatusString;
        public readonly ContextCreateDelegate ContextCreate;
        public readonly ContextDestroyDelegate ContextDestroy;
        public readonly ContextCopyLastErrorDelegate ContextCopyLastError;
        public readonly ContextQueryCapabilitiesDelegate ContextQueryCapabilities;
        public readonly ContextRunValidationDelegate ContextRunValidation;
        public readonly PresentClearDelegate PresentClear;
        public readonly TextureCreateDelegate TextureCreate;
        public readonly TextureCreateBufferViewDelegate TextureCreateBufferView;
        public readonly TextureCreateViewDelegate TextureCreateView;
        public readonly TextureDestroyDelegate TextureDestroy;
        public readonly TextureUploadDelegate TextureUpload;
        public readonly TextureDownloadDelegate TextureDownload;
        public readonly TextureDownloadDelegate? TextureProbeDownloadDepth32;
        public readonly TextureDownloadDepthStencilSubresourceDelegate?
            TextureDownloadDepthStencilSubresource;
        public readonly TextureCopyToBufferDelegate TextureCopyToBuffer;
        public readonly TextureCopyDelegate TextureCopy;
        public readonly TextureCopySubresourceDelegate TextureCopySubresource;
        public readonly TextureCopySubresourceDelegate?
            TextureCopyR32FloatToDepth32;
        public readonly TextureClearColorDelegate TextureClearColor;
        public readonly TextureClearDepthStencilDelegate TextureClearDepthStencil;
        public readonly TextureBlitDelegate TextureBlit;
        public readonly PresentTextureDelegate PresentTexture;
        public readonly SamplerCreateDelegate SamplerCreate;
        public readonly SamplerDestroyDelegate SamplerDestroy;
        public readonly BufferCreateDelegate BufferCreate;
        public readonly BufferDestroyDelegate BufferDestroy;
        public readonly BufferUploadDelegate BufferUpload;
        public readonly BufferDownloadDelegate BufferDownload;
        public readonly BufferCopyDelegate BufferCopy;
        public readonly BufferFillU32Delegate BufferFillU32;
        public readonly BufferExpandQuadIndicesDelegate BufferExpandQuadIndices;
        public readonly MemoryBarrierDelegate MemoryBarrier;
        public readonly TimelineSubmitDelegate TimelineSubmit;
        public readonly TimelineQueryDelegate TimelineQuery;
        public readonly RuntimeBatchQueryDelegate? RuntimeBatchQuery;
        public readonly TimelineWaitDelegate TimelineWait;
        public readonly WaitIdleDelegate WaitIdle;
        public readonly TranslateSpirvDelegate TranslateSpirv;
        public readonly ShaderTranslationCopyMslDelegate ShaderTranslationCopyMsl;
        public readonly ShaderTranslationDestroyDelegate ShaderTranslationDestroy;
        public readonly ComputePipelineCreateDelegate ComputePipelineCreate;
        public readonly ComputePipelineDestroyDelegate ComputePipelineDestroy;
        public readonly ComputeDispatchDelegate ComputeDispatch;
        public readonly RenderPipelineCreateDelegate RenderPipelineCreate;
        public readonly RenderPipelineCreateWithVertexLayoutDelegate
            RenderPipelineCreateWithVertexLayout;
        public readonly RenderPipelineCreateAdvancedDelegate
            RenderPipelineCreateAdvanced;
        public readonly RenderPipelineCreateMrtDelegate RenderPipelineCreateMrt;
        public readonly RenderPipelineDestroyDelegate RenderPipelineDestroy;
        public readonly RenderDrawDelegate RenderDraw;
        public readonly RenderDrawBoundDelegate RenderDrawBound;
        public readonly RenderDrawIndexedBoundDelegate RenderDrawIndexedBound;
        public readonly RenderDrawRasterizedDelegate RenderDrawRasterized;
        public readonly RenderDrawMrtRasterizedDelegate RenderDrawMrtRasterized;
        public readonly RenderDrawMrtRasterizedIndirectDelegate
            RenderDrawMrtRasterizedIndirect;
        public readonly RenderDrawMrtRasterizedIndirectCountDelegate
            RenderDrawMrtRasterizedIndirectCount;
        public readonly RenderDrawMrtRasterizedVisibilityDelegate
            RenderDrawMrtRasterizedVisibility;
        public readonly VisibilityQueryCreateDelegate VisibilityQueryCreate;
        public readonly VisibilityQueryDestroyDelegate VisibilityQueryDestroy;
        public readonly VisibilityQueryResolveDelegate VisibilityQueryResolve;
        public readonly RenderDrawMrtRasterizedQueryDelegate
            RenderDrawMrtRasterizedQuery;

        public Api(IntPtr handle)
        {
            AbiVersion = Export<AbiVersionDelegate>(handle, "sol_metal_abi_version");
            StatusString = Export<StatusStringDelegate>(handle, "sol_metal_status_string");
            _ = NativeLibrary.GetExport(handle, "sol_metal_query_capabilities");
            ContextCreate = Export<ContextCreateDelegate>(handle, "sol_metal_context_create");
            ContextDestroy = Export<ContextDestroyDelegate>(handle, "sol_metal_context_destroy");
            ContextCopyLastError = Export<ContextCopyLastErrorDelegate>(
                handle,
                "sol_metal_context_copy_last_error"
            );
            ContextQueryCapabilities = Export<ContextQueryCapabilitiesDelegate>(
                handle,
                "sol_metal_context_query_capabilities"
            );
            ContextRunValidation = Export<ContextRunValidationDelegate>(
                handle,
                "sol_metal_context_run_validation"
            );
            PresentClear = Export<PresentClearDelegate>(
                handle,
                "sol_metal_context_present_clear"
            );
            TextureCreate = Export<TextureCreateDelegate>(
                handle,
                "sol_metal_context_texture_create_2d"
            );
            TextureCreateBufferView = Export<TextureCreateBufferViewDelegate>(
                handle,
                "sol_metal_context_texture_create_buffer_view"
            );
            TextureCreateView = Export<TextureCreateViewDelegate>(
                handle,
                "sol_metal_context_texture_create_view_2d"
            );
            TextureDestroy = Export<TextureDestroyDelegate>(
                handle,
                "sol_metal_texture_destroy"
            );
            TextureUpload = Export<TextureUploadDelegate>(
                handle,
                "sol_metal_context_texture_upload_2d"
            );
            TextureDownload = Export<TextureDownloadDelegate>(
                handle,
                "sol_metal_context_texture_download_2d"
            );
            TextureProbeDownloadDepth32 = OptionalExport<TextureDownloadDelegate>(
                handle,
                "sol_metal_context_texture_probe_download_depth32_2d"
            );
            TextureDownloadDepthStencilSubresource =
                OptionalExport<TextureDownloadDepthStencilSubresourceDelegate>(
                    handle,
                    "sol_metal_context_texture_download_depth_stencil_subresource_2d"
                );
            TextureCopyToBuffer = Export<TextureCopyToBufferDelegate>(
                handle,
                "sol_metal_context_texture_copy_to_buffer"
            );
            TextureCopy = Export<TextureCopyDelegate>(
                handle,
                "sol_metal_context_texture_copy_2d"
            );
            TextureCopySubresource = Export<TextureCopySubresourceDelegate>(
                handle,
                "sol_metal_context_texture_copy_subresource_2d"
            );
            TextureCopyR32FloatToDepth32 =
                OptionalExport<TextureCopySubresourceDelegate>(
                    handle,
                    "sol_metal_context_texture_copy_r32float_to_depth32_subresource_2d"
                );
            TextureClearColor = Export<TextureClearColorDelegate>(
                handle,
                "sol_metal_context_texture_clear_color"
            );
            TextureClearDepthStencil = Export<TextureClearDepthStencilDelegate>(
                handle,
                "sol_metal_context_texture_clear_depth_stencil"
            );
            TextureBlit = Export<TextureBlitDelegate>(
                handle,
                "sol_metal_context_texture_blit_2d"
            );
            PresentTexture = Export<PresentTextureDelegate>(
                handle,
                "sol_metal_context_present_texture"
            );
            SamplerCreate = Export<SamplerCreateDelegate>(
                handle,
                "sol_metal_context_sampler_create"
            );
            SamplerDestroy = Export<SamplerDestroyDelegate>(
                handle,
                "sol_metal_sampler_destroy"
            );
            BufferCreate = Export<BufferCreateDelegate>(
                handle,
                "sol_metal_context_buffer_create"
            );
            BufferDestroy = Export<BufferDestroyDelegate>(
                handle,
                "sol_metal_buffer_destroy"
            );
            BufferUpload = Export<BufferUploadDelegate>(
                handle,
                "sol_metal_context_buffer_upload"
            );
            BufferDownload = Export<BufferDownloadDelegate>(
                handle,
                "sol_metal_context_buffer_download"
            );
            BufferCopy = Export<BufferCopyDelegate>(
                handle,
                "sol_metal_context_buffer_copy"
            );
            BufferFillU32 = Export<BufferFillU32Delegate>(
                handle,
                "sol_metal_context_buffer_fill_u32"
            );
            BufferExpandQuadIndices = Export<BufferExpandQuadIndicesDelegate>(
                handle,
                "sol_metal_context_buffer_expand_quad_indices"
            );
            MemoryBarrier = Export<MemoryBarrierDelegate>(
                handle,
                "sol_metal_context_memory_barrier"
            );
            TimelineSubmit = Export<TimelineSubmitDelegate>(
                handle,
                "sol_metal_context_timeline_submit"
            );
            TimelineQuery = Export<TimelineQueryDelegate>(
                handle,
                "sol_metal_context_timeline_query"
            );
            RuntimeBatchQuery = OptionalExport<RuntimeBatchQueryDelegate>(
                handle,
                "sol_metal_context_runtime_batch_query"
            );
            TimelineWait = Export<TimelineWaitDelegate>(
                handle,
                "sol_metal_context_timeline_wait"
            );
            WaitIdle = Export<WaitIdleDelegate>(
                handle,
                "sol_metal_context_wait_idle"
            );
            TranslateSpirv = Export<TranslateSpirvDelegate>(
                handle,
                "sol_metal_context_translate_spirv"
            );
            ShaderTranslationCopyMsl = Export<ShaderTranslationCopyMslDelegate>(
                handle,
                "sol_metal_shader_translation_copy_msl"
            );
            ShaderTranslationDestroy = Export<ShaderTranslationDestroyDelegate>(
                handle,
                "sol_metal_shader_translation_destroy"
            );
            ComputePipelineCreate = Export<ComputePipelineCreateDelegate>(
                handle,
                "sol_metal_context_compute_pipeline_create"
            );
            ComputePipelineDestroy = Export<ComputePipelineDestroyDelegate>(
                handle,
                "sol_metal_compute_pipeline_destroy"
            );
            ComputeDispatch = Export<ComputeDispatchDelegate>(
                handle,
                "sol_metal_context_compute_dispatch"
            );
            RenderPipelineCreate = Export<RenderPipelineCreateDelegate>(
                handle,
                "sol_metal_context_render_pipeline_create"
            );
            RenderPipelineCreateWithVertexLayout =
                Export<RenderPipelineCreateWithVertexLayoutDelegate>(
                    handle,
                    "sol_metal_context_render_pipeline_create_with_vertex_layout"
                );
            RenderPipelineCreateAdvanced =
                Export<RenderPipelineCreateAdvancedDelegate>(
                    handle,
                    "sol_metal_context_render_pipeline_create_advanced"
                );
            RenderPipelineCreateMrt = Export<RenderPipelineCreateMrtDelegate>(
                handle,
                "sol_metal_context_render_pipeline_create_mrt"
            );
            RenderPipelineDestroy = Export<RenderPipelineDestroyDelegate>(
                handle,
                "sol_metal_render_pipeline_destroy"
            );
            RenderDraw = Export<RenderDrawDelegate>(
                handle,
                "sol_metal_context_render_draw"
            );
            RenderDrawBound = Export<RenderDrawBoundDelegate>(
                handle,
                "sol_metal_context_render_draw_bound"
            );
            RenderDrawIndexedBound = Export<RenderDrawIndexedBoundDelegate>(
                handle,
                "sol_metal_context_render_draw_indexed_bound"
            );
            RenderDrawRasterized = Export<RenderDrawRasterizedDelegate>(
                handle,
                "sol_metal_context_render_draw_rasterized"
            );
            RenderDrawMrtRasterized = Export<RenderDrawMrtRasterizedDelegate>(
                handle,
                "sol_metal_context_render_draw_mrt_rasterized"
            );
            RenderDrawMrtRasterizedIndirect =
                Export<RenderDrawMrtRasterizedIndirectDelegate>(
                    handle,
                    "sol_metal_context_render_draw_mrt_rasterized_indirect"
                );
            RenderDrawMrtRasterizedIndirectCount =
                Export<RenderDrawMrtRasterizedIndirectCountDelegate>(
                    handle,
                    "sol_metal_context_render_draw_mrt_rasterized_indirect_count"
                );
            RenderDrawMrtRasterizedVisibility =
                Export<RenderDrawMrtRasterizedVisibilityDelegate>(
                    handle,
                    "sol_metal_context_render_draw_mrt_rasterized_visibility"
                );
            VisibilityQueryCreate = Export<VisibilityQueryCreateDelegate>(
                handle,
                "sol_metal_context_visibility_query_create"
            );
            VisibilityQueryDestroy = Export<VisibilityQueryDestroyDelegate>(
                handle,
                "sol_metal_visibility_query_destroy"
            );
            VisibilityQueryResolve = Export<VisibilityQueryResolveDelegate>(
                handle,
                "sol_metal_context_visibility_query_resolve"
            );
            RenderDrawMrtRasterizedQuery =
                Export<RenderDrawMrtRasterizedQueryDelegate>(
                    handle,
                    "sol_metal_context_render_draw_mrt_rasterized_query"
                );
            _ = NativeLibrary.GetExport(handle, "sol_metal_shader_translation_copy_msl");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_buffer_create");
            _ = NativeLibrary.GetExport(handle, "sol_metal_buffer_destroy");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_buffer_upload");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_buffer_download");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_buffer_copy");
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_buffer_fill_u32"
            );
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_texture_create_2d");
            _ = NativeLibrary.GetExport(handle, "sol_metal_texture_destroy");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_texture_upload_2d");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_texture_download_2d");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_texture_copy_2d");
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_texture_copy_subresource_2d"
            );
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_texture_clear_color"
            );
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_texture_clear_depth_stencil"
            );
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_sampler_create");
            _ = NativeLibrary.GetExport(handle, "sol_metal_sampler_destroy");
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_compute_pipeline_create"
            );
            _ = NativeLibrary.GetExport(handle, "sol_metal_compute_pipeline_destroy");
            _ = NativeLibrary.GetExport(handle, "sol_metal_compute_pipeline_query_info");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_compute_dispatch");
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_render_pipeline_create"
            );
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_render_pipeline_create_with_vertex_layout"
            );
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_render_pipeline_create_advanced"
            );
            _ = NativeLibrary.GetExport(handle, "sol_metal_render_pipeline_destroy");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_render_draw");
            _ = NativeLibrary.GetExport(handle, "sol_metal_context_render_draw_bound");
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_render_draw_indexed_bound"
            );
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_render_draw_advanced"
            );
            _ = NativeLibrary.GetExport(
                handle,
                "sol_metal_context_render_draw_rasterized"
            );
        }

        public string StatusText(NativeStatus status)
        {
            IntPtr text = StatusString(status);
            return text == IntPtr.Zero
                ? status.ToString()
                : Marshal.PtrToStringUTF8(text) ?? status.ToString();
        }

        private static T Export<T>(IntPtr handle, string symbol) where T : Delegate =>
            Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(handle, symbol));

        private static T? OptionalExport<T>(IntPtr handle, string symbol)
            where T : Delegate =>
            NativeLibrary.TryGetExport(handle, symbol, out IntPtr address)
                ? Marshal.GetDelegateForFunctionPointer<T>(address)
                : null;
    }

    private enum NativeStatus : int
    {
        Ok = 0,
        IncompatibleAbi = 2,
        OutputTooSmall = 13,
        TimedOut = 14,
    }

    private enum NativeTexturePixelFormat : int
    {
        Rgba8Unorm = 1,
        Bgra8Unorm = 2,
        R32Uint = 3,
        Rgba16Float = 4,
        Depth32Float = 5,
        Depth32FloatStencil8 = 6,
        R8Unorm = 7,
        Rg8Unorm = 8,
        R16Unorm = 9,
        Rg16Unorm = 10,
        R16Float = 11,
        Rg16Float = 12,
        R32Float = 13,
        Rg32Float = 14,
        Rgba32Float = 15,
        Rgba8Srgb = 16,
        Bgra8Srgb = 17,
        R32Sint = 18,
        Rg16Snorm = 19,
        R8Uint = 20,
        Rg11B10Float = 21,
        D24UnormStencil8 = 22,
        Bc1RgbaUnorm = 23,
        Bc1RgbaSrgb = 24,
        Bc2RgbaUnorm = 25,
        Bc2RgbaSrgb = 26,
        Bc3RgbaUnorm = 27,
        Bc3RgbaSrgb = 28,
        Bc4RUnorm = 29,
        Bc4RSnorm = 30,
        Bc5RgUnorm = 31,
        Bc5RgSnorm = 32,
        Bc6hRgbFloat = 33,
        Bc6hRgbUfloat = 34,
        Bc7RgbaUnorm = 35,
        Bc7RgbaSrgb = 36,
        Rgb10A2Unorm = 37,
        Rgb10A2Uint = 38,
        Rgb9E5Float = 39,
        Bgr10A2Unorm = 40,
        Rgba32Uint = 41,
        Depth16Unorm = 42,
        Rgba16Uint = 43,
        Rgba16Unorm = 44,
    }

    private enum NativeBufferStorageMode : int
    {
        Shared = 1,
        Private = 2,
    }

    [Flags]
    private enum NativeTextureUsage : uint
    {
        Sampled = 1u << 0,
        Storage = 1u << 1,
        RenderTarget = 1u << 2,
        All = Sampled | Storage | RenderTarget,
    }

    private enum NativeSamplerFilter : int
    {
        Linear = 2,
    }

    private enum NativeShaderStage : int
    {
        Vertex = 1,
        Fragment = 5,
        Compute = 6,
    }

    private enum NativePrimitiveType : int
    {
        Triangle = 4,
    }

    private enum NativeRenderLoadAction : int
    {
        Clear = 3,
    }

    private enum NativeRenderStoreAction : int
    {
        Store = 2,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSpirvResourceBinding
    {
        public uint DescriptorSet;
        public uint Binding;
        public uint MetalBuffer;
        public uint MetalTexture;
        public uint MetalSampler;
        public uint ResourceArraySize;
        public fixed uint Reserved[2];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeCapabilities
    {
        public uint StructSize;
        public uint AbiVersion;
        public ulong RegistryId;
        public ulong MaxBufferLength;
        public ulong RecommendedMaxWorkingSetSize;
        public uint MaxThreadsPerThreadgroup;
        public uint AppleGpuFamily;
        public uint ArgumentBufferTier;
        public uint HasUnifiedMemory;
        public uint IsLowPower;
        public uint IsRemovable;
        public uint IsHeadless;
        public uint SupportsBcTextureCompression;
        public uint SupportsRayTracing;
        public uint SupportsBinaryArchives;
        public uint SupportsLayeredVertexOutput;
        public fixed uint Reserved[7];
        public fixed byte DeviceName[DeviceNameCapacity];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeValidationReport
    {
        public uint StructSize;
        public uint AbiVersion;
        public uint RequestedFlags;
        public uint CompletedFlags;
        public uint IterationsRequested;
        public uint IterationsCompleted;
        public uint TestsRun;
        public uint TestsPassed;
        public ulong CommandBuffersCompleted;
        public ulong BytesVerified;
        public ulong OutputSignature;
        public ulong GpuTimeNanoseconds;
        public NativeStatus LastStatus;
        public uint ShaderCacheHits;
        public uint ShaderCacheMisses;
        public uint BinaryArchivesCreated;
        public fixed uint Reserved[4];
        public fixed byte LastError[ErrorCapacity];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTextureDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public uint Width;
        public uint Height;
        public NativeTexturePixelFormat PixelFormat;
        public NativeBufferStorageMode StorageMode;
        public NativeTextureUsage Usage;
        public GalTextureType TextureType;
        public uint DepthOrArrayLength;
        public uint MipmapLevelCount;
        public uint SampleCount;
        public GalTextureSwizzle SwizzleR;
        public GalTextureSwizzle SwizzleG;
        public GalTextureSwizzle SwizzleB;
        public GalTextureSwizzle SwizzleA;
        public fixed uint Reserved[1];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTextureViewDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public GalTextureFormat PixelFormat;
        public GalTextureSwizzle SwizzleR;
        public GalTextureSwizzle SwizzleG;
        public GalTextureSwizzle SwizzleB;
        public GalTextureSwizzle SwizzleA;
        public uint FirstLevel;
        public uint LevelCount;
        public uint FirstSlice;
        public uint SliceCount;
        public GalTextureType TextureType;
        public fixed uint Reserved[7];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTextureBlitDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public int SourceX1;
        public int SourceY1;
        public int SourceX2;
        public int SourceY2;
        public int DestinationX1;
        public int DestinationY1;
        public int DestinationX2;
        public int DestinationY2;
        public uint LinearFilter;
        public uint SourceSlice;
        public uint SourceLevel;
        public uint DestinationSlice;
        public uint DestinationLevel;
        public fixed uint Reserved[3];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTextureCopyDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public uint SourceSlice;
        public uint DestinationSlice;
        public uint SourceLevel;
        public uint DestinationLevel;
        public uint Width;
        public uint Height;
        public fixed uint Reserved[8];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTextureClearColorDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public uint FirstSlice;
        public uint SliceCount;
        public uint ComponentMask;
        public uint Flags;
        public double ClearRed;
        public double ClearGreen;
        public double ClearBlue;
        public double ClearAlpha;
        public uint ClearX;
        public uint ClearY;
        public uint ClearWidth;
        public uint ClearHeight;
        public uint ClearRedBits;
        public uint ClearGreenBits;
        public uint ClearBlueBits;
        public uint ClearAlphaBits;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTextureClearDepthStencilDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public uint FirstSlice;
        public uint SliceCount;
        public uint DepthMask;
        public uint StencilMask;
        public double ClearDepth;
        public uint ClearStencil;
        public uint Flags;
        public uint ClearX;
        public uint ClearY;
        public uint ClearWidth;
        public uint ClearHeight;
        public fixed uint Reserved[4];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeBufferDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public ulong Size;
        public NativeBufferStorageMode StorageMode;
        public fixed uint Reserved[11];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTimelineReport
    {
        public uint StructSize;
        public uint AbiVersion;
        public ulong LatestSubmittedValue;
        public ulong LatestCompletedValue;
        public ulong FirstFailedValue;
        public NativeStatus LastStatus;
        public uint DrawRenderPassCount;
        public ulong BatchedDrawCount;
        public ulong DrawCommandBufferCount;
        public ulong DrawBoundaryFlushCount;
        public uint MaximumDrawBatchSize;
        public uint PendingDrawCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRuntimeBatchReport
    {
        public uint StructSize;
        public uint AbiVersion;
        public uint DirectMutationBatchingEnabled;
        public uint MutationEncoderLimit;
        public ulong MutationTransientByteLimit;
        public ulong BatchedDrawCount;
        public ulong DrawCommandBufferCount;
        public ulong DrawRenderPassCount;
        public ulong BorrowedMutationCount;
        public ulong BorrowedMutationEncoderCount;
        public ulong BorrowedMutationTransientBytes;
        public ulong StandaloneMutationCount;
        public ulong DiscardedPendingCommandBufferCount;
        public ulong DiscardedPendingDrawCount;
        public uint MaximumDrawBatchSize;
        public uint MaximumMutationCount;
        public uint MaximumMutationEncoderCount;
        public uint PendingDrawCount;
        public uint PendingMutationCount;
        public uint PendingMutationEncoderCount;
        public ulong MaximumMutationTransientBytes;
        public ulong PendingMutationTransientBytes;
        public fixed ulong FlushReasonCounts[8];
        public fixed ulong Reserved[8];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSpirvTranslationOptions
    {
        public uint StructSize;
        public uint AbiVersion;
        public NativeShaderStage Stage;
        public uint MslVersion;
        public uint EnableArgumentBuffers;
        public uint FlipVertexY;
        public uint ResourceBindingCount;
        public uint ArgumentBufferSetMask;
        public IntPtr ResourceBindings;
        public uint DisablePointSizeBuiltin;
        public fixed uint Reserved[7];
        public fixed byte EntryPoint[128];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSpirvTranslationReport
    {
        public uint StructSize;
        public uint AbiVersion;
        public NativeShaderStage Stage;
        public uint MslVersion;
        public ulong SpirvBytes;
        public ulong MslSourceBytes;
        public uint EntryPointCount;
        public uint UniformBufferCount;
        public uint StorageBufferCount;
        public uint SampledImageCount;
        public uint SeparateImageCount;
        public uint StorageImageCount;
        public uint SeparateSamplerCount;
        public uint PushConstantBufferCount;
        public uint StageInputCount;
        public uint StageOutputCount;
        public uint RemappedBindingCount;
        public uint ArgumentBuffersEnabled;
        public uint MetalLibraryCompiled;
        public uint MetalFunctionCreated;
        public uint WritesPointSize;
        public fixed uint Reserved[7];
        public fixed byte EntryPoint[128];
        public fixed byte LastError[ErrorCapacity];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderPipelineDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public IntPtr VertexTranslation;
        public IntPtr FragmentTranslation;
        public GalTextureFormat ColorFormat;
        public uint ColorWriteMask;
        public uint AlphaToCoverageEnabled;
        public uint AlphaToCoverageDitherEnabled;
        public uint AlphaToOneEnabled;
        public GalPrimitiveTopologyClass InputPrimitiveTopology;
        public fixed uint Reserved[6];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeBlendDescriptor
    {
        public uint Enabled;
        public GalBlendOperation RgbOperation;
        public GalBlendOperation AlphaOperation;
        public GalBlendFactor SourceRgbFactor;
        public GalBlendFactor DestinationRgbFactor;
        public GalBlendFactor SourceAlphaFactor;
        public GalBlendFactor DestinationAlphaFactor;
        public fixed uint Reserved[5];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeStencilFaceDescriptor
    {
        public GalCompareFunction CompareFunction;
        public GalStencilOperation StencilFailureOperation;
        public GalStencilOperation DepthFailureOperation;
        public GalStencilOperation PassOperation;
        public uint ReadMask;
        public uint WriteMask;
        public fixed uint Reserved[4];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeDepthStencilDescriptor
    {
        public GalCompareFunction DepthCompareFunction;
        public uint DepthWriteEnabled;
        public uint StencilEnabled;
        public uint Reserved0;
        public NativeStencilFaceDescriptor FrontFace;
        public NativeStencilFaceDescriptor BackFace;
        public fixed uint Reserved[8];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderPipelineAdvancedDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public IntPtr VertexTranslation;
        public IntPtr FragmentTranslation;
        public GalTextureFormat ColorFormat;
        public uint ColorWriteMask;
        public GalTextureFormat DepthStencilFormat;
        public uint ColorAttachmentIndex;
        public NativeBlendDescriptor ColorBlend;
        public NativeDepthStencilDescriptor DepthStencil;
        public uint AlphaToCoverageEnabled;
        public uint AlphaToCoverageDitherEnabled;
        public uint AlphaToOneEnabled;
        public GalPrimitiveTopologyClass InputPrimitiveTopology;
        public fixed uint Reserved[4];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderColorAttachmentDescriptor
    {
        public uint AttachmentIndex;
        public GalTextureFormat PixelFormat;
        public uint ColorWriteMask;
        public uint Reserved0;
        public NativeBlendDescriptor Blend;
        public fixed uint Reserved[4];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderPipelineMrtDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public IntPtr VertexTranslation;
        public IntPtr FragmentTranslation;
        public uint ColorAttachmentCount;
        public GalTextureFormat DepthStencilFormat;
        public IntPtr ColorAttachments;
        public NativeDepthStencilDescriptor DepthStencil;
        public uint AlphaToCoverageEnabled;
        public uint AlphaToCoverageDitherEnabled;
        public uint AlphaToOneEnabled;
        public GalPrimitiveTopologyClass InputPrimitiveTopology;
        public fixed uint Reserved[4];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeVertexBufferLayout
    {
        public uint BufferIndex;
        public uint Stride;
        public GalVertexStepFunction StepFunction;
        public uint StepRate;
        public fixed uint Reserved[4];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeVertexAttribute
    {
        public uint Location;
        public uint BufferIndex;
        public GalVertexFormat Format;
        public uint Offset;
        public fixed uint Reserved[4];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeBufferBinding
    {
        public uint Index;
        public uint ArgumentBuffer;
        public IntPtr Buffer;
        public ulong Offset;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTextureBinding
    {
        public uint Index;
        public uint ArgumentBuffer;
        public IntPtr Texture;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSamplerBinding
    {
        public uint Index;
        public uint ArgumentBuffer;
        public IntPtr Sampler;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeComputeDispatchDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public uint ThreadCountX;
        public uint ThreadCountY;
        public uint ThreadCountZ;
        public uint ThreadgroupSizeX;
        public uint ThreadgroupSizeY;
        public uint ThreadgroupSizeZ;
        public uint BufferBindingCount;
        public uint TextureBindingCount;
        public uint SamplerBindingCount;
        public uint Reserved0;
        public IntPtr BufferBindings;
        public IntPtr TextureBindings;
        public IntPtr SamplerBindings;
        public fixed uint Reserved[8];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderStageBindings
    {
        public uint StructSize;
        public uint AbiVersion;
        public uint BufferBindingCount;
        public uint TextureBindingCount;
        public uint SamplerBindingCount;
        public uint Reserved0;
        public IntPtr BufferBindings;
        public IntPtr TextureBindings;
        public IntPtr SamplerBindings;
        public fixed uint Reserved[8];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderIndexBinding
    {
        public uint StructSize;
        public uint AbiVersion;
        public IntPtr Buffer;
        public ulong Offset;
        public GalIndexType IndexType;
        public int BaseVertex;
        public uint BaseInstance;
        public fixed uint Reserved[8];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderIndirectBinding
    {
        public uint StructSize;
        public uint AbiVersion;
        public IntPtr Buffer;
        public ulong Offset;
        public ulong Size;
        public fixed uint Reserved[6];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderIndirectCountBinding
    {
        public uint StructSize;
        public uint AbiVersion;
        public IntPtr Buffer;
        public ulong Offset;
        public ulong Size;
        public uint MaxDrawCount;
        public uint Stride;
        public fixed uint Reserved[6];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderDrawDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public IntPtr ColorTarget;
        public GalPrimitiveType PrimitiveType;
        public GalRenderLoadAction LoadAction;
        public GalRenderStoreAction StoreAction;
        public uint VertexStart;
        public uint VertexCount;
        public uint InstanceCount;
        public uint BaseInstance;
        public double ClearRed;
        public double ClearGreen;
        public double ClearBlue;
        public double ClearAlpha;
        public double ViewportX;
        public double ViewportY;
        public double ViewportWidth;
        public double ViewportHeight;
        public double ViewportNearZ;
        public double ViewportFarZ;
        public uint ScissorX;
        public uint ScissorY;
        public uint ScissorWidth;
        public uint ScissorHeight;
        public uint ColorAttachmentIndex;
        public float BlendRed;
        public float BlendGreen;
        public float BlendBlue;
        public float BlendAlpha;
        public fixed uint Reserved[3];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderColorTargetBinding
    {
        public uint AttachmentIndex;
        public GalRenderLoadAction LoadAction;
        public GalRenderStoreAction StoreAction;
        public uint Reserved0;
        public IntPtr Texture;
        public double ClearRed;
        public double ClearGreen;
        public double ClearBlue;
        public double ClearAlpha;
        public fixed uint Reserved[4];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRenderPassState
    {
        public uint StructSize;
        public uint AbiVersion;
        public IntPtr DepthStencilTarget;
        public GalRenderLoadAction DepthLoadAction;
        public GalRenderStoreAction DepthStoreAction;
        public GalRenderLoadAction StencilLoadAction;
        public GalRenderStoreAction StencilStoreAction;
        public double ClearDepth;
        public uint ClearStencil;
        public uint StencilReferenceFront;
        public uint StencilReferenceBack;
        public fixed uint Reserved[8];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRasterizerState
    {
        public uint StructSize;
        public uint AbiVersion;
        public GalFrontFaceWinding FrontFace;
        public GalCullMode CullMode;
        public GalTriangleFillMode TriangleFillMode;
        public GalDepthClipMode DepthClipMode;
        public float DepthBias;
        public float DepthBiasSlopeScale;
        public float DepthBiasClamp;
        public uint Reserved0;
        public fixed uint Reserved[8];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePresentTextureDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public IntPtr SourceTexture;
        public uint PixelWidth;
        public uint PixelHeight;
        public NativeSamplerFilter Filter;
        public int SourceLeft;
        public int SourceTop;
        public int SourceRight;
        public int SourceBottom;
        public float AspectRatioX;
        public float AspectRatioY;
        public uint Flags;
        public fixed uint Reserved[2];
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSamplerDescriptor
    {
        public uint StructSize;
        public uint AbiVersion;
        public GalSamplerFilter MinFilter;
        public GalSamplerFilter MagFilter;
        public GalSamplerMipFilter MipFilter;
        public GalSamplerAddressMode AddressU;
        public GalSamplerAddressMode AddressV;
        public GalSamplerAddressMode AddressW;
        public uint MaxAnisotropy;
        public float LodMinClamp;
        public float LodMaxClamp;
        public GalSamplerBorderColor BorderColor;
        public uint CompareEnabled;
        public GalCompareFunction CompareFunction;
        public float LodBias;
        public uint Reserved0;
        public fixed uint Reserved[4];
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate uint AbiVersionDelegate();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate IntPtr StatusStringDelegate(NativeStatus status);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus ContextCreateDelegate(IntPtr* context);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void ContextDestroyDelegate(IntPtr context);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus ContextCopyLastErrorDelegate(
        IntPtr context,
        byte* destination,
        ulong capacity
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus ContextQueryCapabilitiesDelegate(
        IntPtr context,
        NativeCapabilities* capabilities
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus ContextRunValidationDelegate(
        IntPtr context,
        uint flags,
        uint iterations,
        NativeValidationReport* report
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus PresentClearDelegate(
        IntPtr context,
        nint metalLayer,
        uint pixelWidth,
        uint pixelHeight,
        double red,
        double green,
        double blue,
        double alpha
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureCreateDelegate(
        IntPtr context,
        NativeTextureDescriptor* descriptor,
        IntPtr* texture
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureCreateBufferViewDelegate(
        IntPtr context,
        IntPtr buffer,
        ulong bufferOffset,
        ulong bufferSize,
        NativeTextureDescriptor* descriptor,
        IntPtr* texture
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureCreateViewDelegate(
        IntPtr context,
        IntPtr source,
        NativeTextureViewDescriptor* descriptor,
        IntPtr* texture
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void TextureDestroyDelegate(IntPtr texture);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureUploadDelegate(
        IntPtr context,
        IntPtr texture,
        void* source,
        ulong sourceBytesPerRow,
        ulong sourceSize
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureDownloadDelegate(
        IntPtr context,
        IntPtr texture,
        void* destination,
        ulong destinationBytesPerRow,
        ulong destinationSize
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureDownloadDepthStencilSubresourceDelegate(
        IntPtr context,
        IntPtr texture,
        uint sourceSlice,
        uint sourceLevel,
        void* destination,
        ulong destinationBytesPerRow,
        ulong destinationSize
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureCopyToBufferDelegate(
        IntPtr context,
        IntPtr texture,
        uint sourceSlice,
        uint sourceLevel,
        IntPtr destination,
        ulong destinationOffset,
        ulong destinationSize,
        ulong destinationBytesPerRow
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureCopyDelegate(
        IntPtr context,
        IntPtr source,
        IntPtr destination
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureCopySubresourceDelegate(
        IntPtr context,
        IntPtr source,
        IntPtr destination,
        NativeTextureCopyDescriptor* descriptor
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureClearColorDelegate(
        IntPtr context,
        IntPtr texture,
        NativeTextureClearColorDescriptor* descriptor
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureClearDepthStencilDelegate(
        IntPtr context,
        IntPtr texture,
        NativeTextureClearDepthStencilDescriptor* descriptor
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TextureBlitDelegate(
        IntPtr context,
        IntPtr source,
        IntPtr destination,
        NativeTextureBlitDescriptor* descriptor
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus SamplerCreateDelegate(
        IntPtr context,
        NativeSamplerDescriptor* descriptor,
        IntPtr* sampler
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void SamplerDestroyDelegate(IntPtr sampler);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus PresentTextureDelegate(
        IntPtr context,
        nint metalLayer,
        NativePresentTextureDescriptor* descriptor
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus BufferCreateDelegate(
        IntPtr context,
        NativeBufferDescriptor* descriptor,
        IntPtr* buffer
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void BufferDestroyDelegate(IntPtr buffer);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus BufferUploadDelegate(
        IntPtr context,
        IntPtr buffer,
        ulong destinationOffset,
        void* source,
        ulong size
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus BufferDownloadDelegate(
        IntPtr context,
        IntPtr buffer,
        ulong sourceOffset,
        void* destination,
        ulong size
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus BufferCopyDelegate(
        IntPtr context,
        IntPtr source,
        ulong sourceOffset,
        IntPtr destination,
        ulong destinationOffset,
        ulong size
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus BufferFillU32Delegate(
        IntPtr context,
        IntPtr buffer,
        ulong destinationOffset,
        ulong size,
        uint value
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus BufferExpandQuadIndicesDelegate(
        IntPtr context,
        IntPtr source,
        ulong sourceOffset,
        GalIndexType sourceIndexType,
        uint quadCount,
        IntPtr destination,
        ulong destinationOffset
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus MemoryBarrierDelegate(IntPtr context);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TimelineSubmitDelegate(
        IntPtr context,
        ulong* value
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TimelineQueryDelegate(
        IntPtr context,
        NativeTimelineReport* report
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RuntimeBatchQueryDelegate(
        IntPtr context,
        NativeRuntimeBatchReport* report
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TimelineWaitDelegate(
        IntPtr context,
        ulong value,
        ulong timeoutNanoseconds
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus WaitIdleDelegate(
        IntPtr context,
        ulong timeoutNanoseconds
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus TranslateSpirvDelegate(
        IntPtr context,
        uint* spirvWords,
        ulong wordCount,
        NativeSpirvTranslationOptions* options,
        NativeSpirvTranslationReport* report,
        IntPtr* translation
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus ShaderTranslationCopyMslDelegate(
        IntPtr translation,
        byte* destination,
        ulong destinationSize,
        ulong* requiredSize
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void ShaderTranslationDestroyDelegate(IntPtr translation);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus ComputePipelineCreateDelegate(
        IntPtr context,
        IntPtr translation,
        IntPtr* pipeline
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void ComputePipelineDestroyDelegate(IntPtr pipeline);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus ComputeDispatchDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeComputeDispatchDescriptor* descriptor
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderPipelineCreateDelegate(
        IntPtr context,
        NativeRenderPipelineDescriptor* descriptor,
        IntPtr* pipeline
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderPipelineCreateWithVertexLayoutDelegate(
        IntPtr context,
        NativeRenderPipelineDescriptor* descriptor,
        NativeVertexBufferLayout* vertexBufferLayouts,
        uint vertexBufferLayoutCount,
        NativeVertexAttribute* vertexAttributes,
        uint vertexAttributeCount,
        IntPtr* pipeline
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderPipelineCreateAdvancedDelegate(
        IntPtr context,
        NativeRenderPipelineAdvancedDescriptor* descriptor,
        NativeVertexBufferLayout* vertexBufferLayouts,
        uint vertexBufferLayoutCount,
        NativeVertexAttribute* vertexAttributes,
        uint vertexAttributeCount,
        IntPtr* pipeline
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderPipelineCreateMrtDelegate(
        IntPtr context,
        NativeRenderPipelineMrtDescriptor* descriptor,
        NativeVertexBufferLayout* vertexBufferLayouts,
        uint vertexBufferLayoutCount,
        NativeVertexAttribute* vertexAttributes,
        uint vertexAttributeCount,
        IntPtr* pipeline
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void RenderPipelineDestroyDelegate(IntPtr pipeline);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderDrawDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeRenderDrawDescriptor* descriptor
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderDrawBoundDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeRenderDrawDescriptor* descriptor,
        NativeRenderStageBindings* vertexBindings,
        NativeRenderStageBindings* fragmentBindings
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderDrawIndexedBoundDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeRenderDrawDescriptor* descriptor,
        NativeRenderIndexBinding* indexBinding,
        NativeRenderStageBindings* vertexBindings,
        NativeRenderStageBindings* fragmentBindings
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderDrawRasterizedDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeRenderDrawDescriptor* descriptor,
        NativeRenderIndexBinding* indexBinding,
        NativeRenderStageBindings* vertexBindings,
        NativeRenderStageBindings* fragmentBindings,
        NativeRenderPassState* renderPassState,
        NativeRasterizerState* rasterizerState
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderDrawMrtRasterizedDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeRenderDrawDescriptor* descriptor,
        NativeRenderColorTargetBinding* colorTargets,
        uint colorTargetCount,
        NativeRenderIndexBinding* indexBinding,
        NativeRenderStageBindings* vertexBindings,
        NativeRenderStageBindings* fragmentBindings,
        NativeRenderPassState* renderPassState,
        NativeRasterizerState* rasterizerState
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderDrawMrtRasterizedIndirectDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeRenderDrawDescriptor* descriptor,
        NativeRenderColorTargetBinding* colorTargets,
        uint colorTargetCount,
        NativeRenderIndirectBinding* indirectBinding,
        NativeRenderIndexBinding* indexBinding,
        NativeRenderStageBindings* vertexBindings,
        NativeRenderStageBindings* fragmentBindings,
        NativeRenderPassState* renderPassState,
        NativeRasterizerState* rasterizerState
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderDrawMrtRasterizedIndirectCountDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeRenderDrawDescriptor* descriptor,
        NativeRenderColorTargetBinding* colorTargets,
        uint colorTargetCount,
        NativeRenderIndirectBinding* indirectBinding,
        NativeRenderIndirectCountBinding* countBinding,
        NativeRenderIndexBinding* indexBinding,
        NativeRenderStageBindings* vertexBindings,
        NativeRenderStageBindings* fragmentBindings,
        NativeRenderPassState* renderPassState,
        NativeRasterizerState* rasterizerState
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderDrawMrtRasterizedVisibilityDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeRenderDrawDescriptor* descriptor,
        NativeRenderColorTargetBinding* colorTargets,
        uint colorTargetCount,
        NativeRenderIndexBinding* indexBinding,
        NativeRenderStageBindings* vertexBindings,
        NativeRenderStageBindings* fragmentBindings,
        NativeRenderPassState* renderPassState,
        NativeRasterizerState* rasterizerState,
        ulong* visibleSamples
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus VisibilityQueryCreateDelegate(
        IntPtr context,
        IntPtr* query
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void VisibilityQueryDestroyDelegate(IntPtr query);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus VisibilityQueryResolveDelegate(
        IntPtr context,
        IntPtr query,
        ulong* visibleSamples
    );

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeStatus RenderDrawMrtRasterizedQueryDelegate(
        IntPtr context,
        IntPtr pipeline,
        NativeRenderDrawDescriptor* descriptor,
        NativeRenderColorTargetBinding* colorTargets,
        uint colorTargetCount,
        NativeRenderIndexBinding* indexBinding,
        NativeRenderStageBindings* vertexBindings,
        NativeRenderStageBindings* fragmentBindings,
        NativeRenderPassState* renderPassState,
        NativeRasterizerState* rasterizerState,
        IntPtr query
    );
}
