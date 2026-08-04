using System;
using System.Threading;

namespace Ryujinx.Graphics.Vulkan
{
    [Flags]
    public enum MetalFxFrameFlags : ulong
    {
        None = 0,
        Color = 1UL << 0,
        Depth = 1UL << 1,
        Motion = 1UL << 2,
        Camera = 1UL << 3,
        Jitter = 1UL << 4,
        Discontinuity = 1UL << 5,
        DepthReversed = 1UL << 6,
    }

    public enum MetalFxTextureFormat : uint
    {
        Unknown = 0,
        Bgra8Unorm = 1,
        Bgra8UnormSrgb = 2,
        R32Float = 3,
        Rg16Float = 4,
    }

    /// <summary>
    /// A renderer-owned frame whose Metal object pointers are borrowed and
    /// must first be consumed during the synchronous presentation callback.
    /// The native presenter may retain active swapchain objects for the
    /// renderer session, but must release them before Vulkan teardown.
    /// Motion is current-to-previous displacement in pixels after applying
    /// MotionVectorScaleX/Y. Depth is normalized device depth.
    /// </summary>
    public readonly struct MetalFxFrame
    {
        public ulong FrameId { get; }
        public MetalFxFrameFlags Flags { get; }
        public nint MetalCommandQueue { get; }
        public nint ColorTexture { get; }
        public nint DepthTexture { get; }
        public nint MotionTexture { get; }
        public int ColorWidth { get; }
        public int ColorHeight { get; }
        public int DepthWidth { get; }
        public int DepthHeight { get; }
        public int MotionWidth { get; }
        public int MotionHeight { get; }
        public MetalFxTextureFormat ColorFormat { get; }
        public MetalFxTextureFormat DepthFormat { get; }
        public MetalFxTextureFormat MotionFormat { get; }
        public float MotionVectorScaleX { get; }
        public float MotionVectorScaleY { get; }
        public float JitterOffsetX { get; }
        public float JitterOffsetY { get; }
        public float NearPlane { get; }
        public float FarPlane { get; }
        public float FieldOfViewDegrees { get; }
        public float AspectRatio { get; }
        public float DeltaTimeSeconds { get; }
        public ulong PresentationTimestampNanoseconds { get; }

        public MetalFxFrame(
            ulong frameId,
            MetalFxFrameFlags flags,
            nint metalCommandQueue,
            nint colorTexture,
            nint depthTexture,
            nint motionTexture,
            int colorWidth,
            int colorHeight,
            int depthWidth,
            int depthHeight,
            int motionWidth,
            int motionHeight,
            MetalFxTextureFormat colorFormat,
            MetalFxTextureFormat depthFormat,
            MetalFxTextureFormat motionFormat,
            float motionVectorScaleX,
            float motionVectorScaleY,
            float jitterOffsetX,
            float jitterOffsetY,
            float nearPlane,
            float farPlane,
            float fieldOfViewDegrees,
            float aspectRatio,
            float deltaTimeSeconds,
            ulong presentationTimestampNanoseconds)
        {
            FrameId = frameId;
            Flags = flags;
            MetalCommandQueue = metalCommandQueue;
            ColorTexture = colorTexture;
            DepthTexture = depthTexture;
            MotionTexture = motionTexture;
            ColorWidth = colorWidth;
            ColorHeight = colorHeight;
            DepthWidth = depthWidth;
            DepthHeight = depthHeight;
            MotionWidth = motionWidth;
            MotionHeight = motionHeight;
            ColorFormat = colorFormat;
            DepthFormat = depthFormat;
            MotionFormat = motionFormat;
            MotionVectorScaleX = motionVectorScaleX;
            MotionVectorScaleY = motionVectorScaleY;
            JitterOffsetX = jitterOffsetX;
            JitterOffsetY = jitterOffsetY;
            NearPlane = nearPlane;
            FarPlane = farPlane;
            FieldOfViewDegrees = fieldOfViewDegrees;
            AspectRatio = aspectRatio;
            DeltaTimeSeconds = deltaTimeSeconds;
            PresentationTimestampNanoseconds = presentationTimestampNanoseconds;
        }
    }

    public delegate bool MetalFxPresentFrame(in MetalFxFrame frame);
    public delegate void MetalFxReportAttachmentLabels(string message);
    public delegate void MetalFxReportProviderReadiness(in MetalFxProviderReadiness readiness);

    /// <summary>
    /// Stable, pointer-free handoff from attachment discovery to the future
    /// renderer provider. A candidate becoming ready does not make its Vulkan
    /// image exportable and therefore never unlocks Temporal by itself.
    /// </summary>
    public readonly struct MetalFxProviderReadiness
    {
        public ulong FrameId { get; }
        public int Generation { get; }
        public bool SceneReady { get; }
        public bool DepthReady { get; }
        public bool MotionReady { get; }
        public bool RawExportReady { get; }
        public bool CanonicalExportReady { get; }
        public bool SceneCut { get; }
        public string SceneLabel { get; }
        public string DepthLabel { get; }
        public string MotionLabel { get; }
        public string DepthFormat { get; }
        public string MotionFormat { get; }
        public int Width { get; }
        public int Height { get; }

        public MetalFxProviderReadiness(
            ulong frameId,
            int generation,
            bool sceneReady,
            bool depthReady,
            bool motionReady,
            bool rawExportReady,
            bool canonicalExportReady,
            bool sceneCut,
            string sceneLabel,
            string depthLabel,
            string motionLabel,
            string depthFormat,
            string motionFormat,
            int width,
            int height)
        {
            FrameId = frameId;
            Generation = generation;
            SceneReady = sceneReady;
            DepthReady = depthReady;
            MotionReady = motionReady;
            RawExportReady = rawExportReady;
            CanonicalExportReady = canonicalExportReady;
            SceneCut = sceneCut;
            SceneLabel = sceneLabel;
            DepthLabel = depthLabel;
            MotionLabel = motionLabel;
            DepthFormat = depthFormat;
            MotionFormat = motionFormat;
            Width = width;
            Height = height;
        }
    }

    public static class MetalFxPresentation
    {
        private static readonly object _lock = new();
        private static MetalFxPresentFrame _presentFrame;
        private static MetalFxReportAttachmentLabels _reportAttachmentLabels;
        private static MetalFxReportProviderReadiness _reportProviderReadiness;
        private static int _attachmentDiscoveryEnabled;

        public static void Configure(
            MetalFxPresentFrame presentFrame,
            MetalFxReportAttachmentLabels reportAttachmentLabels = null,
            MetalFxReportProviderReadiness reportProviderReadiness = null)
        {
            lock (_lock)
            {
                _presentFrame = presentFrame;
                _reportAttachmentLabels = reportAttachmentLabels;
                _reportProviderReadiness = reportProviderReadiness;
                Volatile.Write(
                    ref _attachmentDiscoveryEnabled,
                    reportAttachmentLabels == null && reportProviderReadiness == null ? 0 : 1);
            }
        }

        public static void Clear()
        {
            lock (_lock)
            {
                _presentFrame = null;
                _reportAttachmentLabels = null;
                _reportProviderReadiness = null;
                Volatile.Write(ref _attachmentDiscoveryEnabled, 0);
            }
        }

        internal static bool IsAttachmentDiscoveryEnabled =>
            Volatile.Read(ref _attachmentDiscoveryEnabled) != 0;

        internal static void ReportAttachmentLabels(string message)
        {
            MetalFxReportAttachmentLabels reportAttachmentLabels;
            lock (_lock)
            {
                reportAttachmentLabels = _reportAttachmentLabels;
            }

            reportAttachmentLabels?.Invoke(message);
        }

        internal static void ReportProviderReadiness(in MetalFxProviderReadiness readiness)
        {
            MetalFxReportProviderReadiness reportProviderReadiness;
            lock (_lock)
            {
                reportProviderReadiness = _reportProviderReadiness;
            }

            reportProviderReadiness?.Invoke(in readiness);
        }

        internal static bool TryPresent(in MetalFxFrame frame)
        {
            MetalFxPresentFrame presentFrame;
            lock (_lock)
            {
                presentFrame = _presentFrame;
            }

            return presentFrame?.Invoke(in frame) == true;
        }
    }
}
