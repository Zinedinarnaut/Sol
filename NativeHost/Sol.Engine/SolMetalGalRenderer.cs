#nullable enable

using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Buffers;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Ryujinx.Headless;

/// <summary>
/// First managed GAL slice backed by SolMetal. Buffer ownership, transfers,
/// copies, and ordered syncs are real; unsupported graphics operations fail
/// closed so an incomplete backend can never silently produce corrupt frames.
/// </summary>
internal sealed unsafe class SolMetalGalRenderer : IRenderer
{
    private const int MaximumGuestVertexBuffers = 16;
    private const uint VertexBufferBase = 1;
    // A zero guest stride means every vertex/instance reads the same element.
    // Metal expresses that with a constant step function, but still validates
    // attribute offsets against the descriptor stride. Use the maximum legal
    // Metal stride so every otherwise-valid guest attribute remains addressable;
    // the stride is never advanced for a constant layout.
    private const uint ConstantVertexFetchStride = 2048;
    private const uint VertexResourceBufferBase =
        VertexBufferBase + MaximumGuestVertexBuffers;
    private const uint MaximumMetalBuffersPerStage = 31;
    private const uint MaximumMetalTexturesPerStage = 128;
    private const uint MaximumMetalSamplersPerStage = 16;
    private const uint MaximumMetalArgumentBufferResources = 256;
    private const int DummyBufferSize = 0x10000;
    private const uint TextureDescriptorSet = 2;
    private const uint MetalArgumentBufferSlot = 30;
    private const uint MetalArgumentBufferEncoding = MetalArgumentBufferSlot + 1;
    private const long AutoD16ProbeMinimumDepthPasses = 128;
    private const long AutoD16ProbeMinimumClearPasses = 8;

    private readonly record struct TargetedProbeSelection(
        long CaptureId,
        string Name,
        string Description,
        bool CaptureTextures,
        int PreferredColorSlot
    );

    private readonly record struct ProbeDrawDepthSnapshot(
        SolMetalGalTexture? Target,
        string? TargetIdentity,
        SolMetalNativeBridge.GalRenderLoadAction LoadAction,
        double ClearDepth,
        SolMetalNativeBridge.GalCompareFunction CompareFunction,
        bool WriteEnabled
    )
    {
        internal string Description => FormatProbeDrawDepth(
            Target is not null,
            TargetIdentity,
            LoadAction,
            ClearDepth,
            CompareFunction,
            WriteEnabled
        );
    }

    private const string SmokeVertexSpirvBase64 =
        "AwIjBwAAAQALAA0AKAAAAAAAAAARAAIAAQAAAAsABgABAAAAR0xTTC5zdGQuNDUwAAAAAA4AAwAAAAAAAQAAAA8ABwAAAAAABAAAAG1haW4AAAAAGQAAAB0AAAADAAMAAgAAAMIBAAAEAAoAR0xfR09PR0xFX2NwcF9zdHlsZV9saW5lX2RpcmVjdGl2ZQAABAAIAEdMX0dPT0dMRV9pbmNsdWRlX2RpcmVjdGl2ZQAFAAQABAAAAG1haW4AAAAABQAFAAwAAABwb3NpdGlvbnMAAAAFAAYAFwAAAGdsX1BlclZlcnRleAAAAAAGAAYAFwAAAAAAAABnbF9Qb3NpdGlvbgAGAAcAFwAAAAEAAABnbF9Qb2ludFNpemUAAAAABgAHABcAAAACAAAAZ2xfQ2xpcERpc3RhbmNlAAYABwAXAAAAAwAAAGdsX0N1bGxEaXN0YW5jZQAFAAMAGQAAAAAAAAAFAAYAHQAAAGdsX1ZlcnRleEluZGV4AABIAAUAFwAAAAAAAAALAAAAAAAAAEgABQAXAAAAAQAAAAsAAAABAAAASAAFABcAAAACAAAACwAAAAMAAABIAAUAFwAAAAMAAAALAAAABAAAAEcAAwAXAAAAAgAAAEcABAAdAAAACwAAACoAAAATAAIAAgAAACEAAwADAAAAAgAAABYAAwAGAAAAIAAAABcABAAHAAAABgAAAAIAAAAVAAQACAAAACAAAAAAAAAAKwAEAAgAAAAJAAAAAwAAABwABAAKAAAABwAAAAkAAAAgAAQACwAAAAYAAAAKAAAAOwAEAAsAAAAMAAAABgAAACsABAAGAAAADQAAAM3MTL8sAAUABwAAAA4AAAANAAAADQAAACsABAAGAAAADwAAAM3MTD8sAAUABwAAABAAAAAPAAAADQAAACsABAAGAAAAEQAAAAAAAAAsAAUABwAAABIAAAARAAAADwAAACwABgAKAAAAEwAAAA4AAAAQAAAAEgAAABcABAAUAAAABgAAAAQAAAArAAQACAAAABUAAAABAAAAHAAEABYAAAAGAAAAFQAAAB4ABgAXAAAAFAAAAAYAAAAWAAAAFgAAACAABAAYAAAAAwAAABcAAAA7AAQAGAAAABkAAAADAAAAFQAEABoAAAAgAAAAAQAAACsABAAaAAAAGwAAAAAAAAAgAAQAHAAAAAEAAAAaAAAAOwAEABwAAAAdAAAAAQAAACAABAAfAAAABgAAAAcAAAArAAQABgAAACIAAAAAAIA/IAAEACYAAAADAAAAFAAAADYABQACAAAABAAAAAAAAAADAAAA+AACAAUAAAA+AAMADAAAABMAAAA9AAQAGgAAAB4AAAAdAAAAQQAFAB8AAAAgAAAADAAAAB4AAAA9AAQABwAAACEAAAAgAAAAUQAFAAYAAAAjAAAAIQAAAAAAAABRAAUABgAAACQAAAAhAAAAAQAAAFAABwAUAAAAJQAAACMAAAAkAAAAEQAAACIAAABBAAUAJgAAACcAAAAZAAAAGwAAAD4AAwAnAAAAJQAAAP0AAQA4AAEA";
    private const string SmokeFragmentSpirvBase64 =
        "AwIjBwAAAQALAA0ADQAAAAAAAAARAAIAAQAAAAsABgABAAAAR0xTTC5zdGQuNDUwAAAAAA4AAwAAAAAAAQAAAA8ABgAEAAAABAAA" +
        "AG1haW4AAAAACQAAABAAAwAEAAAABwAAAAMAAwACAAAAwgEAAAQACgBHTF9HT09HTEVfY3BwX3N0eWxlX2xpbmVfZGlyZWN0aXZl" +
        "AAAEAAgAR0xfR09PR0xFX2luY2x1ZGVfZGlyZWN0aXZlAAUABAAEAAAAbWFpbgAAAAAFAAQACQAAAGNvbG9yAAAARwAEAAkAAAAe" +
        "AAAAAAAAABMAAgACAAAAIQADAAMAAAACAAAAFgADAAYAAAAgAAAAFwAEAAcAAAAGAAAABAAAACAABAAIAAAAAwAAAAcAAAA7AAQA" +
        "CAAAAAkAAAADAAAAKwAEAAYAAAAKAAAAAACAPysABAAGAAAACwAAAAAAAAAsAAcABwAAAAwAAAAKAAAACwAAAAsAAAAKAAAANgAF" +
        "AAIAAAAEAAAAAAAAAAMAAAD4AAIABQAAAD4AAwAJAAAADAAAAP0AAQA4AAEA";
    // Same fragment shader as SmokeFragmentSpirvBase64, with its sole RGBA
    // output decorated for location 3. Keeping this as SPIR-V makes the smoke
    // exercise the exact guest translation path used by real render programs.
    private const string SparseSmokeFragmentSpirvBase64 =
        "AwIjBwAAAQALAA0ADQAAAAAAAAARAAIAAQAAAAsABgABAAAAR0xTTC5zdGQuNDUwAAAAAA4AAwAAAAAAAQAAAA8ABgAEAAAABAAA" +
        "AG1haW4AAAAACQAAABAAAwAEAAAABwAAAAMAAwACAAAAwgEAAAQACgBHTF9HT09HTEVfY3BwX3N0eWxlX2xpbmVfZGlyZWN0aXZl" +
        "AAAEAAgAR0xfR09PR0xFX2luY2x1ZGVfZGlyZWN0aXZlAAUABAAEAAAAbWFpbgAAAAAFAAQACQAAAGNvbG9yAAAARwAEAAkAAAAe" +
        "AAAAAwAAABMAAgACAAAAIQADAAMAAAACAAAAFgADAAYAAAAgAAAAFwAEAAcAAAAGAAAABAAAACAABAAIAAAAAwAAAAcAAAA7AAQA" +
        "CAAAAAkAAAADAAAAKwAEAAYAAAAKAAAAAACAPysABAAGAAAACwAAAAAAAAAsAAcABwAAAAwAAAAKAAAACwAAAAsAAAAKAAAANgAF" +
        "AAIAAAAEAAAAAAAAAAMAAAD4AAIABQAAAD4AAwAJAAAADAAAAP0AAQA4AAEA";
    private const string BoundSmokeVertexSpirvBase64 =
        "AwIjBwAAAQALAA0AKgAAAAAAAAARAAIAAQAAAAsABgABAAAAR0xTTC5zdGQuNDUwAAAAAA4AAwAAAAAAAQAAAA8ACQAAAAAABAAA" +
        "AG1haW4AAAAADQAAABIAAAAmAAAAKAAAAAMAAwACAAAAwgEAAAQACgBHTF9HT09HTEVfY3BwX3N0eWxlX2xpbmVfZGlyZWN0aXZl" +
        "AAAEAAgAR0xfR09PR0xFX2luY2x1ZGVfZGlyZWN0aXZlAAUABAAEAAAAbWFpbgAAAAAFAAYACwAAAGdsX1BlclZlcnRleAAAAAAG" +
        "AAYACwAAAAAAAABnbF9Qb3NpdGlvbgAGAAcACwAAAAEAAABnbF9Qb2ludFNpemUAAAAABgAHAAsAAAACAAAAZ2xfQ2xpcERpc3Rh" +
        "bmNlAAYABwALAAAAAwAAAGdsX0N1bGxEaXN0YW5jZQAFAAMADQAAAAAAAAAFAAUAEgAAAHBvc2l0aW9uAAAAAAUABwAUAAAAU29s" +
        "TWV0YWxUcmFuc2Zvcm0AAAAGAAYAFAAAAAAAAAB0cmFuc2Zvcm0AAAAFAAMAFgAAAAAAAAAFAAYAJgAAAGZyYWdtZW50X2NvbG9y" +
        "AAAFAAYAKAAAAHZlcnRleF9jb2xvcgAAAABIAAUACwAAAAAAAAALAAAAAAAAAEgABQALAAAAAQAAAAsAAAABAAAASAAFAAsAAAAC" +
        "AAAACwAAAAMAAABIAAUACwAAAAMAAAALAAAABAAAAEcAAwALAAAAAgAAAEcABAASAAAAHgAAAAAAAABIAAUAFAAAAAAAAAAjAAAA" +
        "AAAAAEcAAwAUAAAAAgAAAEcABAAWAAAAIgAAAAAAAABHAAQAFgAAACEAAAAAAAAARwAEACYAAAAeAAAAAAAAAEcABAAoAAAAHgAA" +
        "AAEAAAATAAIAAgAAACEAAwADAAAAAgAAABYAAwAGAAAAIAAAABcABAAHAAAABgAAAAQAAAAVAAQACAAAACAAAAAAAAAAKwAEAAgA" +
        "AAAJAAAAAQAAABwABAAKAAAABgAAAAkAAAAeAAYACwAAAAcAAAAGAAAACgAAAAoAAAAgAAQADAAAAAMAAAALAAAAOwAEAAwAAAAN" +
        "AAAAAwAAABUABAAOAAAAIAAAAAEAAAArAAQADgAAAA8AAAAAAAAAFwAEABAAAAAGAAAAAgAAACAABAARAAAAAQAAABAAAAA7AAQA" +
        "EQAAABIAAAABAAAAHgADABQAAAAHAAAAIAAEABUAAAACAAAAFAAAADsABAAVAAAAFgAAAAIAAAAgAAQAFwAAAAIAAAAHAAAAKwAE" +
        "AAgAAAAcAAAAAgAAACAABAAdAAAAAgAAAAYAAAArAAQABgAAACAAAAAAAIA/IAAEACQAAAADAAAABwAAADsABAAkAAAAJgAAAAMA" +
        "AAAgAAQAJwAAAAEAAAAHAAAAOwAEACcAAAAoAAAAAQAAADYABQACAAAABAAAAAAAAAADAAAA+AACAAUAAAA9AAQAEAAAABMAAAAS" +
        "AAAAQQAFABcAAAAYAAAAFgAAAA8AAAA9AAQABwAAABkAAAAYAAAATwAHABAAAAAaAAAAGQAAABkAAAAAAAAAAQAAAIEABQAQAAAA" +
        "GwAAABMAAAAaAAAAQQAGAB0AAAAeAAAAFgAAAA8AAAAcAAAAPQAEAAYAAAAfAAAAHgAAAFEABQAGAAAAIQAAABsAAAAAAAAAUQAF" +
        "AAYAAAAiAAAAGwAAAAEAAABQAAcABwAAACMAAAAhAAAAIgAAAB8AAAAgAAAAQQAFACQAAAAlAAAADQAAAA8AAAA+AAMAJQAAACMA" +
        "AAA9AAQABwAAACkAAAAoAAAAPgADACYAAAApAAAA/QABADgAAQA=";
    private const string BoundSmokeFragmentSpirvBase64 =
        "AwIjBwAAAQALAA0AFwAAAAAAAAARAAIAAQAAAAsABgABAAAAR0xTTC5zdGQuNDUwAAAAAA4AAwAAAAAAAQAAAA8ABwAEAAAABAAA" +
        "AG1haW4AAAAACQAAAAsAAAAQAAMABAAAAAcAAAADAAMAAgAAAMIBAAAEAAoAR0xfR09PR0xFX2NwcF9zdHlsZV9saW5lX2RpcmVj" +
        "dGl2ZQAABAAIAEdMX0dPT0dMRV9pbmNsdWRlX2RpcmVjdGl2ZQAFAAQABAAAAG1haW4AAAAABQAEAAkAAABjb2xvcgAAAAUABgAL" +
        "AAAAZnJhZ21lbnRfY29sb3IAAAUABgAQAAAAdGludF90ZXh0dXJlAAAAAEcABAAJAAAAHgAAAAAAAABHAAQACwAAAB4AAAAAAAAA" +
        "RwAEABAAAAAiAAAAAAAAAEcABAAQAAAAIQAAAAAAAAATAAIAAgAAACEAAwADAAAAAgAAABYAAwAGAAAAIAAAABcABAAHAAAABgAA" +
        "AAQAAAAgAAQACAAAAAMAAAAHAAAAOwAEAAgAAAAJAAAAAwAAACAABAAKAAAAAQAAAAcAAAA7AAQACgAAAAsAAAABAAAAGQAJAA0A" +
        "AAAGAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAGwADAA4AAAANAAAAIAAEAA8AAAAAAAAADgAAADsABAAPAAAAEAAAAAAAAAAX" +
        "AAQAEgAAAAYAAAACAAAAKwAEAAYAAAATAAAAAAAAPywABQASAAAAFAAAABMAAAATAAAANgAFAAIAAAAEAAAAAAAAAAMAAAD4AAIA" +
        "BQAAAD0ABAAHAAAADAAAAAsAAAA9AAQADgAAABEAAAAQAAAAVwAFAAcAAAAVAAAAEQAAABQAAACFAAUABwAAABYAAAAMAAAAFQAA" +
        "AD4AAwAJAAAAFgAAAP0AAQA4AAEA";
    private const string SmokeComputeSpirvBase64 =
        "AwIjBwAAAQALAA0AHQAAAAAAAAARAAIAAQAAAAsABgABAAAAR0xTTC5zdGQuNDUwAAAAAA4AAwAAAAAAAQAAAA8ABgAFAAAABAAA" +
        "AG1haW4AAAAADwAAABAABgAEAAAAEQAAAEAAAAABAAAAAQAAAAMAAwACAAAAwgEAAAQACgBHTF9HT09HTEVfY3BwX3N0eWxlX2xp" +
        "bmVfZGlyZWN0aXZlAAAEAAgAR0xfR09PR0xFX2luY2x1ZGVfZGlyZWN0aXZlAAUABAAEAAAAbWFpbgAAAAAFAAYACAAAAFNvbE1l" +
        "dGFsVmFsdWVzAAAGAAUACAAAAAAAAAB2YWx1ZXMAAAUAAwAKAAAAAAAAAAUACAAPAAAAZ2xfR2xvYmFsSW52b2NhdGlvbklEAAAA" +
        "RwAEAAcAAAAGAAAABAAAAEgABQAIAAAAAAAAACMAAAAAAAAARwADAAgAAAADAAAARwAEAAoAAAAiAAAAAAAAAEcABAAKAAAAIQAA" +
        "AAAAAABHAAQADwAAAAsAAAAcAAAARwAEABwAAAALAAAAGQAAABMAAgACAAAAIQADAAMAAAACAAAAFQAEAAYAAAAgAAAAAAAAAB0A" +
        "AwAHAAAABgAAAB4AAwAIAAAABwAAACAABAAJAAAAAgAAAAgAAAA7AAQACQAAAAoAAAACAAAAFQAEAAsAAAAgAAAAAQAAACsABAAL" +
        "AAAADAAAAAAAAAAXAAQADQAAAAYAAAADAAAAIAAEAA4AAAABAAAADQAAADsABAAOAAAADwAAAAEAAAArAAQABgAAABAAAAAAAAAA" +
        "IAAEABEAAAABAAAABgAAACsABAAGAAAAFAAAAAcAAAAgAAQAFQAAAAIAAAAGAAAAKwAEAAYAAAAaAAAAQAAAACsABAAGAAAAGwAA" +
        "AAEAAAAsAAYADQAAABwAAAAaAAAAGwAAABsAAAA2AAUAAgAAAAQAAAAAAAAAAwAAAPgAAgAFAAAAQQAFABEAAAASAAAADwAAABAA" +
        "AAA9AAQABgAAABMAAAASAAAAQQAGABUAAAAWAAAACgAAAAwAAAATAAAAPQAEAAYAAAAXAAAAFgAAAIAABQAGAAAAGAAAABcAAAAU" +
        "AAAAQQAGABUAAAAZAAAACgAAAAwAAAATAAAAPgADABkAAAAYAAAA/QABADgAAQA=";

    private readonly object _gate = new();
    private readonly SolMetalNativeBridge.IGalSession _session;
    private readonly IntPtr _zeroVertexBuffer;
    private readonly IntPtr _dummyTexture;
    private readonly IntPtr _dummyBufferTexture;
    private readonly IntPtr _dummySampler;
    private readonly Dictionary<ulong, BufferEntry> _buffers = [];
    private readonly HashSet<SolMetalGalTexture> _textures = [];
    private readonly HashSet<SolMetalGalSampler> _samplers = [];
    private readonly HashSet<SolMetalGalProgram> _programs = [];
    private readonly SortedDictionary<ulong, ulong> _syncTimeline = [];
    private readonly Queue<SolMetalCounterEvent> _sampleCounterEvents = [];
    private readonly object _frameProbeTargetGate = new();
    private readonly Dictionary<long, FrameProbeTarget> _frameProbeTargets = [];
    private readonly object _targetedVisibilityProbeGate = new();
    private readonly HashSet<long> _targetedVisibilityProbePrograms =
        ParseProbeProgramIds(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_VISIBILITY_PROBE_PROGRAMS"
            )
        );
    private readonly HashSet<string> _targetedVisibilityProbeProgramKeys =
        SolMetalRenderProgramIdentity.ParseEnvironmentKeys(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_VISIBILITY_PROBE_PROGRAM_KEYS"
            )
        );
    private readonly SolMetalTargetedProbeSelector[]
        _configuredTargetedProbeSelectors;
    private readonly List<SolMetalTargetedProbeSelector>
        _pendingTargetedProbeSelectors = [];
    private readonly HashSet<long> _debugSkipPrograms = ParseProbeProgramIds(
        Environment.GetEnvironmentVariable("SOL_METAL_DEBUG_SKIP_PROGRAMS")
    );
    private readonly HashSet<string> _debugSkipProgramKeys =
        SolMetalRenderProgramIdentity.ParseEnvironmentKeys(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_DEBUG_SKIP_PROGRAM_KEYS"
            )
        );
    private readonly HashSet<long> _debugForceDepthAlwaysPrograms =
        ParseProbeProgramIds(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_DEBUG_FORCE_DEPTH_ALWAYS_PROGRAMS"
            )
        );
    private readonly HashSet<string> _debugForceDepthAlwaysProgramKeys =
        SolMetalRenderProgramIdentity.ParseEnvironmentKeys(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_DEBUG_FORCE_DEPTH_ALWAYS_PROGRAM_KEYS"
            )
        );
    private readonly HashSet<string> _debugDisableColorWriteProgramKeys =
        SolMetalRenderProgramIdentity.ParseEnvironmentKeys(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_DEBUG_DISABLE_COLOR_WRITE_PROGRAM_KEYS"
            )
        );
    private readonly long _autoProbeAfterPresentations =
        ParseBoundedPositiveLong(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_AUTO_PROBE_AFTER_PRESENTATIONS"
            ),
            100_000
        );
    private readonly bool _autoProbeD16SequenceRequested =
        !string.IsNullOrWhiteSpace(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_AUTO_PROBE_D16_SEQUENCE_KEYS"
            )
        );
    private readonly string[] _autoProbeD16SequenceKeys =
        SolMetalRenderProgramIdentity.ParseEnvironmentKeySequence(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_AUTO_PROBE_D16_SEQUENCE_KEYS"
            ),
            expectedCount: 3
        );
    private readonly long _autoProbeTimeoutPresentations =
        ParseBoundedPositiveLong(
            Environment.GetEnvironmentVariable(
                "SOL_METAL_AUTO_PROBE_TIMEOUT_PRESENTATIONS"
            ),
            100_000
        );
    private readonly HashSet<long> _pendingTargetedVisibilityProbePrograms = [];
    private readonly HashSet<string> _pendingTargetedVisibilityProbeProgramKeys =
        new(StringComparer.Ordinal);
    private TargetedD16WriterProbe? _targetedD16WriterProbe;
    private readonly object _autoD16ProbeGate = new();
    private long _autoD16ProbeCandidateTargetId;
    private long _autoD16ProbeStableTargetId;
    private int _autoD16ProbeSequenceIndex;
    private int _autoD16ProbeCompletedSequences;
    private long _autoD16ProbeLastCompletionPresentation;
    private long _autoD16ProbeCaptureTargetId;
    private int _autoD16ProbeCaptureIndex;
    private int _autoD16ProbeArmed;
    private readonly SolMetalGalPipeline _pipeline;
    private readonly SolMetalGalWindow _window;
    private ulong _nextBufferHandle = 1;
    private long _nextTextureProbeId;
    private long _nextTextureProbeViewId;
    private long _nextProgramProbeId;
    private long _successfulDrawCount;
    private long _presentedFrameCount;
    private long _bufferReadbackCallCount;
    private long _bufferUploadCallCount;
    private long _targetedProbeArmedPresentation;
    private long _nextTargetedProbeCaptureId;
    private int _pendingTargetedProbeSelectorCount;
    private long _frameProbeTargetSequence;
    private long _postDrawProbeSequence;
    private IntPtr _sampleCounterQuery;
    private ulong _sampleCounterAccumulated;
    private bool _sampleCounterClearPending;
    private readonly bool _frameProbeEnabled =
        Environment.GetEnvironmentVariable("SOL_METAL_FRAME_PROBE") == "1";
    private readonly bool _debugDisableDepthTest =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_DISABLE_DEPTH_TEST"
        ) == "1";
    private readonly bool _debugInvertNegativeViewportFrontFace =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_INVERT_NEGATIVE_VIEWPORT_FRONT_FACE"
        ) == "1";
    private readonly bool _debugInvertPositiveViewportFrontFace =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_INVERT_POSITIVE_VIEWPORT_FRONT_FACE"
        ) == "1";
    private readonly bool _debugInvertAllFrontFaces =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_INVERT_ALL_FRONT_FACES"
        ) == "1";
    private readonly bool _debugDisableFaceCulling =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_DISABLE_FACE_CULLING"
        ) == "1";
    private readonly bool _debugSwapFaceCulling =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_SWAP_FACE_CULLING"
        ) == "1";
    private readonly bool _debugForceDepthClamp =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_FORCE_DEPTH_CLAMP"
        ) == "1";
    private readonly bool _debugForceDepthAlways =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_FORCE_DEPTH_ALWAYS"
        ) == "1";
    private readonly bool _debugMapDepthEqualToLessEqual =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_DEPTH_EQUAL_LESS_EQUAL"
        ) == "1";
    private readonly bool _debugMapDepthEqualToGreaterEqual =
        Environment.GetEnvironmentVariable(
            "SOL_METAL_DEBUG_DEPTH_EQUAL_GREATER_EQUAL"
        ) == "1";
    private int _frameProbeCompleted;
    private int _screenshotRequested;
    private int _postInstancedDrawProbeBudget;
    private int _postFullscreenDrawProbeBudget;
    private int _postLargeDrawProbeBudget;
    private int _postHdrLargeDrawProbeBudget;
    private bool _disposed;

    private readonly record struct BufferEntry(IntPtr Native, int Size);

    private readonly record struct FrameProbeTarget(
        SolMetalGalTexture Texture,
        string Role,
        int ElementCount,
        long Sequence
    );

    private sealed class SolMetalCounterEvent(
        SolMetalGalRenderer owner,
        IntPtr query,
        ulong timeline,
        bool clearsAccumulatedCounter,
        EventHandler<ulong> resultHandler,
        float divisor
    ) : ICounterEvent
    {
        private readonly object _gate = new();
        private bool _completed;
        private bool _disposed;

        internal SolMetalGalRenderer Owner { get; } = owner;
        internal IntPtr Query { get; } = query;
        internal ulong Timeline { get; } = timeline;
        internal bool ClearsAccumulatedCounter { get; } =
            clearsAccumulatedCounter;
        internal float Divisor { get; } = divisor;
        internal bool IsCompleted
        {
            get
            {
                lock (_gate)
                {
                    return _completed;
                }
            }
        }

        public bool Invalid { get; set; }

        public bool ReserveForHostAccess() => false;

        public void Flush() => Owner.FlushCounter(this);

        internal void Complete(ulong result)
        {
            EventHandler<ulong>? handler;
            lock (_gate)
            {
                if (_completed)
                {
                    return;
                }
                _completed = true;
                handler = _disposed ? null : resultHandler;
            }
            handler?.Invoke(this, result);
        }

        public void Dispose()
        {
            lock (_gate)
            {
                _disposed = true;
            }
        }
    }

    private sealed class SolMetalImmediateCounterEvent : ICounterEvent
    {
        public bool Invalid { get; set; }
        public bool ReserveForHostAccess() => false;
        public void Flush() { }
        public void Dispose() { }
    }

    private readonly record struct ProgramResourceBinding(
        ShaderStage Stage,
        int DescriptorSet,
        int Binding,
        ResourceType Type,
        uint MetalBuffer,
        uint MetalTexture,
        uint MetalSampler,
        uint ArgumentBuffer
    );

    private sealed record ProgramResourcePlan(
        SolMetalNativeBridge.GalSpirvResourceBinding[] VertexRemaps,
        SolMetalNativeBridge.GalSpirvResourceBinding[] FragmentRemaps,
        SolMetalNativeBridge.GalSpirvResourceBinding[] ComputeRemaps,
        uint VertexArgumentBufferSetMask,
        uint FragmentArgumentBufferSetMask,
        uint ComputeArgumentBufferSetMask,
        ProgramResourceBinding[] Bindings
    )
    {
        public static ProgramResourcePlan Empty { get; } = new(
            [], [], [], 0, 0, 0, []
        );
    }

    private SolMetalGalRenderer(
        SolMetalNativeBridge.IGalSession session,
        nint metalLayer
    )
    {
        _session = session;
        _configuredTargetedProbeSelectors =
            SolMetalTargetedProbeSelector.ParseEnvironment(
                Environment.GetEnvironmentVariable(
                    "SOL_METAL_TARGETED_PROBE_SELECTORS_JSON"
                ),
                out string? targetedProbeSelectorFailure
            );
        if (targetedProbeSelectorFailure is not null)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal ignored malformed " +
                "SOL_METAL_TARGETED_PROBE_SELECTORS_JSON: " +
                targetedProbeSelectorFailure + "."
            );
        }
        _postInstancedDrawProbeBudget = _frameProbeEnabled ? 1 : 0;
        _postFullscreenDrawProbeBudget = _frameProbeEnabled ? 1 : 0;
        _postLargeDrawProbeBudget = _frameProbeEnabled ? 1 : 0;
        _postHdrLargeDrawProbeBudget = _frameProbeEnabled ? 1 : 0;
        if (_debugDisableDepthTest)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal depth testing is disabled for renderer diagnosis."
            );
        }
        if (_debugInvertNegativeViewportFrontFace)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal front-face winding is inverted for negative-height " +
                "viewports for renderer diagnosis."
            );
        }
        if (_debugInvertPositiveViewportFrontFace)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal front-face winding is inverted for positive-height " +
                "viewports for renderer diagnosis."
            );
        }
        if (_debugInvertAllFrontFaces)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal front-face winding is globally inverted for " +
                "renderer diagnosis."
            );
        }
        if (_debugDisableFaceCulling)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal face culling is disabled for renderer diagnosis."
            );
        }
        if (_debugSwapFaceCulling)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal front/back cull modes are swapped for renderer " +
                "diagnosis."
            );
        }
        if (_debugForceDepthClamp)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal depth clipping is forced to clamp for renderer " +
                "diagnosis."
            );
        }
        if (_debugForceDepthAlways)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal depth comparisons are forced to always pass while " +
                "preserving guest depth writes for renderer diagnosis."
            );
        }
        if (_debugMapDepthEqualToLessEqual ||
            _debugMapDepthEqualToGreaterEqual)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                "SolMetal guest equal-depth comparisons are mapped to " +
                (_debugMapDepthEqualToLessEqual
                    ? "less-equal"
                    : "greater-equal") +
                " for renderer diagnosis."
            );
        }
        try
        {
            _zeroVertexBuffer = session.CreateBuffer(
                DummyBufferSize,
                deviceLocal: false
            );
            session.UploadBuffer(
                _zeroVertexBuffer,
                0,
                new byte[DummyBufferSize]
            );
            _dummyTexture = session.CreateTexture(
                1,
                1,
                SolMetalNativeBridge.GalTextureType.Texture2D,
                1,
                1,
                1,
                SolMetalNativeBridge.GalTextureFormat.Rgba8Unorm,
                SolMetalNativeBridge.GalTextureSwizzle.Red,
                SolMetalNativeBridge.GalTextureSwizzle.Green,
                SolMetalNativeBridge.GalTextureSwizzle.Blue,
                SolMetalNativeBridge.GalTextureSwizzle.Alpha,
                depthStencil: false
            );
            session.UploadTexture(_dummyTexture, new byte[4], 4);
            _dummyBufferTexture = session.CreateBufferTexture(
                _zeroVertexBuffer,
                0,
                256,
                64,
                SolMetalNativeBridge.GalTextureFormat.R32Uint,
                SolMetalNativeBridge.GalTextureSwizzle.Red,
                SolMetalNativeBridge.GalTextureSwizzle.Green,
                SolMetalNativeBridge.GalTextureSwizzle.Blue,
                SolMetalNativeBridge.GalTextureSwizzle.Alpha
            );
            _dummySampler = session.CreateSampler(new(
                SolMetalNativeBridge.GalSamplerFilter.Nearest,
                SolMetalNativeBridge.GalSamplerFilter.Nearest,
                SolMetalNativeBridge.GalSamplerMipFilter.NotMipmapped,
                SolMetalNativeBridge.GalSamplerAddressMode.ClampToEdge,
                SolMetalNativeBridge.GalSamplerAddressMode.ClampToEdge,
                SolMetalNativeBridge.GalSamplerAddressMode.ClampToEdge,
                1,
                0,
                0.25f,
                SolMetalNativeBridge.GalSamplerBorderColor.TransparentBlack,
                false,
                SolMetalNativeBridge.GalCompareFunction.Always,
                0
            ));
            _pipeline = new SolMetalGalPipeline(this);
            _window = new SolMetalGalWindow(this, metalLayer);
            if (_frameProbeEnabled &&
                _configuredTargetedProbeSelectors.Length > 0)
            {
                ArmStructuredTargetedProbeSelectors(
                    "renderer construction"
                );
            }
        }
        catch
        {
            if (_dummySampler != IntPtr.Zero)
            {
                session.DestroySampler(_dummySampler);
            }
            if (_dummyBufferTexture != IntPtr.Zero)
            {
                session.DestroyTexture(_dummyBufferTexture);
            }
            if (_dummyTexture != IntPtr.Zero)
            {
                session.DestroyTexture(_dummyTexture);
            }
            if (_zeroVertexBuffer != IntPtr.Zero)
            {
                session.DestroyBuffer(_zeroVertexBuffer);
            }
            session.Dispose();
            throw;
        }
    }

    private static HashSet<long> ParseProbeProgramIds(string? value)
    {
        HashSet<long> result = [];
        if (string.IsNullOrWhiteSpace(value))
        {
            return result;
        }

        foreach (string candidate in value.Split(','))
        {
            if (long.TryParse(candidate.Trim(), out long programId) &&
                programId > 0)
            {
                result.Add(programId);
            }
        }

        return result;
    }

    private static long ParseBoundedPositiveLong(string? value, long maximum)
    {
        return long.TryParse(value?.Trim(), out long parsed) &&
            parsed > 0 && parsed <= maximum
                ? parsed
                : 0;
    }

    private static string FormatProbeDrawDepth(
        bool hasTarget,
        string? targetIdentity,
        SolMetalNativeBridge.GalRenderLoadAction loadAction,
        double clearDepth,
        SolMetalNativeBridge.GalCompareFunction compareFunction,
        bool writeEnabled
    )
    {
        if (!hasTarget)
        {
            return "none";
        }

        return $"{targetIdentity ?? "unknown"}:load={loadAction}:" +
            $"clear={clearDepth:0.######}:compare={compareFunction}:" +
            $"write={writeEnabled}";
    }

    private static void ValidateProbeDrawDepthSnapshot()
    {
        string equalReadOnly = FormatProbeDrawDepth(
            true,
            "#7/view #9:Depth32Float/Depth32Float:64x64",
            SolMetalNativeBridge.GalRenderLoadAction.Load,
            1,
            SolMetalNativeBridge.GalCompareFunction.Equal,
            false
        );
        string alwaysWriting = FormatProbeDrawDepth(
            true,
            "#7/view #9:Depth32Float/Depth32Float:64x64",
            SolMetalNativeBridge.GalRenderLoadAction.Clear,
            0.5,
            SolMetalNativeBridge.GalCompareFunction.Always,
            true
        );
        if (!equalReadOnly.Contains(
                "load=Load:clear=1:compare=Equal:write=False",
                StringComparison.Ordinal
            ) ||
            equalReadOnly.Contains("Always", StringComparison.Ordinal) ||
            equalReadOnly.Contains("write=True", StringComparison.Ordinal) ||
            equalReadOnly == alwaysWriting ||
            FormatProbeDrawDepth(
                false,
                null,
                default,
                0,
                default,
                false
            ) != "none")
        {
            throw new InvalidOperationException(
                "SolMetal current-draw depth snapshot validation failed."
            );
        }
    }

    private bool TryTakeTargetedVisibilityProbe(
        SolMetalGalProgram program,
        SolMetalGalTexture?[] colorTargets,
        SolMetalGalTexture? depthTarget,
        SolMetalNativeBridge.GalDepthStencilState depthStencilState,
        int elementCount,
        int instanceCount,
        Func<SolMetalTargetedProbeD16Replay?> d16ReplaySnapshotFactory,
        out TargetedProbeSelection selection
    )
    {
        selection = default;
        bool selectedByAutoSequence = TryTakeAutoD16VisibilityProbe(
            program,
            depthTarget,
            depthStencilState,
            elementCount,
            instanceCount
        );
        bool reserveForAutoSequence =
            Volatile.Read(ref _autoD16ProbeArmed) == 2 &&
            Array.IndexOf(
                _autoProbeD16SequenceKeys,
                program.StableKey
            ) >= 0;
        lock (_targetedVisibilityProbeGate)
        {
            if (reserveForAutoSequence && !selectedByAutoSequence)
            {
                return false;
            }

            bool selectedById =
                _pendingTargetedVisibilityProbePrograms.Remove(program.ProbeId);
            bool selectedByKey =
                _pendingTargetedVisibilityProbeProgramKeys.Remove(
                    program.StableKey
                );
            SolMetalTargetedProbeSelector? structuredSelector = null;
            if (_pendingTargetedProbeSelectors.Count > 0)
            {
                SolMetalTargetedProbeDraw draw = default;
                bool builtDrawSnapshot = false;
                bool builtD16ReplaySnapshot = false;
                for (int index = 0;
                     index < _pendingTargetedProbeSelectors.Count;
                     index++)
                {
                    SolMetalTargetedProbeSelector candidate =
                        _pendingTargetedProbeSelectors[index];
                    if (!string.Equals(
                            candidate.ProgramKey,
                            program.StableKey,
                            StringComparison.Ordinal
                        ))
                    {
                        continue;
                    }
                    if (!builtDrawSnapshot)
                    {
                        draw = BuildTargetedProbeDraw(
                            program,
                            colorTargets,
                            depthTarget
                        );
                        builtDrawSnapshot = true;
                    }
                    if (candidate.RequiresD16Replay &&
                        candidate.IsEligibleWithoutRuntimeConstraints(draw) &&
                        !builtD16ReplaySnapshot)
                    {
                        draw = draw with
                        {
                            D16Replay = d16ReplaySnapshotFactory(),
                        };
                        builtD16ReplaySnapshot = true;
                    }
                    if (!candidate.TrySelect(draw))
                    {
                        continue;
                    }
                    structuredSelector = candidate;
                    _pendingTargetedProbeSelectors.RemoveAt(index);
                    Volatile.Write(
                        ref _pendingTargetedProbeSelectorCount,
                        _pendingTargetedProbeSelectors.Count
                    );
                    break;
                }
            }

            if (!selectedByAutoSequence && !selectedById && !selectedByKey &&
                structuredSelector is null)
            {
                return false;
            }

            bool legacyTextureCapture = IsConfiguredTargetedProbeProgram(
                program
            );
            string name;
            string description;
            if (structuredSelector is not null)
            {
                name = structuredSelector.Name;
                description = structuredSelector.Description;
            }
            else if (selectedById)
            {
                name = $"legacy-id-{program.ProbeId}";
                description = $"legacy runtime program #{program.ProbeId}";
            }
            else if (selectedByKey || legacyTextureCapture)
            {
                name = $"legacy-key-{program.StableKey[..12]}";
                description = $"legacy stable key {program.StableKey}";
            }
            else
            {
                name = $"auto-d16-{program.StableKey[..12]}";
                description = "automatic stable D16 sequence";
            }
            selection = new TargetedProbeSelection(
                Interlocked.Increment(ref _nextTargetedProbeCaptureId),
                name,
                description,
                selectedByAutoSequence || structuredSelector is not null ||
                    legacyTextureCapture,
                structuredSelector?.ColorSlot ?? -1
            );
            return true;
        }
    }

    private SolMetalTargetedProbeDraw BuildTargetedProbeDraw(
        SolMetalGalProgram program,
        SolMetalGalTexture?[] colorTargets,
        SolMetalGalTexture? depthTarget
    )
    {
        List<SolMetalTargetedProbeColorTarget> colors = [];
        for (int slot = 0; slot < colorTargets.Length; slot++)
        {
            if (colorTargets[slot] is SolMetalGalTexture color)
            {
                colors.Add(new SolMetalTargetedProbeColorTarget(
                    slot,
                    color.Width,
                    color.Height,
                    color.NativeFormat,
                    color.ProbeColorDraws,
                    color.ProbeColorClears
                ));
            }
        }
        SolMetalTargetedProbeDepthTarget? depth = depthTarget is null
            ? null
            : new SolMetalTargetedProbeDepthTarget(
                depthTarget.Width,
                depthTarget.Height,
                depthTarget.NativeFormat,
                depthTarget.ProbeDepthPasses,
                depthTarget.ProbeDepthClearPasses
            );
        return new SolMetalTargetedProbeDraw(
            program.StableKey,
            Interlocked.Read(ref _presentedFrameCount),
            colors.ToArray(),
            depth,
            null
        );
    }

    private void ArmStructuredTargetedProbeSelectors(string reason)
    {
        long presentation = Interlocked.Read(ref _presentedFrameCount);
        lock (_targetedVisibilityProbeGate)
        {
            ResetStructuredTargetedProbeSelectorsLocked(presentation);
        }
        LogStructuredTargetedProbeSelectorsArmed(reason, presentation);
    }

    private void LogStructuredTargetedProbeSelectorsArmed(
        string reason,
        long presentation
    )
    {
        Logger.Notice.Print(
            LogClass.Gpu,
            $"SolMetal armed {_configuredTargetedProbeSelectors.Length} " +
            $"structured targeted probe selector(s) at presentation " +
            $"{presentation} ({reason}): [" +
            string.Join(
                "; ",
                _configuredTargetedProbeSelectors.Select(
                    selector => selector.Description
                )
            ) + "]."
        );
    }

    private void ResetStructuredTargetedProbeSelectorsLocked(
        long presentation
    )
    {
        _pendingTargetedProbeSelectors.Clear();
        foreach (SolMetalTargetedProbeSelector selector in
                 _configuredTargetedProbeSelectors)
        {
            _pendingTargetedProbeSelectors.Add(selector.ClonePending());
        }
        _targetedProbeArmedPresentation = presentation;
        Volatile.Write(
            ref _pendingTargetedProbeSelectorCount,
            _pendingTargetedProbeSelectors.Count
        );
    }

    private void ExpireStructuredTargetedProbeSelectors(long presentation)
    {
        if (Volatile.Read(ref _pendingTargetedProbeSelectorCount) == 0)
        {
            return;
        }

        List<string>? expired = null;
        lock (_targetedVisibilityProbeGate)
        {
            for (int index = _pendingTargetedProbeSelectors.Count - 1;
                 index >= 0;
                 index--)
            {
                SolMetalTargetedProbeSelector selector =
                    _pendingTargetedProbeSelectors[index];
                if (!selector.IsExpired(
                        presentation,
                        _targetedProbeArmedPresentation
                    ))
                {
                    continue;
                }
                expired ??= [];
                expired.Add(selector.Name);
                _pendingTargetedProbeSelectors.RemoveAt(index);
            }
            Volatile.Write(
                ref _pendingTargetedProbeSelectorCount,
                _pendingTargetedProbeSelectors.Count
            );
        }
        if (expired is not null)
        {
            expired.Reverse();
            Logger.Warning?.Print(
                LogClass.Gpu,
                $"SolMetal structured targeted probe selector(s) expired " +
                $"at presentation {presentation} without a match: [" +
                string.Join(", ", expired) + "]."
            );
        }
    }

    private bool IsConfiguredTargetedProbeProgram(SolMetalGalProgram program) =>
        _targetedVisibilityProbePrograms.Contains(program.ProbeId) ||
        _targetedVisibilityProbeProgramKeys.Contains(program.StableKey);

    private bool TryTakeAutoD16VisibilityProbe(
        SolMetalGalProgram program,
        SolMetalGalTexture? depthTarget,
        SolMetalNativeBridge.GalDepthStencilState depthStencilState,
        int elementCount,
        int instanceCount
    )
    {
        if (Volatile.Read(ref _autoD16ProbeArmed) != 2 ||
            !IsAutoD16ProbeDraw(depthTarget, elementCount, instanceCount))
        {
            return false;
        }

        lock (_autoD16ProbeGate)
        {
            if (_autoD16ProbeArmed != 2)
            {
                return false;
            }

            string key = program.StableKey;
            string writerKey = _autoProbeD16SequenceKeys[0];
            long targetId = depthTarget!.ProbeId;
            if (_autoD16ProbeCaptureIndex == 0)
            {
                if (key != writerKey ||
                    !MatchesAutoD16SequenceDepthRole(
                        0,
                        depthStencilState
                    ))
                {
                    return false;
                }
                _autoD16ProbeCaptureTargetId = targetId;
                _autoD16ProbeCaptureIndex = 1;
                return true;
            }

            if (targetId != _autoD16ProbeCaptureTargetId)
            {
                bool startsSequence = key == writerKey &&
                    MatchesAutoD16SequenceDepthRole(0, depthStencilState);
                _autoD16ProbeCaptureTargetId =
                    startsSequence ? targetId : 0;
                _autoD16ProbeCaptureIndex = startsSequence ? 1 : 0;
                return startsSequence;
            }

            string expected =
                _autoProbeD16SequenceKeys[_autoD16ProbeCaptureIndex];
            if (key == expected && MatchesAutoD16SequenceDepthRole(
                    _autoD16ProbeCaptureIndex,
                    depthStencilState
                ))
            {
                _autoD16ProbeCaptureIndex++;
                if (_autoD16ProbeCaptureIndex ==
                    _autoProbeD16SequenceKeys.Length)
                {
                    Volatile.Write(ref _autoD16ProbeArmed, 3);
                }
                return true;
            }

            if (key == writerKey && MatchesAutoD16SequenceDepthRole(
                    0,
                    depthStencilState
                ))
            {
                _autoD16ProbeCaptureTargetId = targetId;
                _autoD16ProbeCaptureIndex = 1;
                return true;
            }

            _autoD16ProbeCaptureTargetId = 0;
            _autoD16ProbeCaptureIndex = 0;
            return false;
        }
    }

    private static bool IsAutoD16ProbeDraw(
        SolMetalGalTexture? depthTarget,
        int elementCount,
        int instanceCount
    ) =>
        depthTarget is not null &&
        depthTarget.NativeFormat ==
            SolMetalNativeBridge.GalTextureFormat.Depth16Unorm &&
        elementCount == 6 && instanceCount == 350;

    private static bool MatchesAutoD16SequenceDepthRole(
        int sequenceIndex,
        SolMetalNativeBridge.GalDepthStencilState depthStencilState
    ) => sequenceIndex switch
    {
        0 => depthStencilState.DepthWriteEnabled &&
            depthStencilState.DepthCompareFunction ==
                SolMetalNativeBridge.GalCompareFunction.Always,
        1 or 2 => !depthStencilState.DepthWriteEnabled &&
            depthStencilState.DepthCompareFunction ==
                SolMetalNativeBridge.GalCompareFunction.Equal,
        _ => false,
    };

    private static void ValidateAutoD16SequenceDepthRoles()
    {
        SolMetalNativeBridge.GalDepthStencilState writer = new(
            SolMetalNativeBridge.GalCompareFunction.Always,
            true,
            false,
            default,
            default
        );
        SolMetalNativeBridge.GalDepthStencilState replay = new(
            SolMetalNativeBridge.GalCompareFunction.Equal,
            false,
            false,
            default,
            default
        );
        SolMetalNativeBridge.GalDepthStencilState falseWriter = writer with
        {
            DepthWriteEnabled = false,
        };
        SolMetalNativeBridge.GalDepthStencilState falseReplay = replay with
        {
            DepthCompareFunction =
                SolMetalNativeBridge.GalCompareFunction.Always,
        };
        if (!MatchesAutoD16SequenceDepthRole(0, writer) ||
            MatchesAutoD16SequenceDepthRole(0, falseWriter) ||
            !MatchesAutoD16SequenceDepthRole(1, replay) ||
            !MatchesAutoD16SequenceDepthRole(2, replay) ||
            MatchesAutoD16SequenceDepthRole(1, falseReplay) ||
            MatchesAutoD16SequenceDepthRole(3, replay))
        {
            throw new InvalidOperationException(
                "SolMetal automatic D16 sequence depth-role validation failed."
            );
        }
    }

    private void ObserveAutoD16ProbeSequence(
        SolMetalGalProgram program,
        SolMetalGalTexture? depthTarget,
        SolMetalNativeBridge.GalDepthStencilState depthStencilState,
        int elementCount,
        int instanceCount
    )
    {
        if (!_frameProbeEnabled || _autoProbeD16SequenceKeys.Length != 3 ||
            !IsAutoD16ProbeDraw(depthTarget, elementCount, instanceCount) ||
            Volatile.Read(ref _autoD16ProbeArmed) != 0)
        {
            return;
        }

        long presented = Interlocked.Read(ref _presentedFrameCount);
        long lowerBound = _autoProbeAfterPresentations == 0
            ? 1
            : _autoProbeAfterPresentations;
        if (presented < lowerBound)
        {
            return;
        }

        bool armProbe = false;
        int completedSequences = 0;
        long targetId = depthTarget!.ProbeId;
        lock (_autoD16ProbeGate)
        {
            string key = program.StableKey;
            string writerKey = _autoProbeD16SequenceKeys[0];
            bool targetIsMature =
                depthTarget.ProbeDepthPasses >=
                    AutoD16ProbeMinimumDepthPasses &&
                depthTarget.ProbeDepthClearPasses >=
                    AutoD16ProbeMinimumClearPasses;
            if (_autoD16ProbeSequenceIndex == 0)
            {
                if (key == writerKey && targetIsMature &&
                    MatchesAutoD16SequenceDepthRole(0, depthStencilState))
                {
                    _autoD16ProbeCandidateTargetId = targetId;
                    _autoD16ProbeSequenceIndex = 1;
                }
            }
            else if (_autoD16ProbeCandidateTargetId != targetId)
            {
                bool startsSequence = key == writerKey && targetIsMature &&
                    MatchesAutoD16SequenceDepthRole(0, depthStencilState);
                _autoD16ProbeCandidateTargetId =
                    startsSequence ? targetId : 0;
                _autoD16ProbeSequenceIndex =
                    startsSequence ? 1 : 0;
            }
            else if (key ==
                     _autoProbeD16SequenceKeys[_autoD16ProbeSequenceIndex] &&
                     MatchesAutoD16SequenceDepthRole(
                         _autoD16ProbeSequenceIndex,
                         depthStencilState
                     ))
            {
                _autoD16ProbeSequenceIndex++;
                if (_autoD16ProbeSequenceIndex ==
                    _autoProbeD16SequenceKeys.Length)
                {
                    _autoD16ProbeSequenceIndex = 0;
                    _autoD16ProbeCandidateTargetId = 0;
                    if (_autoD16ProbeCompletedSequences == 0 ||
                        _autoD16ProbeStableTargetId != targetId)
                    {
                        _autoD16ProbeStableTargetId = targetId;
                        _autoD16ProbeCompletedSequences = 1;
                        _autoD16ProbeLastCompletionPresentation = presented;
                    }
                    else if (presented >
                             _autoD16ProbeLastCompletionPresentation)
                    {
                        _autoD16ProbeCompletedSequences++;
                        _autoD16ProbeLastCompletionPresentation = presented;
                    }
                    completedSequences = _autoD16ProbeCompletedSequences;
                    if (completedSequences >= 2)
                    {
                        _autoD16ProbeCaptureIndex = 0;
                        Volatile.Write(ref _autoD16ProbeArmed, 1);
                        armProbe = true;
                    }
                }
            }
            else
            {
                bool startsSequence = key == writerKey && targetIsMature &&
                    MatchesAutoD16SequenceDepthRole(0, depthStencilState);
                _autoD16ProbeCandidateTargetId =
                    startsSequence ? targetId : 0;
                _autoD16ProbeSequenceIndex =
                    startsSequence ? 1 : 0;
            }
        }

        if (armProbe)
        {
            Logger.Notice.Print(
                LogClass.Gpu,
                $"SolMetal recognized {completedSequences} stable D16 " +
                $"writer/replay sequences on target #{targetId} after " +
                $"{presented} presentations; the next presentation will " +
                "arm the following sequence probe."
            );
        }
    }

    internal static bool TryCreate(
        out SolMetalGalRenderer? renderer,
        out string? failure
    )
    {
        renderer = null;
        if (!SolMetalNativeBridge.TryCreateGalSession(
                out SolMetalNativeBridge.IGalSession? session,
                out failure) || session is null)
        {
            return false;
        }

        renderer = new SolMetalGalRenderer(session, 0);
        return true;
    }

    internal static bool TryCreateForEmbeddedSurface(
        nint metalLayer,
        out SolMetalGalRenderer? renderer,
        out string? failure
    )
    {
        renderer = null;
        if (metalLayer == 0)
        {
            failure = "SolMetal requires the embedded CAMetalLayer.";
            return false;
        }
        if (!SolMetalNativeBridge.TryCreateGalSession(
                out SolMetalNativeBridge.IGalSession? session,
                out failure) || session is null)
        {
            return false;
        }
        renderer = new SolMetalGalRenderer(session, metalLayer);
        return true;
    }

    private static byte[] BuildLayeredSmokeVertexSpirv()
    {
        byte[] sourceBytes = Convert.FromBase64String(SmokeVertexSpirvBase64);
        if (sourceBytes.Length < 20 || sourceBytes.Length % sizeof(uint) != 0)
        {
            throw new InvalidOperationException(
                "SolMetal layered smoke fixture has an invalid SPIR-V size."
            );
        }
        uint[] source = new uint[sourceBytes.Length / sizeof(uint)];
        Buffer.BlockCopy(sourceBytes, 0, source, 0, sourceBytes.Length);
        const uint MagicNumber = 0x07230203;
        const uint OpCapability = 17;
        const uint OpEntryPoint = 15;
        const uint OpDecorate = 71;
        const uint OpTypeVoid = 19;
        const uint OpTypePointer = 32;
        const uint OpVariable = 59;
        const uint OpFunction = 54;
        const uint OpLoad = 61;
        const uint OpStore = 62;
        const uint OpReturn = 253;
        const uint DecorationBuiltIn = 11;
        const uint BuiltInLayer = 9;
        const uint BuiltInVertexIndex = 42;
        const uint BuiltInInstanceIndex = 43;
        const uint CapabilityShaderLayer = 69;
        const uint StorageClassInput = 1;
        const uint StorageClassOutput = 3;
        if (source[0] != MagicNumber || source[3] == 0)
        {
            throw new InvalidOperationException(
                "SolMetal layered smoke fixture has an invalid SPIR-V header."
            );
        }

        uint vertexIndexVariable = 0;
        uint inputPointerType = 0;
        uint signedIntType = 0;
        for (int offset = 5; offset < source.Length;)
        {
            int wordCount = checked((int)(source[offset] >> 16));
            uint opcode = source[offset] & 0xffff;
            if (wordCount == 0 || offset > source.Length - wordCount)
            {
                throw new InvalidOperationException(
                    "SolMetal layered smoke fixture contains malformed SPIR-V."
                );
            }
            if (opcode == OpDecorate && wordCount >= 4 &&
                source[offset + 2] == DecorationBuiltIn &&
                source[offset + 3] == BuiltInVertexIndex)
            {
                vertexIndexVariable = source[offset + 1];
            }
            offset += wordCount;
        }
        for (int offset = 5; offset < source.Length;)
        {
            int wordCount = checked((int)(source[offset] >> 16));
            uint opcode = source[offset] & 0xffff;
            if (opcode == OpVariable && wordCount >= 4 &&
                source[offset + 2] == vertexIndexVariable)
            {
                inputPointerType = source[offset + 1];
            }
            offset += wordCount;
        }
        for (int offset = 5; offset < source.Length;)
        {
            int wordCount = checked((int)(source[offset] >> 16));
            uint opcode = source[offset] & 0xffff;
            if (opcode == OpTypePointer && wordCount == 4 &&
                source[offset + 1] == inputPointerType &&
                source[offset + 2] == StorageClassInput)
            {
                signedIntType = source[offset + 3];
            }
            offset += wordCount;
        }
        if (vertexIndexVariable == 0 || inputPointerType == 0 ||
            signedIntType == 0 || source[3] > uint.MaxValue - 4)
        {
            throw new InvalidOperationException(
                "SolMetal layered smoke fixture lacks its vertex-index type chain."
            );
        }

        uint instanceVariable = source[3];
        uint outputPointerType = source[3] + 1;
        uint layerVariable = source[3] + 2;
        uint loadedInstance = source[3] + 3;
        source[3] += 4;
        List<uint> output = new(source.Length + 32);
        output.AddRange(source.AsSpan(0, 5).ToArray());
        bool capabilityInserted = false;
        bool decorationsInserted = false;
        bool declarationsInserted = false;
        bool storeInserted = false;
        for (int offset = 5; offset < source.Length;)
        {
            int wordCount = checked((int)(source[offset] >> 16));
            uint opcode = source[offset] & 0xffff;
            if (!capabilityInserted && opcode != OpCapability)
            {
                output.Add((2u << 16) | OpCapability);
                output.Add(CapabilityShaderLayer);
                capabilityInserted = true;
            }
            if (!decorationsInserted && opcode == OpTypeVoid)
            {
                output.AddRange([
                    (4u << 16) | OpDecorate,
                    instanceVariable,
                    DecorationBuiltIn,
                    BuiltInInstanceIndex,
                    (4u << 16) | OpDecorate,
                    layerVariable,
                    DecorationBuiltIn,
                    BuiltInLayer,
                ]);
                decorationsInserted = true;
            }
            if (!declarationsInserted && opcode == OpFunction)
            {
                output.AddRange([
                    (4u << 16) | OpTypePointer,
                    outputPointerType,
                    StorageClassOutput,
                    signedIntType,
                    (4u << 16) | OpVariable,
                    inputPointerType,
                    instanceVariable,
                    StorageClassInput,
                    (4u << 16) | OpVariable,
                    outputPointerType,
                    layerVariable,
                    StorageClassOutput,
                ]);
                declarationsInserted = true;
            }
            if (!storeInserted && opcode == OpReturn)
            {
                output.AddRange([
                    (4u << 16) | OpLoad,
                    signedIntType,
                    loadedInstance,
                    instanceVariable,
                    (3u << 16) | OpStore,
                    layerVariable,
                    loadedInstance,
                ]);
                storeInserted = true;
            }
            if (opcode == OpEntryPoint)
            {
                output.Add((checked((uint)wordCount) + 2u << 16) | opcode);
                output.AddRange(
                    source.AsSpan(offset + 1, wordCount - 1).ToArray()
                );
                output.Add(instanceVariable);
                output.Add(layerVariable);
            }
            else
            {
                output.AddRange(source.AsSpan(offset, wordCount).ToArray());
            }
            offset += wordCount;
        }
        if (!capabilityInserted || !decorationsInserted ||
            !declarationsInserted || !storeInserted)
        {
            throw new InvalidOperationException(
                "SolMetal layered smoke fixture could not be augmented safely."
            );
        }
        byte[] result = new byte[checked(output.Count * sizeof(uint))];
        Buffer.BlockCopy(output.ToArray(), 0, result, 0, result.Length);
        return result;
    }

    private static byte[] BuildPointSizeSmokeVertexSpirv()
    {
        byte[] sourceBytes = Convert.FromBase64String(SmokeVertexSpirvBase64);
        uint[] source = new uint[sourceBytes.Length / sizeof(uint)];
        Buffer.BlockCopy(sourceBytes, 0, source, 0, sourceBytes.Length);
        const uint MagicNumber = 0x07230203;
        const uint OpMemberDecorate = 72;
        const uint OpTypeInt = 21;
        const uint OpTypeFloat = 22;
        const uint OpTypePointer = 32;
        const uint OpVariable = 59;
        const uint OpConstant = 43;
        const uint OpFunction = 54;
        const uint OpAccessChain = 65;
        const uint OpStore = 62;
        const uint OpReturn = 253;
        const uint DecorationBuiltIn = 11;
        const uint BuiltInPointSize = 1;
        const uint StorageClassOutput = 3;
        if (sourceBytes.Length < 20 ||
            sourceBytes.Length % sizeof(uint) != 0 ||
            source[0] != MagicNumber || source[3] == 0)
        {
            throw new InvalidOperationException(
                "SolMetal point-size smoke fixture has an invalid SPIR-V header."
            );
        }

        uint outputStructType = 0;
        uint pointSizeMember = 0;
        uint outputStructPointerType = 0;
        uint outputVariable = 0;
        uint signedIntType = 0;
        uint floatType = 0;
        for (int offset = 5; offset < source.Length;)
        {
            int wordCount = checked((int)(source[offset] >> 16));
            uint opcode = source[offset] & 0xffff;
            if (wordCount == 0 || offset > source.Length - wordCount)
            {
                throw new InvalidOperationException(
                    "SolMetal point-size smoke fixture contains malformed SPIR-V."
                );
            }
            if (opcode == OpMemberDecorate && wordCount >= 5 &&
                source[offset + 3] == DecorationBuiltIn &&
                source[offset + 4] == BuiltInPointSize)
            {
                outputStructType = source[offset + 1];
                pointSizeMember = source[offset + 2];
            }
            else if (opcode == OpTypeInt && wordCount == 4 &&
                     source[offset + 2] == 32 && source[offset + 3] == 1)
            {
                signedIntType = source[offset + 1];
            }
            else if (opcode == OpTypeFloat && wordCount == 3 &&
                     source[offset + 2] == 32)
            {
                floatType = source[offset + 1];
            }
            offset += wordCount;
        }
        for (int offset = 5; offset < source.Length;)
        {
            int wordCount = checked((int)(source[offset] >> 16));
            uint opcode = source[offset] & 0xffff;
            if (opcode == OpTypePointer && wordCount == 4 &&
                source[offset + 2] == StorageClassOutput &&
                source[offset + 3] == outputStructType)
            {
                outputStructPointerType = source[offset + 1];
            }
            offset += wordCount;
        }
        for (int offset = 5; offset < source.Length;)
        {
            int wordCount = checked((int)(source[offset] >> 16));
            uint opcode = source[offset] & 0xffff;
            if (opcode == OpVariable && wordCount >= 4 &&
                source[offset + 1] == outputStructPointerType &&
                source[offset + 3] == StorageClassOutput)
            {
                outputVariable = source[offset + 2];
            }
            offset += wordCount;
        }
        if (outputStructType == 0 || outputStructPointerType == 0 ||
            outputVariable == 0 || signedIntType == 0 || floatType == 0 ||
            source[3] > uint.MaxValue - 4)
        {
            throw new InvalidOperationException(
                "SolMetal point-size smoke fixture lacks its output type chain."
            );
        }

        uint outputFloatPointerType = source[3];
        uint memberIndexConstant = source[3] + 1;
        uint pointSizeConstant = source[3] + 2;
        uint pointSizePointer = source[3] + 3;
        source[3] += 4;
        List<uint> output = new(source.Length + 24);
        output.AddRange(source.AsSpan(0, 5).ToArray());
        bool declarationsInserted = false;
        bool storeInserted = false;
        for (int offset = 5; offset < source.Length;)
        {
            int wordCount = checked((int)(source[offset] >> 16));
            uint opcode = source[offset] & 0xffff;
            if (!declarationsInserted && opcode == OpFunction)
            {
                output.AddRange([
                    (4u << 16) | OpTypePointer,
                    outputFloatPointerType,
                    StorageClassOutput,
                    floatType,
                    (4u << 16) | OpConstant,
                    signedIntType,
                    memberIndexConstant,
                    pointSizeMember,
                    (4u << 16) | OpConstant,
                    floatType,
                    pointSizeConstant,
                    0x41000000u,
                ]);
                declarationsInserted = true;
            }
            if (!storeInserted && opcode == OpReturn)
            {
                output.AddRange([
                    (5u << 16) | OpAccessChain,
                    outputFloatPointerType,
                    pointSizePointer,
                    outputVariable,
                    memberIndexConstant,
                    (3u << 16) | OpStore,
                    pointSizePointer,
                    pointSizeConstant,
                ]);
                storeInserted = true;
            }
            output.AddRange(source.AsSpan(offset, wordCount).ToArray());
            offset += wordCount;
        }
        if (!declarationsInserted || !storeInserted)
        {
            throw new InvalidOperationException(
                "SolMetal point-size smoke fixture could not be augmented safely."
            );
        }
        byte[] result = new byte[checked(output.Count * sizeof(uint))];
        Buffer.BlockCopy(output.ToArray(), 0, result, 0, result.Length);
        return result;
    }

    private static int ValidatePointSizeGalVariants(
        SolMetalGalRenderer renderer
    )
    {
        using IProgram program = renderer.CreateProgram(
            [
                new ShaderSource(
                    BuildPointSizeSmokeVertexSpirv(),
                    ShaderStage.Vertex,
                    TargetLanguage.Spirv
                ),
                new ShaderSource(
                    Convert.FromBase64String(SmokeFragmentSpirvBase64),
                    ShaderStage.Fragment,
                    TargetLanguage.Spirv
                ),
            ],
            new ShaderInfo(0, default(ResourceLayout))
        );
        SolMetalGalProgram nativeProgram = (SolMetalGalProgram)program;
        string? pointMsl = nativeProgram.CopyVertexMslForTopology(
            SolMetalNativeBridge.GalPrimitiveTopologyClass.Point
        );
        string? triangleMsl = nativeProgram.CopyVertexMslForTopology(
            SolMetalNativeBridge.GalPrimitiveTopologyClass.Triangle
        );
        string? lineMsl = nativeProgram.CopyVertexMslForTopology(
            SolMetalNativeBridge.GalPrimitiveTopologyClass.Line
        );
        if (pointMsl?.Contains("[[point_size]]", StringComparison.Ordinal) !=
                true ||
            triangleMsl?.Contains(
                "[[point_size]]",
                StringComparison.Ordinal
            ) != false ||
            lineMsl?.Contains("[[point_size]]", StringComparison.Ordinal) !=
                false)
        {
            throw new InvalidOperationException(
                "SolMetal GAL did not select topology-specific point-size MSL."
            );
        }

        TextureCreateInfo info = new(
            width: 64,
            height: 64,
            depth: 1,
            levels: 1,
            samples: 1,
            blockWidth: 1,
            blockHeight: 1,
            bytesPerPixel: 4,
            format: Format.B8G8R8A8Unorm,
            depthStencilMode: DepthStencilMode.Depth,
            target: Target.Texture2D,
            swizzleR: SwizzleComponent.Red,
            swizzleG: SwizzleComponent.Green,
            swizzleB: SwizzleComponent.Blue,
            swizzleA: SwizzleComponent.Alpha
        );
        ITexture pointTarget = renderer.CreateTexture(info);
        ITexture triangleTarget = renderer.CreateTexture(info);
        try
        {
            renderer.Pipeline.SetRenderTargetColorMasks([0xfu]);
            renderer.Pipeline.SetRenderTargets([pointTarget], null!);
            renderer.Pipeline.ClearRenderTargetColor(
                0, 0, 1, 0xf, new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.SetPrimitiveTopology(PrimitiveTopology.Points);
            renderer.Pipeline.SetProgram(program);
            renderer.Pipeline.Draw(1, 1, 0, 0);
            using PinnedSpan<byte> pointReadback = pointTarget.GetData();
            ReadOnlySpan<byte> pointPixels = pointReadback.Get();
            bool pointVisible = false;
            for (int offset = 0; offset < pointPixels.Length; offset += 4)
            {
                if (pointPixels[offset] <= 8 &&
                    pointPixels[offset + 1] <= 8 &&
                    pointPixels[offset + 2] >= 240 &&
                    pointPixels[offset + 3] >= 240)
                {
                    pointVisible = true;
                    break;
                }
            }
            if (!pointVisible)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL point-size program did not render its point."
                );
            }

            renderer.Pipeline.SetRenderTargets([triangleTarget], null!);
            renderer.Pipeline.ClearRenderTargetColor(
                0, 0, 1, 0xf, new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.SetPrimitiveTopology(
                PrimitiveTopology.Triangles
            );
            renderer.Pipeline.SetProgram(program);
            renderer.Pipeline.Draw(3, 1, 0, 0);
            using PinnedSpan<byte> triangleReadback = triangleTarget.GetData();
            ReadOnlySpan<byte> trianglePixels = triangleReadback.Get();
            int center = ((32 * 64) + 32) * 4;
            if (trianglePixels[center] > 8 ||
                trianglePixels[center + 1] > 8 ||
                trianglePixels[center + 2] < 240 ||
                trianglePixels[center + 3] < 240)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL point-size program did not render as a triangle."
                );
            }
            return 2 * 64 * 64 * 4;
        }
        finally
        {
            triangleTarget.Release();
            pointTarget.Release();
        }
    }

    private static int ValidateLayeredGalRendering(
        SolMetalGalRenderer renderer
    )
    {
        if (!renderer._session.SupportsLayeredVertexOutput)
        {
            if (renderer.GetCapabilities().SupportsLayerVertexTessellation)
            {
                throw new InvalidOperationException(
                    "SolMetal advertised layered vertex output on an unsupported GPU."
                );
            }
            return 0;
        }
        if (!renderer.GetCapabilities().SupportsLayerVertexTessellation)
        {
            throw new InvalidOperationException(
                "SolMetal failed to advertise its validated layered vertex path."
            );
        }

        byte[] layeredVertex = BuildLayeredSmokeVertexSpirv();
        using IProgram layeredProgram = renderer.CreateProgram(
            [
                new ShaderSource(
                    layeredVertex,
                    ShaderStage.Vertex,
                    TargetLanguage.Spirv
                ),
                new ShaderSource(
                    Convert.FromBase64String(SmokeFragmentSpirvBase64),
                    ShaderStage.Fragment,
                    TargetLanguage.Spirv
                ),
            ],
            new ShaderInfo(0, default(ResourceLayout))
        );
        SolMetalGalProgram nativeProgram = (SolMetalGalProgram)layeredProgram;
        if (nativeProgram.CopyVertexMsl()?.Contains(
                "[[render_target_array_index]]",
                StringComparison.Ordinal
            ) != true)
        {
            throw new InvalidOperationException(
                "SolMetal did not lower SPIR-V BuiltInLayer to Metal layered output."
            );
        }

        int verifiedBytes = 0;
        foreach ((Target Target, int Layers, string Name) fixture in new[]
        {
            (Target.Texture2D, 1, "single-layer 2D"),
            (Target.Texture2DArray, 2, "2D-array"),
            (Target.Cubemap, 6, "cube"),
        })
        {
            TextureCreateInfo info = new(
                width: 64,
                height: 64,
                depth: fixture.Layers,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 4,
                format: Format.B8G8R8A8Unorm,
                depthStencilMode: DepthStencilMode.Depth,
                target: fixture.Target,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            ITexture target = renderer.CreateTexture(info);
            try
            {
                renderer.Pipeline.SetRenderTargetColorMasks([0xfu]);
                renderer.Pipeline.SetRenderTargets([target], null!);
                renderer.Pipeline.ClearRenderTargetColor(
                    0,
                    0,
                    fixture.Layers,
                    0xf,
                    new ColorF(0, 0, 0, 1)
                );
                renderer.Pipeline.SetPrimitiveTopology(
                    PrimitiveTopology.Triangles
                );
                renderer.Pipeline.SetProgram(layeredProgram);
                renderer.Pipeline.Draw(3, fixture.Layers, 0, 0);
                using PinnedSpan<byte> readback = target.GetData();
                ReadOnlySpan<byte> pixels = readback.Get();
                int bytesPerImage = 64 * 64 * 4;
                if (pixels.Length < bytesPerImage * fixture.Layers)
                {
                    throw new InvalidOperationException(
                        $"SolMetal GAL {fixture.Name} readback omitted layers."
                    );
                }
                for (int layer = 0; layer < fixture.Layers; layer++)
                {
                    int imageOffset = layer * bytesPerImage;
                    int center = imageOffset + ((32 * 64) + 32) * 4;
                    int corner = imageOffset + ((2 * 64) + 2) * 4;
                    bool centerIsRed = pixels[center] <= 8 &&
                        pixels[center + 1] <= 8 &&
                        pixels[center + 2] >= 240 &&
                        pixels[center + 3] >= 240;
                    bool cornerIsClear = pixels[corner] <= 8 &&
                        pixels[corner + 1] <= 8 &&
                        pixels[corner + 2] <= 8 &&
                        pixels[corner + 3] >= 240;
                    if (!centerIsRed || !cornerIsClear)
                    {
                        throw new InvalidOperationException(
                            $"SolMetal GAL {fixture.Name} layer {layer} " +
                            "did not receive the expected layered draw."
                        );
                    }
                }
                verifiedBytes += bytesPerImage * fixture.Layers;
            }
            finally
            {
                target.Release();
            }
        }
        return verifiedBytes;
    }

    private static void ValidateUnsupportedTessellation(
        SolMetalGalRenderer renderer
    )
    {
        try
        {
            using IProgram unexpected = renderer.CreateProgram(
                [
                    new ShaderSource(
                        Convert.FromBase64String(SmokeVertexSpirvBase64),
                        ShaderStage.Vertex,
                        TargetLanguage.Spirv
                    ),
                    new ShaderSource(
                        Convert.FromBase64String(SmokeVertexSpirvBase64),
                        ShaderStage.TessellationControl,
                        TargetLanguage.Spirv
                    ),
                    new ShaderSource(
                        Convert.FromBase64String(SmokeFragmentSpirvBase64),
                        ShaderStage.Fragment,
                        TargetLanguage.Spirv
                    ),
                ],
                new ShaderInfo(0, default(ResourceLayout))
            );
        }
        catch (NotSupportedException exception) when (
            exception.Message.Contains(
                "tessellation shader stages",
                StringComparison.Ordinal
            ))
        {
            return;
        }
        throw new InvalidOperationException(
            "SolMetal did not fail closed for a genuine tessellation program."
        );
    }

    private static int ValidateGreenQuadReadback(
        ITexture target,
        string description
    )
    {
        using PinnedSpan<byte> readback = target.GetData();
        ReadOnlySpan<byte> pixels = readback.Get();
        foreach ((int X, int Y) sample in new[]
        {
            (32, 32),
            (96, 32),
            (32, 96),
            (96, 96),
        })
        {
            int offset = ((sample.Y * 128) + sample.X) * 4;
            if (offset < 0 || offset > pixels.Length - 4 ||
                pixels[offset] > 8 || pixels[offset + 1] < 240 ||
                pixels[offset + 2] > 8 || pixels[offset + 3] < 240)
            {
                throw new InvalidOperationException(
                    $"SolMetal GAL {description} did not shade the full quad " +
                    $"at ({sample.X}, {sample.Y})."
                );
            }
        }
        return pixels.Length;
    }

    private static void RequireUnsupported(
        Action action,
        string expectedMessage
    )
    {
        try
        {
            action();
        }
        catch (NotSupportedException exception) when (
            exception.Message.Contains(expectedMessage, StringComparison.Ordinal)
        )
        {
            return;
        }
        throw new InvalidOperationException(
            $"SolMetal did not fail closed for {expectedMessage}."
        );
    }

    internal static GalSmokeResult RunResourceSmoke()
    {
        SolMetalRenderProgramIdentity.Validate();
        SolMetalTargetedProbeSelector.Validate();
        SolMetalGalProgram.ValidatePipelineKeyTopologySeparation();
        SolMetalGalPipeline.ValidateZeroStrideVertexLayout();
        SolMetalGalPipeline.ValidateQuadTopologyConversion();
        ValidateProbeDrawDepthSnapshot();
        ValidateAutoD16SequenceDepthRoles();
        if (!TryCreate(out SolMetalGalRenderer? renderer, out string? failure) ||
            renderer is null)
        {
            throw new InvalidOperationException(
                failure ?? "SolMetal GAL renderer could not be created."
            );
        }

        using (renderer)
        {
            ValidateUnsupportedTessellation(renderer);
            int pointSizeBytesVerified =
                ValidatePointSizeGalVariants(renderer);
            int layeredBytesVerified = ValidateLayeredGalRendering(renderer);
            const int byteCount = 1024 * 1024 + 37;
            const ulong guestSync = 0x534f4c4d;
            byte[] pattern = new byte[byteCount];
            for (int index = 0; index < pattern.Length; index++)
            {
                pattern[index] = (byte)((index * 197 + (index >> 5) + 29) & 0xff);
            }

            BufferHandle upload = renderer.CreateBuffer(
                byteCount,
                BufferAccess.HostMemory
            );
            BufferHandle device = renderer.CreateBuffer(
                byteCount,
                BufferAccess.DeviceMemory
            );
            renderer.SetBufferData(upload, 0, pattern);
            renderer.Pipeline.CopyBuffer(upload, device, 0, 0, byteCount);
            renderer.CreateSync(guestSync, strict: true);
            renderer.WaitSync(guestSync);
            if (renderer.GetCurrentSync() < guestSync)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL sync did not advance after the buffer copy."
                );
            }

            using PinnedSpan<byte> readback = renderer.GetBufferData(
                device,
                0,
                byteCount
            );
            if (!readback.Get().SequenceEqual(pattern))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL buffer copy changed the validation pattern."
                );
            }

            const int clearOffset = 64;
            const int clearByteCount = 4096;
            const uint clearValue = 0x7a31c95d;
            renderer.Pipeline.ClearBuffer(
                device,
                clearOffset,
                clearByteCount,
                clearValue
            );
            using PinnedSpan<byte> clearReadback = renderer.GetBufferData(
                device,
                clearOffset,
                clearByteCount
            );
            ReadOnlySpan<uint> clearedWords = MemoryMarshal.Cast<byte, uint>(
                clearReadback.Get()
            );
            foreach (uint word in clearedWords)
            {
                if (word != clearValue)
                {
                    throw new InvalidOperationException(
                        "SolMetal GAL buffer fill changed the requested value."
                    );
                }
            }

            const int bufferTextureOffset = 256;
            const int bufferTextureTexels = 64;
            const int bufferTextureBytes = bufferTextureTexels * sizeof(uint);
            TextureCreateInfo bufferTextureInfo = new(
                width: bufferTextureTexels,
                height: 1,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: sizeof(uint),
                format: Format.R32Uint,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.TextureBuffer,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            byte[] bufferTexturePattern = new byte[bufferTextureBytes];
            for (int index = 0; index < bufferTexturePattern.Length; index++)
            {
                bufferTexturePattern[index] = (byte)(index * 31 + 17);
            }
            ITexture bufferTexture = renderer.CreateTexture(bufferTextureInfo);
            bufferTexture.SetStorage(new BufferRange(
                device,
                bufferTextureOffset,
                bufferTextureBytes
            ));
            bufferTexture.SetData(
                MemoryOwner<byte>.RentCopy(bufferTexturePattern)
            );
            using PinnedSpan<byte> bufferTextureReadback =
                bufferTexture.GetData();
            if (!bufferTextureReadback.Get().SequenceEqual(bufferTexturePattern))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL buffer-texture storage changed the validation pattern."
                );
            }
            bufferTexture.Release();

            const int textureWidth = 257;
            const int textureHeight = 129;
            TextureCreateInfo textureInfo = new(
                textureWidth,
                textureHeight,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 4,
                Format.B8G8R8A8Unorm,
                DepthStencilMode.Depth,
                Target.Texture2D,
                SwizzleComponent.Red,
                SwizzleComponent.Green,
                SwizzleComponent.Blue,
                SwizzleComponent.Alpha
            );
            byte[] texturePattern = new byte[textureWidth * textureHeight * 4];
            for (int index = 0; index < texturePattern.Length; index++)
            {
                texturePattern[index] = (byte)((index * 83 + (index >> 3) + 7) & 0xff);
            }
            ITexture sourceTexture = renderer.CreateTexture(textureInfo);
            ITexture copiedTexture = renderer.CreateTexture(textureInfo);
            sourceTexture.SetData(MemoryOwner<byte>.RentCopy(texturePattern));
            sourceTexture.CopyTo(copiedTexture, firstLayer: 0, firstLevel: 0);
            using PinnedSpan<byte> textureReadback = copiedTexture.GetData();
            if (!textureReadback.Get().SequenceEqual(texturePattern))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL texture copy changed the validation pattern."
                );
            }

            TextureCreateInfo mipArrayInfo = new(
                width: 16,
                height: 8,
                depth: 2,
                levels: 2,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 4,
                format: Format.R8G8B8A8Unorm,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2DArray,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            byte[] mipArrayPattern = new byte[GetTextureDataSize(mipArrayInfo)];
            int mipArrayOffset = 0;
            for (int level = 0; level < mipArrayInfo.Levels; level++)
            {
                int sliceBytes = mipArrayInfo.GetMipSize2D(level);
                for (int layer = 0; layer < mipArrayInfo.GetLayers(); layer++)
                {
                    byte sentinel = (byte)(0x21 + level * 0x31 + layer * 0x13);
                    mipArrayPattern.AsSpan(mipArrayOffset, sliceBytes).Fill(
                        sentinel
                    );
                    mipArrayOffset += sliceBytes;
                }
            }
            ITexture mipArray = renderer.CreateTexture(mipArrayInfo);
            mipArray.SetData(MemoryOwner<byte>.RentCopy(mipArrayPattern));
            using PinnedSpan<byte> mipArrayReadback = mipArray.GetData();
            if (!mipArrayReadback.Get().SequenceEqual(mipArrayPattern))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL all-mip array readback changed a subresource."
                );
            }

            int levelOneOffset = mipArrayInfo.GetMipSize(0);
            int levelOneSliceBytes = mipArrayInfo.GetMipSize2D(1);
            ReadOnlySpan<byte> expectedLevelOneSliceOne =
                mipArrayPattern.AsSpan(
                    levelOneOffset + levelOneSliceBytes,
                    levelOneSliceBytes
                );
            using PinnedSpan<byte> selectedMipReadback = mipArray.GetData(1, 1);
            if (!selectedMipReadback.Get().SequenceEqual(
                    expectedLevelOneSliceOne))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL selected mip/layer readback used the wrong subresource."
                );
            }

            TextureCreateInfo parentViewInfo = new(
                width: 16,
                height: 8,
                depth: 1,
                levels: 2,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 4,
                format: Format.R8G8B8A8Unorm,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2DArray,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            ITexture parentView = mipArray.CreateView(
                parentViewInfo,
                firstLayer: 1,
                firstLevel: 0
            );
            TextureCreateInfo nestedMipViewInfo = new(
                width: 8,
                height: 4,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 4,
                format: Format.R8G8B8A8Unorm,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2D,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            ITexture nestedMipView = parentView.CreateView(
                nestedMipViewInfo,
                firstLayer: 0,
                firstLevel: 1
            );
            using PinnedSpan<byte> nestedMipReadback = nestedMipView.GetData();
            if (!nestedMipReadback.Get().SequenceEqual(
                    expectedLevelOneSliceOne))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL nested mip view resolved the wrong root subresource."
                );
            }
            nestedMipView.Release();
            parentView.Release();
            mipArray.Release();

            const int d16Width = 19;
            const int d16Height = 11;
            TextureCreateInfo d16Info = new(
                d16Width,
                d16Height,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: sizeof(ushort),
                Format.D16Unorm,
                DepthStencilMode.Depth,
                Target.Texture2D,
                SwizzleComponent.Red,
                SwizzleComponent.Red,
                SwizzleComponent.Red,
                SwizzleComponent.One
            );
            int d16Stride = d16Info.GetMipStride(0);
            byte[] d16Pattern = new byte[d16Info.GetMipSize(0)];
            ushort[] d16Codes =
            [
                0,
                1,
                32_768,
                33_024,
                39_192,
                65_534,
                65_535,
            ];
            ulong[] expectedD16Histogram = new ulong[ushort.MaxValue + 1];
            for (int y = 0; y < d16Height; y++)
            {
                for (int x = 0; x < d16Width; x++)
                {
                    ushort code = d16Codes[(x + y * d16Width) % d16Codes.Length];
                    int offset = y * d16Stride + x * sizeof(ushort);
                    d16Pattern[offset] = (byte)code;
                    d16Pattern[offset + 1] = (byte)(code >> 8);
                    expectedD16Histogram[code]++;
                }
            }
            ITexture d16Texture = renderer.CreateTexture(d16Info);
            d16Texture.SetData(MemoryOwner<byte>.RentCopy(d16Pattern));
            using PinnedSpan<byte> d16Readback = d16Texture.GetData();
            ReadOnlySpan<byte> d16Bytes = d16Readback.Get();
            ulong[] actualD16Histogram = BuildD16Histogram(
                d16Bytes,
                d16Width,
                d16Height,
                d16Stride
            );
            if (!d16Bytes.SequenceEqual(d16Pattern) ||
                !actualD16Histogram.SequenceEqual(expectedD16Histogram) ||
                D16CodeForTag(35, 0.5f) != 39_192 ||
                D16CodeForTag(32, 0.5f) != 33_024)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL bounded D16 readback or code histogram diverged."
                );
            }
            d16Texture.Release();

            TextureCreateInfo d16MipArrayInfo = new(
                width: 8,
                height: 4,
                depth: 2,
                levels: 2,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: sizeof(ushort),
                format: Format.D16Unorm,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2DArray,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Red,
                swizzleB: SwizzleComponent.Red,
                swizzleA: SwizzleComponent.One
            );
            byte[] d16MipArrayPattern = new byte[
                GetTextureDataSize(d16MipArrayInfo)
            ];
            int d16MipArrayOffset = 0;
            for (int level = 0; level < d16MipArrayInfo.Levels; level++)
            {
                int sliceBytes = d16MipArrayInfo.GetMipSize2D(level);
                for (int layer = 0;
                     layer < d16MipArrayInfo.GetLayers();
                     layer++)
                {
                    ushort code = (ushort)(
                        0x2100 + level * 0x1800 + layer * 0x0711
                    );
                    Span<ushort> words = MemoryMarshal.Cast<byte, ushort>(
                        d16MipArrayPattern.AsSpan(
                            d16MipArrayOffset,
                            sliceBytes
                        )
                    );
                    words.Fill(code);
                    d16MipArrayOffset += sliceBytes;
                }
            }
            ITexture d16MipArray = renderer.CreateTexture(d16MipArrayInfo);
            d16MipArray.SetData(
                MemoryOwner<byte>.RentCopy(d16MipArrayPattern)
            );
            using PinnedSpan<byte> d16MipArrayReadback =
                d16MipArray.GetData();
            if (!d16MipArrayReadback.Get().SequenceEqual(
                    d16MipArrayPattern))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL all-mip D16 array readback changed a subresource."
                );
            }
            int d16LevelOneOffset = d16MipArrayInfo.GetMipSize(0);
            int d16LevelOneSliceBytes = d16MipArrayInfo.GetMipSize2D(1);
            using PinnedSpan<byte> d16SelectedReadback =
                d16MipArray.GetData(1, 1);
            if (!d16SelectedReadback.Get().SequenceEqual(
                    d16MipArrayPattern.AsSpan(
                        d16LevelOneOffset + d16LevelOneSliceBytes,
                        d16LevelOneSliceBytes
                    )))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL selected D16 mip/layer readback used the wrong subresource."
                );
            }
            d16MipArray.Release();

            TextureCreateInfo depthMipArrayInfo = new(
                width: 8,
                height: 4,
                depth: 2,
                levels: 2,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: sizeof(float),
                format: Format.D32Float,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2DArray,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Red,
                swizzleB: SwizzleComponent.Red,
                swizzleA: SwizzleComponent.One
            );
            byte[] depthMipArrayPattern = new byte[
                GetTextureDataSize(depthMipArrayInfo)
            ];
            int depthMipArrayOffset = 0;
            for (int level = 0; level < depthMipArrayInfo.Levels; level++)
            {
                int sliceBytes = depthMipArrayInfo.GetMipSize2D(level);
                int stride = depthMipArrayInfo.GetMipStride(level);
                int height = Math.Max(1, depthMipArrayInfo.Height >> level);
                int width = Math.Max(1, depthMipArrayInfo.Width >> level);
                for (int layer = 0;
                     layer < depthMipArrayInfo.GetLayers();
                     layer++)
                {
                    float depth = (level + 1) * 0.125f + layer * 0.25f;
                    for (int y = 0; y < height; y++)
                    {
                        for (int x = 0; x < width; x++)
                        {
                            BitConverter.TryWriteBytes(
                                depthMipArrayPattern.AsSpan(
                                    depthMipArrayOffset + y * stride +
                                        x * sizeof(float),
                                    sizeof(float)
                                ),
                                depth
                            );
                        }
                    }
                    depthMipArrayOffset += sliceBytes;
                }
            }
            ITexture depthMipArray = renderer.CreateTexture(
                depthMipArrayInfo
            );
            depthMipArray.SetData(
                MemoryOwner<byte>.RentCopy(depthMipArrayPattern)
            );
            using PinnedSpan<byte> allDepthReadback =
                depthMipArray.GetData();
            if (!allDepthReadback.Get().SequenceEqual(depthMipArrayPattern))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL all-mip D32 array readback changed a subresource."
                );
            }
            int depthLevelOneOffset = depthMipArrayInfo.GetMipSize(0);
            int depthLevelOneSliceBytes =
                depthMipArrayInfo.GetMipSize2D(1);
            using PinnedSpan<byte> selectedDepthReadback =
                depthMipArray.GetData(1, 1);
            if (!selectedDepthReadback.Get().SequenceEqual(
                    depthMipArrayPattern.AsSpan(
                        depthLevelOneOffset + depthLevelOneSliceBytes,
                        depthLevelOneSliceBytes
                    )))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL selected D32 mip/layer readback used the wrong subresource."
                );
            }

            TextureCreateInfo colorDepthMipArrayInfo = new(
                width: depthMipArrayInfo.Width,
                height: depthMipArrayInfo.Height,
                depth: depthMipArrayInfo.Depth,
                levels: depthMipArrayInfo.Levels,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: sizeof(float),
                format: Format.R32Float,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2DArray,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Red,
                swizzleB: SwizzleComponent.Red,
                swizzleA: SwizzleComponent.One
            );
            ITexture colorDepthMipArray = renderer.CreateTexture(
                colorDepthMipArrayInfo
            );
            colorDepthMipArray.SetData(
                MemoryOwner<byte>.RentCopy(depthMipArrayPattern)
            );
            colorDepthMipArray.CopyTo(
                depthMipArray,
                firstLayer: 0,
                firstLevel: 0
            );
            using (PinnedSpan<byte> convertedDepthReadback =
                depthMipArray.GetData())
            {
                if (!convertedDepthReadback.Get().SequenceEqual(
                        depthMipArrayPattern))
                {
                    throw new InvalidOperationException(
                        "SolMetal GAL all-mip R32Float-to-D32Float array copy changed a subresource."
                    );
                }
            }

            byte[] depthConversionSentinel = new byte[
                depthMipArrayPattern.Length
            ];
            MemoryMarshal.Cast<byte, float>(
                depthConversionSentinel.AsSpan()
            ).Fill(0.9375f);
            byte[] expectedSelectedDepthConversion =
                (byte[])depthConversionSentinel.Clone();
            Buffer.BlockCopy(
                depthMipArrayPattern,
                depthLevelOneOffset + depthLevelOneSliceBytes,
                expectedSelectedDepthConversion,
                depthLevelOneOffset,
                depthLevelOneSliceBytes
            );
            depthMipArray.SetData(
                MemoryOwner<byte>.RentCopy(depthConversionSentinel)
            );
            colorDepthMipArray.CopyTo(
                depthMipArray,
                srcLayer: 1,
                dstLayer: 0,
                srcLevel: 1,
                dstLevel: 1
            );
            using (PinnedSpan<byte> selectedConvertedDepthReadback =
                depthMipArray.GetData())
            {
                if (!selectedConvertedDepthReadback.Get().SequenceEqual(
                        expectedSelectedDepthConversion))
                {
                    throw new InvalidOperationException(
                        "SolMetal GAL selected R32Float-to-D32Float array mip copy touched the wrong subresource."
                    );
                }
            }
            colorDepthMipArray.Release();
            depthMipArray.Release();

            TextureCreateInfo d24s8Info = new(
                width: 7,
                height: 5,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: sizeof(uint),
                format: Format.D24UnormS8Uint,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2D,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Red,
                swizzleB: SwizzleComponent.Red,
                swizzleA: SwizzleComponent.One
            );
            byte[] d24s8Pattern = new byte[d24s8Info.GetMipSize(0)];
            Span<uint> d24s8Words = MemoryMarshal.Cast<byte, uint>(
                d24s8Pattern.AsSpan()
            );
            for (int index = 0; index < d24s8Words.Length; index++)
            {
                uint depth = (uint)((index * 0x31_337u) & 0x00ff_ffffu);
                uint stencil = (uint)((index * 29 + 7) & 0xff);
                d24s8Words[index] = (depth << 8) | stencil;
            }
            ITexture d24s8Texture = renderer.CreateTexture(d24s8Info);
            d24s8Texture.SetData(MemoryOwner<byte>.RentCopy(d24s8Pattern));
            using PinnedSpan<byte> d24s8Readback = d24s8Texture.GetData();
            ReadOnlySpan<uint> actualD24s8 = MemoryMarshal.Cast<byte, uint>(
                d24s8Readback.Get()
            );
            if (actualD24s8.Length != d24s8Words.Length)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL D24S8 readback returned the wrong byte count."
                );
            }
            for (int index = 0; index < actualD24s8.Length; index++)
            {
                uint expected = d24s8Words[index];
                uint actual = actualD24s8[index];
                int depthDelta = Math.Abs(
                    (int)(actual >> 8) - (int)(expected >> 8)
                );
                if (depthDelta > 1 ||
                    (actual & 0xffu) != (expected & 0xffu))
                {
                    throw new InvalidOperationException(
                        "SolMetal GAL D24S8 readback changed depth or stencil."
                    );
                }
            }
            d24s8Texture.Release();

            TextureCreateInfo d32s8Info = new(
                width: 7,
                height: 5,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: sizeof(ulong),
                format: Format.D32FloatS8Uint,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2D,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Red,
                swizzleB: SwizzleComponent.Red,
                swizzleA: SwizzleComponent.One
            );
            ITexture d32s8Texture = renderer.CreateTexture(d32s8Info);
            const float d32s8Depth = 0.625f;
            const int d32s8Stencil = 0x5c;
            SolMetalGalTexture d32s8Native =
                (SolMetalGalTexture)d32s8Texture;
            lock (renderer._gate)
            {
                renderer._session.ClearDepthStencilTexture(
                    d32s8Native.Native,
                    firstSlice: 0,
                    sliceCount: 1,
                    depthMask: true,
                    stencilMask: 0xff,
                    clearX: 0,
                    clearY: 0,
                    clearWidth: d32s8Info.Width,
                    clearHeight: d32s8Info.Height,
                    depth: d32s8Depth,
                    stencil: d32s8Stencil
                );
            }
            using PinnedSpan<byte> d32s8Readback = d32s8Texture.GetData();
            ReadOnlySpan<uint> d32s8Words = MemoryMarshal.Cast<byte, uint>(
                d32s8Readback.Get()
            );
            for (int index = 0; index < d32s8Words.Length; index += 2)
            {
                if (BitConverter.Int32BitsToSingle(
                        unchecked((int)d32s8Words[index])) != d32s8Depth ||
                    d32s8Words[index + 1] != d32s8Stencil)
                {
                    throw new InvalidOperationException(
                        "SolMetal GAL D32S8 readback changed depth or stencil."
                    );
                }
            }
            d32s8Texture.Release();

            const int textureBufferOffset = 13;
            const int textureBufferStride = textureWidth * 4 + 12;
            int textureBufferCopySize = checked(
                textureBufferStride * textureHeight
            );
            byte[] textureBufferSentinel = Enumerable.Repeat(
                (byte)0xcd,
                textureBufferOffset + textureBufferCopySize + 17
            ).ToArray();
            BufferHandle textureBuffer = renderer.CreateBuffer(
                textureBufferSentinel.Length,
                BufferAccess.DeviceMemory
            );
            renderer.SetBufferData(
                textureBuffer,
                0,
                textureBufferSentinel
            );
            copiedTexture.CopyTo(
                new BufferRange(
                    textureBuffer,
                    textureBufferOffset,
                    textureBufferCopySize,
                    write: true
                ),
                layer: 0,
                level: 0,
                stride: textureBufferStride
            );
            using PinnedSpan<byte> textureBufferReadback =
                renderer.GetBufferData(
                    textureBuffer,
                    0,
                    textureBufferSentinel.Length
                );
            ReadOnlySpan<byte> copiedBufferBytes = textureBufferReadback.Get();
            if (!copiedBufferBytes[..textureBufferOffset].SequenceEqual(
                    textureBufferSentinel.AsSpan(0, textureBufferOffset)) ||
                !copiedBufferBytes[(textureBufferOffset + textureBufferCopySize)..]
                    .SequenceEqual(textureBufferSentinel.AsSpan(
                        textureBufferOffset + textureBufferCopySize)))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL texture-to-buffer copy changed bytes outside the destination range."
                );
            }
            for (int row = 0; row < textureHeight; row++)
            {
                ReadOnlySpan<byte> expectedRow = texturePattern.AsSpan(
                    row * textureWidth * 4,
                    textureWidth * 4
                );
                ReadOnlySpan<byte> actualRow = copiedBufferBytes.Slice(
                    textureBufferOffset + row * textureBufferStride,
                    textureWidth * 4
                );
                ReadOnlySpan<byte> padding = copiedBufferBytes.Slice(
                    textureBufferOffset + row * textureBufferStride +
                        textureWidth * 4,
                    textureBufferStride - textureWidth * 4
                );
                if (!actualRow.SequenceEqual(expectedRow) ||
                    padding.IndexOfAnyExcept((byte)0xcd) >= 0)
                {
                    throw new InvalidOperationException(
                        $"SolMetal GAL texture-to-buffer copy diverged at row {row}."
                    );
                }
            }
            renderer.DeleteBuffer(textureBuffer);

            const int volumeWidth = 17;
            const int volumeHeight = 9;
            const int volumeDepth = 5;
            TextureCreateInfo volumeInfo = new(
                volumeWidth,
                volumeHeight,
                volumeDepth,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 8,
                Format.R16G16B16A16Float,
                DepthStencilMode.Depth,
                Target.Texture3D,
                SwizzleComponent.Red,
                SwizzleComponent.Green,
                SwizzleComponent.Blue,
                SwizzleComponent.Alpha
            );
            byte[] volumePattern = new byte[
                volumeInfo.GetMipSize(0)
            ];
            for (int index = 0; index < volumePattern.Length; index++)
            {
                volumePattern[index] = (byte)(
                    (index * 61 + (index >> 4) + 43) & 0xff
                );
            }
            ITexture volumeSource = renderer.CreateTexture(volumeInfo);
            ITexture volumeCopy = renderer.CreateTexture(volumeInfo);
            volumeSource.SetData(MemoryOwner<byte>.RentCopy(volumePattern));
            volumeSource.CopyTo(volumeCopy, firstLayer: 0, firstLevel: 0);
            using PinnedSpan<byte> volumeReadback = volumeCopy.GetData();
            if (!volumeReadback.Get().SequenceEqual(volumePattern))
            {
                throw new InvalidOperationException(
                    "SolMetal GAL 3D texture copy changed the validation volume."
                );
            }
            const int volumeBufferOffset = 7;
            const int volumeBufferStride = volumeWidth * 8 + 8;
            int volumeSliceBytes = checked(
                volumeBufferStride * volumeHeight
            );
            byte[] volumeBufferSentinel = Enumerable.Repeat(
                (byte)0x91,
                volumeBufferOffset + volumeSliceBytes + 11
            ).ToArray();
            BufferHandle volumeBuffer = renderer.CreateBuffer(
                volumeBufferSentinel.Length,
                BufferAccess.DeviceMemory
            );
            renderer.SetBufferData(volumeBuffer, 0, volumeBufferSentinel);
            const int copiedVolumeSlice = 3;
            volumeCopy.CopyTo(
                new BufferRange(
                    volumeBuffer,
                    volumeBufferOffset,
                    volumeSliceBytes,
                    write: true
                ),
                copiedVolumeSlice,
                level: 0,
                stride: volumeBufferStride
            );
            using PinnedSpan<byte> volumeBufferReadback =
                renderer.GetBufferData(
                    volumeBuffer,
                    0,
                    volumeBufferSentinel.Length
                );
            ReadOnlySpan<byte> volumeBufferBytes = volumeBufferReadback.Get();
            int volumeSourceSliceOffset = copiedVolumeSlice *
                volumeInfo.GetMipSize2D(0);
            for (int row = 0; row < volumeHeight; row++)
            {
                if (!volumeBufferBytes.Slice(
                        volumeBufferOffset + row * volumeBufferStride,
                        volumeWidth * 8
                    ).SequenceEqual(volumePattern.AsSpan(
                        volumeSourceSliceOffset + row * volumeWidth * 8,
                        volumeWidth * 8)))
                {
                    throw new InvalidOperationException(
                        $"SolMetal GAL 3D texture-to-buffer copy diverged at row {row}."
                    );
                }
            }
            renderer.DeleteBuffer(volumeBuffer);
            volumeCopy.Release();
            volumeSource.Release();
            using ISampler sampler = renderer.CreateSampler(
                SamplerCreateInfo.Create(MinFilter.Linear, MagFilter.Linear)
            );
            copiedTexture.Release();
            sourceTexture.Release();

            TextureCreateInfo drawInfo = new(
                width: 128,
                height: 128,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 4,
                format: Format.B8G8R8A8Unorm,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2D,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            ITexture drawTarget = renderer.CreateTexture(drawInfo);
            using IProgram program = renderer.CreateProgram(
                [
                    new ShaderSource(
                        Convert.FromBase64String(SmokeVertexSpirvBase64),
                        ShaderStage.Vertex,
                        TargetLanguage.Spirv
                    ),
                    new ShaderSource(
                        Convert.FromBase64String(SmokeFragmentSpirvBase64),
                        ShaderStage.Fragment,
                        TargetLanguage.Spirv
                    ),
                ],
                new ShaderInfo(0, default(ResourceLayout))
            );
            ITexture[] renderTargets = [drawTarget];
            renderer.Pipeline.SetRenderTargets(renderTargets, null!);
            renderer.Pipeline.SetPrimitiveTopology(PrimitiveTopology.Triangles);
            renderer.Pipeline.SetProgram(program);
            renderer.Pipeline.Draw(3, 1, 0, 0);
            long simpleBindingRebuilds =
                renderer._pipeline.StageBindingRebuildCount;
            long simpleAvoidedInvalidations =
                renderer._pipeline.AvoidedStageBindingInvalidationCount;
            long simpleColorBindingRebuilds =
                renderer._pipeline.ColorBindingRebuildCount;
            long simpleAvoidedColorBindingRebuilds =
                renderer._pipeline.AvoidedColorBindingRebuildCount;
            renderer.Pipeline.SetRenderTargets(renderTargets, null!);
            renderer.Pipeline.SetRenderTargetColorMasks([0xfu]);
            renderer.Pipeline.SetBlendState(
                0,
                new BlendDescriptor(
                    false,
                    new ColorF(0.25f, 0.5f, 0.75f, 1),
                    BlendOp.Add,
                    BlendFactor.One,
                    BlendFactor.Zero,
                    BlendOp.Add,
                    BlendFactor.One,
                    BlendFactor.Zero
                )
            );
            renderer.Pipeline.SetProgram(program);
            renderer.Pipeline.Draw(3, 1, 0, 0);
            if (renderer._pipeline.StageBindingRebuildCount !=
                    simpleBindingRebuilds ||
                renderer._pipeline.AvoidedStageBindingInvalidationCount !=
                    simpleAvoidedInvalidations + 1)
            {
                throw new InvalidOperationException(
                    "SolMetal rebuilt stage bindings after an identical program bind."
                );
            }
            if (renderer._pipeline.ColorBindingRebuildCount !=
                    simpleColorBindingRebuilds ||
                renderer._pipeline.AvoidedColorBindingRebuildCount !=
                    simpleAvoidedColorBindingRebuilds + 3)
            {
                throw new InvalidOperationException(
                    "SolMetal rebuilt color bindings after identical targets, masks, and blend state."
                );
            }
            renderer.Pipeline.SetRenderTargetColorMasks([0xfu, 0u]);
            ITexture[] aliasedRenderTargets = [drawTarget, drawTarget];
            renderer.Pipeline.SetRenderTargets(
                aliasedRenderTargets,
                null!
            );
            renderer.Pipeline.Draw(3, 1, 0, 0);
            renderer.Pipeline.SetRenderTargetColorMasks([0xfu]);
            renderer.Pipeline.SetRenderTargets(renderTargets, null!);
            using PinnedSpan<byte> drawReadback = drawTarget.GetData();
            ReadOnlySpan<byte> drawPixels = drawReadback.Get();
            int center = ((64 * 128) + 64) * 4;
            if (drawPixels[center] > 8 || drawPixels[center + 1] > 8 ||
                drawPixels[center + 2] < 240 || drawPixels[center + 3] < 240)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL translated draw did not shade the target center red."
                );
            }

            ITexture sparseUntouchedTarget = renderer.CreateTexture(drawInfo);
            ITexture sparseWrittenTarget = renderer.CreateTexture(drawInfo);
            using IProgram sparseProgram = renderer.CreateProgram(
                [
                    new ShaderSource(
                        Convert.FromBase64String(SmokeVertexSpirvBase64),
                        ShaderStage.Vertex,
                        TargetLanguage.Spirv
                    ),
                    new ShaderSource(
                        Convert.FromBase64String(
                            SparseSmokeFragmentSpirvBase64
                        ),
                        ShaderStage.Fragment,
                        TargetLanguage.Spirv
                    ),
                ],
                new ShaderInfo(0xf000, default(ResourceLayout))
            );
            ITexture[] sparseRenderTargets =
            [
                null!,
                sparseUntouchedTarget,
                null!,
                sparseWrittenTarget,
            ];
            renderer.Pipeline.SetRenderTargetColorMasks([
                0u,
                0xfu,
                0u,
                0xfu,
            ]);
            renderer.Pipeline.SetRenderTargets(sparseRenderTargets, null!);
            renderer.Pipeline.ClearRenderTargetColor(
                1,
                0,
                1,
                0xf,
                new ColorF(0, 1, 0, 1)
            );
            renderer.Pipeline.ClearRenderTargetColor(
                3,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.SetProgram(sparseProgram);
            renderer.Pipeline.Draw(3, 1, 0, 0);
            using PinnedSpan<byte> sparseUntouchedReadback =
                sparseUntouchedTarget.GetData();
            using PinnedSpan<byte> sparseWrittenReadback =
                sparseWrittenTarget.GetData();
            ReadOnlySpan<byte> sparseUntouchedPixels =
                sparseUntouchedReadback.Get();
            ReadOnlySpan<byte> sparseWrittenPixels = sparseWrittenReadback.Get();
            if (sparseUntouchedPixels[center] > 8 ||
                sparseUntouchedPixels[center + 1] < 240 ||
                sparseUntouchedPixels[center + 2] > 8 ||
                sparseUntouchedPixels[center + 3] < 240)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL sparse MRT draw modified unwritten attachment 1."
                );
            }
            if (sparseWrittenPixels[center] > 8 ||
                sparseWrittenPixels[center + 1] > 8 ||
                sparseWrittenPixels[center + 2] < 240 ||
                sparseWrittenPixels[center + 3] < 240)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL sparse MRT output did not reach attachment 3."
                );
            }
            sparseWrittenTarget.Release();
            sparseUntouchedTarget.Release();
            renderer.Pipeline.SetRenderTargetColorMasks([0xfu]);
            renderer.Pipeline.SetRenderTargets(renderTargets, null!);
            renderer.Pipeline.SetProgram(program);

            renderer.Pipeline.SetScissors([
                new Rectangle<int>(0, 0, 128, 128),
            ]);
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 1, 0, 1)
            );
            renderer.Pipeline.SetScissors([
                new Rectangle<int>(32, 24, 48, 40),
            ]);
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0x5,
                new ColorF(1, 0, 1, 0)
            );
            using PinnedSpan<byte> maskedClearReadback = drawTarget.GetData();
            ReadOnlySpan<byte> maskedClearPixels = maskedClearReadback.Get();
            int outsideClear = ((8 * 128) + 8) * 4;
            int insideClear = ((32 * 128) + 40) * 4;
            if (maskedClearPixels[outsideClear] > 8 ||
                maskedClearPixels[outsideClear + 1] < 240 ||
                maskedClearPixels[outsideClear + 2] > 8 ||
                maskedClearPixels[outsideClear + 3] < 240)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL scissored clear modified pixels outside its region."
                );
            }
            if (maskedClearPixels[insideClear] < 240 ||
                maskedClearPixels[insideClear + 1] < 240 ||
                maskedClearPixels[insideClear + 2] < 240 ||
                maskedClearPixels[insideClear + 3] < 240)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL masked clear did not preserve and update the requested channels."
                );
            }
            renderer.Pipeline.SetScissors([
                new Rectangle<int>(0, 0, 128, 128),
            ]);
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.SetViewports([
                new Viewport(
                    new Rectangle<float>(0, 128, 128, -128),
                    ViewportSwizzle.PositiveX,
                    ViewportSwizzle.PositiveY,
                    ViewportSwizzle.PositiveZ,
                    ViewportSwizzle.PositiveW,
                    0,
                    1
                ),
            ]);
            renderer.Pipeline.Draw(3, 1, 0, 0);
            using PinnedSpan<byte> negativeViewportReadback =
                drawTarget.GetData();
            ReadOnlySpan<byte> negativeViewportPixels =
                negativeViewportReadback.Get();
            if (negativeViewportPixels[center] > 8 ||
                negativeViewportPixels[center + 1] > 8 ||
                negativeViewportPixels[center + 2] < 240 ||
                negativeViewportPixels[center + 3] < 240)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL negative-height viewport did not shade the target center red."
                );
            }
            renderer.Pipeline.SetViewports([
                new Viewport(
                    new Rectangle<float>(0, 0, 128, 128),
                    ViewportSwizzle.PositiveX,
                    ViewportSwizzle.PositiveY,
                    ViewportSwizzle.PositiveZ,
                    ViewportSwizzle.PositiveW,
                    0,
                    1
                ),
            ]);

            TextureCreateInfo packedFloatInfo = new(
                width: 128,
                height: 128,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 4,
                format: Format.R11G11B10Float,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2D,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            ITexture packedFloatTarget = renderer.CreateTexture(
                packedFloatInfo
            );
            ITexture[] packedFloatTargets = [packedFloatTarget];
            renderer.Pipeline.SetRenderTargets(packedFloatTargets, null!);
            renderer.Pipeline.Draw(3, 1, 0, 0);
            using PinnedSpan<byte> packedFloatReadback =
                packedFloatTarget.GetData();
            if (BitConverter.ToUInt32(
                    packedFloatReadback.Get().Slice(center, 4)
                ) == 0)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL translated draw did not shade the packed-float target."
                );
            }
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.SetBlendState(
                0,
                new BlendDescriptor(
                    true,
                    new ColorF(0, 0, 0, 0),
                    BlendOp.Add,
                    BlendFactor.SrcAlpha,
                    BlendFactor.OneMinusSrcAlpha,
                    BlendOp.Add,
                    BlendFactor.One,
                    BlendFactor.Zero
                )
            );
            renderer.Pipeline.Draw(3, 1, 0, 0);
            using PinnedSpan<byte> packedFloatBlendReadback =
                packedFloatTarget.GetData();
            if (BitConverter.ToUInt32(
                    packedFloatBlendReadback.Get().Slice(center, 4)
                ) == 0)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL source-alpha blending did not shade the packed-float target."
                );
            }
            renderer.Pipeline.SetBlendState(
                0,
                new BlendDescriptor(
                    false,
                    new ColorF(0, 0, 0, 0),
                    BlendOp.Add,
                    BlendFactor.One,
                    BlendFactor.Zero,
                    BlendOp.Add,
                    BlendFactor.One,
                    BlendFactor.Zero
                )
            );
            packedFloatTarget.Release();
            renderer.Pipeline.SetRenderTargets(renderTargets, null!);

            float[] boundVertices =
            [
                -0.8f, -0.8f, 0f, 1f, 0f, 1f,
                 0.8f, -0.8f, 0f, 1f, 0f, 1f,
                 0.0f,  0.8f, 0f, 1f, 0f, 1f,
            ];
            float[] quadPositions =
            [
                2f, 2f,
                2f, 2f,
                2f, 2f,
                2f, 2f,
                -0.8f, -0.8f,
                 0.8f, -0.8f,
                 0.8f,  0.8f,
                -0.8f,  0.8f,
            ];
            float[] quadInstanceColors =
            [
                1f, 0f, 0f, 1f,
                1f, 0f, 0f, 1f,
                1f, 0f, 0f, 1f,
                1f, 0f, 0f, 1f,
                1f, 0f, 0f, 1f,
                0f, 1f, 0f, 1f,
            ];
            float[] transform = [0f, 0f, 0f, 0f];
            ushort[] indices = [0, 1, 2];
            byte[] byteIndices = [0, 1, 2];
            byte[] quadByteIndices = [0, 0, 1, 2, 3];
            ushort[] quadShortIndices = [0, 0, 1, 2, 3];
            uint[] quadIntIndices = [0, 0, 1, 2, 3];
            uint[] visibleQuadIndices = [4, 5, 6, 7];
            uint[] hiddenQuadIndices = [0, 1, 2, 3];
            byte[] vertexBytes = MemoryMarshal.AsBytes(
                boundVertices.AsSpan()
            ).ToArray();
            byte[] quadPositionBytes = MemoryMarshal.AsBytes(
                quadPositions.AsSpan()
            ).ToArray();
            byte[] quadInstanceColorBytes = MemoryMarshal.AsBytes(
                quadInstanceColors.AsSpan()
            ).ToArray();
            byte[] transformBytes = MemoryMarshal.AsBytes(
                transform.AsSpan()
            ).ToArray();
            byte[] indexBytes = MemoryMarshal.AsBytes(
                indices.AsSpan()
            ).ToArray();
            byte[] quadShortIndexBytes = MemoryMarshal.AsBytes(
                quadShortIndices.AsSpan()
            ).ToArray();
            byte[] quadIntIndexBytes = MemoryMarshal.AsBytes(
                quadIntIndices.AsSpan()
            ).ToArray();
            byte[] visibleQuadIndexBytes = MemoryMarshal.AsBytes(
                visibleQuadIndices.AsSpan()
            ).ToArray();
            byte[] hiddenQuadIndexBytes = MemoryMarshal.AsBytes(
                hiddenQuadIndices.AsSpan()
            ).ToArray();
            BufferHandle vertexBuffer = renderer.CreateBuffer(
                vertexBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle transformBuffer = renderer.CreateBuffer(
                transformBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle indexBuffer = renderer.CreateBuffer(
                indexBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle byteIndexBuffer = renderer.CreateBuffer(
                byteIndices.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle quadPositionBuffer = renderer.CreateBuffer(
                quadPositionBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle quadInstanceColorBuffer = renderer.CreateBuffer(
                quadInstanceColorBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle quadByteIndexBuffer = renderer.CreateBuffer(
                quadByteIndices.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle quadShortIndexBuffer = renderer.CreateBuffer(
                quadShortIndexBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle quadIntIndexBuffer = renderer.CreateBuffer(
                quadIntIndexBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle visibleQuadIndexBuffer = renderer.CreateBuffer(
                visibleQuadIndexBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle hiddenQuadIndexBuffer = renderer.CreateBuffer(
                hiddenQuadIndexBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle mutableQuadIndexBuffer = renderer.CreateBuffer(
                visibleQuadIndexBytes.Length,
                BufferAccess.DeviceMemory
            );
            renderer.SetBufferData(vertexBuffer, 0, vertexBytes);
            renderer.SetBufferData(transformBuffer, 0, transformBytes);
            renderer.SetBufferData(indexBuffer, 0, indexBytes);
            renderer.SetBufferData(byteIndexBuffer, 0, byteIndices);
            renderer.SetBufferData(
                quadPositionBuffer,
                0,
                quadPositionBytes
            );
            renderer.SetBufferData(
                quadInstanceColorBuffer,
                0,
                quadInstanceColorBytes
            );
            renderer.SetBufferData(
                quadByteIndexBuffer,
                0,
                quadByteIndices
            );
            renderer.SetBufferData(
                quadShortIndexBuffer,
                0,
                quadShortIndexBytes
            );
            renderer.SetBufferData(
                quadIntIndexBuffer,
                0,
                quadIntIndexBytes
            );
            renderer.SetBufferData(
                visibleQuadIndexBuffer,
                0,
                visibleQuadIndexBytes
            );
            renderer.SetBufferData(
                hiddenQuadIndexBuffer,
                0,
                hiddenQuadIndexBytes
            );

            TextureCreateInfo tintInfo = new(
                width: 1,
                height: 1,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 4,
                format: Format.R8G8B8A8Unorm,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2D,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            ITexture tintTexture = renderer.CreateTexture(tintInfo);
            tintTexture.SetData(MemoryOwner<byte>.RentCopy(
                new byte[] { 255, 255, 255, 255 }
            ));

            ResourceDescriptor[] boundDescriptors =
            [
                new ResourceDescriptor(
                    0,
                    1,
                    ResourceType.UniformBuffer,
                    ResourceStages.Vertex
                ),
                new ResourceDescriptor(
                    0,
                    1,
                    ResourceType.TextureAndSampler,
                    ResourceStages.Fragment
                ),
            ];
            ResourceUsage[] boundUsages =
            [
                new ResourceUsage(
                    0,
                    1,
                    ResourceType.UniformBuffer,
                    ResourceStages.Vertex,
                    write: false
                ),
                new ResourceUsage(
                    0,
                    1,
                    ResourceType.TextureAndSampler,
                    ResourceStages.Fragment,
                    write: false
                ),
            ];
            ResourceLayout boundLayout = new(
                Array.AsReadOnly(new[]
                {
                    new ResourceDescriptorCollection(
                        Array.AsReadOnly(boundDescriptors)
                    ),
                }),
                Array.AsReadOnly(new[]
                {
                    new ResourceUsageCollection(Array.AsReadOnly(boundUsages)),
                })
            );
            using IProgram boundProgram = renderer.CreateProgram(
                [
                    new ShaderSource(
                        Convert.FromBase64String(BoundSmokeVertexSpirvBase64),
                        ShaderStage.Vertex,
                        TargetLanguage.Spirv
                    ),
                    new ShaderSource(
                        Convert.FromBase64String(BoundSmokeFragmentSpirvBase64),
                        ShaderStage.Fragment,
                        TargetLanguage.Spirv
                    ),
                ],
                new ShaderInfo(0, boundLayout)
            );
            TextureCreateInfo depthInfo = new(
                width: 128,
                height: 128,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: 4,
                format: Format.D32Float,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2D,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            ITexture depthTarget = renderer.CreateTexture(depthInfo);
            renderer.Pipeline.SetRenderTargets(renderTargets, depthTarget);
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.ClearRenderTargetDepthStencil(
                0,
                1,
                1,
                true,
                0,
                0
            );
            renderer.Pipeline.SetDepthTest(
                new DepthTestDescriptor(true, true, CompareOp.Less)
            );
            renderer.Pipeline.SetBlendState(
                0,
                new BlendDescriptor(
                    true,
                    new ColorF(0, 0, 0, 0),
                    BlendOp.Add,
                    BlendFactor.One,
                    BlendFactor.Zero,
                    BlendOp.Add,
                    BlendFactor.One,
                    BlendFactor.Zero
                )
            );
            // SolMetal flips vertex Y while translating SPIR-V to MSL. The
            // GAL winding therefore maps to the opposite Metal winding, just
            // like Ryubing's Vulkan backend maps it to the opposite Vulkan
            // winding for the host-origin difference.
            renderer.Pipeline.SetFrontFace(FrontFace.CounterClockwise);
            renderer.Pipeline.SetFaceCulling(true, Face.Back);
            renderer.Pipeline.SetPolygonMode(PolygonMode.Fill, PolygonMode.Fill);
            renderer.Pipeline.SetDepthClamp(false);
            renderer.Pipeline.SetVertexBuffers(
                [
                    new VertexBufferDescriptor(
                        new BufferRange(vertexBuffer, 0, vertexBytes.Length),
                        stride: 6 * sizeof(float),
                        divisor: 0
                    ),
                ]
            );
            renderer.Pipeline.SetVertexAttribs(
                [
                    new VertexAttribDescriptor(
                        0,
                        0,
                        false,
                        Format.R32G32Float
                    ),
                    new VertexAttribDescriptor(
                        0,
                        2 * sizeof(float),
                        false,
                        Format.R32G32B32A32Float
                    ),
                ]
            );
            renderer.Pipeline.SetUniformBuffers(
                [
                    new BufferAssignment(
                        0,
                        new BufferRange(
                            transformBuffer,
                            0,
                            transformBytes.Length
                        )
                    ),
                ]
            );
            renderer.Pipeline.SetTextureAndSampler(
                ShaderStage.Fragment,
                0,
                tintTexture,
                sampler
            );
            renderer.Pipeline.SetIndexBuffer(
                new BufferRange(indexBuffer, 0, indexBytes.Length),
                IndexType.UShort
            );
            renderer.Pipeline.SetProgram(boundProgram);
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);
            long boundBindingRebuilds =
                renderer._pipeline.StageBindingRebuildCount;
            long boundAvoidedInvalidations =
                renderer._pipeline.AvoidedStageBindingInvalidationCount;
            renderer.Pipeline.SetProgram(boundProgram);
            renderer.Pipeline.SetUniformBuffers(
                [
                    new BufferAssignment(
                        0,
                        new BufferRange(
                            transformBuffer,
                            0,
                            transformBytes.Length
                        )
                    ),
                ]
            );
            renderer.Pipeline.SetTextureAndSampler(
                ShaderStage.Fragment,
                0,
                tintTexture,
                sampler
            );
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);
            if (renderer._pipeline.StageBindingRebuildCount !=
                    boundBindingRebuilds ||
                renderer._pipeline.AvoidedStageBindingInvalidationCount !=
                    boundAvoidedInvalidations + 3)
            {
                throw new InvalidOperationException(
                    "SolMetal rebuilt stage bindings after identical program and resource binds."
                );
            }
            uint[] directIndirectArguments = [0, 3, 1, 0, 0];
            uint[] indexedIndirectArguments = [0, 3, 1, 0, 0, 0];
            byte[] directIndirectBytes = MemoryMarshal.AsBytes(
                directIndirectArguments.AsSpan()
            ).ToArray();
            byte[] indexedIndirectBytes = MemoryMarshal.AsBytes(
                indexedIndirectArguments.AsSpan()
            ).ToArray();
            BufferHandle directIndirectBuffer = renderer.CreateBuffer(
                directIndirectBytes.Length,
                BufferAccess.DeviceMemory
            );
            BufferHandle indexedIndirectBuffer = renderer.CreateBuffer(
                indexedIndirectBytes.Length,
                BufferAccess.DeviceMemory
            );
            uint[] indirectCountArguments = [1];
            byte[] indirectCountBytes = MemoryMarshal.AsBytes(
                indirectCountArguments.AsSpan()
            ).ToArray();
            BufferHandle indirectCountBuffer = renderer.CreateBuffer(
                indirectCountBytes.Length,
                BufferAccess.DeviceMemory
            );
            renderer.SetBufferData(
                directIndirectBuffer,
                0,
                directIndirectBytes
            );
            renderer.SetBufferData(
                indexedIndirectBuffer,
                0,
                indexedIndirectBytes
            );
            renderer.SetBufferData(
                indirectCountBuffer,
                0,
                indirectCountBytes
            );
            renderer.Pipeline.DrawIndirect(
                new BufferRange(
                    directIndirectBuffer,
                    sizeof(uint),
                    directIndirectBytes.Length - sizeof(uint)
                )
            );
            renderer.Pipeline.DrawIndexedIndirect(
                new BufferRange(
                    indexedIndirectBuffer,
                    sizeof(uint),
                    indexedIndirectBytes.Length - sizeof(uint)
                )
            );
            renderer.Pipeline.SetIndexBuffer(
                new BufferRange(
                    byteIndexBuffer,
                    0,
                    byteIndices.Length
                ),
                IndexType.UByte
            );
            renderer.Pipeline.DrawIndexedIndirect(
                new BufferRange(
                    indexedIndirectBuffer,
                    sizeof(uint),
                    indexedIndirectBytes.Length - sizeof(uint)
                )
            );
            renderer.Pipeline.DrawIndirectCount(
                new BufferRange(
                    directIndirectBuffer,
                    sizeof(uint),
                    directIndirectBytes.Length - sizeof(uint)
                ),
                new BufferRange(
                    indirectCountBuffer,
                    0,
                    indirectCountBytes.Length
                ),
                maxDrawCount: 1,
                stride: 4 * sizeof(uint)
            );
            renderer.Pipeline.DrawIndexedIndirectCount(
                new BufferRange(
                    indexedIndirectBuffer,
                    sizeof(uint),
                    indexedIndirectBytes.Length - sizeof(uint)
                ),
                new BufferRange(
                    indirectCountBuffer,
                    0,
                    indirectCountBytes.Length
                ),
                maxDrawCount: 1,
                stride: 5 * sizeof(uint)
            );
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);
            using PinnedSpan<byte> boundReadback = drawTarget.GetData();
            ReadOnlySpan<byte> boundPixels = boundReadback.Get();
            if (boundPixels[center] > 8 || boundPixels[center + 1] < 240 ||
                boundPixels[center + 2] > 8 || boundPixels[center + 3] < 240)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL bound indexed draw did not shade the target center green."
                );
            }

            renderer.Pipeline.SetDepthTest(
                new DepthTestDescriptor(false, false, CompareOp.Always)
            );
            renderer.Pipeline.SetFaceCulling(false, Face.Back);
            renderer.Pipeline.SetVertexBuffers(
                [
                    new VertexBufferDescriptor(
                        new BufferRange(
                            quadPositionBuffer,
                            0,
                            quadPositionBytes.Length
                        ),
                        stride: 2 * sizeof(float),
                        divisor: 0
                    ),
                    new VertexBufferDescriptor(
                        new BufferRange(
                            quadInstanceColorBuffer,
                            0,
                            quadInstanceColorBytes.Length
                        ),
                        stride: 4 * sizeof(float),
                        divisor: 1
                    ),
                ]
            );
            renderer.Pipeline.SetVertexAttribs(
                [
                    new VertexAttribDescriptor(
                        0,
                        0,
                        false,
                        Format.R32G32Float
                    ),
                    new VertexAttribDescriptor(
                        1,
                        0,
                        false,
                        Format.R32G32B32A32Float
                    ),
                ]
            );
            renderer.Pipeline.SetPrimitiveTopology(PrimitiveTopology.Quads);
            renderer.Pipeline.SetIndexBuffer(BufferRange.Empty, IndexType.UInt);
            renderer.Pipeline.Draw(0, 1, 0, 0);
            renderer.Pipeline.Draw(4, 0, 0, 0);
            renderer.Pipeline.DrawIndexed(0, 1, 0, 0, 0);
            renderer.Pipeline.DrawIndexed(4, 0, 0, 0, 0);
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.Draw(
                vertexCount: 4,
                instanceCount: 1,
                firstVertex: 4,
                firstInstance: 5
            );
            int quadBytesVerified = ValidateGreenQuadReadback(
                drawTarget,
                "non-indexed quad conversion"
            );
            BufferHandle sequentialQuadCache =
                renderer._pipeline.SequentialQuadIndexBuffer;
            renderer.Pipeline.Draw(4, 1, 4, 5);
            if (sequentialQuadCache == BufferHandle.Null ||
                !sequentialQuadCache.Equals(
                    renderer._pipeline.SequentialQuadIndexBuffer
                ))
            {
                throw new InvalidOperationException(
                    "SolMetal did not reuse its sequential quad index buffer."
                );
            }

            renderer.Pipeline.SetPrimitiveTopology(PrimitiveTopology.QuadStrip);
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.Draw(3, 1, 4, 5);
            using (PinnedSpan<byte> incompleteQuadStripReadback =
                   drawTarget.GetData())
            {
                ReadOnlySpan<byte> pixels = incompleteQuadStripReadback.Get();
                if (pixels[center] > 8 || pixels[center + 1] > 8 ||
                    pixels[center + 2] > 8 || pixels[center + 3] < 240)
                {
                    throw new InvalidOperationException(
                        "SolMetal emitted a primitive for an incomplete quad strip."
                    );
                }
            }
            renderer.Pipeline.Draw(5, 1, 4, 5);
            quadBytesVerified += ValidateGreenQuadReadback(
                drawTarget,
                "odd-tail quad-strip remap"
            );
            renderer.Pipeline.SetPrimitiveTopology(PrimitiveTopology.Quads);

            long bufferReadbacksBeforeIndexedQuads =
                renderer.BufferReadbackCallCount;
            long bufferUploadsBeforeIndexedQuads =
                renderer.BufferUploadCallCount;
            BufferHandle expandedQuadCache = BufferHandle.Null;
            foreach ((BufferHandle Buffer, int Size, IndexType Type, string Name)
                     fixture in new[]
                {
                    (
                        quadByteIndexBuffer,
                        quadByteIndices.Length,
                        IndexType.UByte,
                        "U8"
                    ),
                    (
                        quadShortIndexBuffer,
                        quadShortIndexBytes.Length,
                        IndexType.UShort,
                        "U16"
                    ),
                    (
                        quadIntIndexBuffer,
                        quadIntIndexBytes.Length,
                        IndexType.UInt,
                        "U32"
                    ),
                })
            {
                renderer.Pipeline.SetIndexBuffer(
                    new BufferRange(fixture.Buffer, 0, fixture.Size),
                    fixture.Type
                );
                renderer.Pipeline.ClearRenderTargetColor(
                    0,
                    0,
                    1,
                    0xf,
                    new ColorF(0, 0, 0, 1)
                );
                renderer.Pipeline.DrawIndexed(
                    indexCount: 4,
                    instanceCount: 1,
                    firstIndex: 1,
                    firstVertex: 4,
                    firstInstance: 5
                );
                quadBytesVerified += ValidateGreenQuadReadback(
                    drawTarget,
                    $"{fixture.Name} indexed quad conversion"
                );
                if (expandedQuadCache == BufferHandle.Null)
                {
                    expandedQuadCache =
                        renderer._pipeline.ExpandedQuadIndexBuffer;
                }
                else if (!expandedQuadCache.Equals(
                             renderer._pipeline.ExpandedQuadIndexBuffer
                         ))
                {
                    throw new InvalidOperationException(
                        "SolMetal did not reuse its expanded quad index buffer."
                    );
                }
            }
            if (expandedQuadCache == BufferHandle.Null)
            {
                throw new InvalidOperationException(
                    "SolMetal did not create its expanded quad index buffer."
                );
            }
            if (renderer._pipeline.IndexedQuadConversionCount != 3 ||
                renderer._pipeline.IndexedQuadPrimitiveCount != 3 ||
                renderer._pipeline.IndexedQuadConversionBytes !=
                    3 * 6 * sizeof(uint) ||
                renderer._pipeline.ExpandedQuadScratchGrowthCount != 1 ||
                renderer._pipeline.IndexedQuadCpuReadbackCount != 0 ||
                renderer._pipeline.IndexedQuadCpuUploadCount != 0 ||
                renderer.BufferReadbackCallCount !=
                    bufferReadbacksBeforeIndexedQuads ||
                renderer.BufferUploadCallCount !=
                    bufferUploadsBeforeIndexedQuads)
            {
                throw new InvalidOperationException(
                    "SolMetal returned inconsistent indexed-quad telemetry."
                );
            }

            const int orderedQuadDrawCount = 72;
            const int orderedQuadColumns = 9;
            const int orderedQuadOriginX = 18;
            const int orderedQuadOriginY = 16;
            const int orderedQuadTileWidth = 10;
            const int orderedQuadTileHeight = 12;
            long indexedQuadConversionsBeforeOrdering =
                renderer._pipeline.IndexedQuadConversionCount;
            long indexedQuadPrimitivesBeforeOrdering =
                renderer._pipeline.IndexedQuadPrimitiveCount;
            long indexedQuadBytesBeforeOrdering =
                renderer._pipeline.IndexedQuadConversionBytes;
            SolMetalNativeBridge.RuntimeBatchSnapshot? batchBeforeQuadOrdering =
                renderer._session.QueryRuntimeBatch();
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.SetViewports([
                new Viewport(
                    new Rectangle<float>(0, 0, 128, 128),
                    ViewportSwizzle.PositiveX,
                    ViewportSwizzle.PositiveY,
                    ViewportSwizzle.PositiveZ,
                    ViewportSwizzle.PositiveW,
                    0,
                    1
                ),
            ]);
            renderer.Pipeline.SetIndexBuffer(
                new BufferRange(
                    mutableQuadIndexBuffer,
                    0,
                    visibleQuadIndexBytes.Length
                ),
                IndexType.UInt
            );
            for (int draw = 0; draw < orderedQuadDrawCount; draw++)
            {
                bool visible = (draw & 1) == 0;
                renderer.Pipeline.CopyBuffer(
                    visible
                        ? visibleQuadIndexBuffer
                        : hiddenQuadIndexBuffer,
                    mutableQuadIndexBuffer,
                    0,
                    0,
                    visibleQuadIndexBytes.Length
                );
                int column = draw % orderedQuadColumns;
                int row = draw / orderedQuadColumns;
                renderer.Pipeline.SetScissors([
                    new Rectangle<int>(
                        orderedQuadOriginX + column * orderedQuadTileWidth,
                        orderedQuadOriginY + row * orderedQuadTileHeight,
                        orderedQuadTileWidth,
                        orderedQuadTileHeight
                    ),
                ]);
                renderer.Pipeline.DrawIndexed(
                    indexCount: 4,
                    instanceCount: 1,
                    firstIndex: 0,
                    firstVertex: 0,
                    firstInstance: 5
                );
            }
            using (PinnedSpan<byte> orderedQuadReadback = drawTarget.GetData())
            {
                ReadOnlySpan<byte> orderedPixels = orderedQuadReadback.Get();
                for (int draw = 0; draw < orderedQuadDrawCount; draw++)
                {
                    int column = draw % orderedQuadColumns;
                    int row = draw / orderedQuadColumns;
                    int sampleX = orderedQuadOriginX +
                        column * orderedQuadTileWidth +
                        orderedQuadTileWidth / 2;
                    int sampleY = orderedQuadOriginY +
                        row * orderedQuadTileHeight +
                        orderedQuadTileHeight / 2;
                    int sampleOffset = ((sampleY * 128) + sampleX) * 4;
                    bool expectedGreen = (draw & 1) == 0;
                    bool isGreen = orderedPixels[sampleOffset] <= 8 &&
                        orderedPixels[sampleOffset + 1] >= 240 &&
                        orderedPixels[sampleOffset + 2] <= 8 &&
                        orderedPixels[sampleOffset + 3] >= 240;
                    bool isBlack = orderedPixels[sampleOffset] <= 8 &&
                        orderedPixels[sampleOffset + 1] <= 8 &&
                        orderedPixels[sampleOffset + 2] <= 8 &&
                        orderedPixels[sampleOffset + 3] >= 240;
                    if ((expectedGreen && !isGreen) ||
                        (!expectedGreen && !isBlack))
                    {
                        throw new InvalidOperationException(
                            $"SolMetal lost quad source-mutation ordering at " +
                            $"draw {draw} ({sampleX},{sampleY})."
                        );
                    }
                }
                quadBytesVerified += orderedPixels.Length;
            }
            renderer.Pipeline.SetScissors([
                new Rectangle<int>(0, 0, 128, 128),
            ]);
            if (renderer._pipeline.IndexedQuadConversionCount -
                    indexedQuadConversionsBeforeOrdering != orderedQuadDrawCount ||
                renderer._pipeline.IndexedQuadPrimitiveCount -
                    indexedQuadPrimitivesBeforeOrdering != orderedQuadDrawCount ||
                renderer._pipeline.IndexedQuadConversionBytes -
                    indexedQuadBytesBeforeOrdering !=
                        orderedQuadDrawCount * 6 * sizeof(uint) ||
                renderer._pipeline.ExpandedQuadScratchGrowthCount != 1 ||
                renderer._pipeline.IndexedQuadCpuReadbackCount != 0 ||
                renderer._pipeline.IndexedQuadCpuUploadCount != 0 ||
                renderer.BufferReadbackCallCount !=
                    bufferReadbacksBeforeIndexedQuads ||
                renderer.BufferUploadCallCount !=
                    bufferUploadsBeforeIndexedQuads)
            {
                throw new InvalidOperationException(
                    "SolMetal quad source-ordering telemetry diverged."
                );
            }
            SolMetalNativeBridge.RuntimeBatchSnapshot? batchAfterQuadOrdering =
                renderer._session.QueryRuntimeBatch();
            if (batchBeforeQuadOrdering is { } beforeQuadBatch &&
                batchAfterQuadOrdering is { } afterQuadBatch &&
                afterQuadBatch.DirectMutationBatchingEnabled &&
                (afterQuadBatch.BatchedDrawCount -
                        beforeQuadBatch.BatchedDrawCount < orderedQuadDrawCount ||
                 afterQuadBatch.BorrowedMutationCount -
                        beforeQuadBatch.BorrowedMutationCount <
                            orderedQuadDrawCount ||
                 afterQuadBatch.PendingMutationCount != 0 ||
                 afterQuadBatch.PendingDrawCount != 0))
            {
                throw new InvalidOperationException(
                    "SolMetal did not retain GPU quad expansion in the " +
                    "ordered draw batch."
                );
            }

            renderer.Pipeline.SetIndexBuffer(
                new BufferRange(
                    quadShortIndexBuffer,
                    0,
                    quadShortIndexBytes.Length
                ),
                IndexType.UShort
            );
            RequireUnsupported(
                () => renderer.Pipeline.DrawIndexed(4, 1, 2, 4, 5),
                "quad conversion outside the bound index-buffer range"
            );
            RequireUnsupported(
                () => renderer.Pipeline.DrawIndirect(
                    new BufferRange(
                        directIndirectBuffer,
                        sizeof(uint),
                        directIndirectBytes.Length - sizeof(uint)
                    )
                ),
                "indirect quad topology conversion"
            );
            RequireUnsupported(
                () => renderer.Pipeline.DrawIndirectCount(
                    new BufferRange(
                        directIndirectBuffer,
                        sizeof(uint),
                        directIndirectBytes.Length - sizeof(uint)
                    ),
                    new BufferRange(
                        indirectCountBuffer,
                        0,
                        indirectCountBytes.Length
                    ),
                    maxDrawCount: 1,
                    stride: 4 * sizeof(uint)
                ),
                "counted indirect quad topology conversion"
            );
            RequireUnsupported(
                () => renderer.Pipeline.DrawIndexedIndirect(
                    new BufferRange(
                        indexedIndirectBuffer,
                        sizeof(uint),
                        indexedIndirectBytes.Length - sizeof(uint)
                    )
                ),
                "indirect quad topology conversion"
            );
            RequireUnsupported(
                () => renderer.Pipeline.DrawIndexedIndirectCount(
                    new BufferRange(
                        indexedIndirectBuffer,
                        sizeof(uint),
                        indexedIndirectBytes.Length - sizeof(uint)
                    ),
                    new BufferRange(
                        indirectCountBuffer,
                        0,
                        indirectCountBytes.Length
                    ),
                    maxDrawCount: 1,
                    stride: 5 * sizeof(uint)
                ),
                "counted indirect quad topology conversion"
            );
            if (renderer._pipeline.IndirectQuadRejectionCount != 4)
            {
                throw new InvalidOperationException(
                    "SolMetal did not account for every indirect-quad gate."
                );
            }

            renderer.Pipeline.SetPrimitiveTopology(
                PrimitiveTopology.Triangles
            );
            renderer.Pipeline.SetFaceCulling(true, Face.Back);
            renderer.Pipeline.SetVertexBuffers(
                [
                    new VertexBufferDescriptor(
                        new BufferRange(vertexBuffer, 0, vertexBytes.Length),
                        stride: 6 * sizeof(float),
                        divisor: 0
                    ),
                ]
            );
            renderer.Pipeline.SetVertexAttribs(
                [
                    new VertexAttribDescriptor(
                        0,
                        0,
                        false,
                        Format.R32G32Float
                    ),
                    new VertexAttribDescriptor(
                        0,
                        2 * sizeof(float),
                        false,
                        Format.R32G32B32A32Float
                    ),
                ]
            );
            renderer.Pipeline.SetIndexBuffer(
                new BufferRange(indexBuffer, 0, indexBytes.Length),
                IndexType.UShort
            );

            renderer.Pipeline.SetDepthTest(
                new DepthTestDescriptor(false, false, CompareOp.Always)
            );
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.SetViewports([
                new Viewport(
                    new Rectangle<float>(0, 128, 128, -128),
                    ViewportSwizzle.PositiveX,
                    ViewportSwizzle.PositiveY,
                    ViewportSwizzle.PositiveZ,
                    ViewportSwizzle.PositiveW,
                    0,
                    1
                ),
            ]);
            renderer.Pipeline.SetFrontFace(FrontFace.Clockwise);
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);
            bool negativeClockwiseVisible;
            using (PinnedSpan<byte> negativeClockwiseReadback =
                   drawTarget.GetData())
            {
                ReadOnlySpan<byte> pixels = negativeClockwiseReadback.Get();
                negativeClockwiseVisible =
                    pixels[center] <= 8 && pixels[center + 1] >= 240 &&
                    pixels[center + 2] <= 8 && pixels[center + 3] >= 240;
            }
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.SetFrontFace(FrontFace.CounterClockwise);
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);
            bool negativeCounterClockwiseVisible;
            using (PinnedSpan<byte> negativeCounterClockwiseReadback =
                   drawTarget.GetData())
            {
                ReadOnlySpan<byte> pixels =
                    negativeCounterClockwiseReadback.Get();
                negativeCounterClockwiseVisible =
                    pixels[center] <= 8 && pixels[center + 1] >= 240 &&
                    pixels[center + 2] <= 8 && pixels[center + 3] >= 240;
            }
            bool negativeWindingMatches =
                renderer._debugInvertNegativeViewportFrontFace
                    ? !negativeClockwiseVisible &&
                        negativeCounterClockwiseVisible
                    : negativeClockwiseVisible &&
                        !negativeCounterClockwiseVisible;
            if (!negativeWindingMatches)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL negative-height viewport produced an " +
                    "unexpected front-face winding under back-face culling " +
                    $"(clockwise={negativeClockwiseVisible}, " +
                    $"counter-clockwise={negativeCounterClockwiseVisible})."
                );
            }
            renderer.Pipeline.SetViewports([
                new Viewport(
                    new Rectangle<float>(0, 0, 128, 128),
                    ViewportSwizzle.PositiveX,
                    ViewportSwizzle.PositiveY,
                    ViewportSwizzle.PositiveZ,
                    ViewportSwizzle.PositiveW,
                    0,
                    1
                ),
            ]);
            renderer.Pipeline.SetFrontFace(FrontFace.CounterClockwise);

            ulong samplesPassed = 0;
            renderer.ResetCounter(CounterType.SamplesPassed);
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);
            using (ICounterEvent sampleCounter = renderer.ReportCounter(
                CounterType.SamplesPassed,
                (_, result) => samplesPassed = result,
                divisor: 1,
                hostReserved: false
            ))
            {
                sampleCounter.Flush();
            }
            if (samplesPassed == 0)
            {
                throw new InvalidOperationException(
                    "SolMetal GAL asynchronous sample counter returned zero " +
                    "for a visible indexed triangle."
                );
            }

            renderer.ResetCounter(CounterType.SamplesPassed);
            renderer.Pipeline.SetFrontFace(FrontFace.Clockwise);
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);
            using (ICounterEvent culledSampleCounter = renderer.ReportCounter(
                CounterType.SamplesPassed,
                (_, result) => samplesPassed = result,
                divisor: 1,
                hostReserved: false
            ))
            {
                culledSampleCounter.Flush();
            }
            if (samplesPassed != 0)
            {
                throw new InvalidOperationException(
                    $"SolMetal GAL asynchronous sample counter reported " +
                    $"{samplesPassed} samples for a fully culled triangle."
                );
            }
            renderer.Pipeline.SetFrontFace(FrontFace.CounterClockwise);

            TextureCreateInfo bc4Info = new(
                width: 4,
                height: 4,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 4,
                blockHeight: 4,
                bytesPerPixel: 8,
                format: Format.Bc4Unorm,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2D,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            ITexture bc4Texture = renderer.CreateTexture(bc4Info);
            bc4Texture.SetData(MemoryOwner<byte>.RentCopy(
                new byte[] { 255, 0, 0, 0, 0, 0, 0, 0 }
            ));
            float[] redVertices = (float[])boundVertices.Clone();
            for (int vertex = 0; vertex < 3; vertex++)
            {
                int color = vertex * 6 + 2;
                redVertices[color] = 1;
                redVertices[color + 1] = 0;
                redVertices[color + 2] = 0;
                redVertices[color + 3] = 1;
            }
            renderer.SetBufferData(
                vertexBuffer,
                0,
                MemoryMarshal.AsBytes(redVertices.AsSpan())
            );
            renderer.Pipeline.SetTextureAndSampler(
                ShaderStage.Fragment,
                0,
                bc4Texture,
                sampler
            );
            renderer.Pipeline.ClearRenderTargetColor(
                0,
                0,
                1,
                0xf,
                new ColorF(0, 0, 0, 1)
            );
            renderer.Pipeline.SetDepthTest(
                new DepthTestDescriptor(false, false, CompareOp.Always)
            );
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);
            renderer.CreateSync(0x42433453, strict: true);
            renderer.WaitSync(0x42433453);
            using (PinnedSpan<byte> bc4Readback = drawTarget.GetData())
            {
                ReadOnlySpan<byte> bc4Pixels = bc4Readback.Get();
                if (bc4Pixels[center] > 8 ||
                    bc4Pixels[center + 1] > 8 ||
                    bc4Pixels[center + 2] < 240 ||
                    bc4Pixels[center + 3] < 240)
                {
                    throw new InvalidOperationException(
                        $"SolMetal GAL BC4 upload and sampling did not shade " +
                        $"the target center red (BGRA=" +
                        $"{bc4Pixels[center]},{bc4Pixels[center + 1]}," +
                        $"{bc4Pixels[center + 2]},{bc4Pixels[center + 3]})."
                    );
                }
            }
            renderer.Pipeline.SetTextureAndSampler(
                ShaderStage.Fragment,
                0,
                tintTexture,
                sampler
            );
            bc4Texture.Release();
            renderer.Pipeline.SetUniformBuffers(
                [new BufferAssignment(0, BufferRange.Empty)]
            );
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);
            renderer.Pipeline.SetTextureAndSampler(
                ShaderStage.Fragment,
                0,
                null!,
                null!
            );
            renderer.Pipeline.DrawIndexed(3, 1, 0, 0, 0);

            const float copiedDepthValue = 0.375f;
            const int depthCopyByteCount = 128 * 128 * sizeof(float);
            renderer.Pipeline.SetScissors([
                new Rectangle<int>(0, 0, 128, 128),
            ]);
            renderer.Pipeline.ClearRenderTargetDepthStencil(
                0,
                1,
                copiedDepthValue,
                true,
                0,
                0
            );
            TextureCreateInfo depthAsColorInfo = new(
                width: 128,
                height: 128,
                depth: 1,
                levels: 1,
                samples: 1,
                blockWidth: 1,
                blockHeight: 1,
                bytesPerPixel: sizeof(float),
                format: Format.R32Float,
                depthStencilMode: DepthStencilMode.Depth,
                target: Target.Texture2D,
                swizzleR: SwizzleComponent.Red,
                swizzleG: SwizzleComponent.Green,
                swizzleB: SwizzleComponent.Blue,
                swizzleA: SwizzleComponent.Alpha
            );
            ITexture depthAsColor = renderer.CreateTexture(depthAsColorInfo);
            depthTarget.CopyTo(
                depthAsColor,
                srcLayer: 0,
                dstLayer: 0,
                srcLevel: 0,
                dstLevel: 0
            );
            using (PinnedSpan<byte> depthAsColorReadback =
                depthAsColor.GetData())
            {
                ReadOnlySpan<float> copiedDepth =
                    MemoryMarshal.Cast<byte, float>(
                        depthAsColorReadback.Get()
                    );
                for (int index = 0; index < copiedDepth.Length; index++)
                {
                    if (copiedDepth[index] != copiedDepthValue)
                    {
                        throw new InvalidOperationException(
                            $"SolMetal GAL D32Float-to-R32Float copy " +
                            $"diverged at pixel {index}: " +
                            $"{copiedDepth[index]:R}."
                        );
                    }
                }
            }
            depthAsColor.CopyTo(
                depthTarget,
                srcLayer: 0,
                dstLayer: 0,
                srcLevel: 0,
                dstLevel: 0
            );
            using (PinnedSpan<byte> colorAsDepthReadback =
                depthTarget.GetData())
            {
                ReadOnlySpan<float> copiedBackDepth =
                    MemoryMarshal.Cast<byte, float>(
                        colorAsDepthReadback.Get()
                    );
                for (int index = 0; index < copiedBackDepth.Length; index++)
                {
                    if (copiedBackDepth[index] != copiedDepthValue)
                    {
                        throw new InvalidOperationException(
                            $"SolMetal GAL R32Float-to-D32Float copy " +
                            $"diverged at pixel {index}: " +
                            $"{copiedBackDepth[index]:R}."
                        );
                    }
                }
            }
            depthAsColor.Release();

            depthTarget.Release();
            tintTexture.Release();
            renderer.DeleteBuffer(mutableQuadIndexBuffer);
            renderer.DeleteBuffer(hiddenQuadIndexBuffer);
            renderer.DeleteBuffer(visibleQuadIndexBuffer);
            renderer.DeleteBuffer(quadIntIndexBuffer);
            renderer.DeleteBuffer(quadShortIndexBuffer);
            renderer.DeleteBuffer(quadByteIndexBuffer);
            renderer.DeleteBuffer(quadInstanceColorBuffer);
            renderer.DeleteBuffer(quadPositionBuffer);
            renderer.DeleteBuffer(byteIndexBuffer);
            renderer.DeleteBuffer(indirectCountBuffer);
            renderer.DeleteBuffer(indexedIndirectBuffer);
            renderer.DeleteBuffer(directIndirectBuffer);
            renderer.DeleteBuffer(indexBuffer);
            renderer.DeleteBuffer(transformBuffer);
            renderer.DeleteBuffer(vertexBuffer);

            uint[] computeValues = new uint[64];
            for (int index = 0; index < computeValues.Length; index++)
            {
                computeValues[index] = checked((uint)(index * 3 + 1));
            }
            byte[] computeBytes = MemoryMarshal.AsBytes(
                computeValues.AsSpan()
            ).ToArray();
            BufferHandle computeBuffer = renderer.CreateBuffer(
                computeBytes.Length,
                BufferAccess.DeviceMemory
            );
            renderer.SetBufferData(computeBuffer, 0, computeBytes);
            ResourceDescriptor[] computeDescriptors =
            [
                new ResourceDescriptor(
                    0,
                    1,
                    ResourceType.StorageBuffer,
                    ResourceStages.Compute
                ),
            ];
            ResourceUsage[] computeUsages =
            [
                new ResourceUsage(
                    0,
                    1,
                    ResourceType.StorageBuffer,
                    ResourceStages.Compute,
                    write: true
                ),
            ];
            ResourceLayout computeLayout = new(
                Array.AsReadOnly(new[]
                {
                    new ResourceDescriptorCollection(
                        Array.AsReadOnly(computeDescriptors)
                    ),
                }),
                Array.AsReadOnly(new[]
                {
                    new ResourceUsageCollection(Array.AsReadOnly(computeUsages)),
                })
            );
            using IProgram computeProgram = renderer.CreateProgram(
                [
                    new ShaderSource(
                        Convert.FromBase64String(SmokeComputeSpirvBase64),
                        ShaderStage.Compute,
                        TargetLanguage.Spirv
                    ),
                ],
                new ShaderInfo(0, computeLayout)
            );
            renderer.Pipeline.SetStorageBuffers(
                [
                    new BufferAssignment(
                        0,
                        new BufferRange(
                            computeBuffer,
                            0,
                            computeBytes.Length,
                            write: true
                        )
                    ),
                ]
            );
            renderer.Pipeline.SetProgram(computeProgram);
            renderer.Pipeline.DispatchCompute(0, 1, 1);
            renderer.Pipeline.DispatchCompute(1, 0, 1);
            renderer.Pipeline.DispatchCompute(1, 1, 0);
            using (PinnedSpan<byte> zeroDispatchReadback =
                renderer.GetBufferData(
                    computeBuffer,
                    0,
                    computeBytes.Length
                ))
            {
                ReadOnlySpan<uint> unchanged = MemoryMarshal.Cast<byte, uint>(
                    zeroDispatchReadback.Get()
                );
                for (int index = 0; index < unchanged.Length; index++)
                {
                    if (unchanged[index] != computeValues[index])
                    {
                        throw new InvalidOperationException(
                            "SolMetal GAL zero-sized compute dispatch changed storage."
                        );
                    }
                }
            }
            renderer.Pipeline.DispatchCompute(1, 1, 1);
            using PinnedSpan<byte> computeReadback = renderer.GetBufferData(
                computeBuffer,
                0,
                computeBytes.Length
            );
            ReadOnlySpan<uint> computed = MemoryMarshal.Cast<byte, uint>(
                computeReadback.Get()
            );
            for (int index = 0; index < computed.Length; index++)
            {
                if (computed[index] != computeValues[index] + 7)
                {
                    throw new InvalidOperationException(
                        $"SolMetal GAL compute output diverged at element {index}."
                    );
                }
            }
            renderer.DeleteBuffer(computeBuffer);
            drawTarget.Release();

            renderer.DeleteBuffer(device);
            renderer.DeleteBuffer(upload);
            HardwareInfo hardware = renderer.GetHardwareInfo();
            Capabilities capabilities = renderer.GetCapabilities();
            if (capabilities.SupportsDepthClipControl)
            {
                throw new InvalidOperationException(
                    "SolMetal must request shader depth remapping because " +
                    "Metal has no host depth-clip-control convention switch."
                );
            }
            SolMetalNativeBridge.RuntimeBatchSnapshot? runtimeBatch =
                renderer._session.QueryRuntimeBatch();
            if (runtimeBatch is { } telemetry &&
                (telemetry.MutationEncoderLimit == 0 ||
                 telemetry.MutationTransientByteLimit == 0 ||
                 telemetry.DrawCommandBufferCount > telemetry.BatchedDrawCount))
            {
                throw new InvalidOperationException(
                    "SolMetal returned inconsistent runtime batch telemetry."
                );
            }
            return new GalSmokeResult(
                hardware.GpuModel,
                byteCount + texturePattern.Length + drawPixels.Length +
                    boundPixels.Length + vertexBytes.Length +
                    boundPixels.Length * 2 +
                    transformBytes.Length + indexBytes.Length +
                    directIndirectBytes.Length + indexedIndirectBytes.Length +
                    byteIndices.Length + 4 +
                    computeBytes.Length + clearByteCount +
                    bufferTexturePattern.Length +
                    textureBufferCopySize + volumePattern.Length +
                    volumeSliceBytes + mipArrayPattern.Length +
                    levelOneSliceBytes * 2 + depthCopyByteCount +
                    layeredBytesVerified + pointSizeBytesVerified +
                    quadBytesVerified + quadPositionBytes.Length +
                    quadInstanceColorBytes.Length +
                    quadByteIndices.Length + quadShortIndexBytes.Length +
                    quadIntIndexBytes.Length + visibleQuadIndexBytes.Length +
                    hiddenQuadIndexBytes.Length,
                guestSync,
                capabilities.Api == TargetApi.Metal
            );
        }
    }

    internal readonly record struct GalSmokeResult(
        string DeviceName,
        int BytesVerified,
        ulong CompletedSync,
        bool ReportsMetalApi
    );

    public event EventHandler<ScreenCaptureImageInfo>? ScreenCaptured;

    // Keep GAL calls on Ryujinx's GPU thread until the threaded wrapper's
    // syncpoint lifecycle passes the same sustained-presentation gate.
    public bool PreferThreading => false;
    public IPipeline Pipeline => _pipeline;
    public IWindow Window => _window;
    public uint ProgramCount { get; private set; }
    internal long BufferReadbackCallCount =>
        Interlocked.Read(ref _bufferReadbackCallCount);
    internal long BufferUploadCallCount =>
        Interlocked.Read(ref _bufferUploadCallCount);

    public BufferHandle CreateBuffer(
        int size,
        BufferAccess access = BufferAccess.Default
    )
    {
        bool deviceLocal = (access & BufferAccess.MemoryTypeMask) ==
            BufferAccess.DeviceMemory;
        lock (_gate)
        {
            ThrowIfDisposed();
            IntPtr native = _session.CreateBuffer(size, deviceLocal);
            ulong value = NextBufferHandle();
            _buffers.Add(value, new BufferEntry(native, size));
            return ToBufferHandle(value);
        }
    }

    public BufferHandle CreateBuffer(nint pointer, int size)
    {
        if (pointer == 0 && size != 0)
        {
            throw new ArgumentNullException(nameof(pointer));
        }

        BufferHandle handle = CreateBuffer(size, BufferAccess.HostMemory);
        if (size != 0)
        {
            SetBufferData(
                handle,
                0,
                new ReadOnlySpan<byte>((void*)pointer, size)
            );
        }
        return handle;
    }

    public BufferHandle CreateBufferSparse(ReadOnlySpan<BufferRange> storageBuffers) =>
        throw Unsupported("sparse buffers");

    public void DeleteBuffer(BufferHandle buffer)
    {
        ulong handle = FromBufferHandle(buffer);
        if (handle == 0)
        {
            return;
        }

        lock (_gate)
        {
            ThrowIfDisposed();
            if (_buffers.Remove(handle, out BufferEntry entry))
            {
                _session.DestroyBuffer(entry.Native);
            }
        }
    }

    public PinnedSpan<byte> GetBufferData(
        BufferHandle buffer,
        int offset,
        int size
    )
    {
        if (size < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(size));
        }

        Interlocked.Increment(ref _bufferReadbackCallCount);
        byte[] data = new byte[size];
        lock (_gate)
        {
            ThrowIfDisposed();
            BufferEntry entry = GetBuffer(buffer, offset, size);
            _session.DownloadBuffer(entry.Native, offset, data);
        }

        if (data.Length == 0)
        {
            return new PinnedSpan<byte>(null, 0);
        }
        GCHandle pin = GCHandle.Alloc(data, GCHandleType.Pinned);
        return new PinnedSpan<byte>(
            (void*)pin.AddrOfPinnedObject(),
            data.Length,
            pin.Free
        );
    }

    public void SetBufferData(
        BufferHandle buffer,
        int offset,
        ReadOnlySpan<byte> data
    )
    {
        Interlocked.Increment(ref _bufferUploadCallCount);
        lock (_gate)
        {
            ThrowIfDisposed();
            BufferEntry entry = GetBuffer(buffer, offset, data.Length);
            _session.UploadBuffer(entry.Native, offset, data);
        }
    }

    internal void CopyBuffer(
        BufferHandle source,
        BufferHandle destination,
        int sourceOffset,
        int destinationOffset,
        int size
    )
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            BufferEntry sourceEntry = GetBuffer(source, sourceOffset, size);
            BufferEntry destinationEntry = GetBuffer(
                destination,
                destinationOffset,
                size
            );
            _session.CopyBuffer(
                sourceEntry.Native,
                sourceOffset,
                destinationEntry.Native,
                destinationOffset,
                size
            );
        }
    }

    internal void ExpandQuadIndices(
        BufferHandle source,
        int sourceOffset,
        int sourceByteCount,
        SolMetalNativeBridge.GalIndexType sourceIndexType,
        int quadCount,
        BufferHandle destination,
        int destinationOffset,
        int destinationByteCount
    )
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            BufferEntry sourceEntry = GetBuffer(
                source,
                sourceOffset,
                sourceByteCount
            );
            BufferEntry destinationEntry = GetBuffer(
                destination,
                destinationOffset,
                destinationByteCount
            );
            _session.ExpandQuadIndices(
                sourceEntry.Native,
                sourceOffset,
                sourceIndexType,
                quadCount,
                destinationEntry.Native,
                destinationOffset
            );
        }
    }

    internal void ClearBuffer(
        BufferHandle destination,
        int offset,
        int size,
        uint value
    )
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            BufferEntry destinationEntry = GetBuffer(
                destination,
                offset,
                size
            );
            _session.FillBuffer(
                destinationEntry.Native,
                offset,
                size,
                value
            );
        }
    }

    internal ulong SubmitBarrier()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            return _session.SubmitTimeline();
        }
    }

    internal void EncodeBarrier()
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            _session.MemoryBarrier();
        }
    }

    public void CreateSync(ulong id, bool strict)
    {
        lock (_gate)
        {
            ThrowIfDisposed();
            _syncTimeline[id] = _session.SubmitTimeline();
        }
    }

    public void WaitSync(ulong id)
    {
        ulong timeline;
        lock (_gate)
        {
            ThrowIfDisposed();
            if (!_syncTimeline.TryGetValue(id, out timeline))
            {
                throw new InvalidOperationException(
                    $"SolMetal sync {id} was never submitted."
                );
            }
        }

        if (!_session.WaitTimeline(timeline, Timeout.InfiniteTimeSpan))
        {
            throw new TimeoutException($"SolMetal sync {id} did not complete.");
        }
    }

    public ulong GetCurrentSync()
    {
        SolMetalNativeBridge.TimelineSnapshot timeline = _session.QueryTimeline();
        if (!timeline.Healthy)
        {
            throw new InvalidOperationException(
                $"SolMetal timeline failed at value {timeline.FirstFailed}."
            );
        }

        ulong current = 0;
        lock (_gate)
        {
            foreach ((ulong guestId, ulong nativeValue) in _syncTimeline)
            {
                if (nativeValue > timeline.LatestCompleted)
                {
                    break;
                }
                current = guestId;
            }
        }
        return current;
    }

    private void FlushCounter(SolMetalCounterEvent target)
    {
        if (!ReferenceEquals(target.Owner, this) || target.IsCompleted)
        {
            return;
        }
        if (!_session.WaitTimeline(target.Timeline, Timeout.InfiniteTimeSpan))
        {
            throw new TimeoutException(
                "SolMetal's visibility counter did not complete."
            );
        }
        CompleteSampleCounters(target.Timeline);
    }

    private void CompleteSampleCounters(ulong completedTimeline)
    {
        while (true)
        {
            SolMetalCounterEvent counter;
            ulong rawResult;
            ulong accumulated;
            lock (_gate)
            {
                ThrowIfDisposed();
                if (!_sampleCounterEvents.TryPeek(out counter!) ||
                    counter.Timeline > completedTimeline)
                {
                    return;
                }
                _sampleCounterEvents.Dequeue();
                rawResult = _session.ResolveVisibilityQuery(counter.Query);
                _session.DestroyVisibilityQuery(counter.Query);
                if (counter.ClearsAccumulatedCounter)
                {
                    _sampleCounterAccumulated = 0;
                }
                _sampleCounterAccumulated = rawResult >
                    ulong.MaxValue - _sampleCounterAccumulated
                        ? ulong.MaxValue
                        : _sampleCounterAccumulated + rawResult;
                accumulated = _sampleCounterAccumulated;
            }

            ulong result = counter.Divisor == 1
                ? accumulated
                : checked((ulong)Math.Ceiling(
                    accumulated / (double)counter.Divisor
                ));
            counter.Complete(result);
        }
    }

    public Capabilities GetCapabilities()
    {
        return new Capabilities(
            api: TargetApi.Metal,
            vendorName: "Apple",
            memoryType: SystemMemoryType.UnifiedMemory,
            hasFrontFacingBug: false,
            hasVectorIndexingBug: false,
            // SPIRV-Cross must emit fragment outputs whose scalar types match
            // the active Metal attachment formats. Ask Ryujinx to rebuild the
            // guest fragment shader whenever those types change, as its
            // MoltenVK path already does for the same Metal constraint.
            needsFragmentOutputSpecialization: true,
            // Apple GPUs pay heavily for NoContraction on every guest FP32
            // operation. Ryubing already enables its reduced-precision path
            // for MoltenVK; direct Metal has the same hardware constraint.
            // The translator preserves operations it identifies as requiring
            // precise behavior (for example divide-by-zero guard biases).
            reduceShaderPrecision: true,
            supportsAstcCompression: false,
            supportsBc123Compression: _session.SupportsBcTextureCompression,
            supportsBc45Compression: _session.SupportsBcTextureCompression,
            supportsBc67Compression: _session.SupportsBcTextureCompression,
            supportsEtc2Compression: false,
            supports3DTextureCompression: false,
            supportsBgraFormat: true,
            supportsR4G4Format: false,
            supportsR4G4B4A4Format: false,
            supportsScaledVertexFormats: false,
            supportsSnormBufferTextureFormat: false,
            supports5BitComponentFormat: false,
            supportsSparseBuffer: false,
            supportsBlendEquationAdvanced: false,
            supportsFragmentShaderInterlock: false,
            supportsFragmentShaderOrderingIntel: false,
            supportsGeometryShader: false,
            supportsGeometryShaderPassthrough: false,
            supportsTransformFeedback: false,
            supportsImageLoadFormatted: true,
            supportsLayerVertexTessellation:
                _session.SupportsLayeredVertexOutput,
            supportsMismatchingViewFormat: false,
            supportsCubemapView: false,
            supportsNonConstantTextureOffset: false,
            supportsQuads: false,
            supportsSeparateSampler: true,
            supportsShaderBallot: false,
            supportsShaderBarrierDivergence: false,
            supportsShaderFloat64: false,
            supportsShaderNonUniformIndexing: false,
            supportsTextureGatherOffsets: false,
            supportsTextureShadowLod: false,
            supportsVertexStoreAndAtomics: false,
            supportsViewportIndexVertexTessellation: false,
            supportsViewportMask: false,
            supportsViewportSwizzle: false,
            supportsIndirectParameters: true,
            // Metal clips homogeneous depth to 0...w and does not expose the
            // Vulkan depth-clip-control switch. Advertising this as false
            // makes Ryujinx lower the guest -1...1 convention into the
            // vertex shader when a title selects that mode.
            supportsDepthClipControl: false,
            uniformBufferSetIndex: 0,
            storageBufferSetIndex: 1,
            textureSetIndex: 2,
            imageSetIndex: 3,
            extraSetBaseIndex: 4,
            maximumExtraSets: 4,
            maximumUniformBuffersPerStage: 18,
            maximumStorageBuffersPerStage: 16,
            maximumTexturesPerStage: 32,
            maximumImagesPerStage: 8,
            maximumComputeSharedMemorySize: 32 * 1024,
            maximumSupportedAnisotropy: 16,
            shaderSubgroupSize: 32,
            storageBufferOffsetAlignment: 16,
            textureBufferOffsetAlignment: 16,
            gatherBiasPrecision: 0,
            maximumGpuMemory: _session.RecommendedWorkingSetBytes
        );
    }

    public HardwareInfo GetHardwareInfo() => new(
        "Apple",
        _session.DeviceName,
        "Metal"
    );

    public void BackgroundContextAction(Action action, bool alwaysBackground = false) =>
        action();

    public void Initialize(GraphicsDebugLevel logLevel) { }
    public void PreFrame() { }
    public void UpdateCounters()
    {
        SolMetalNativeBridge.TimelineSnapshot timeline =
            _session.QueryTimeline();
        if (!timeline.Healthy)
        {
            throw new InvalidOperationException(
                $"SolMetal counter timeline failed at value " +
                $"{timeline.FirstFailed}."
            );
        }
        CompleteSampleCounters(timeline.LatestCompleted);
    }

    public void ResetCounter(CounterType type)
    {
        if (type != CounterType.SamplesPassed)
        {
            return;
        }

        IntPtr replacement;
        IntPtr previous;
        lock (_gate)
        {
            ThrowIfDisposed();
            replacement = _session.CreateVisibilityQuery();
            previous = _sampleCounterQuery;
            _sampleCounterQuery = replacement;
            _sampleCounterClearPending = true;
        }
        _session.DestroyVisibilityQuery(previous);
    }
    public void SetInterruptAction(Action<Action> interruptAction) { }
    public bool PrepareHostMapping(nint address, ulong size) => false;

    public IImageArray CreateImageArray(int size, bool isBuffer) =>
        throw Unsupported("image arrays");
    public ITextureArray CreateTextureArray(int size, bool isBuffer) =>
        throw Unsupported("texture arrays");
    public ITexture CreateTexture(TextureCreateInfo info)
    {
        ValidateInitialTexture(info);
        (
            SolMetalNativeBridge.GalTextureFormat format,
            int bytesPerPixel,
            int blockWidth,
            int blockHeight,
            bool depthStencil
        ) =
            MapTextureFormat(info.Format);
        if ((info.Target != Target.TextureBuffer &&
             info.BytesPerPixel != bytesPerPixel) ||
            info.BlockWidth != blockWidth || info.BlockHeight != blockHeight)
        {
            throw new NotSupportedException(
                $"SolMetal expected {blockWidth}x{blockHeight} blocks of " +
                $"{bytesPerPixel} bytes for {info.Format}, not " +
                $"{info.BlockWidth}x{info.BlockHeight} blocks of {info.BytesPerPixel} bytes."
            );
        }

        lock (_gate)
        {
            ThrowIfDisposed();
            IntPtr native = info.Target == Target.TextureBuffer
                ? IntPtr.Zero
                : _session.CreateTexture(
                    info.Width,
                    info.Height,
                    MapTextureType(info.Target),
                    info.Depth,
                    info.Levels,
                    info.Samples,
                    format,
                    MapTextureSwizzle(info.SwizzleR),
                    MapTextureSwizzle(info.SwizzleG),
                    MapTextureSwizzle(info.SwizzleB),
                    MapTextureSwizzle(info.SwizzleA),
                    depthStencil
                );
            SolMetalGalTexture texture = new(
                this,
                native,
                info,
                format,
                bytesPerPixel,
                depthStencil
            );
            _textures.Add(texture);
            return texture;
        }
    }

    public ISampler CreateSampler(SamplerCreateInfo info)
    {
        if ((info.CompareMode != CompareMode.None &&
             info.CompareMode != CompareMode.CompareRToTexture) ||
            !float.IsFinite(info.MinLod) || !float.IsFinite(info.MaxLod) ||
            !float.IsFinite(info.MipLodBias) ||
            info.MinLod > info.MaxLod)
        {
            throw Unsupported("invalid comparison sampler or LOD state");
        }

        SolMetalNativeBridge.GalSamplerFilter minFilter;
        SolMetalNativeBridge.GalSamplerMipFilter mipFilter;
        switch (info.MinFilter)
        {
            case MinFilter.Nearest:
                minFilter = SolMetalNativeBridge.GalSamplerFilter.Nearest;
                mipFilter = SolMetalNativeBridge.GalSamplerMipFilter.NotMipmapped;
                break;
            case MinFilter.Linear:
                minFilter = SolMetalNativeBridge.GalSamplerFilter.Linear;
                mipFilter = SolMetalNativeBridge.GalSamplerMipFilter.NotMipmapped;
                break;
            case MinFilter.NearestMipmapNearest:
                minFilter = SolMetalNativeBridge.GalSamplerFilter.Nearest;
                mipFilter = SolMetalNativeBridge.GalSamplerMipFilter.Nearest;
                break;
            case MinFilter.LinearMipmapNearest:
                minFilter = SolMetalNativeBridge.GalSamplerFilter.Linear;
                mipFilter = SolMetalNativeBridge.GalSamplerMipFilter.Nearest;
                break;
            case MinFilter.NearestMipmapLinear:
                minFilter = SolMetalNativeBridge.GalSamplerFilter.Nearest;
                mipFilter = SolMetalNativeBridge.GalSamplerMipFilter.Linear;
                break;
            case MinFilter.LinearMipmapLinear:
                minFilter = SolMetalNativeBridge.GalSamplerFilter.Linear;
                mipFilter = SolMetalNativeBridge.GalSamplerMipFilter.Linear;
                break;
            default:
                throw Unsupported($"minification filter {info.MinFilter}");
        }

        float minLod = info.MinLod;
        float maxLod = info.MaxLod;
        if (info.MinFilter is MinFilter.Nearest or MinFilter.Linear)
        {
            minLod = 0;
            maxLod = 0.25f;
        }

        SolMetalNativeBridge.GalSamplerDescriptor descriptor = new(
            minFilter,
            info.MagFilter == MagFilter.Linear
                ? SolMetalNativeBridge.GalSamplerFilter.Linear
                : SolMetalNativeBridge.GalSamplerFilter.Nearest,
            mipFilter,
            MapAddressMode(info.AddressU),
            MapAddressMode(info.AddressV),
            MapAddressMode(info.AddressP),
            (uint)Math.Clamp((int)MathF.Ceiling(info.MaxAnisotropy), 1, 16),
            minLod,
            maxLod,
            info.AddressU == AddressMode.ClampToBorder ||
            info.AddressV == AddressMode.ClampToBorder ||
            info.AddressP == AddressMode.ClampToBorder
                ? MapBorderColor(info.BorderColor)
                : SolMetalNativeBridge.GalSamplerBorderColor.TransparentBlack,
            info.CompareMode == CompareMode.CompareRToTexture,
            MapCompare(info.CompareOp),
            info.MipLodBias
        );

        lock (_gate)
        {
            ThrowIfDisposed();
            SolMetalGalSampler sampler = new(
                this,
                _session.CreateSampler(descriptor),
                info,
                descriptor
            );
            _samplers.Add(sampler);
            return sampler;
        }
    }

    public IProgram CreateProgram(ShaderSource[] shaders, ShaderInfo info)
    {
        if (shaders.Length == 1 && shaders[0].Stage == ShaderStage.Compute)
        {
            ShaderSource compute = shaders[0];
            if (compute.Language != TargetLanguage.Spirv ||
                compute.BinaryCode is null)
            {
                throw Unsupported("non-SPIR-V or incomplete compute programs");
            }
            ProgramResourcePlan computePlan = BuildComputeResourcePlan(
                info.ResourceLayout,
                compute.BinaryCode,
                _session.ArgumentBufferTier
            );
            (uint X, uint Y, uint Z) localSize = ReadComputeLocalSize(
                compute.BinaryCode
            );
            lock (_gate)
            {
                ThrowIfDisposed();
                SolMetalGalProgram program = new(
                    this,
                    _session.CreateComputePipeline(
                        compute.BinaryCode,
                        computePlan.ComputeRemaps
                    ),
                    computePlan.Bindings,
                    localSize
                );
                _programs.Add(program);
                ProgramCount++;
                return program;
            }
        }
        if (shaders.Any(shader => shader.Stage is
                ShaderStage.TessellationControl or
                ShaderStage.TessellationEvaluation))
        {
            throw Unsupported("tessellation shader stages");
        }
        if (shaders.Length != 2)
        {
            string stages = string.Join(
                ", ",
                shaders.Select(shader => shader.Stage.ToString())
            );
            throw Unsupported(
                $"shader stage set [{stages}] (expected one vertex/fragment pair)"
            );
        }
        int vertexIndex = Array.FindIndex(
            shaders,
            source => source.Stage == ShaderStage.Vertex
        );
        int fragmentIndex = Array.FindIndex(
            shaders,
            source => source.Stage == ShaderStage.Fragment
        );
        if (vertexIndex < 0 || fragmentIndex < 0)
        {
            throw Unsupported("incomplete vertex/fragment shader programs");
        }
        ShaderSource vertex = shaders[vertexIndex];
        ShaderSource fragment = shaders[fragmentIndex];
        if (vertex.Language != TargetLanguage.Spirv ||
            fragment.Language != TargetLanguage.Spirv ||
            vertex.BinaryCode is null || fragment.BinaryCode is null)
        {
            throw Unsupported("non-SPIR-V or incomplete shader programs");
        }
        ProgramResourcePlan resourcePlan = BuildResourcePlan(
            info.ResourceLayout,
            vertex.BinaryCode,
            fragment.BinaryCode,
            _session.ArgumentBufferTier
        );

        lock (_gate)
        {
            ThrowIfDisposed();
            SolMetalGalProgram program = new(
                this,
                _session.CreateRenderProgram(
                    vertex.BinaryCode,
                    fragment.BinaryCode,
                    resourcePlan.VertexRemaps,
                    resourcePlan.FragmentRemaps,
                    resourcePlan.VertexArgumentBufferSetMask,
                    resourcePlan.FragmentArgumentBufferSetMask
                ),
                resourcePlan.Bindings,
                SolMetalRenderProgramIdentity.CreateKey(
                    vertex.BinaryCode,
                    fragment.BinaryCode
                ),
                vertex.BinaryCode,
                resourcePlan.VertexRemaps,
                resourcePlan.VertexArgumentBufferSetMask
            );
            _programs.Add(program);
            ProgramCount++;
            return program;
        }
    }

    public IProgram LoadProgramBinary(
        byte[] programBinary,
        bool hasFragmentShader,
        ShaderInfo info
    ) => throw Unsupported("program binaries");

    public ICounterEvent ReportCounter(
        CounterType type,
        EventHandler<ulong> resultHandler,
        float divisor,
        bool hostReserved
    )
    {
        ArgumentNullException.ThrowIfNull(resultHandler);
        if (!float.IsFinite(divisor) || divisor <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(divisor));
        }
        if (type != CounterType.SamplesPassed)
        {
            // SolMetal advertises neither pipeline-statistics queries nor
            // transform feedback. Ryubing's other backends resolve those
            // unsupported query kinds to zero rather than aborting a title.
            SolMetalImmediateCounterEvent immediate = new();
            resultHandler(immediate, 0);
            return immediate;
        }

        lock (_gate)
        {
            ThrowIfDisposed();
            IntPtr completedQuery = _sampleCounterQuery;
            if (completedQuery == IntPtr.Zero)
            {
                completedQuery = _session.CreateVisibilityQuery();
            }
            IntPtr nextQuery = _session.CreateVisibilityQuery();
            try
            {
                ulong timeline = _session.SubmitTimeline();
                SolMetalCounterEvent counter = new(
                    this,
                    completedQuery,
                    timeline,
                    _sampleCounterClearPending,
                    resultHandler,
                    divisor
                );
                _sampleCounterQuery = nextQuery;
                _sampleCounterClearPending = false;
                _sampleCounterEvents.Enqueue(counter);
                return counter;
            }
            catch
            {
                _session.DestroyVisibilityQuery(nextQuery);
                if (_sampleCounterQuery == IntPtr.Zero)
                {
                    _session.DestroyVisibilityQuery(completedQuery);
                }
                throw;
            }
        }
    }

    public void Screenshot()
    {
        Interlocked.Exchange(ref _screenshotRequested, 1);
        long structuredProbePresentation = 0;
        bool rearmedStructuredProbes = false;
        if (_frameProbeEnabled)
        {
            Interlocked.Exchange(ref _postDrawProbeSequence, 0);
            Interlocked.Exchange(ref _postInstancedDrawProbeBudget, 16);
            Interlocked.Exchange(ref _postFullscreenDrawProbeBudget, 8);
            Interlocked.Exchange(ref _postLargeDrawProbeBudget, 8);
            Interlocked.Exchange(ref _postHdrLargeDrawProbeBudget, 8);
            lock (_targetedVisibilityProbeGate)
            {
                _pendingTargetedVisibilityProbePrograms.Clear();
                _pendingTargetedVisibilityProbePrograms.UnionWith(
                    _targetedVisibilityProbePrograms
                );
                _pendingTargetedVisibilityProbeProgramKeys.Clear();
                _pendingTargetedVisibilityProbeProgramKeys.UnionWith(
                    _targetedVisibilityProbeProgramKeys
                );
                if (_configuredTargetedProbeSelectors.Length > 0)
                {
                    structuredProbePresentation = Interlocked.Read(
                        ref _presentedFrameCount
                    );
                    ResetStructuredTargetedProbeSelectorsLocked(
                        structuredProbePresentation
                    );
                    rearmedStructuredProbes = true;
                }
                Volatile.Write(ref _targetedD16WriterProbe, null);
            }
        }
        if (rearmedStructuredProbes)
        {
            LogStructuredTargetedProbeSelectorsArmed(
                "screenshot request",
                structuredProbePresentation
            );
        }
        Logger.Notice.Print(
            LogClass.Gpu,
            "SolMetal screenshot requested."
        );
    }

    private void RecordFrameProbeTarget(
        SolMetalGalTexture texture,
        string role,
        int elementCount
    )
    {
        if (!_frameProbeEnabled || texture.ProbeId == 0 ||
            !texture.CanProbeRaw || texture.Width < 1280 ||
            texture.Height < 720)
        {
            return;
        }

        lock (_frameProbeTargetGate)
        {
            long sequence = ++_frameProbeTargetSequence;
            _frameProbeTargets[texture.ProbeId] = new FrameProbeTarget(
                texture,
                role,
                elementCount,
                sequence
            );
            while (_frameProbeTargets.Count > 8)
            {
                long oldestId = 0;
                long oldestSequence = long.MaxValue;
                foreach ((long id, FrameProbeTarget candidate) in
                         _frameProbeTargets)
                {
                    if (candidate.Sequence < oldestSequence)
                    {
                        oldestId = id;
                        oldestSequence = candidate.Sequence;
                    }
                }
                _frameProbeTargets.Remove(oldestId);
            }
        }
    }

    private FrameProbeTarget[] TakeFrameProbeTargets()
    {
        if (!_frameProbeEnabled)
        {
            return [];
        }

        lock (_frameProbeTargetGate)
        {
            FrameProbeTarget[] targets = _frameProbeTargets.Values
                .OrderBy(target => target.Sequence)
                .ToArray();
            _frameProbeTargets.Clear();
            return targets;
        }
    }

    private void OnScreenCaptured(ScreenCaptureImageInfo image) =>
        ScreenCaptured?.Invoke(this, image);

    private static void LogFrameProbe(
        ReadOnlySpan<byte> pixels,
        int width,
        int height,
        bool isBgra,
        string label = "first-frame source"
    )
    {
        long nonBlackPixels = 0;
        byte minimumRgb = byte.MaxValue;
        byte maximumRgb = byte.MinValue;
        ulong checksum = 14695981039346656037UL;

        for (int offset = 0; offset < pixels.Length; offset += 4)
        {
            byte first = pixels[offset];
            byte green = pixels[offset + 1];
            byte third = pixels[offset + 2];
            if (first != 0 || green != 0 || third != 0)
            {
                nonBlackPixels++;
            }

            minimumRgb = Math.Min(minimumRgb, Math.Min(first, Math.Min(green, third)));
            maximumRgb = Math.Max(maximumRgb, Math.Max(first, Math.Max(green, third)));
            for (int channel = 0; channel < 4; channel++)
            {
                checksum ^= pixels[offset + channel];
                checksum *= 1099511628211UL;
            }
        }

        Logger.Notice.Print(
            LogClass.Gpu,
            $"SolMetal {label} probe {width}x{height} " +
            $"{(isBgra ? "BGRA" : "RGBA")}: non-black " +
            $"{nonBlackPixels}/{(long)width * height}, RGB range " +
            $"{minimumRgb}-{maximumRgb}, checksum 0x{checksum:X16}."
        );
    }

    private static void DumpPresentedFrameProbe(
        ReadOnlySpan<byte> pixels,
        int width,
        int height,
        SolMetalNativeBridge.GalTextureFormat format,
        long presentation,
        string role
    )
    {
        try
        {
            string directory = Path.Combine(
                Path.GetTempPath(),
                $"SolMetalFrameProbe-{Environment.ProcessId}"
            );
            Directory.CreateDirectory(directory);
            string path = Path.Combine(
                directory,
                $"presentation-{presentation:D6}-{role}-" +
                $"{format}-{width}x{height}-{pixels.Length}-bytes.bin"
            );
            File.WriteAllBytes(path, pixels.ToArray());
            Logger.Notice.Print(
                LogClass.Gpu,
                $"SolMetal {role} frame written to {path}."
            );
        }
        catch (Exception exception)
        {
            Logger.Warning?.Print(
                LogClass.Gpu,
                $"SolMetal could not persist the {role} frame probe: " +
                exception.Message
            );
        }
    }

    private static void LogRawProbe(
        ReadOnlySpan<byte> bytes,
        string label
    )
    {
        long nonZeroBytes = 0;
        byte minimum = byte.MaxValue;
        byte maximum = byte.MinValue;
        ulong checksum = 14695981039346656037UL;
        foreach (byte value in bytes)
        {
            if (value != 0)
            {
                nonZeroBytes++;
            }
            minimum = Math.Min(minimum, value);
            maximum = Math.Max(maximum, value);
            checksum ^= value;
            checksum *= 1099511628211UL;
        }
        Logger.Notice.Print(
            LogClass.Gpu,
            $"SolMetal {label} raw probe: non-zero " +
            $"{nonZeroBytes}/{bytes.Length} bytes, range {minimum}-{maximum}, " +
            $"checksum 0x{checksum:X16}."
        );
    }

    private static ulong[] BuildD16Histogram(
        ReadOnlySpan<byte> bytes,
        int width,
        int height,
        int bytesPerRow
    )
    {
        if (width <= 0 || height <= 0 || bytesPerRow < width * sizeof(ushort) ||
            bytes.Length < checked(bytesPerRow * height))
        {
            throw new ArgumentException("Invalid D16 histogram layout.");
        }

        ulong[] histogram = new ulong[ushort.MaxValue + 1];
        for (int y = 0; y < height; y++)
        {
            int rowOffset = y * bytesPerRow;
            for (int x = 0; x < width; x++)
            {
                int offset = rowOffset + x * sizeof(ushort);
                ushort code = (ushort)(bytes[offset] | bytes[offset + 1] << 8);
                histogram[code]++;
            }
        }
        return histogram;
    }

    private static uint DecodeNibbleSwappedTag(uint rawTag) =>
        ((rawTag & 0xfu) << 4) | (rawTag >> 4);

    private static int QuantizeD16Code(float depth)
    {
        float bounded = Math.Clamp(depth, 0f, 1f);
        return checked((int)MathF.Round(
            bounded * ushort.MaxValue,
            MidpointRounding.ToEven
        ));
    }

    private static int D16CodeForTag(uint rawTag, float bias)
    {
        float encoded = DecodeNibbleSwappedTag(rawTag) *
            0.0039215688593685627f;
        float depth = MathF.FusedMultiplyAdd(encoded, -bias, encoded) + bias;
        return QuantizeD16Code(depth);
    }

    private static string FormatNonZeroHistogram(ulong[] histogram) =>
        string.Join(
            '\n',
            histogram.Select((count, code) => (count, code))
                .Where(entry => entry.count != 0)
                .Select(entry => $"{entry.code}={entry.count}")
        );

    private static string SummarizeHistogram(
        ulong[] histogram,
        int maximumBins = 12
    ) => string.Join(
        ", ",
        histogram.Select((count, code) => (count, code))
            .Where(entry => entry.count != 0)
            .OrderByDescending(entry => entry.count)
            .ThenBy(entry => entry.code)
            .Take(maximumBins)
            .Select(entry => $"{entry.code}:{entry.count}")
    );

    private void DumpPostDrawProbe(
        ReadOnlySpan<byte> bytes,
        SolMetalGalTexture texture,
        SolMetalGalProgram program,
        string role
    )
    {
        if (!_frameProbeEnabled)
        {
            return;
        }

        long sequence = Interlocked.Increment(ref _postDrawProbeSequence);
        string directory = Path.Combine(
            Path.GetTempPath(),
            $"SolMetalFrameProbe-{Environment.ProcessId}"
        );
        Directory.CreateDirectory(directory);
        string path = Path.Combine(
            directory,
            $"post-{sequence:D3}-{role}-program-{program.ProbeId}-" +
            $"texture-{texture.ProbeId}-{texture.NativeFormat}-" +
            $"{texture.Width}x{texture.Height}.bin"
        );
        File.WriteAllBytes(path, bytes.ToArray());
        Logger.Notice.Print(
            LogClass.Gpu,
            $"SolMetal post-draw target written to {path}."
        );
    }

    private BufferEntry GetBuffer(BufferHandle buffer, int offset, int size)
    {
        if (offset < 0 || size < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(offset));
        }
        ulong handle = FromBufferHandle(buffer);
        if (handle == 0 || !_buffers.TryGetValue(handle, out BufferEntry entry))
        {
            throw new ArgumentException("Unknown SolMetal buffer handle.", nameof(buffer));
        }
        if (offset > entry.Size || size > entry.Size - offset)
        {
            throw new ArgumentOutOfRangeException(nameof(size));
        }
        return entry;
    }

    private SolMetalNativeBridge.GalBufferBinding ResolveBufferBinding(
        uint index,
        BufferRange range,
        uint argumentBuffer = 0
    )
    {
        if (range.Handle == BufferHandle.Null || range.Size <= 0)
        {
            throw new ArgumentException(
                "SolMetal requires a non-empty buffer range.",
                nameof(range)
            );
        }
        BufferEntry entry = GetBuffer(range.Handle, range.Offset, range.Size);
        return new SolMetalNativeBridge.GalBufferBinding(
            index,
            entry.Native,
            checked((ulong)range.Offset),
            argumentBuffer
        );
    }

    private ulong NextBufferHandle()
    {
        if (_nextBufferHandle == 0)
        {
            throw new InvalidOperationException("SolMetal buffer handles were exhausted.");
        }
        return _nextBufferHandle++;
    }

    private static BufferHandle ToBufferHandle(ulong value) =>
        Unsafe.As<ulong, BufferHandle>(ref value);

    private static ulong FromBufferHandle(BufferHandle handle) =>
        Unsafe.As<BufferHandle, ulong>(ref handle);

    private static NotSupportedException Unsupported(string feature) => new(
        $"SolMetal's controlled GAL milestone does not support {feature} yet."
    );

    private static ProgramResourcePlan BuildResourcePlan(
        ResourceLayout layout,
        ReadOnlySpan<byte> vertexSpirv,
        ReadOnlySpan<byte> fragmentSpirv,
        uint argumentBufferTier
    )
    {
        HashSet<(uint Set, uint Binding)> vertexResources =
            ReadSpirvDescriptorBindings(vertexSpirv);
        HashSet<(uint Set, uint Binding)> fragmentResources =
            ReadSpirvDescriptorBindings(fragmentSpirv);
        if (vertexResources.Count == 0 && fragmentResources.Count == 0)
        {
            return ProgramResourcePlan.Empty;
        }
        if (layout.Sets is null)
        {
            throw Unsupported("shader resources without a GAL resource layout");
        }

        List<ProgramResourceBinding> bindings = [];
        SolMetalNativeBridge.GalSpirvResourceBinding[] vertexRemaps =
            BuildStageResourceRemaps(
                layout,
                ShaderStage.Vertex,
                vertexResources,
                bindings,
                allowArgumentBuffers: true,
                argumentBufferTier: argumentBufferTier,
                argumentBufferSetMask: out uint vertexArgumentBufferSetMask
            );
        SolMetalNativeBridge.GalSpirvResourceBinding[] fragmentRemaps =
            BuildStageResourceRemaps(
                layout,
                ShaderStage.Fragment,
                fragmentResources,
                bindings,
                allowArgumentBuffers: true,
                argumentBufferTier: argumentBufferTier,
                argumentBufferSetMask: out uint fragmentArgumentBufferSetMask
            );
        return new ProgramResourcePlan(
            vertexRemaps,
            fragmentRemaps,
            [],
            vertexArgumentBufferSetMask,
            fragmentArgumentBufferSetMask,
            0,
            bindings.ToArray()
        );
    }

    private static ProgramResourcePlan BuildComputeResourcePlan(
        ResourceLayout layout,
        ReadOnlySpan<byte> computeSpirv,
        uint argumentBufferTier
    )
    {
        HashSet<(uint Set, uint Binding)> resources =
            ReadSpirvDescriptorBindings(computeSpirv);
        if (resources.Count == 0)
        {
            return ProgramResourcePlan.Empty;
        }
        if (layout.Sets is null)
        {
            throw Unsupported("compute resources without a GAL resource layout");
        }
        List<ProgramResourceBinding> bindings = [];
        SolMetalNativeBridge.GalSpirvResourceBinding[] remaps =
            BuildStageResourceRemaps(
                layout,
                ShaderStage.Compute,
                resources,
                bindings,
                allowArgumentBuffers: false,
                argumentBufferTier: argumentBufferTier,
                argumentBufferSetMask: out uint computeArgumentBufferSetMask
            );
        return new ProgramResourcePlan(
            [], [], remaps, 0, 0, computeArgumentBufferSetMask,
            bindings.ToArray()
        );
    }

    private static SolMetalNativeBridge.GalSpirvResourceBinding[]
        BuildStageResourceRemaps(
            ResourceLayout layout,
            ShaderStage stage,
            HashSet<(uint Set, uint Binding)> resources,
            List<ProgramResourceBinding> allBindings,
            bool allowArgumentBuffers,
            uint argumentBufferTier,
            out uint argumentBufferSetMask
        )
    {
        ResourceStages requiredStage = stage switch
        {
            ShaderStage.Compute => ResourceStages.Compute,
            ShaderStage.Vertex => ResourceStages.Vertex,
            ShaderStage.Fragment => ResourceStages.Fragment,
            _ => throw Unsupported($"shader stage {stage}"),
        };
        List<(uint Set, uint Binding, ResourceDescriptor Descriptor)> resolved = [];

        foreach ((uint set, uint binding) in resources
                     .OrderBy(resource => resource.Set)
                     .ThenBy(resource => resource.Binding))
        {
            if (set >= layout.Sets.Count ||
                layout.Sets[(int)set].Descriptors is null)
            {
                throw Unsupported(
                    $"SPIR-V descriptor set {set}, binding {binding} without GAL metadata"
                );
            }

            ResourceDescriptor descriptor = default;
            int matches = 0;
            foreach (ResourceDescriptor candidate in
                     layout.Sets[(int)set].Descriptors)
            {
                if (candidate.Binding == binding &&
                    (candidate.Stages & requiredStage) != 0)
                {
                    descriptor = candidate;
                    matches++;
                }
            }
            if (matches != 1)
            {
                throw Unsupported(
                    matches == 0
                        ? $"unmapped SPIR-V descriptor set {set}, binding {binding} for {stage}"
                        : $"ambiguous SPIR-V descriptor set {set}, binding {binding} for {stage}"
                );
            }
            if (descriptor.Count != 1)
            {
                throw Unsupported("descriptor arrays");
            }
            resolved.Add((set, binding, descriptor));
        }

        int textureSetSamplerCount = resolved.Count(resource =>
            resource.Set == TextureDescriptorSet &&
            resource.Descriptor.Type is ResourceType.TextureAndSampler or
                ResourceType.Sampler
        );
        bool useTextureArgumentBuffer =
            textureSetSamplerCount > (int)MaximumMetalSamplersPerStage;
        if (useTextureArgumentBuffer && !allowArgumentBuffers)
        {
            throw Unsupported(
                $"the requested {stage} texture table requires Metal argument buffers"
            );
        }
        if (useTextureArgumentBuffer && argumentBufferTier < 2)
        {
            throw Unsupported(
                $"the requested {stage} texture table requires Metal argument-buffer tier 2"
            );
        }
        argumentBufferSetMask = useTextureArgumentBuffer
            ? 1u << (int)TextureDescriptorSet
            : 0;

        uint nextBuffer = stage == ShaderStage.Vertex
            ? VertexResourceBufferBase
            : 0;
        uint nextTexture = 0;
        uint nextSampler = 0;
        uint nextArgumentBufferResource = 0;
        List<SolMetalNativeBridge.GalSpirvResourceBinding> remaps = [];

        foreach ((uint set, uint binding, ResourceDescriptor descriptor) in resolved)
        {
            bool argumentBuffer =
                useTextureArgumentBuffer && set == TextureDescriptorSet;

            uint metalBuffer = 0;
            uint metalTexture = 0;
            uint metalSampler = 0;
            uint argumentBufferEncoding = 0;
            if (argumentBuffer)
            {
                argumentBufferEncoding = MetalArgumentBufferEncoding;
                switch (descriptor.Type)
                {
                    case ResourceType.UniformBuffer:
                    case ResourceType.StorageBuffer:
                        metalBuffer = nextArgumentBufferResource++;
                        break;
                    case ResourceType.TextureAndSampler:
                        metalTexture = nextArgumentBufferResource++;
                        metalSampler = nextArgumentBufferResource++;
                        break;
                    case ResourceType.Texture:
                    case ResourceType.Image:
                        metalTexture = nextArgumentBufferResource++;
                        break;
                    case ResourceType.Sampler:
                        metalSampler = nextArgumentBufferResource++;
                        break;
                    case ResourceType.BufferTexture:
                    case ResourceType.BufferImage:
                        metalTexture = nextArgumentBufferResource++;
                        break;
                    default:
                        throw Unsupported($"resource type {descriptor.Type}");
                }
                if (nextArgumentBufferResource >
                    MaximumMetalArgumentBufferResources)
                {
                    throw Unsupported(
                        $"more than {MaximumMetalArgumentBufferResources} Metal argument-buffer resources in the {stage} stage"
                    );
                }
            }
            else
            {
                switch (descriptor.Type)
                {
                    case ResourceType.UniformBuffer:
                    case ResourceType.StorageBuffer:
                        metalBuffer = nextBuffer++;
                        break;
                    case ResourceType.TextureAndSampler:
                        metalTexture = nextTexture++;
                        metalSampler = nextSampler++;
                        break;
                    case ResourceType.Texture:
                        metalTexture = nextTexture++;
                        break;
                    case ResourceType.Sampler:
                        metalSampler = nextSampler++;
                        break;
                    case ResourceType.Image:
                        metalTexture = nextTexture++;
                        break;
                    case ResourceType.BufferTexture:
                    case ResourceType.BufferImage:
                        metalTexture = nextTexture++;
                        break;
                    default:
                        throw Unsupported($"resource type {descriptor.Type}");
                }
                uint bufferLimit = useTextureArgumentBuffer
                    ? MetalArgumentBufferSlot
                    : MaximumMetalBuffersPerStage;
                if (nextBuffer > bufferLimit)
                {
                    throw Unsupported($"more Metal buffers in the {stage} stage");
                }
                if (nextTexture > MaximumMetalTexturesPerStage ||
                    nextSampler > MaximumMetalSamplersPerStage)
                {
                    throw Unsupported(
                        $"the requested {stage} texture/sampler count " +
                        $"({nextTexture}/{MaximumMetalTexturesPerStage} textures, " +
                        $"{nextSampler}/{MaximumMetalSamplersPerStage} samplers)"
                    );
                }
            }

            remaps.Add(new SolMetalNativeBridge.GalSpirvResourceBinding(
                set,
                binding,
                metalBuffer,
                metalTexture,
                metalSampler,
                1
            ));
            allBindings.Add(new ProgramResourceBinding(
                stage,
                (int)set,
                (int)binding,
                descriptor.Type,
                metalBuffer,
                metalTexture,
                metalSampler,
                argumentBufferEncoding
            ));
        }

        return remaps.ToArray();
    }

    private static HashSet<(uint Set, uint Binding)>
        ReadSpirvDescriptorBindings(ReadOnlySpan<byte> spirv)
    {
        if (spirv.Length < 20 || spirv.Length % sizeof(uint) != 0)
        {
            throw new ArgumentException("SPIR-V has an invalid byte length.", nameof(spirv));
        }
        ReadOnlySpan<uint> words = MemoryMarshal.Cast<byte, uint>(spirv);
        if (words[0] != 0x07230203)
        {
            throw new ArgumentException("SPIR-V has an invalid magic word.", nameof(spirv));
        }

        const ushort OpDecorate = 71;
        const uint DecorationBinding = 33;
        const uint DecorationDescriptorSet = 34;
        Dictionary<uint, uint> sets = [];
        Dictionary<uint, uint> bindings = [];
        int offset = 5;
        while (offset < words.Length)
        {
            uint header = words[offset];
            int wordCount = checked((int)(header >> 16));
            ushort opcode = (ushort)(header & 0xffff);
            if (wordCount <= 0 || offset > words.Length - wordCount)
            {
                throw new ArgumentException(
                    "SPIR-V contains a malformed instruction.",
                    nameof(spirv)
                );
            }
            if (opcode == OpDecorate && wordCount >= 4)
            {
                uint target = words[offset + 1];
                uint decoration = words[offset + 2];
                uint value = words[offset + 3];
                if (decoration == DecorationDescriptorSet)
                {
                    sets[target] = value;
                }
                else if (decoration == DecorationBinding)
                {
                    bindings[target] = value;
                }
            }
            offset += wordCount;
        }

        HashSet<(uint Set, uint Binding)> result = [];
        foreach ((uint target, uint set) in sets)
        {
            if (bindings.TryGetValue(target, out uint binding))
            {
                result.Add((set, binding));
            }
        }
        return result;
    }

    private static (uint X, uint Y, uint Z) ReadComputeLocalSize(
        ReadOnlySpan<byte> spirv
    )
    {
        ReadOnlySpan<uint> words = MemoryMarshal.Cast<byte, uint>(spirv);
        const ushort OpExecutionMode = 16;
        const uint ExecutionModeLocalSize = 17;
        int offset = 5;
        while (offset < words.Length)
        {
            uint header = words[offset];
            int wordCount = checked((int)(header >> 16));
            ushort opcode = (ushort)(header & 0xffff);
            if (wordCount <= 0 || offset > words.Length - wordCount)
            {
                throw new ArgumentException(
                    "SPIR-V contains a malformed instruction.",
                    nameof(spirv)
                );
            }
            if (opcode == OpExecutionMode && wordCount >= 6 &&
                words[offset + 2] == ExecutionModeLocalSize)
            {
                uint x = words[offset + 3];
                uint y = words[offset + 4];
                uint z = words[offset + 5];
                if (x == 0 || y == 0 || z == 0)
                {
                    break;
                }
                return (x, y, z);
            }
            offset += wordCount;
        }
        throw Unsupported("compute shaders without a fixed LocalSize execution mode");
    }

    private static void ValidateInitialTexture(TextureCreateInfo info)
    {
        bool bufferTexture = info.Target == Target.TextureBuffer;
        bool validTargetAndDepth =
            (info.Target == Target.Texture2D && info.Depth == 1) ||
            (info.Target == Target.Texture2DArray && info.Depth > 0) ||
            (info.Target == Target.Texture3D && info.Depth > 0) ||
            (info.Target == Target.Cubemap && info.Depth == 6) ||
            (info.Target == Target.CubemapArray && info.Depth > 0 &&
             info.Depth % 6 == 0) ||
            (bufferTexture && info.Height == 1 && info.Depth == 1);
        int maximumLevels = BitOperations.Log2(
            checked((uint)Math.Max(
                Math.Max(info.Width, info.Height),
                info.Target == Target.Texture3D ? info.Depth : 1
            ))
        ) + 1;
        if (info.Width <= 0 || info.Height <= 0 ||
            !validTargetAndDepth || info.Levels <= 0 ||
            info.Levels > maximumLevels || info.Samples != 1 ||
            info.BlockWidth <= 0 || info.BlockHeight <= 0 ||
            (bufferTexture &&
             (info.Levels != 1 || info.BlockWidth != 1 ||
              info.BlockHeight != 1)))
        {
            throw Unsupported(
                $"texture {info.Target} {info.Width}x{info.Height}x{info.Depth}, " +
                $"levels={info.Levels}, samples={info.Samples}, " +
                $"block={info.BlockWidth}x{info.BlockHeight}, format={info.Format}"
            );
        }
    }

    private static SolMetalNativeBridge.GalTextureType MapTextureType(
        Target target
    ) => target switch
    {
        Target.Texture2D => SolMetalNativeBridge.GalTextureType.Texture2D,
        Target.Texture2DArray =>
            SolMetalNativeBridge.GalTextureType.Texture2DArray,
        Target.Texture3D => SolMetalNativeBridge.GalTextureType.Texture3D,
        Target.Cubemap => SolMetalNativeBridge.GalTextureType.TextureCube,
        Target.CubemapArray =>
            SolMetalNativeBridge.GalTextureType.TextureCubeArray,
        Target.TextureBuffer =>
            SolMetalNativeBridge.GalTextureType.TextureBuffer,
        _ => throw Unsupported($"texture target {target}"),
    };

    private static int GetTextureDataSize(TextureCreateInfo info)
    {
        int size = 0;
        for (int level = 0; level < info.Levels; level++)
        {
            size = checked(size + info.GetMipSize(level));
        }
        return size;
    }

    private static (
        SolMetalNativeBridge.GalTextureFormat Format,
        int BytesPerPixel,
        int BlockWidth,
        int BlockHeight,
        bool DepthStencil
    ) MapTextureFormat(Format format) => format switch
    {
        Format.R8Unorm => (SolMetalNativeBridge.GalTextureFormat.R8Unorm, 1, 1, 1, false),
        Format.R8Uint => (SolMetalNativeBridge.GalTextureFormat.R8Uint, 1, 1, 1, false),
        Format.R16Unorm => (SolMetalNativeBridge.GalTextureFormat.R16Unorm, 2, 1, 1, false),
        Format.R16Float => (SolMetalNativeBridge.GalTextureFormat.R16Float, 2, 1, 1, false),
        Format.R32Float => (SolMetalNativeBridge.GalTextureFormat.R32Float, 4, 1, 1, false),
        Format.R32Uint => (SolMetalNativeBridge.GalTextureFormat.R32Uint, 4, 1, 1, false),
        Format.R32Sint => (SolMetalNativeBridge.GalTextureFormat.R32Sint, 4, 1, 1, false),
        Format.R8G8Unorm => (SolMetalNativeBridge.GalTextureFormat.Rg8Unorm, 2, 1, 1, false),
        Format.R16G16Unorm => (SolMetalNativeBridge.GalTextureFormat.Rg16Unorm, 4, 1, 1, false),
        Format.R16G16Snorm => (SolMetalNativeBridge.GalTextureFormat.Rg16Snorm, 4, 1, 1, false),
        Format.R16G16Float => (SolMetalNativeBridge.GalTextureFormat.Rg16Float, 4, 1, 1, false),
        Format.R32G32Float => (SolMetalNativeBridge.GalTextureFormat.Rg32Float, 8, 1, 1, false),
        Format.R11G11B10Float => (SolMetalNativeBridge.GalTextureFormat.Rg11B10Float, 4, 1, 1, false),
        Format.R10G10B10A2Unorm => (SolMetalNativeBridge.GalTextureFormat.Rgb10A2Unorm, 4, 1, 1, false),
        Format.R10G10B10A2Uint => (SolMetalNativeBridge.GalTextureFormat.Rgb10A2Uint, 4, 1, 1, false),
        Format.R9G9B9E5Float => (SolMetalNativeBridge.GalTextureFormat.Rgb9E5Float, 4, 1, 1, false),
        Format.B10G10R10A2Unorm => (SolMetalNativeBridge.GalTextureFormat.Bgr10A2Unorm, 4, 1, 1, false),
        Format.R8G8B8A8Unorm => (SolMetalNativeBridge.GalTextureFormat.Rgba8Unorm, 4, 1, 1, false),
        Format.B8G8R8A8Unorm => (SolMetalNativeBridge.GalTextureFormat.Bgra8Unorm, 4, 1, 1, false),
        Format.R8G8B8A8Srgb => (SolMetalNativeBridge.GalTextureFormat.Rgba8Srgb, 4, 1, 1, false),
        Format.B8G8R8A8Srgb => (SolMetalNativeBridge.GalTextureFormat.Bgra8Srgb, 4, 1, 1, false),
        Format.R16G16B16A16Float => (SolMetalNativeBridge.GalTextureFormat.Rgba16Float, 8, 1, 1, false),
        Format.R16G16B16A16Unorm => (SolMetalNativeBridge.GalTextureFormat.Rgba16Unorm, 8, 1, 1, false),
        Format.R16G16B16A16Uint => (SolMetalNativeBridge.GalTextureFormat.Rgba16Uint, 8, 1, 1, false),
        Format.R32G32B32A32Float => (SolMetalNativeBridge.GalTextureFormat.Rgba32Float, 16, 1, 1, false),
        Format.R32G32B32A32Uint => (SolMetalNativeBridge.GalTextureFormat.Rgba32Uint, 16, 1, 1, false),
        Format.D32Float => (SolMetalNativeBridge.GalTextureFormat.Depth32Float, 4, 1, 1, true),
        Format.D16Unorm => (SolMetalNativeBridge.GalTextureFormat.Depth16Unorm, 2, 1, 1, true),
        Format.D24UnormS8Uint => (SolMetalNativeBridge.GalTextureFormat.D24UnormStencil8, 4, 1, 1, true),
        Format.D32FloatS8Uint => (SolMetalNativeBridge.GalTextureFormat.Depth32FloatStencil8, 8, 1, 1, true),
        Format.Bc1RgbaUnorm => (SolMetalNativeBridge.GalTextureFormat.Bc1RgbaUnorm, 8, 4, 4, false),
        Format.Bc1RgbaSrgb => (SolMetalNativeBridge.GalTextureFormat.Bc1RgbaSrgb, 8, 4, 4, false),
        Format.Bc2Unorm => (SolMetalNativeBridge.GalTextureFormat.Bc2RgbaUnorm, 16, 4, 4, false),
        Format.Bc2Srgb => (SolMetalNativeBridge.GalTextureFormat.Bc2RgbaSrgb, 16, 4, 4, false),
        Format.Bc3Unorm => (SolMetalNativeBridge.GalTextureFormat.Bc3RgbaUnorm, 16, 4, 4, false),
        Format.Bc3Srgb => (SolMetalNativeBridge.GalTextureFormat.Bc3RgbaSrgb, 16, 4, 4, false),
        Format.Bc4Unorm => (SolMetalNativeBridge.GalTextureFormat.Bc4RUnorm, 8, 4, 4, false),
        Format.Bc4Snorm => (SolMetalNativeBridge.GalTextureFormat.Bc4RSnorm, 8, 4, 4, false),
        Format.Bc5Unorm => (SolMetalNativeBridge.GalTextureFormat.Bc5RgUnorm, 16, 4, 4, false),
        Format.Bc5Snorm => (SolMetalNativeBridge.GalTextureFormat.Bc5RgSnorm, 16, 4, 4, false),
        Format.Bc6HSfloat => (SolMetalNativeBridge.GalTextureFormat.Bc6hRgbFloat, 16, 4, 4, false),
        Format.Bc6HUfloat => (SolMetalNativeBridge.GalTextureFormat.Bc6hRgbUfloat, 16, 4, 4, false),
        Format.Bc7Unorm => (SolMetalNativeBridge.GalTextureFormat.Bc7RgbaUnorm, 16, 4, 4, false),
        Format.Bc7Srgb => (SolMetalNativeBridge.GalTextureFormat.Bc7RgbaSrgb, 16, 4, 4, false),
        _ => throw Unsupported($"texture format {format}"),
    };

    private static SolMetalNativeBridge.GalVertexFormat MapVertexFormat(
        Format format
    ) => format switch
    {
        Format.R8Unorm => SolMetalNativeBridge.GalVertexFormat.UcharNormalized,
        Format.R8Snorm => SolMetalNativeBridge.GalVertexFormat.CharNormalized,
        Format.R8Uint => SolMetalNativeBridge.GalVertexFormat.Uchar,
        Format.R8Sint => SolMetalNativeBridge.GalVertexFormat.Char,
        Format.R16Float => SolMetalNativeBridge.GalVertexFormat.Half,
        Format.R16Unorm => SolMetalNativeBridge.GalVertexFormat.UshortNormalized,
        Format.R16Snorm => SolMetalNativeBridge.GalVertexFormat.ShortNormalized,
        Format.R16Uint => SolMetalNativeBridge.GalVertexFormat.Ushort,
        Format.R16Sint => SolMetalNativeBridge.GalVertexFormat.Short,
        Format.R32Float => SolMetalNativeBridge.GalVertexFormat.Float,
        Format.R32Sint => SolMetalNativeBridge.GalVertexFormat.Int,
        Format.R32G32Float => SolMetalNativeBridge.GalVertexFormat.Float2,
        Format.R32G32Sint => SolMetalNativeBridge.GalVertexFormat.Int2,
        Format.R32G32B32Float => SolMetalNativeBridge.GalVertexFormat.Float3,
        Format.R32G32B32Uint => SolMetalNativeBridge.GalVertexFormat.Uint3,
        Format.R32G32B32Sint => SolMetalNativeBridge.GalVertexFormat.Int3,
        Format.R32G32B32A32Float => SolMetalNativeBridge.GalVertexFormat.Float4,
        Format.R32G32B32A32Sint => SolMetalNativeBridge.GalVertexFormat.Int4,
        Format.R8G8Unorm =>
            SolMetalNativeBridge.GalVertexFormat.Uchar2Normalized,
        Format.R8G8Snorm =>
            SolMetalNativeBridge.GalVertexFormat.Char2Normalized,
        Format.R8G8Uint => SolMetalNativeBridge.GalVertexFormat.Uchar2,
        Format.R8G8Sint => SolMetalNativeBridge.GalVertexFormat.Char2,
        Format.R8G8B8Unorm =>
            SolMetalNativeBridge.GalVertexFormat.Uchar3Normalized,
        Format.R8G8B8Snorm =>
            SolMetalNativeBridge.GalVertexFormat.Char3Normalized,
        Format.R8G8B8Uint => SolMetalNativeBridge.GalVertexFormat.Uchar3,
        Format.R8G8B8Sint => SolMetalNativeBridge.GalVertexFormat.Char3,
        Format.R16G16Float => SolMetalNativeBridge.GalVertexFormat.Half2,
        Format.R16G16B16Float => SolMetalNativeBridge.GalVertexFormat.Half3,
        Format.R16G16B16A16Float => SolMetalNativeBridge.GalVertexFormat.Half4,
        Format.R8G8B8A8Unorm =>
            SolMetalNativeBridge.GalVertexFormat.Uchar4Normalized,
        Format.R8G8B8A8Snorm =>
            SolMetalNativeBridge.GalVertexFormat.Char4Normalized,
        Format.R8G8B8A8Uint => SolMetalNativeBridge.GalVertexFormat.Uchar4,
        Format.R8G8B8A8Sint => SolMetalNativeBridge.GalVertexFormat.Char4,
        Format.R16G16Unorm =>
            SolMetalNativeBridge.GalVertexFormat.Ushort2Normalized,
        Format.R16G16Snorm =>
            SolMetalNativeBridge.GalVertexFormat.Short2Normalized,
        Format.R16G16Uint => SolMetalNativeBridge.GalVertexFormat.Ushort2,
        Format.R16G16Sint => SolMetalNativeBridge.GalVertexFormat.Short2,
        Format.R16G16B16Unorm =>
            SolMetalNativeBridge.GalVertexFormat.Ushort3Normalized,
        Format.R16G16B16Snorm =>
            SolMetalNativeBridge.GalVertexFormat.Short3Normalized,
        Format.R16G16B16Uint => SolMetalNativeBridge.GalVertexFormat.Ushort3,
        Format.R16G16B16Sint => SolMetalNativeBridge.GalVertexFormat.Short3,
        Format.R16G16B16A16Unorm =>
            SolMetalNativeBridge.GalVertexFormat.Ushort4Normalized,
        Format.R16G16B16A16Snorm =>
            SolMetalNativeBridge.GalVertexFormat.Short4Normalized,
        Format.R16G16B16A16Uint => SolMetalNativeBridge.GalVertexFormat.Ushort4,
        Format.R16G16B16A16Sint => SolMetalNativeBridge.GalVertexFormat.Short4,
        Format.R32Uint => SolMetalNativeBridge.GalVertexFormat.Uint,
        Format.R32G32Uint => SolMetalNativeBridge.GalVertexFormat.Uint2,
        Format.R32G32B32A32Uint => SolMetalNativeBridge.GalVertexFormat.Uint4,
        Format.R10G10B10A2Snorm =>
            SolMetalNativeBridge.GalVertexFormat.Int1010102Normalized,
        Format.R10G10B10A2Unorm =>
            SolMetalNativeBridge.GalVertexFormat.Uint1010102Normalized,
        Format.R11G11B10Float =>
            SolMetalNativeBridge.GalVertexFormat.FloatRg11B10,
        Format.R9G9B9E5Float =>
            SolMetalNativeBridge.GalVertexFormat.FloatRgb9E5,
        _ => throw Unsupported($"vertex format {format}"),
    };

    private static SolMetalNativeBridge.GalTextureSwizzle MapTextureSwizzle(
        SwizzleComponent component
    ) => component switch
    {
        SwizzleComponent.Zero => SolMetalNativeBridge.GalTextureSwizzle.Zero,
        SwizzleComponent.One => SolMetalNativeBridge.GalTextureSwizzle.One,
        SwizzleComponent.Red => SolMetalNativeBridge.GalTextureSwizzle.Red,
        SwizzleComponent.Green => SolMetalNativeBridge.GalTextureSwizzle.Green,
        SwizzleComponent.Blue => SolMetalNativeBridge.GalTextureSwizzle.Blue,
        SwizzleComponent.Alpha => SolMetalNativeBridge.GalTextureSwizzle.Alpha,
        _ => throw Unsupported($"texture swizzle {component}"),
    };

    private static bool AreTextureCopyFormatsCompatible(
        SolMetalNativeBridge.GalTextureFormat source,
        SolMetalNativeBridge.GalTextureFormat destination
    ) => source == destination || (source, destination) switch
    {
        (SolMetalNativeBridge.GalTextureFormat.Rgba8Unorm,
         SolMetalNativeBridge.GalTextureFormat.Rgba8Srgb) => true,
        (SolMetalNativeBridge.GalTextureFormat.Rgba8Srgb,
         SolMetalNativeBridge.GalTextureFormat.Rgba8Unorm) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bgra8Unorm,
         SolMetalNativeBridge.GalTextureFormat.Bgra8Srgb) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bgra8Srgb,
         SolMetalNativeBridge.GalTextureFormat.Bgra8Unorm) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bc1RgbaUnorm,
         SolMetalNativeBridge.GalTextureFormat.Bc1RgbaSrgb) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bc1RgbaSrgb,
         SolMetalNativeBridge.GalTextureFormat.Bc1RgbaUnorm) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bc2RgbaUnorm,
         SolMetalNativeBridge.GalTextureFormat.Bc2RgbaSrgb) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bc2RgbaSrgb,
         SolMetalNativeBridge.GalTextureFormat.Bc2RgbaUnorm) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bc3RgbaUnorm,
         SolMetalNativeBridge.GalTextureFormat.Bc3RgbaSrgb) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bc3RgbaSrgb,
         SolMetalNativeBridge.GalTextureFormat.Bc3RgbaUnorm) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bc7RgbaUnorm,
         SolMetalNativeBridge.GalTextureFormat.Bc7RgbaSrgb) => true,
        (SolMetalNativeBridge.GalTextureFormat.Bc7RgbaSrgb,
         SolMetalNativeBridge.GalTextureFormat.Bc7RgbaUnorm) => true,
        _ => false,
    };

    private static SolMetalNativeBridge.GalSamplerAddressMode MapAddressMode(
        AddressMode mode
    ) => mode switch
    {
        AddressMode.ClampToEdge or AddressMode.Clamp =>
            SolMetalNativeBridge.GalSamplerAddressMode.ClampToEdge,
        AddressMode.Repeat => SolMetalNativeBridge.GalSamplerAddressMode.Repeat,
        AddressMode.MirroredRepeat =>
            SolMetalNativeBridge.GalSamplerAddressMode.MirrorRepeat,
        AddressMode.ClampToBorder =>
            SolMetalNativeBridge.GalSamplerAddressMode.ClampToBorder,
        _ => throw Unsupported($"sampler address mode {mode}"),
    };

    private static SolMetalNativeBridge.GalSamplerBorderColor MapBorderColor(
        ColorF color
    )
    {
        static bool Near(float value, float expected) =>
            MathF.Abs(value - expected) <= 0.000001f;
        if (Near(color.Red, 0) && Near(color.Green, 0) &&
            Near(color.Blue, 0))
        {
            if (Near(color.Alpha, 0))
            {
                return SolMetalNativeBridge.GalSamplerBorderColor.TransparentBlack;
            }
            if (Near(color.Alpha, 1))
            {
                return SolMetalNativeBridge.GalSamplerBorderColor.OpaqueBlack;
            }
        }
        if (Near(color.Red, 1) && Near(color.Green, 1) &&
            Near(color.Blue, 1) && Near(color.Alpha, 1))
        {
            return SolMetalNativeBridge.GalSamplerBorderColor.OpaqueWhite;
        }
        throw Unsupported($"custom sampler border color {color}");
    }

    private static SolMetalNativeBridge.GalCompareFunction MapCompare(
        CompareOp op
    ) => op switch
    {
        CompareOp.Never or CompareOp.NeverGl =>
            SolMetalNativeBridge.GalCompareFunction.Never,
        CompareOp.Less or CompareOp.LessGl =>
            SolMetalNativeBridge.GalCompareFunction.Less,
        CompareOp.Equal or CompareOp.EqualGl =>
            SolMetalNativeBridge.GalCompareFunction.Equal,
        CompareOp.LessOrEqual or CompareOp.LessOrEqualGl =>
            SolMetalNativeBridge.GalCompareFunction.LessEqual,
        CompareOp.Greater or CompareOp.GreaterGl =>
            SolMetalNativeBridge.GalCompareFunction.Greater,
        CompareOp.NotEqual or CompareOp.NotEqualGl =>
            SolMetalNativeBridge.GalCompareFunction.NotEqual,
        CompareOp.GreaterOrEqual or CompareOp.GreaterOrEqualGl =>
            SolMetalNativeBridge.GalCompareFunction.GreaterEqual,
        CompareOp.Always or CompareOp.AlwaysGl =>
            SolMetalNativeBridge.GalCompareFunction.Always,
        _ => throw Unsupported($"compare operation {op}"),
    };

    private static SolMetalNativeBridge.GalStencilOperation MapStencil(
        StencilOp op
    ) => op switch
    {
        StencilOp.Keep or StencilOp.KeepGl =>
            SolMetalNativeBridge.GalStencilOperation.Keep,
        StencilOp.Zero or StencilOp.ZeroGl =>
            SolMetalNativeBridge.GalStencilOperation.Zero,
        StencilOp.Replace or StencilOp.ReplaceGl =>
            SolMetalNativeBridge.GalStencilOperation.Replace,
        StencilOp.IncrementAndClamp or StencilOp.IncrementAndClampGl =>
            SolMetalNativeBridge.GalStencilOperation.IncrementClamp,
        StencilOp.DecrementAndClamp or StencilOp.DecrementAndClampGl =>
            SolMetalNativeBridge.GalStencilOperation.DecrementClamp,
        StencilOp.Invert or StencilOp.InvertGl =>
            SolMetalNativeBridge.GalStencilOperation.Invert,
        StencilOp.IncrementAndWrap or StencilOp.IncrementAndWrapGl =>
            SolMetalNativeBridge.GalStencilOperation.IncrementWrap,
        StencilOp.DecrementAndWrap or StencilOp.DecrementAndWrapGl =>
            SolMetalNativeBridge.GalStencilOperation.DecrementWrap,
        _ => throw Unsupported($"stencil operation {op}"),
    };

    private static SolMetalNativeBridge.GalBlendOperation MapBlendOperation(
        BlendOp op
    ) => op switch
    {
        BlendOp.Add or BlendOp.AddGl =>
            SolMetalNativeBridge.GalBlendOperation.Add,
        BlendOp.Subtract or BlendOp.SubtractGl =>
            SolMetalNativeBridge.GalBlendOperation.Subtract,
        BlendOp.ReverseSubtract or BlendOp.ReverseSubtractGl =>
            SolMetalNativeBridge.GalBlendOperation.ReverseSubtract,
        BlendOp.Minimum or BlendOp.MinimumGl =>
            SolMetalNativeBridge.GalBlendOperation.Min,
        BlendOp.Maximum or BlendOp.MaximumGl =>
            SolMetalNativeBridge.GalBlendOperation.Max,
        _ => throw Unsupported($"blend operation {op}"),
    };

    private static SolMetalNativeBridge.GalBlendFactor MapBlendFactor(
        BlendFactor factor
    ) => factor switch
    {
        BlendFactor.Zero or BlendFactor.ZeroGl =>
            SolMetalNativeBridge.GalBlendFactor.Zero,
        BlendFactor.One or BlendFactor.OneGl =>
            SolMetalNativeBridge.GalBlendFactor.One,
        BlendFactor.SrcColor or BlendFactor.SrcColorGl =>
            SolMetalNativeBridge.GalBlendFactor.SourceColor,
        BlendFactor.OneMinusSrcColor or BlendFactor.OneMinusSrcColorGl =>
            SolMetalNativeBridge.GalBlendFactor.OneMinusSourceColor,
        BlendFactor.SrcAlpha or BlendFactor.SrcAlphaGl =>
            SolMetalNativeBridge.GalBlendFactor.SourceAlpha,
        BlendFactor.OneMinusSrcAlpha or BlendFactor.OneMinusSrcAlphaGl =>
            SolMetalNativeBridge.GalBlendFactor.OneMinusSourceAlpha,
        BlendFactor.DstColor or BlendFactor.DstColorGl =>
            SolMetalNativeBridge.GalBlendFactor.DestinationColor,
        BlendFactor.OneMinusDstColor or BlendFactor.OneMinusDstColorGl =>
            SolMetalNativeBridge.GalBlendFactor.OneMinusDestinationColor,
        BlendFactor.DstAlpha or BlendFactor.DstAlphaGl =>
            SolMetalNativeBridge.GalBlendFactor.DestinationAlpha,
        BlendFactor.OneMinusDstAlpha or BlendFactor.OneMinusDstAlphaGl =>
            SolMetalNativeBridge.GalBlendFactor.OneMinusDestinationAlpha,
        BlendFactor.SrcAlphaSaturate or BlendFactor.SrcAlphaSaturateGl =>
            SolMetalNativeBridge.GalBlendFactor.SourceAlphaSaturated,
        BlendFactor.Src1Color or BlendFactor.Src1ColorGl =>
            SolMetalNativeBridge.GalBlendFactor.Source1Color,
        BlendFactor.OneMinusSrc1Color or BlendFactor.OneMinusSrc1ColorGl =>
            SolMetalNativeBridge.GalBlendFactor.OneMinusSource1Color,
        BlendFactor.Src1Alpha or BlendFactor.Src1AlphaGl =>
            SolMetalNativeBridge.GalBlendFactor.Source1Alpha,
        BlendFactor.OneMinusSrc1Alpha or BlendFactor.OneMinusSrc1AlphaGl =>
            SolMetalNativeBridge.GalBlendFactor.OneMinusSource1Alpha,
        BlendFactor.ConstantColor =>
            SolMetalNativeBridge.GalBlendFactor.BlendColor,
        BlendFactor.OneMinusConstantColor =>
            SolMetalNativeBridge.GalBlendFactor.OneMinusBlendColor,
        BlendFactor.ConstantAlpha =>
            SolMetalNativeBridge.GalBlendFactor.BlendAlpha,
        BlendFactor.OneMinusConstantAlpha =>
            SolMetalNativeBridge.GalBlendFactor.OneMinusBlendAlpha,
        _ => throw Unsupported($"blend factor {factor}"),
    };

    private static SolMetalNativeBridge.GalPrimitiveType MapPrimitiveType(
        PrimitiveTopology topology
    ) => topology switch
    {
        PrimitiveTopology.Points => SolMetalNativeBridge.GalPrimitiveType.Point,
        PrimitiveTopology.Lines => SolMetalNativeBridge.GalPrimitiveType.Line,
        PrimitiveTopology.LineStrip =>
            SolMetalNativeBridge.GalPrimitiveType.LineStrip,
        PrimitiveTopology.Triangles =>
            SolMetalNativeBridge.GalPrimitiveType.Triangle,
        PrimitiveTopology.TriangleStrip =>
            SolMetalNativeBridge.GalPrimitiveType.TriangleStrip,
        PrimitiveTopology.QuadStrip =>
            SolMetalNativeBridge.GalPrimitiveType.TriangleStrip,
        PrimitiveTopology.Quads =>
            SolMetalNativeBridge.GalPrimitiveType.Triangle,
        _ => throw Unsupported($"primitive topology {topology}"),
    };

    private static SolMetalNativeBridge.GalPrimitiveTopologyClass
        MapPrimitiveTopologyClass(PrimitiveTopology topology) =>
        topology switch
        {
            PrimitiveTopology.Points =>
                SolMetalNativeBridge.GalPrimitiveTopologyClass.Point,
            PrimitiveTopology.Lines or PrimitiveTopology.LineStrip =>
                SolMetalNativeBridge.GalPrimitiveTopologyClass.Line,
            PrimitiveTopology.Triangles or PrimitiveTopology.TriangleStrip or
            PrimitiveTopology.QuadStrip =>
                SolMetalNativeBridge.GalPrimitiveTopologyClass.Triangle,
            PrimitiveTopology.Quads =>
                SolMetalNativeBridge.GalPrimitiveTopologyClass.Triangle,
            _ => throw Unsupported($"primitive topology {topology}"),
        };

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
    }

    public void Dispose()
    {
        SolMetalCounterEvent[] pendingCounters;
        IntPtr activeCounterQuery;
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }
            _disposed = true;
            pendingCounters = _sampleCounterEvents.ToArray();
            _sampleCounterEvents.Clear();
            activeCounterQuery = _sampleCounterQuery;
            _sampleCounterQuery = IntPtr.Zero;
            foreach (BufferEntry entry in _buffers.Values)
            {
                _session.DestroyBuffer(entry.Native);
            }
            _buffers.Clear();
            foreach (SolMetalGalTexture texture in _textures)
            {
                texture.DestroyFromRenderer();
            }
            _textures.Clear();
            foreach (SolMetalGalSampler sampler in _samplers)
            {
                sampler.DestroyFromRenderer();
            }
            _samplers.Clear();
            foreach (SolMetalGalProgram program in _programs)
            {
                program.DestroyFromRenderer();
            }
            _programs.Clear();
            ProgramCount = 0;
            _syncTimeline.Clear();
            _session.DestroySampler(_dummySampler);
            _session.DestroyTexture(_dummyBufferTexture);
            _session.DestroyTexture(_dummyTexture);
            _session.DestroyBuffer(_zeroVertexBuffer);
            Interlocked.Exchange(ref _screenshotRequested, 0);
        }

        _ = _session.WaitIdle(TimeSpan.FromSeconds(5));
        foreach (SolMetalCounterEvent counter in pendingCounters)
        {
            _session.DestroyVisibilityQuery(counter.Query);
            counter.Dispose();
        }
        _session.DestroyVisibilityQuery(activeCounterQuery);
        _session.Dispose();
        ScreenCaptured = null;
    }

    private enum TextureProbeWriteKind
    {
        None,
        Upload,
        Copy,
        Blit,
        Clear,
        Draw,
        DrawWithClear,
        NonWritingDraw,
        Compute,
    }

    private sealed class TextureProbeState(long id)
    {
        public const int MaximumSampledTextures = 8;
        public const int MaximumRecentColorClears = 16;
        // Frame probes are opt-in and short-lived. Keep enough history to
        // retain the D16 prepass immediately preceding deferred lighting;
        // sixteen records could evict the writer before a screenshot dumped
        // its equality-tested consumers.
        public const int MaximumRecentDraws = 64;
        public long Id { get; } = id;
        public long Uploads;
        public long Copies;
        public long Blits;
        public long Clears;
        public long Draws;
        public long DrawsWithClear;
        public long NonWritingDraws;
        public long Computes;
        public long DepthPasses;
        public long DepthClearPasses;
        public long DepthTestPasses;
        public long DepthWritePasses;
        public int LastDepthLoadAction;
        public long LastDepthClearBits;
        public int LastDepthCompareFunction;
        public int LastDepthWriteEnabled;
        public int LastWriteKind;
        public uint LastColorMask;
        public int LastCullMode;
        public long LastSourceId;
        public TextureProbeState? LastSource;
        public WeakReference<SolMetalGalTexture>? LastSourceTexture;
        public readonly WeakReference<SolMetalGalTexture>?[]
            LastSampledTextures =
                new WeakReference<SolMetalGalTexture>?[
                    MaximumSampledTextures
                ];
        public int LastSampledTextureCount;
        public int LastVertexDummyTextureCount;
        public int LastFragmentDummyTextureCount;
        public int LastVertexDummyBufferCount;
        public int LastFragmentDummyBufferCount;
        public string? LastDrawDetails;
        public WeakReference<SolMetalGalProgram>? LastProgram;
        public ProbeBufferBinding[] LastBufferBindings = [];
        public int LargestElementCount;
        public string? LargestDrawDetails;
        public WeakReference<SolMetalGalProgram>? LargestProgram;
        public ProbeBufferSnapshot[] LargestBufferSnapshots = [];
        public readonly Queue<ProbeDrawRecord> RecentDraws = new();
        public readonly Queue<ProbeColorClearRecord> RecentColorClears = new();
    }

    private readonly record struct ProbeBufferBinding(
        string Label,
        BufferRange Range
    );

    private readonly record struct ProbeBufferSnapshot(
        string Label,
        int RangeSize,
        byte[] Prefix
    );

    private readonly record struct ProbeDrawRecord(
        SolMetalGalProgram? Program,
        string? Details,
        ProbeBufferBinding[] Buffers,
        SolMetalGalTexture[] SampledTextures,
        long TargetViewId,
        string TargetView
    );

    private readonly record struct ProbeColorClearRecord(
        long Presentation,
        long Draws,
        long TargetViewId,
        string TargetView,
        int X,
        int Y,
        int Width,
        int Height,
        uint ComponentMask,
        float Red,
        float Green,
        float Blue,
        float Alpha
    );

    private sealed record TargetedD16WriterProbe(
        long ProgramId,
        long DepthTextureId,
        ulong[] Histogram,
        string CapturePath,
        string SidecarPath
    );

    private sealed record TextureProbeViewLineage(
        long ViewId,
        long RootViewId,
        long ParentViewId,
        int ParentRelativeLevel,
        int ParentRelativeLayer,
        int RootBaseLevel,
        int RootBaseLayer
    );

    private sealed class SolMetalGalTexture : ITexture
    {
        private readonly SolMetalGalRenderer _renderer;
        private readonly TextureCreateInfo _info;
        private readonly SolMetalNativeBridge.GalTextureFormat _nativeFormat;
        private readonly int _bytesPerPixel;
        private readonly bool _depthStencil;
        private readonly TextureProbeState? _probe;
        private readonly TextureProbeViewLineage? _probeView;
        private IntPtr _native;
        private BufferHandle _storageHandle;
        private int _storageOffset;
        private int _storageSize;
        private int _referenceCount = 1;

        public int Width => _info.Width;
        public int Height => _info.Height;
        public int Layers => _info.GetLayers();
        public int Levels => _info.Levels;
        public int Samples => _info.Samples;
        public int BlockWidth => _info.BlockWidth;
        public int BlockHeight => _info.BlockHeight;
        public int BytesPerPixel => _bytesPerPixel;
        public int BaseLevelStride => _info.GetMipStride(0);
        public int BaseLevelSize => _info.GetMipSize(0);
        public Format Format => _info.Format;
        public SwizzleComponent SwizzleR => _info.SwizzleR;
        public bool IsBufferTexture => _info.Target == Target.TextureBuffer;
        public bool IsSingleLevelTexture2D =>
            _info.Target == Target.Texture2D && _info.Levels == 1 &&
            _info.GetLayers() == 1 && _info.Samples == 1;
        public bool IsBgra => _info.Format.IsBgr;
        public bool CanProbeColor =>
            _info.Target == Target.Texture2D && !_depthStencil &&
            _bytesPerPixel == 4 && _info.BlockWidth == 1 &&
            _info.BlockHeight == 1;
        public bool CanProbeRgba8 => CanProbeColor && _nativeFormat is
            SolMetalNativeBridge.GalTextureFormat.Rgba8Unorm or
            SolMetalNativeBridge.GalTextureFormat.Rgba8Srgb or
            SolMetalNativeBridge.GalTextureFormat.Bgra8Unorm or
            SolMetalNativeBridge.GalTextureFormat.Bgra8Srgb;
        public bool CanProbeRaw => !IsBufferTexture && !_depthStencil &&
            _info.Samples == 1;
        public bool CanProbeDepth32 => _depthStencil &&
            IsSingleLevelTexture2D &&
            _nativeFormat ==
                SolMetalNativeBridge.GalTextureFormat.Depth32Float &&
            _renderer._session.SupportsDepth32ProbeReadback;
        private bool CanReadDepthStencil => _depthStencil &&
            !IsBufferTexture && _info.Samples == 1 &&
            _info.Target != Target.Texture3D &&
            (_nativeFormat is
                SolMetalNativeBridge.GalTextureFormat.Depth16Unorm or
                SolMetalNativeBridge.GalTextureFormat.Depth32Float or
                SolMetalNativeBridge.GalTextureFormat.D24UnormStencil8 or
                SolMetalNativeBridge.GalTextureFormat.Depth32FloatStencil8) &&
            _renderer._session.SupportsDepthStencilReadback;

        public SolMetalGalTexture(
            SolMetalGalRenderer renderer,
            IntPtr native,
            TextureCreateInfo info,
            SolMetalNativeBridge.GalTextureFormat nativeFormat,
            int bytesPerPixel,
            bool depthStencil,
            TextureProbeState? probe = null,
            long probeRootViewId = 0,
            long probeParentViewId = 0,
            int probeParentRelativeLevel = 0,
            int probeParentRelativeLayer = 0,
            int probeRootBaseLevel = 0,
            int probeRootBaseLayer = 0
        )
        {
            _renderer = renderer;
            _native = native;
            _info = info;
            _nativeFormat = nativeFormat;
            _bytesPerPixel = bytesPerPixel;
            _depthStencil = depthStencil;
            _probe = renderer._frameProbeEnabled
                ? probe ?? new TextureProbeState(
                    Interlocked.Increment(ref renderer._nextTextureProbeId)
                )
                : null;
            if (_probe is not null)
            {
                long viewId = Interlocked.Increment(
                    ref renderer._nextTextureProbeViewId
                );
                _probeView = new TextureProbeViewLineage(
                    viewId,
                    probeRootViewId == 0 ? viewId : probeRootViewId,
                    probeParentViewId,
                    probeParentRelativeLevel,
                    probeParentRelativeLayer,
                    probeRootBaseLevel,
                    probeRootBaseLayer
                );
            }
        }

        public void MarkProbeWrite(
            TextureProbeWriteKind kind,
            SolMetalGalTexture? source = null
        )
        {
            if (_probe is not TextureProbeState probe)
            {
                return;
            }

            switch (kind)
            {
                case TextureProbeWriteKind.Upload:
                    Interlocked.Increment(ref probe.Uploads);
                    break;
                case TextureProbeWriteKind.Copy:
                    Interlocked.Increment(ref probe.Copies);
                    break;
                case TextureProbeWriteKind.Blit:
                    Interlocked.Increment(ref probe.Blits);
                    break;
                case TextureProbeWriteKind.Clear:
                    Interlocked.Increment(ref probe.Clears);
                    break;
                case TextureProbeWriteKind.Draw:
                    Interlocked.Increment(ref probe.Draws);
                    break;
                case TextureProbeWriteKind.DrawWithClear:
                    Interlocked.Increment(ref probe.DrawsWithClear);
                    break;
                case TextureProbeWriteKind.NonWritingDraw:
                    Interlocked.Increment(ref probe.NonWritingDraws);
                    break;
                case TextureProbeWriteKind.Compute:
                    Interlocked.Increment(ref probe.Computes);
                    break;
            }

            Volatile.Write(
                ref probe.LastSourceId,
                source?._probe?.Id ?? 0
            );
            Volatile.Write(ref probe.LastSource, source?._probe);
            WeakReference<SolMetalGalTexture>? previousSource =
                Volatile.Read(ref probe.LastSourceTexture);
            if (source is null)
            {
                Volatile.Write(ref probe.LastSourceTexture, null);
            }
            else if (previousSource is null ||
                     !previousSource.TryGetTarget(out SolMetalGalTexture? prior) ||
                     !ReferenceEquals(prior, source))
            {
                Volatile.Write(
                    ref probe.LastSourceTexture,
                    new WeakReference<SolMetalGalTexture>(source)
                );
            }
            Volatile.Write(ref probe.LastWriteKind, (int)kind);
        }

        public void MarkProbeColorClear(
            Rectangle<int> region,
            uint componentMask,
            ColorF color
        )
        {
            if (_probe is not TextureProbeState probe)
            {
                return;
            }
            MarkProbeWrite(TextureProbeWriteKind.Clear);
            lock (probe.RecentColorClears)
            {
                probe.RecentColorClears.Enqueue(new ProbeColorClearRecord(
                    Interlocked.Read(ref _renderer._presentedFrameCount),
                    Interlocked.Read(ref probe.Draws) +
                        Interlocked.Read(ref probe.DrawsWithClear),
                    ProbeViewId,
                    DescribeProbeViewIdentity(),
                    region.X,
                    region.Y,
                    region.Width,
                    region.Height,
                    componentMask,
                    color.Red,
                    color.Green,
                    color.Blue,
                    color.Alpha
                ));
                while (probe.RecentColorClears.Count >
                       TextureProbeState.MaximumRecentColorClears)
                {
                    _ = probe.RecentColorClears.Dequeue();
                }
            }
        }

        public ProbeColorClearRecord[] GetRecentProbeColorClears()
        {
            if (_probe is not TextureProbeState probe)
            {
                return [];
            }
            lock (probe.RecentColorClears)
            {
                return probe.RecentColorClears.ToArray();
            }
        }

        public void MarkProbeDraw(
            SolMetalNativeBridge.GalRenderLoadAction loadAction,
            uint colorMask,
            SolMetalNativeBridge.GalCullMode cullMode,
            int vertexDummyTextureCount,
            int fragmentDummyTextureCount,
            int vertexDummyBufferCount,
            int fragmentDummyBufferCount,
            string? drawDetails,
            SolMetalGalProgram? program,
            ProbeBufferBinding[] bufferBindings,
            int elementCount,
            SolMetalGalTexture[] sampledTextures
        )
        {
            if (_probe is TextureProbeState probe)
            {
                Volatile.Write(ref probe.LastColorMask, colorMask);
                Volatile.Write(ref probe.LastCullMode, (int)cullMode);
                Volatile.Write(
                    ref probe.LastVertexDummyTextureCount,
                    vertexDummyTextureCount
                );
                Volatile.Write(
                    ref probe.LastFragmentDummyTextureCount,
                    fragmentDummyTextureCount
                );
                Volatile.Write(
                    ref probe.LastVertexDummyBufferCount,
                    vertexDummyBufferCount
                );
                Volatile.Write(
                    ref probe.LastFragmentDummyBufferCount,
                    fragmentDummyBufferCount
                );
                Volatile.Write(ref probe.LastDrawDetails, drawDetails);
                Volatile.Write(ref probe.LastBufferBindings, bufferBindings);
                WeakReference<SolMetalGalProgram>? previousProgram =
                    Volatile.Read(ref probe.LastProgram);
                if (program is null)
                {
                    Volatile.Write(ref probe.LastProgram, null);
                }
                else if (previousProgram is null ||
                         !previousProgram.TryGetTarget(
                             out SolMetalGalProgram? priorProgram
                         ) ||
                         !ReferenceEquals(priorProgram, program))
                {
                    Volatile.Write(
                        ref probe.LastProgram,
                        new WeakReference<SolMetalGalProgram>(program)
                    );
                }
                if (elementCount > probe.LargestElementCount)
                {
                    probe.LargestElementCount = elementCount;
                    probe.LargestDrawDetails = drawDetails;
                    List<ProbeBufferSnapshot> snapshots = [];
                    foreach (ProbeBufferBinding binding in bufferBindings)
                    {
                        try
                        {
                            snapshots.Add(new ProbeBufferSnapshot(
                                binding.Label,
                                binding.Range.Size,
                                ReadProbeBuffer(
                                    binding.Range,
                                    binding.Label.Contains(
                                        "StorageBuffer",
                                        StringComparison.Ordinal
                                    ) ? 16384 : 4096
                                )
                            ));
                        }
                        catch (Exception exception)
                        {
                            Logger.Warning?.Print(
                                LogClass.Gpu,
                                $"SolMetal could not snapshot largest-draw " +
                                $"buffer {binding.Label}: {exception.Message}"
                            );
                        }
                    }
                    probe.LargestBufferSnapshots = snapshots.ToArray();
                    probe.LargestProgram = program is null
                        ? null
                        : new WeakReference<SolMetalGalProgram>(program);
                }
                lock (probe.RecentDraws)
                {
                    probe.RecentDraws.Enqueue(new ProbeDrawRecord(
                        program,
                        drawDetails,
                        bufferBindings,
                        sampledTextures,
                        ProbeViewId,
                        DescribeProbeViewIdentity()
                    ));
                    while (probe.RecentDraws.Count >
                           TextureProbeState.MaximumRecentDraws)
                    {
                        _ = probe.RecentDraws.Dequeue();
                    }
                }
            }
            bool cannotWrite = colorMask == 0 ||
                cullMode == SolMetalNativeBridge.GalCullMode.FrontAndBack;
            MarkProbeWrite(
                loadAction == SolMetalNativeBridge.GalRenderLoadAction.Clear
                    ? TextureProbeWriteKind.DrawWithClear
                    : cannotWrite
                        ? TextureProbeWriteKind.NonWritingDraw
                        : TextureProbeWriteKind.Draw
            );
        }

        public void SetProbeSampledTexture(
            int index,
            SolMetalGalTexture texture
        )
        {
            if (_probe is not TextureProbeState probe ||
                (uint)index >= TextureProbeState.MaximumSampledTextures)
            {
                return;
            }
            WeakReference<SolMetalGalTexture>? existing =
                probe.LastSampledTextures[index];
            if (existing is null ||
                !existing.TryGetTarget(out SolMetalGalTexture? prior) ||
                !ReferenceEquals(prior, texture))
            {
                probe.LastSampledTextures[index] =
                    new WeakReference<SolMetalGalTexture>(texture);
            }
        }

        public void CompleteProbeSampledTextures(int count)
        {
            if (_probe is not TextureProbeState probe)
            {
                return;
            }
            int bounded = Math.Clamp(
                count,
                0,
                TextureProbeState.MaximumSampledTextures
            );
            for (int index = bounded;
                 index < probe.LastSampledTextures.Length;
                 index++)
            {
                probe.LastSampledTextures[index] = null;
            }
            Volatile.Write(ref probe.LastSampledTextureCount, bounded);
        }

        public SolMetalGalTexture[] GetProbeSampledTextures()
        {
            if (_probe is not TextureProbeState probe)
            {
                return [];
            }
            int count = Math.Clamp(
                Volatile.Read(ref probe.LastSampledTextureCount),
                0,
                probe.LastSampledTextures.Length
            );
            List<SolMetalGalTexture> textures = new(count);
            for (int index = 0; index < count; index++)
            {
                if (probe.LastSampledTextures[index] is { } weak &&
                    weak.TryGetTarget(out SolMetalGalTexture? texture))
                {
                    textures.Add(texture);
                }
            }
            return textures.ToArray();
        }

        public long ProbeId => _probe?.Id ?? 0;
        public long ProbeViewId => _probeView?.ViewId ?? 0;
        public long ProbeColorDraws => _probe is TextureProbeState probe
            ? Interlocked.Read(ref probe.Draws) +
                Interlocked.Read(ref probe.DrawsWithClear)
            : 0;
        public long ProbeColorClears => _probe is TextureProbeState probe
            ? Interlocked.Read(ref probe.Clears) +
                Interlocked.Read(ref probe.DrawsWithClear)
            : 0;
        public int GetProbeSliceCount(int level)
        {
            if (level < 0 || level >= _info.Levels)
            {
                throw new ArgumentOutOfRangeException(nameof(level));
            }
            return _info.Target == Target.Texture3D
                ? Math.Max(1, _info.Depth >> level)
                : _info.GetLayers();
        }
        public int GetProbeSubresourceSize(int level)
        {
            if (level < 0 || level >= _info.Levels)
            {
                throw new ArgumentOutOfRangeException(nameof(level));
            }
            int mipHeight = Math.Max(1, _info.Height >> level);
            int blockRows = checked(
                (mipHeight + _info.BlockHeight - 1) / _info.BlockHeight
            );
            return checked(_info.GetMipStride(level) * blockRows);
        }
        public long ProbeDepthPasses => _probe is TextureProbeState probe
            ? Interlocked.Read(ref probe.DepthPasses)
            : 0;
        public long ProbeDepthClearPasses => _probe is TextureProbeState probe
            ? Interlocked.Read(ref probe.DepthClearPasses)
            : 0;

        public void MarkProbeDepthPass(
            SolMetalNativeBridge.GalRenderLoadAction loadAction,
            double clearDepth,
            SolMetalNativeBridge.GalCompareFunction compareFunction,
            bool writeEnabled
        )
        {
            if (_probe is not TextureProbeState probe)
            {
                return;
            }
            Interlocked.Increment(ref probe.DepthPasses);
            if (loadAction == SolMetalNativeBridge.GalRenderLoadAction.Clear)
            {
                Interlocked.Increment(ref probe.DepthClearPasses);
            }
            if (compareFunction != SolMetalNativeBridge.GalCompareFunction.Always)
            {
                Interlocked.Increment(ref probe.DepthTestPasses);
            }
            if (writeEnabled)
            {
                Interlocked.Increment(ref probe.DepthWritePasses);
            }
            Volatile.Write(ref probe.LastDepthLoadAction, (int)loadAction);
            Interlocked.Exchange(
                ref probe.LastDepthClearBits,
                BitConverter.DoubleToInt64Bits(clearDepth)
            );
            Volatile.Write(
                ref probe.LastDepthCompareFunction,
                (int)compareFunction
            );
            Volatile.Write(
                ref probe.LastDepthWriteEnabled,
                writeEnabled ? 1 : 0
            );
            MarkProbeWrite(
                loadAction == SolMetalNativeBridge.GalRenderLoadAction.Clear
                    ? TextureProbeWriteKind.DrawWithClear
                    : writeEnabled
                        ? TextureProbeWriteKind.Draw
                        : TextureProbeWriteKind.NonWritingDraw
            );
        }

        public void MarkProbeDepthClear(double clearDepth, bool depthMask)
        {
            if (_probe is not TextureProbeState probe)
            {
                return;
            }
            if (depthMask)
            {
                Interlocked.Increment(ref probe.DepthClearPasses);
                Volatile.Write(
                    ref probe.LastDepthLoadAction,
                    (int)SolMetalNativeBridge.GalRenderLoadAction.Clear
                );
                Interlocked.Exchange(
                    ref probe.LastDepthClearBits,
                    BitConverter.DoubleToInt64Bits(clearDepth)
                );
            }
            MarkProbeWrite(TextureProbeWriteKind.Clear);
        }

        public string DescribeDepthProbe()
        {
            if (_probe is not TextureProbeState probe)
            {
                return $"{_info.Format}/{_nativeFormat} {Width}x{Height}";
            }
            double clearDepth = BitConverter.Int64BitsToDouble(
                Interlocked.Read(ref probe.LastDepthClearBits)
            );
            return $"#{probe.Id}:{_info.Format}/{_nativeFormat}:" +
                $"{Width}x{Height}:load=" +
                $"{(SolMetalNativeBridge.GalRenderLoadAction)Volatile.Read(ref probe.LastDepthLoadAction)}:" +
                $"clear={clearDepth:0.######}:compare=" +
                $"{(SolMetalNativeBridge.GalCompareFunction)Volatile.Read(ref probe.LastDepthCompareFunction)}:" +
                $"write={Volatile.Read(ref probe.LastDepthWriteEnabled) != 0}:" +
                $"passes={Interlocked.Read(ref probe.DepthPasses)}:" +
                $"clear-passes={Interlocked.Read(ref probe.DepthClearPasses)}:" +
                $"tested={Interlocked.Read(ref probe.DepthTestPasses)}:" +
                $"written={Interlocked.Read(ref probe.DepthWritePasses)}";
        }

        public SolMetalGalTexture? GetProbeSource()
        {
            WeakReference<SolMetalGalTexture>? source = _probe is null
                ? null
                : Volatile.Read(ref _probe.LastSourceTexture);
            return source is not null && source.TryGetTarget(out var target)
                ? target
                : null;
        }

        public SolMetalGalProgram? GetProbeProgram()
        {
            WeakReference<SolMetalGalProgram>? program = _probe is null
                ? null
                : Volatile.Read(ref _probe.LastProgram);
            return program is not null && program.TryGetTarget(out var target)
                ? target
                : null;
        }

        public ProbeBufferBinding[] GetProbeBufferBindings() =>
            _probe is null
                ? []
                : Volatile.Read(ref _probe.LastBufferBindings);

        public (
            int ElementCount,
            string? Details,
            SolMetalGalProgram? Program,
            ProbeBufferSnapshot[] Buffers
        ) GetLargestProbeDraw()
        {
            if (_probe is null)
            {
                return (0, null, null, []);
            }
            WeakReference<SolMetalGalProgram>? program =
                _probe.LargestProgram;
            return (
                _probe.LargestElementCount,
                _probe.LargestDrawDetails,
                program is not null &&
                    program.TryGetTarget(out SolMetalGalProgram? target)
                        ? target
                        : null,
                _probe.LargestBufferSnapshots
            );
        }

        public ProbeDrawRecord[] GetRecentProbeDraws()
        {
            if (_probe is null)
            {
                return [];
            }
            lock (_probe.RecentDraws)
            {
                return _probe.RecentDraws.ToArray();
            }
        }

        public byte[] ReadProbeBuffer(BufferRange range, int maximumBytes)
        {
            int length = Math.Min(range.Size, maximumBytes);
            if (length <= 0)
            {
                return [];
            }
            using PinnedSpan<byte> data = _renderer.GetBufferData(
                range.Handle,
                range.Offset,
                length
            );
            return data.Get().ToArray();
        }

        public string DescribeProbe()
        {
            if (_probe is not TextureProbeState probe)
            {
                return "texture provenance disabled";
            }

            TextureProbeWriteKind last = (TextureProbeWriteKind)Volatile.Read(
                ref probe.LastWriteKind
            );
            long sourceId = Volatile.Read(ref probe.LastSourceId);
            string source = sourceId == 0 ? string.Empty : $" from #{sourceId}";
            string description =
                $"texture #{probe.Id}/view #{_probeView?.ViewId ?? 0} " +
                $"(root-view #{_probeView?.RootViewId ?? 0}, parent-view " +
                $"#{_probeView?.ParentViewId ?? 0}, parent-base=mip" +
                $"{_probeView?.ParentRelativeLevel ?? 0}/layer" +
                $"{_probeView?.ParentRelativeLayer ?? 0}, root-base=mip" +
                $"{_probeView?.RootBaseLevel ?? 0}/layer" +
                $"{_probeView?.RootBaseLayer ?? 0}) " +
                $"{_info.Target} {_info.Format} " +
                $"{Width}x{Height}, layers={Layers}, levels={_info.Levels}, " +
                $"samples={_info.Samples}, swizzle=" +
                $"{_info.SwizzleR}/{_info.SwizzleG}/" +
                $"{_info.SwizzleB}/{_info.SwizzleA}; writes: upload=" +
                $"{Interlocked.Read(ref probe.Uploads)}, copy=" +
                $"{Interlocked.Read(ref probe.Copies)}, blit=" +
                $"{Interlocked.Read(ref probe.Blits)}, clear=" +
                $"{Interlocked.Read(ref probe.Clears)}, draw=" +
                $"{Interlocked.Read(ref probe.Draws)}, draw-clear=" +
                $"{Interlocked.Read(ref probe.DrawsWithClear)}, no-write-draw=" +
                $"{Interlocked.Read(ref probe.NonWritingDraws)}, compute=" +
                $"{Interlocked.Read(ref probe.Computes)}; last={last}{source}";
            description += $", last-mask=0x{Volatile.Read(ref probe.LastColorMask):X}, " +
                $"last-cull={(SolMetalNativeBridge.GalCullMode)Volatile.Read(ref probe.LastCullMode)}, " +
                $"sampled={Volatile.Read(ref probe.LastSampledTextureCount)}, " +
                $"dummy-sampled(v/f)=" +
                $"{Volatile.Read(ref probe.LastVertexDummyTextureCount)}/" +
                $"{Volatile.Read(ref probe.LastFragmentDummyTextureCount)}, " +
                $"dummy-buffers(v/f)=" +
                $"{Volatile.Read(ref probe.LastVertexDummyBufferCount)}/" +
                $"{Volatile.Read(ref probe.LastFragmentDummyBufferCount)}";
            string? drawDetails = Volatile.Read(ref probe.LastDrawDetails);
            if (!string.IsNullOrEmpty(drawDetails))
            {
                description += $", draw-state=[{drawDetails}]";
            }
            TextureProbeState? upstream = Volatile.Read(ref probe.LastSource);
            if (upstream is not null)
            {
                TextureProbeWriteKind upstreamLast =
                    (TextureProbeWriteKind)Volatile.Read(
                        ref upstream.LastWriteKind
                    );
                description += $"; source #{upstream.Id} writes: upload=" +
                    $"{Interlocked.Read(ref upstream.Uploads)}, copy=" +
                    $"{Interlocked.Read(ref upstream.Copies)}, blit=" +
                    $"{Interlocked.Read(ref upstream.Blits)}, clear=" +
                    $"{Interlocked.Read(ref upstream.Clears)}, draw=" +
                    $"{Interlocked.Read(ref upstream.Draws)}, draw-clear=" +
                    $"{Interlocked.Read(ref upstream.DrawsWithClear)}, " +
                    $"no-write-draw={Interlocked.Read(ref upstream.NonWritingDraws)}, compute=" +
                    $"{Interlocked.Read(ref upstream.Computes)}, last=" +
                    $"{upstreamLast}, last-mask=" +
                    $"0x{Volatile.Read(ref upstream.LastColorMask):X}, " +
                    $"last-cull=" +
                    $"{(SolMetalNativeBridge.GalCullMode)Volatile.Read(ref upstream.LastCullMode)}, " +
                    $"sampled={Volatile.Read(ref upstream.LastSampledTextureCount)}, " +
                    $"dummy-sampled(v/f)=" +
                    $"{Volatile.Read(ref upstream.LastVertexDummyTextureCount)}/" +
                    $"{Volatile.Read(ref upstream.LastFragmentDummyTextureCount)}, " +
                    $"dummy-buffers(v/f)=" +
                    $"{Volatile.Read(ref upstream.LastVertexDummyBufferCount)}/" +
                    $"{Volatile.Read(ref upstream.LastFragmentDummyBufferCount)}";
                string? upstreamDrawDetails = Volatile.Read(
                    ref upstream.LastDrawDetails
                );
                if (!string.IsNullOrEmpty(upstreamDrawDetails))
                {
                    description += $", draw-state=[{upstreamDrawDetails}]";
                }
            }
            return description;
        }

        public string DescribeProbeViewIdentity() =>
            $"storage #{ProbeId}/view #{_probeView?.ViewId ?? 0} " +
            $"(root-view #{_probeView?.RootViewId ?? 0}, parent-view " +
            $"#{_probeView?.ParentViewId ?? 0}, parent-base=mip" +
            $"{_probeView?.ParentRelativeLevel ?? 0}/layer" +
            $"{_probeView?.ParentRelativeLayer ?? 0}, root-base=mip" +
            $"{_probeView?.RootBaseLevel ?? 0}/layer" +
            $"{_probeView?.RootBaseLayer ?? 0}) {_info.Target} " +
            $"{_info.Format} {Width}x{Height}, layers={Layers}, " +
            $"levels={Levels}, samples={Samples}";

        public void CopyTo(ITexture destination, int firstLayer, int firstLevel)
        {
            if (destination is not SolMetalGalTexture target ||
                firstLayer < 0 || firstLevel < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(firstLayer));
            }
            if (_info.Target == Target.Texture3D &&
                target._info.Target == Target.Texture3D &&
                firstLayer == 0 && firstLevel == 0 &&
                _info.Width == target._info.Width &&
                _info.Height == target._info.Height &&
                _info.Depth == target._info.Depth &&
                _info.Levels == target._info.Levels &&
                _info.Samples == target._info.Samples &&
                AreTextureCopyFormatsCompatible(
                    _nativeFormat,
                    target._nativeFormat
                ))
            {
                lock (_renderer._gate)
                {
                    _renderer.ThrowIfDisposed();
                    _renderer._session.CopyTexture(
                        RequireNative(),
                        target.RequireNative()
                    );
                }
                target.MarkProbeWrite(TextureProbeWriteKind.Copy, this);
                return;
            }
            int layers = Math.Min(_info.GetLayers(), target._info.GetLayers() - firstLayer);
            int levels = Math.Min(_info.Levels, target._info.Levels - firstLevel);
            if (layers <= 0 || levels <= 0)
            {
                throw Unsupported(
                    $"texture copy destination layer {firstLayer}, mip {firstLevel}"
                );
            }
            for (int level = 0; level < levels; level++)
            {
                for (int layer = 0; layer < layers; layer++)
                {
                    CopyTo(target, layer, firstLayer + layer, level, firstLevel + level);
                }
            }
        }

        public void CopyTo(
            ITexture destination,
            int srcLayer,
            int dstLayer,
            int srcLevel,
            int dstLevel
        )
        {
            if (destination is not SolMetalGalTexture target)
            {
                throw new ArgumentException(
                    "Texture does not belong to SolMetal.",
                    nameof(destination)
                );
            }
            int sourceWidth = srcLevel >= 0 && srcLevel < _info.Levels
                ? Math.Max(1, Width >> srcLevel)
                : 0;
            int sourceHeight = srcLevel >= 0 && srcLevel < _info.Levels
                ? Math.Max(1, Height >> srcLevel)
                : 0;
            int destinationWidth = dstLevel >= 0 && dstLevel < target._info.Levels
                ? Math.Max(1, target.Width >> dstLevel)
                : 0;
            int destinationHeight = dstLevel >= 0 && dstLevel < target._info.Levels
                ? Math.Max(1, target.Height >> dstLevel)
                : 0;
            int sourceSlices = srcLevel >= 0 && srcLevel < _info.Levels &&
                _info.Target == Target.Texture3D
                ? Math.Max(1, _info.Depth >> srcLevel)
                : _info.GetLayers();
            int destinationSlices = dstLevel >= 0 &&
                dstLevel < target._info.Levels &&
                target._info.Target == Target.Texture3D
                ? Math.Max(1, target._info.Depth >> dstLevel)
                : target._info.GetLayers();
            if ((_info.Target == Target.Texture3D) !=
                    (target._info.Target == Target.Texture3D) ||
                srcLayer < 0 || srcLayer >= sourceSlices ||
                dstLayer < 0 || dstLayer >= destinationSlices ||
                sourceWidth == 0 || sourceHeight == 0 ||
                destinationWidth == 0 || destinationHeight == 0 ||
                _info.Samples != target._info.Samples)
            {
                throw Unsupported(
                    $"texture subresource copy {_info.Format} layer {srcLayer}, mip " +
                    $"{srcLevel} to {target._info.Format} layer {dstLayer}, mip {dstLevel}"
                );
            }
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                int width = Math.Min(sourceWidth, destinationWidth);
                int height = Math.Min(sourceHeight, destinationHeight);
                if (AreTextureCopyFormatsCompatible(
                        _nativeFormat,
                        target._nativeFormat))
                {
                    _renderer._session.CopyTextureSubresource(
                        RequireNative(),
                        target.RequireNative(),
                        srcLayer,
                        dstLayer,
                        srcLevel,
                        dstLevel,
                        width,
                        height
                    );
                }
                else if (_info.Samples == 1 && target._info.Samples == 1 &&
                         _info.Target != Target.Texture3D &&
                         target._info.Target != Target.Texture3D &&
                         _info.Target != Target.TextureBuffer &&
                         target._info.Target != Target.TextureBuffer &&
                         _nativeFormat ==
                            SolMetalNativeBridge.GalTextureFormat.R32Float &&
                         target._nativeFormat ==
                            SolMetalNativeBridge.GalTextureFormat.Depth32Float)
                {
                    // Metal cannot blit directly between color and depth
                    // textures. The native conversion keeps the selected
                    // R32Float payload GPU-local through an untyped private
                    // buffer, after any pending draw batch.
                    _renderer._session.CopyR32FloatToDepth32(
                        RequireNative(),
                        target.RequireNative(),
                        srcLayer,
                        dstLayer,
                        srcLevel,
                        dstLevel,
                        width,
                        height
                    );
                }
                else if (_info.Samples == 1 && target._info.Samples == 1 &&
                         _info.Target != Target.Texture3D &&
                         target._info.Target != Target.Texture3D &&
                         _nativeFormat ==
                            SolMetalNativeBridge.GalTextureFormat.Depth32Float &&
                         target._nativeFormat ==
                            SolMetalNativeBridge.GalTextureFormat.R32Float)
                {
                    // Metal cannot blit between depth and color attachments,
                    // even though these formats carry the same 32-bit float
                    // payload. Isolate the selected subresources in 2D views
                    // and preserve those float bits through the bridge's
                    // ordered D32 transfer fallback.
                    _renderer._session.CopyDepth32ToR32Float(
                        RequireNative(),
                        target.RequireNative(),
                        srcLayer,
                        dstLayer,
                        srcLevel,
                        dstLevel,
                        width,
                        height
                    );
                }
                else if (_info.Samples == 1 && !_depthStencil &&
                         !target._depthStencil)
                {
                    _renderer._session.BlitTexture(
                        RequireNative(),
                        target.RequireNative(),
                        srcLayer,
                        srcLevel,
                        dstLayer,
                        dstLevel,
                        0,
                        0,
                        width,
                        height,
                        0,
                        0,
                        width,
                        height,
                        false
                    );
                }
                else
                {
                    throw Unsupported(
                        $"texture format conversion {_info.Format} to " +
                        $"{target._info.Format}"
                    );
                }
            }
            target.MarkProbeWrite(
                AreTextureCopyFormatsCompatible(
                    _nativeFormat,
                    target._nativeFormat
                )
                    ? TextureProbeWriteKind.Copy
                    : TextureProbeWriteKind.Blit,
                this
            );
        }

        public void CopyTo(
            ITexture destination,
            Extents2D srcRegion,
            Extents2D dstRegion,
            bool linearFilter
        )
        {
            if (destination is not SolMetalGalTexture target)
            {
                throw new ArgumentException(
                    "Texture does not belong to SolMetal.",
                    nameof(destination)
                );
            }
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                bool fullSource = srcRegion.X1 == 0 && srcRegion.Y1 == 0 &&
                    srcRegion.X2 == Width && srcRegion.Y2 == Height;
                bool fullDestination = dstRegion.X1 == 0 && dstRegion.Y1 == 0 &&
                    dstRegion.X2 == target.Width &&
                    dstRegion.Y2 == target.Height;
                if (fullSource && fullDestination && Width == target.Width &&
                    Height == target.Height && _nativeFormat == target._nativeFormat &&
                    !_depthStencil)
                {
                    _renderer._session.CopyTexture(
                        RequireNative(),
                        target.RequireNative()
                    );
                    target.MarkProbeWrite(TextureProbeWriteKind.Copy, this);
                    return;
                }
                _renderer._session.BlitTexture(
                    RequireNative(),
                    target.RequireNative(),
                    0,
                    0,
                    0,
                    0,
                    srcRegion.X1,
                    srcRegion.Y1,
                    srcRegion.X2,
                    srcRegion.Y2,
                    dstRegion.X1,
                    dstRegion.Y1,
                    dstRegion.X2,
                    dstRegion.Y2,
                    linearFilter
                );
                target.MarkProbeWrite(TextureProbeWriteKind.Blit, this);
            }
        }

        public void CopyTo(BufferRange range, int layer, int level, int stride)
        {
            int slices = level >= 0 && level < _info.Levels &&
                _info.Target == Target.Texture3D
                ? Math.Max(1, _info.Depth >> level)
                : _info.GetLayers();
            if (layer < 0 || layer >= slices ||
                level < 0 || level >= _info.Levels || stride < 0 ||
                _info.Samples != 1 || _depthStencil)
            {
                throw Unsupported(
                    $"texture-to-buffer copy for {_info.Format}, layer {layer}, " +
                    $"mip {level}, samples={_info.Samples}"
                );
            }
            int mipWidth = Math.Max(1, _info.Width >> level);
            int mipHeight = Math.Max(1, _info.Height >> level);
            int blockColumns = checked(
                (mipWidth + _info.BlockWidth - 1) / _info.BlockWidth
            );
            int blockRows = checked(
                (mipHeight + _info.BlockHeight - 1) / _info.BlockHeight
            );
            int tightBytesPerRow = checked(
                blockColumns * _info.BytesPerPixel
            );
            int bytesPerRow = stride == 0
                ? _info.GetMipStride(level)
                : stride;
            if (bytesPerRow < tightBytesPerRow)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(stride),
                    $"Texture row pitch {bytesPerRow} is smaller than {tightBytesPerRow}."
                );
            }
            int required = checked(bytesPerRow * blockRows);
            if (range.Size < required)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(range),
                    $"Texture copy needs {required} buffer bytes, received {range.Size}."
                );
            }
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                BufferEntry destination = _renderer.GetBuffer(
                    range.Handle,
                    range.Offset,
                    required
                );
                _renderer._session.CopyTextureToBuffer(
                    RequireNative(),
                    layer,
                    level,
                    destination.Native,
                    range.Offset,
                    required,
                    bytesPerRow
                );
            }
        }

        public ITexture CreateView(
            TextureCreateInfo info,
            int firstLayer,
            int firstLevel
        )
        {
            if (firstLayer == 0 && firstLevel == 0 && info == _info)
            {
                lock (_renderer._gate)
                {
                    _renderer.ThrowIfDisposed();
                    _ = RequireNative();
                    checked
                    {
                        _referenceCount++;
                    }
                    return this;
                }
            }
            (
                SolMetalNativeBridge.GalTextureFormat nativeFormat,
                int bytesPerPixel,
                int blockWidth,
                int blockHeight,
                bool depthStencil
            ) = MapTextureFormat(info.Format);
            bool validTargetAndDepth =
                (info.Target == Target.Texture2D && info.Depth == 1) ||
                (info.Target == Target.Texture2DArray && info.Depth > 0) ||
                (info.Target == Target.Texture3D && info.Depth > 0) ||
                (info.Target == Target.Cubemap && info.Depth == 6) ||
                (info.Target == Target.CubemapArray && info.Depth > 0 &&
                 info.Depth % 6 == 0);
            int viewLayers = info.GetLayers();
            int sourceLayers = _info.GetLayers();
            bool compatible3DView =
                (info.Target == Target.Texture3D) ==
                    (_info.Target == Target.Texture3D) &&
                (info.Target != Target.Texture3D ||
                 (firstLayer == 0 && firstLevel >= 0 &&
                  info.Depth == Math.Max(1, _info.Depth >> firstLevel)));
            if (firstLayer < 0 || firstLevel < 0 ||
                info.Width != Math.Max(1, Width >> firstLevel) ||
                info.Height != Math.Max(1, Height >> firstLevel) ||
                !validTargetAndDepth ||
                !compatible3DView ||
                firstLayer > sourceLayers - viewLayers ||
                info.Levels <= 0 || firstLevel > _info.Levels - info.Levels ||
                info.Samples != 1 ||
                info.BlockWidth != blockWidth ||
                info.BlockHeight != blockHeight ||
                info.BlockWidth != _info.BlockWidth ||
                info.BlockHeight != _info.BlockHeight ||
                nativeFormat != _nativeFormat ||
                bytesPerPixel != _info.BytesPerPixel ||
                depthStencil != _depthStencil)
            {
                throw Unsupported(
                    $"texture view {_info.Format} {_info.Width}x{_info.Height} " +
                    $"to {info.Format} {info.Width}x{info.Height} at " +
                    $"layer {firstLayer}, mip {firstLevel}"
                );
            }
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                TextureProbeViewLineage? parentLineage = _probeView;
                int rootBaseLevel = checked(
                    (parentLineage?.RootBaseLevel ?? 0) + firstLevel
                );
                int rootBaseLayer = checked(
                    (parentLineage?.RootBaseLayer ?? 0) + firstLayer
                );
                IntPtr nativeView = _renderer._session.CreateTextureView(
                    RequireNative(),
                    nativeFormat,
                    MapTextureSwizzle(info.SwizzleR),
                    MapTextureSwizzle(info.SwizzleG),
                    MapTextureSwizzle(info.SwizzleB),
                    MapTextureSwizzle(info.SwizzleA),
                    MapTextureType(info.Target),
                    firstLevel,
                    info.Levels,
                    firstLayer,
                    viewLayers
                );
                try
                {
                    SolMetalGalTexture view = new(
                        _renderer,
                        nativeView,
                        info,
                        nativeFormat,
                        bytesPerPixel,
                        depthStencil,
                        _probe,
                        parentLineage?.RootViewId ?? 0,
                        parentLineage?.ViewId ?? 0,
                        firstLevel,
                        firstLayer,
                        rootBaseLevel,
                        rootBaseLayer
                    );
                    _renderer._textures.Add(view);
                    return view;
                }
                catch
                {
                    _renderer._session.DestroyTexture(nativeView);
                    throw;
                }
            }
        }

        public PinnedSpan<byte> GetData()
        {
            if (IsBufferTexture)
            {
                return GetData(0, 0);
            }
            bool readableD16 = _depthStencil && IsSingleLevelTexture2D &&
                _nativeFormat ==
                    SolMetalNativeBridge.GalTextureFormat.Depth16Unorm;
            if (_depthStencil && !readableD16 && !CanReadDepthStencil)
            {
                throw Unsupported("depth/stencil texture readback");
            }
            byte[] data = readableD16
                ? ReadSingleLevelD16()
                : CanReadDepthStencil
                    ? ReadAllDepthStencilSubresources()
                    : ReadAllColorSubresources();
            return PinReadback(data);
        }

        public PinnedSpan<byte> GetData(int layer, int level)
        {
            if (IsBufferTexture)
            {
                if (layer != 0 || level != 0 ||
                    _storageHandle == BufferHandle.Null || _storageSize <= 0)
                {
                    throw Unsupported("an unbound or subresource buffer-texture readback");
                }
                return _renderer.GetBufferData(
                    _storageHandle,
                    _storageOffset,
                    _storageSize
                );
            }
            bool readableD16 = _depthStencil && IsSingleLevelTexture2D &&
                _nativeFormat ==
                    SolMetalNativeBridge.GalTextureFormat.Depth16Unorm;
            if (_depthStencil)
            {
                if (readableD16)
                {
                    if (layer != 0 || level != 0)
                    {
                        throw Unsupported("depth/stencil subresource readback");
                    }
                    return PinReadback(ReadSingleLevelD16());
                }
                if (!CanReadDepthStencil)
                {
                    throw Unsupported("depth/stencil subresource readback");
                }
                return PinReadback(
                    ReadDepthStencilSubresource(layer, level)
                );
            }
            return PinReadback(ReadColorSubresource(layer, level));
        }

        private byte[] ReadSingleLevelD16()
        {
            int bytesPerRow = _info.GetMipStride(0);
            byte[] data = new byte[_info.GetMipSize(0)];
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                _renderer._session.DownloadTexture(
                    RequireNative(),
                    data,
                    bytesPerRow
                );
            }
            return data;
        }

        private byte[] ReadAllDepthStencilSubresources()
        {
            int totalBytes = GetTextureDataSize(_info);
            byte[] data = new byte[totalBytes];
            int offset = 0;
            for (int level = 0; level < _info.Levels; level++)
            {
                int subresourceBytes = GetProbeSubresourceSize(level);
                int slices = GetProbeSliceCount(level);
                for (int layer = 0; layer < slices; layer++)
                {
                    DownloadDepthStencilSubresource(
                        layer,
                        level,
                        data.AsSpan(offset, subresourceBytes)
                    );
                    offset = checked(offset + subresourceBytes);
                }
            }
            if (offset != totalBytes)
            {
                throw new InvalidOperationException(
                    $"SolMetal depth/stencil readback planned {offset} " +
                    $"bytes for a {totalBytes}-byte texture."
                );
            }
            return data;
        }

        private byte[] ReadDepthStencilSubresource(int layer, int level)
        {
            int slices = GetProbeSliceCount(level);
            if (layer < 0 || layer >= slices)
            {
                throw new ArgumentOutOfRangeException(nameof(layer));
            }
            int required = GetProbeSubresourceSize(level);
            byte[] data = new byte[required];
            DownloadDepthStencilSubresource(layer, level, data);
            return data;
        }

        private void DownloadDepthStencilSubresource(
            int layer,
            int level,
            Span<byte> destination
        )
        {
            if (level < 0 || level >= _info.Levels)
            {
                throw new ArgumentOutOfRangeException(nameof(level));
            }
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                _renderer._session.DownloadDepthStencilSubresource(
                    RequireNative(),
                    layer,
                    level,
                    destination,
                    _info.GetMipStride(level)
                );
            }
        }

        public byte[] ReadProbeDepth32()
        {
            if (!CanProbeDepth32)
            {
                throw Unsupported(
                    "diagnostic D32 readback for this texture topology"
                );
            }
            int bytesPerRow = _info.GetMipStride(0);
            byte[] data = new byte[_info.GetMipSize(0)];
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                _renderer._session.DownloadDepth32Probe(
                    RequireNative(),
                    data,
                    bytesPerRow
                );
            }
            return data;
        }

        private byte[] ReadAllColorSubresources()
        {
            int totalBytes = GetTextureDataSize(_info);
            byte[] data = new byte[totalBytes];
            IntPtr staging = IntPtr.Zero;
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                staging = _renderer._session.CreateBuffer(
                    totalBytes,
                    deviceLocal: false
                );
                try
                {
                    _renderer._session.FillBuffer(staging, 0, totalBytes, 0);
                    int offset = 0;
                    for (int level = 0; level < _info.Levels; level++)
                    {
                        int subresourceBytes = GetProbeSubresourceSize(level);
                        int slices = GetProbeSliceCount(level);
                        for (int layer = 0; layer < slices; layer++)
                        {
                            _renderer._session.CopyTextureToBuffer(
                                RequireNative(),
                                layer,
                                level,
                                staging,
                                offset,
                                subresourceBytes,
                                _info.GetMipStride(level)
                            );
                            offset = checked(offset + subresourceBytes);
                        }
                    }
                    if (offset != totalBytes)
                    {
                        throw new InvalidOperationException(
                            $"SolMetal texture readback planned {offset} " +
                            $"bytes for a {totalBytes}-byte texture."
                        );
                    }
                    _renderer._session.DownloadBuffer(staging, 0, data);
                }
                finally
                {
                    _renderer._session.DestroyBuffer(staging);
                }
            }
            return data;
        }

        private byte[] ReadColorSubresource(int layer, int level)
        {
            int slices = GetProbeSliceCount(level);
            if (layer < 0 || layer >= slices)
            {
                throw new ArgumentOutOfRangeException(nameof(layer));
            }
            int required = GetProbeSubresourceSize(level);
            byte[] data = new byte[required];
            IntPtr staging = IntPtr.Zero;
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                staging = _renderer._session.CreateBuffer(
                    required,
                    deviceLocal: false
                );
                try
                {
                    _renderer._session.FillBuffer(staging, 0, required, 0);
                    _renderer._session.CopyTextureToBuffer(
                        RequireNative(),
                        layer,
                        level,
                        staging,
                        0,
                        required,
                        _info.GetMipStride(level)
                    );
                    _renderer._session.DownloadBuffer(staging, 0, data);
                }
                finally
                {
                    _renderer._session.DestroyBuffer(staging);
                }
            }
            return data;
        }

        private static PinnedSpan<byte> PinReadback(byte[] data)
        {
            GCHandle pin = GCHandle.Alloc(data, GCHandleType.Pinned);
            return new PinnedSpan<byte>(
                (void*)pin.AddrOfPinnedObject(),
                data.Length,
                pin.Free
            );
        }

        public byte[] ReadProbeSubresource(int layer, int level)
        {
            if (!_renderer._frameProbeEnabled || IsBufferTexture ||
                _depthStencil || _info.Samples != 1)
            {
                throw Unsupported("a non-color texture probe subresource");
            }
            if (level < 0 || level >= _info.Levels)
            {
                throw new ArgumentOutOfRangeException(nameof(level));
            }

            int mipWidth = Math.Max(1, _info.Width >> level);
            int mipHeight = Math.Max(1, _info.Height >> level);
            int blockRows = checked(
                (mipHeight + _info.BlockHeight - 1) / _info.BlockHeight
            );
            int bytesPerRow = _info.GetMipStride(level);
            int required = checked(bytesPerRow * blockRows);
            const int MaximumProbeSubresourceBytes = 64 * 1024 * 1024;
            if (required <= 0 || required > MaximumProbeSubresourceBytes)
            {
                throw Unsupported(
                    $"texture probe subresource {mipWidth}x{mipHeight}, " +
                    $"rowBytes={bytesPerRow}, bytes={required}"
                );
            }

            return ReadColorSubresource(layer, level);
        }

        public string DescribeProbeSubresource(int layer, int level)
        {
            int width = Math.Max(1, _info.Width >> level);
            int height = Math.Max(1, _info.Height >> level);
            return $"view #{_probeView?.ViewId ?? 0}, storage #{ProbeId}, local " +
                $"mip {level}/layer {layer}, root mip " +
                $"{checked((_probeView?.RootBaseLevel ?? 0) + level)}/layer " +
                $"{checked((_probeView?.RootBaseLayer ?? 0) + layer)}, " +
                $"{width}x{height}, " +
                $"rowBytes={_info.GetMipStride(level)}";
        }

        public void SetData(MemoryOwner<byte> data) => SetData(data, 0, 0);

        public void SetData(MemoryOwner<byte> data, int layer, int level)
        {
            try
            {
                if (IsBufferTexture)
                {
                    if (layer != 0 || level != 0 ||
                        _storageHandle == BufferHandle.Null || _storageSize <= 0)
                    {
                        throw Unsupported(
                            "an unbound or subresource buffer-texture upload"
                        );
                    }
                    int length = Math.Min(data.Length, _storageSize);
                    _renderer.SetBufferData(
                        _storageHandle,
                        _storageOffset,
                        data.Memory.Span[..length]
                    );
                    return;
                }
                if (layer != 0 || level != 0)
                {
                    throw Unsupported(
                        $"texture upload for {_info.Format} at layer {layer}, mip {level}"
                    );
                }
                if (_nativeFormat ==
                    SolMetalNativeBridge.GalTextureFormat.Depth32FloatStencil8)
                {
                    throw Unsupported("combined depth/stencil texture upload");
                }
                int bytesPerRow = _info.GetMipStride(0);
                int required = GetTextureDataSize(_info);
                if (data.Length < required)
                {
                    throw new ArgumentException(
                        $"SolMetal needs at least {required} texture bytes, received {data.Length}.",
                        nameof(data)
                    );
                }
                lock (_renderer._gate)
                {
                    _renderer.ThrowIfDisposed();
                    try
                    {
                        _renderer._session.UploadTexture(
                            RequireNative(),
                            data.Memory.Span,
                            bytesPerRow
                        );
                        MarkProbeWrite(TextureProbeWriteKind.Upload);
                    }
                    catch (Exception exception)
                    {
                        throw new InvalidOperationException(
                            $"SolMetal could not upload {_info.Target} " +
                            $"{_info.Format} {_info.Width}x{_info.Height}x" +
                            $"{_info.Depth}, levels={_info.Levels}, " +
                            $"rowBytes={bytesPerRow}, bytes={data.Length}: " +
                            exception.Message,
                            exception
                        );
                    }
                }
            }
            finally
            {
                data.Dispose();
            }
        }

        public void SetData(
            MemoryOwner<byte> data,
            int layer,
            int level,
            Rectangle<int> region
        )
        {
            if (region.X == 0 && region.Y == 0 &&
                region.Width == Width && region.Height == Height)
            {
                SetData(data, layer, level);
                return;
            }
            data.Dispose();
            throw Unsupported("regional texture upload");
        }

        public void SetStorage(BufferRange buffer)
        {
            if (!IsBufferTexture)
            {
                throw Unsupported("buffer storage on a non-buffer texture");
            }
            if (buffer.Handle == BufferHandle.Null || buffer.Size <= 0 ||
                buffer.Offset < 0 || _bytesPerPixel <= 0 ||
                buffer.Size < _bytesPerPixel)
            {
                throw new ArgumentException(
                    "SolMetal requires a non-empty, texel-aligned buffer range.",
                    nameof(buffer)
                );
            }

            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                BufferEntry entry = _renderer.GetBuffer(
                    buffer.Handle,
                    buffer.Offset,
                    buffer.Size
                );
                if (_storageHandle == buffer.Handle &&
                    _storageOffset == buffer.Offset &&
                    _storageSize == buffer.Size && _native != IntPtr.Zero)
                {
                    return;
                }

                int width = buffer.Size / _bytesPerPixel;
                IntPtr replacement = _renderer._session.CreateBufferTexture(
                    entry.Native,
                    buffer.Offset,
                    buffer.Size,
                    width,
                    _nativeFormat,
                    MapTextureSwizzle(_info.SwizzleR),
                    MapTextureSwizzle(_info.SwizzleG),
                    MapTextureSwizzle(_info.SwizzleB),
                    MapTextureSwizzle(_info.SwizzleA)
                );
                IntPtr previous = _native;
                _native = replacement;
                _storageHandle = buffer.Handle;
                _storageOffset = buffer.Offset;
                _storageSize = buffer.Size;
                _renderer._pipeline.InvalidateTextureBindings(this);
                if (previous != IntPtr.Zero)
                {
                    _renderer._session.DestroyTexture(previous);
                }
            }
        }

        public void Release()
        {
            lock (_renderer._gate)
            {
                if (--_referenceCount > 0)
                {
                    return;
                }
                if (_native != IntPtr.Zero)
                {
                    _renderer._session.DestroyTexture(_native);
                }
                _native = IntPtr.Zero;
                _storageHandle = BufferHandle.Null;
                _storageOffset = 0;
                _storageSize = 0;
                _renderer._textures.Remove(this);
            }
        }

        public void DestroyFromRenderer()
        {
            if (_native != IntPtr.Zero)
            {
                _renderer._session.DestroyTexture(_native);
                _native = IntPtr.Zero;
            }
            _storageHandle = BufferHandle.Null;
            _storageOffset = 0;
            _storageSize = 0;
            _referenceCount = 0;
        }

        private IntPtr RequireNative() => _native != IntPtr.Zero
            ? _native
            : throw new ObjectDisposedException(nameof(SolMetalGalTexture));

        public IntPtr Native => RequireNative();
        public SolMetalNativeBridge.GalTextureFormat NativeFormat => _nativeFormat;
        public bool IsDepthStencil => _depthStencil;
    }

    private sealed class SolMetalGalSampler : ISampler
    {
        private readonly SolMetalGalRenderer _renderer;
        private readonly SamplerCreateInfo _info;
        private readonly SolMetalNativeBridge.GalSamplerDescriptor _nativeInfo;
        private IntPtr _native;

        public SolMetalGalSampler(
            SolMetalGalRenderer renderer,
            IntPtr native,
            SamplerCreateInfo info,
            SolMetalNativeBridge.GalSamplerDescriptor nativeInfo
        )
        {
            _renderer = renderer;
            _native = native;
            _info = info;
            _nativeInfo = nativeInfo;
        }

        public bool IsPointSampled =>
            (_info.MinFilter is MinFilter.Nearest or
                MinFilter.NearestMipmapNearest or
                MinFilter.NearestMipmapLinear) &&
            _info.MagFilter == MagFilter.Nearest;

        public string DescribeProbe() =>
            $"requested[min={_info.MinFilter}, mag={_info.MagFilter}, " +
            $"address={_info.AddressU}/{_info.AddressV}/{_info.AddressP}, " +
            $"lod={_info.MinLod:R}-{_info.MaxLod:R}, " +
            $"bias={_info.MipLodBias:R}, anisotropy={_info.MaxAnisotropy:R}, " +
            $"compare={_info.CompareMode}/{_info.CompareOp}]; " +
            $"effective[min={_nativeInfo.MinFilter}, " +
            $"mag={_nativeInfo.MagFilter}, mip={_nativeInfo.MipFilter}, " +
            $"address={_nativeInfo.AddressU}/{_nativeInfo.AddressV}/" +
            $"{_nativeInfo.AddressW}, lod={_nativeInfo.MinLod:R}-" +
            $"{_nativeInfo.MaxLod:R}, bias={_nativeInfo.LodBias:R}, " +
            $"anisotropy={_nativeInfo.MaxAnisotropy}, " +
            $"compare={_nativeInfo.CompareEnabled}/" +
            $"{_nativeInfo.CompareFunction}]";

        public void Dispose()
        {
            lock (_renderer._gate)
            {
                if (_native == IntPtr.Zero)
                {
                    return;
                }
                _renderer._session.DestroySampler(_native);
                _native = IntPtr.Zero;
                _renderer._samplers.Remove(this);
            }
        }

        public void DestroyFromRenderer()
        {
            if (_native != IntPtr.Zero)
            {
                _renderer._session.DestroySampler(_native);
                _native = IntPtr.Zero;
            }
        }

        public IntPtr Native => _native != IntPtr.Zero
            ? _native
            : throw new ObjectDisposedException(nameof(SolMetalGalSampler));
    }

    private sealed class SolMetalGalProgram : IProgram
    {
        private readonly SolMetalGalRenderer _renderer;
        private readonly Dictionary<PipelineKey, IntPtr> _pipelines = [];
        private SolMetalNativeBridge.GalRenderProgramHandle? _nativeProgram;
        private SolMetalNativeBridge.GalRenderProgramHandle?
            _nonPointNativeProgram;
        private readonly byte[]? _vertexSpirv;
        private readonly SolMetalNativeBridge.GalSpirvResourceBinding[]?
            _vertexRemaps;
        private readonly uint _vertexArgumentBufferSetMask;
        private IntPtr _computePipeline;
        private PipelineKey? _lastPipelineKey;
        private IntPtr _lastPipeline;

        public ProgramResourceBinding[] ResourceBindings { get; }
        public long ProbeId { get; }
        public string StableKey { get; }
        public bool IsCompute => _computePipeline != IntPtr.Zero;
        public (uint X, uint Y, uint Z) ComputeLocalSize { get; }

        public SolMetalGalProgram(
            SolMetalGalRenderer renderer,
            SolMetalNativeBridge.GalRenderProgramHandle nativeProgram,
            ProgramResourceBinding[] resourceBindings,
            string stableKey,
            byte[] vertexSpirv,
            SolMetalNativeBridge.GalSpirvResourceBinding[] vertexRemaps,
            uint vertexArgumentBufferSetMask
        )
        {
            _renderer = renderer;
            _nativeProgram = nativeProgram;
            ResourceBindings = resourceBindings;
            StableKey = stableKey;
            if (nativeProgram.VertexWritesPointSize)
            {
                _vertexSpirv = vertexSpirv;
                _vertexRemaps = vertexRemaps;
                _vertexArgumentBufferSetMask =
                    vertexArgumentBufferSetMask;
            }
            ProbeId = renderer._frameProbeEnabled
                ? Interlocked.Increment(ref renderer._nextProgramProbeId)
                : 0;
        }

        public SolMetalGalProgram(
            SolMetalGalRenderer renderer,
            IntPtr computePipeline,
            ProgramResourceBinding[] resourceBindings,
            (uint X, uint Y, uint Z) computeLocalSize
        )
        {
            _renderer = renderer;
            _computePipeline = computePipeline;
            ResourceBindings = resourceBindings;
            ComputeLocalSize = computeLocalSize;
            StableKey = string.Empty;
            ProbeId = renderer._frameProbeEnabled
                ? Interlocked.Increment(ref renderer._nextProgramProbeId)
                : 0;
        }

        public ProgramLinkStatus CheckProgramLink(bool blocking) =>
            _nativeProgram is null && _computePipeline == IntPtr.Zero
                ? ProgramLinkStatus.Failure
                : ProgramLinkStatus.Success;

        public byte[] GetBinary() => [];

        public string? CopyFragmentMsl()
        {
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                return _nativeProgram is null
                    ? null
                    : _renderer._session.CopyShaderMsl(
                        _nativeProgram.FragmentTranslation
                    );
            }
        }

        public string? CopyVertexMsl()
        {
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                return _nativeProgram is null
                    ? null
                    : _renderer._session.CopyShaderMsl(
                        _nativeProgram.VertexTranslation
                    );
            }
        }

        internal string? CopyVertexMslForTopology(
            SolMetalNativeBridge.GalPrimitiveTopologyClass topology
        )
        {
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                return _nativeProgram is null
                    ? null
                    : _renderer._session.CopyShaderMsl(
                        SelectNativeProgram(topology).VertexTranslation
                    );
            }
        }

        private SolMetalNativeBridge.GalRenderProgramHandle
            SelectNativeProgram(
                SolMetalNativeBridge.GalPrimitiveTopologyClass topology
            )
        {
            SolMetalNativeBridge.GalRenderProgramHandle nativeProgram =
                _nativeProgram ?? throw new ObjectDisposedException(
                    nameof(SolMetalGalProgram)
                );
            if (topology ==
                    SolMetalNativeBridge.GalPrimitiveTopologyClass.Point ||
                !nativeProgram.VertexWritesPointSize)
            {
                return nativeProgram;
            }
            if (_nonPointNativeProgram is not null)
            {
                return _nonPointNativeProgram;
            }
            if (_vertexSpirv is null || _vertexRemaps is null)
            {
                throw new InvalidOperationException(
                    "SolMetal lost the vertex inputs needed for its non-point shader variant."
                );
            }
            _nonPointNativeProgram =
                _renderer._session.CreateRenderProgramWithoutPointSize(
                    nativeProgram,
                    _vertexSpirv,
                    _vertexRemaps,
                    _vertexArgumentBufferSetMask
                );
            return _nonPointNativeProgram;
        }

        public IntPtr GetPipeline(
            SolMetalNativeBridge.GalRenderPipelineState state,
            SolMetalNativeBridge.GalVertexBufferLayout[] layouts,
            SolMetalNativeBridge.GalVertexAttribute[] attributes
        )
        {
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                if (_nativeProgram is null)
                {
                    throw IsCompute
                        ? new InvalidOperationException(
                            "A compute program cannot create a render pipeline."
                        )
                        : new ObjectDisposedException(nameof(SolMetalGalProgram));
                }
                PipelineKey key = new(state, layouts, attributes);
                if (_lastPipelineKey is PipelineKey lastKey &&
                    lastKey.Equals(key))
                {
                    return _lastPipeline;
                }
                if (!_pipelines.TryGetValue(key, out IntPtr pipeline))
                {
                    DumpD16PipelineProbe(state);
                    SolMetalNativeBridge.GalRenderProgramHandle
                        pipelineProgram = SelectNativeProgram(
                            state.InputPrimitiveTopology
                        );
                    pipeline = _renderer._session.CreateRenderPipeline(
                        pipelineProgram,
                        state,
                        layouts,
                        attributes
                    );
                    _pipelines.Add(key, pipeline);
                }
                _lastPipelineKey = key;
                _lastPipeline = pipeline;
                return pipeline;
            }
        }

        private void DumpD16PipelineProbe(
            SolMetalNativeBridge.GalRenderPipelineState state
        )
        {
            if (!_renderer._frameProbeEnabled || ProbeId == 0 ||
                state.DepthStencilFormat !=
                    SolMetalNativeBridge.GalTextureFormat.Depth16Unorm)
            {
                return;
            }

            try
            {
                string directory = Path.Combine(
                    Path.GetTempPath(),
                    $"SolMetalFrameProbe-{Environment.ProcessId}"
                );
                Directory.CreateDirectory(directory);
                string stem =
                    $"program-{ProbeId}-d16-" +
                    $"{state.DepthStencil.DepthCompareFunction}-" +
                    $"write-{state.DepthStencil.DepthWriteEnabled}";
                string? vertexMsl = CopyVertexMsl();
                string? fragmentMsl = CopyFragmentMsl();
                if (!string.IsNullOrEmpty(vertexMsl))
                {
                    File.WriteAllText(
                        Path.Combine(directory, $"{stem}-vertex.metal"),
                        vertexMsl
                    );
                }
                if (!string.IsNullOrEmpty(fragmentMsl))
                {
                    File.WriteAllText(
                        Path.Combine(directory, $"{stem}-fragment.metal"),
                        fragmentMsl
                    );
                }
                File.WriteAllText(
                    Path.Combine(directory, $"{stem}-state.txt"),
                    $"program={ProbeId}\n" +
                    $"stableKey={StableKey}\n" +
                    $"compare={state.DepthStencil.DepthCompareFunction}\n" +
                    $"write={state.DepthStencil.DepthWriteEnabled}\n" +
                    $"stencil={state.DepthStencil.StencilEnabled}\n"
                );
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal captured D16 pipeline #{ProbeId} " +
                    $"(key={StableKey}, " +
                    $"compare={state.DepthStencil.DepthCompareFunction}, " +
                    $"write={state.DepthStencil.DepthWriteEnabled}) in " +
                    $"{directory}."
                );
            }
            catch (Exception exception)
            {
                Logger.Warning?.Print(
                    LogClass.Gpu,
                    $"SolMetal could not capture D16 pipeline " +
                    $"#{ProbeId}: {exception.Message}"
                );
            }
        }

        public IntPtr GetComputePipeline()
        {
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                return _computePipeline != IntPtr.Zero
                    ? _computePipeline
                    : throw new InvalidOperationException(
                        "The active SolMetal program is not a compute program."
                    );
            }
        }

        internal static void ValidatePipelineKeyTopologySeparation()
        {
            SolMetalNativeBridge.GalRenderPipelineState triangleState = new(
                [],
                0,
                default,
                false,
                false,
                false,
                SolMetalNativeBridge.GalPrimitiveTopologyClass.Triangle
            );
            SolMetalNativeBridge.GalRenderPipelineState lineState =
                triangleState with
                {
                    InputPrimitiveTopology =
                        SolMetalNativeBridge.GalPrimitiveTopologyClass.Line,
                };
            PipelineKey triangleKey = new(triangleState, [], []);
            PipelineKey lineKey = new(lineState, [], []);
            Dictionary<PipelineKey, int> keys = [];
            if (!keys.TryAdd(triangleKey, 1) ||
                !keys.TryAdd(lineKey, 2) || keys.Count != 2)
            {
                throw new InvalidOperationException(
                    "SolMetal render pipeline cache merged different topology classes."
                );
            }
        }

        private readonly struct PipelineKey : IEquatable<PipelineKey>
        {
            private readonly SolMetalNativeBridge.GalRenderPipelineState _state;
            private readonly SolMetalNativeBridge.GalVertexBufferLayout[] _layouts;
            private readonly SolMetalNativeBridge.GalVertexAttribute[] _attributes;

            public PipelineKey(
                SolMetalNativeBridge.GalRenderPipelineState state,
                SolMetalNativeBridge.GalVertexBufferLayout[] layouts,
                SolMetalNativeBridge.GalVertexAttribute[] attributes
            )
            {
                _state = state;
                _layouts = layouts;
                _attributes = attributes;
            }

            public bool Equals(PipelineKey other)
            {
                return _state.DepthStencilFormat == other._state.DepthStencilFormat &&
                    _state.DepthStencil == other._state.DepthStencil &&
                    _state.AlphaToCoverageEnabled ==
                        other._state.AlphaToCoverageEnabled &&
                    _state.AlphaToCoverageDitherEnabled ==
                        other._state.AlphaToCoverageDitherEnabled &&
                    _state.AlphaToOneEnabled == other._state.AlphaToOneEnabled &&
                    _state.InputPrimitiveTopology ==
                        other._state.InputPrimitiveTopology &&
                    _state.ColorAttachments.AsSpan().SequenceEqual(
                        other._state.ColorAttachments
                    ) &&
                    _layouts.AsSpan().SequenceEqual(other._layouts) &&
                    _attributes.AsSpan().SequenceEqual(other._attributes);
            }

            public override bool Equals(object? value) =>
                value is PipelineKey other && Equals(other);

            public override int GetHashCode()
            {
                HashCode hash = new();
                hash.Add(_state.DepthStencilFormat);
                hash.Add(_state.DepthStencil);
                hash.Add(_state.AlphaToCoverageEnabled);
                hash.Add(_state.AlphaToCoverageDitherEnabled);
                hash.Add(_state.AlphaToOneEnabled);
                hash.Add(_state.InputPrimitiveTopology);
                foreach (
                    SolMetalNativeBridge.GalRenderColorAttachmentState attachment
                    in _state.ColorAttachments
                )
                {
                    hash.Add(attachment);
                }
                foreach (
                    SolMetalNativeBridge.GalVertexBufferLayout layout
                    in _layouts
                )
                {
                    hash.Add(layout);
                }
                foreach (
                    SolMetalNativeBridge.GalVertexAttribute attribute
                    in _attributes
                )
                {
                    hash.Add(attribute);
                }
                return hash.ToHashCode();
            }
        }

        public void Dispose()
        {
            lock (_renderer._gate)
            {
                if (_nativeProgram is null && _computePipeline == IntPtr.Zero)
                {
                    return;
                }
                DestroyNative();
                _renderer._programs.Remove(this);
                if (_renderer.ProgramCount != 0)
                {
                    _renderer.ProgramCount--;
                }
            }
        }

        public void DestroyFromRenderer()
        {
            if (_nativeProgram is not null || _computePipeline != IntPtr.Zero)
            {
                DestroyNative();
            }
        }

        private void DestroyNative()
        {
            foreach (IntPtr pipeline in _pipelines.Values)
            {
                _renderer._session.DestroyRenderPipeline(pipeline);
            }
            _pipelines.Clear();
            _lastPipelineKey = null;
            _lastPipeline = IntPtr.Zero;
            if (_nativeProgram is not null)
            {
                if (_nonPointNativeProgram is not null)
                {
                    _renderer._session.DestroyRenderProgram(
                        _nonPointNativeProgram
                    );
                    _nonPointNativeProgram = null;
                }
                _renderer._session.DestroyRenderProgram(_nativeProgram);
                _nativeProgram = null;
            }
            if (_computePipeline != IntPtr.Zero)
            {
                _renderer._session.DestroyComputePipeline(_computePipeline);
                _computePipeline = IntPtr.Zero;
            }
        }
    }

    private sealed class SolMetalGalWindow : IWindow
    {
        private readonly SolMetalGalRenderer _renderer;
        private readonly nint _metalLayer;

        public SolMetalGalWindow(SolMetalGalRenderer renderer, nint metalLayer)
        {
            _renderer = renderer;
            _metalLayer = metalLayer;
        }

        private static void DumpProbeProgram(
            SolMetalGalTexture texture,
            HashSet<long> dumpedPrograms
        )
        {
            DumpProbeProgram(texture.GetProbeProgram(), dumpedPrograms);
        }

        internal static void DumpProbeProgram(
            SolMetalGalProgram? program,
            HashSet<long> dumpedPrograms,
            string? outputDirectory = null
        )
        {
            if (program is null || program.ProbeId == 0 ||
                !dumpedPrograms.Add(program.ProbeId))
            {
                return;
            }
            try
            {
                string? vertexMsl = program.CopyVertexMsl();
                string? fragmentMsl = program.CopyFragmentMsl();
                if (string.IsNullOrEmpty(vertexMsl) &&
                    string.IsNullOrEmpty(fragmentMsl))
                {
                    return;
                }
                string directory = outputDirectory ?? Path.Combine(
                    Path.GetTempPath(),
                    $"SolMetalFrameProbe-{Environment.ProcessId}"
                );
                Directory.CreateDirectory(directory);
                List<string> paths = [];
                if (!string.IsNullOrEmpty(vertexMsl))
                {
                    string vertexPath = Path.Combine(
                        directory,
                        $"program-{program.ProbeId}-vertex.metal"
                    );
                    File.WriteAllText(vertexPath, vertexMsl);
                    paths.Add(vertexPath);
                }
                if (!string.IsNullOrEmpty(fragmentMsl))
                {
                    string fragmentPath = Path.Combine(
                        directory,
                        $"program-{program.ProbeId}-fragment.metal"
                    );
                    File.WriteAllText(fragmentPath, fragmentMsl);
                    paths.Add(fragmentPath);
                }
                string bindings = string.Join(
                    ", ",
                    program.ResourceBindings.Select(resource =>
                        $"{resource.Stage}:set{resource.DescriptorSet}/" +
                        $"binding{resource.Binding}:{resource.Type}->" +
                        $"b{resource.MetalBuffer}/t{resource.MetalTexture}/" +
                        $"s{resource.MetalSampler}/a{resource.ArgumentBuffer}"
                    )
                );
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal probe program #{program.ProbeId} " +
                    $"(key={program.StableKey}) MSL written " +
                    $"to {string.Join(", ", paths)}; resources=[{bindings}]."
                );
            }
            catch (Exception exception)
            {
                Logger.Warning?.Print(
                    LogClass.Gpu,
                    $"SolMetal could not dump probe program " +
                    $"#{program.ProbeId}: {exception.Message}"
                );
            }
        }

        private static void DumpProbeBuffers(
            SolMetalGalTexture texture,
            HashSet<string> dumpedPrograms
        )
        {
            DumpProbeBuffers(
                texture,
                texture.GetProbeProgram(),
                texture.GetProbeBufferBindings(),
                "last",
                dumpedPrograms
            );
        }

        internal static void DumpProbeBuffers(
            SolMetalGalTexture texture,
            SolMetalGalProgram? program,
            ProbeBufferBinding[] bindings,
            string role,
            HashSet<string> dumpedPrograms,
            string? outputDirectory = null
        )
        {
            if (program is null || program.ProbeId == 0 ||
                !dumpedPrograms.Add($"{program.ProbeId}:{role}"))
            {
                return;
            }

            string directory = outputDirectory ?? Path.Combine(
                Path.GetTempPath(),
                $"SolMetalFrameProbe-{Environment.ProcessId}"
            );
            Directory.CreateDirectory(directory);
            for (int index = 0; index < bindings.Length; index++)
            {
                ProbeBufferBinding binding = bindings[index];
                try
                {
                    byte[] prefix = texture.ReadProbeBuffer(
                        binding.Range,
                        binding.Label.Contains("StorageBuffer", StringComparison.Ordinal)
                            ? 16384
                            : 4096
                    );
                    string path = Path.Combine(
                        directory,
                        $"program-{program.ProbeId}-{role}-buffer-{index}.bin"
                    );
                    File.WriteAllBytes(path, prefix);
                    LogRawProbe(
                        prefix,
                        $"program #{program.ProbeId} {role} {binding.Label} " +
                        $"range={binding.Range.Size}, prefix={prefix.Length}"
                    );
                    Logger.Notice.Print(
                        LogClass.Gpu,
                        $"SolMetal probe program #{program.ProbeId} " +
                        $"{role} {binding.Label} prefix written to {path}."
                    );
                }
                catch (Exception exception)
                {
                    Logger.Warning?.Print(
                        LogClass.Gpu,
                        $"SolMetal could not inspect probe program " +
                        $"#{program.ProbeId} {role} {binding.Label}: " +
                        exception.Message
                    );
                }
            }
        }

        private static void DumpLargestProbeDraw(
            SolMetalGalTexture texture,
            HashSet<long> dumpedPrograms,
            HashSet<string> dumpedBufferPrograms
        )
        {
            var largest = texture.GetLargestProbeDraw();
            if (largest.ElementCount <= 0 || largest.Program is null)
            {
                return;
            }
            Logger.Notice.Print(
                LogClass.Gpu,
                $"SolMetal largest draw on texture #{texture.ProbeId}: " +
                $"elements={largest.ElementCount}, state=[{largest.Details}]."
            );
            DumpProbeProgram(largest.Program, dumpedPrograms);
            DumpProbeBufferSnapshots(
                largest.Program,
                largest.Buffers,
                "largest",
                dumpedBufferPrograms
            );
        }

        private static void DumpProbeBufferSnapshots(
            SolMetalGalProgram program,
            ProbeBufferSnapshot[] snapshots,
            string role,
            HashSet<string> dumpedPrograms
        )
        {
            if (program.ProbeId == 0 ||
                !dumpedPrograms.Add($"{program.ProbeId}:{role}"))
            {
                return;
            }
            string directory = Path.Combine(
                Path.GetTempPath(),
                $"SolMetalFrameProbe-{Environment.ProcessId}"
            );
            Directory.CreateDirectory(directory);
            for (int index = 0; index < snapshots.Length; index++)
            {
                ProbeBufferSnapshot snapshot = snapshots[index];
                string path = Path.Combine(
                    directory,
                    $"program-{program.ProbeId}-{role}-buffer-{index}.bin"
                );
                File.WriteAllBytes(path, snapshot.Prefix);
                LogRawProbe(
                    snapshot.Prefix,
                    $"program #{program.ProbeId} {role} {snapshot.Label} " +
                    $"range={snapshot.RangeSize}, prefix=" +
                    $"{snapshot.Prefix.Length}"
                );
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal probe program #{program.ProbeId} {role} " +
                    $"{snapshot.Label} prefix written to {path}."
                );
            }
        }

        private static void DumpRecentProbeDraws(
            SolMetalGalTexture texture,
            HashSet<long> dumpedPrograms,
            HashSet<string> dumpedBufferPrograms
        )
        {
            ProbeDrawRecord[] draws = texture.GetRecentProbeDraws();
            HashSet<long> inspectedTextures = [];
            for (int index = 0; index < draws.Length; index++)
            {
                ProbeDrawRecord draw = draws[index];
                if (draw.Program is null)
                {
                    continue;
                }
                string role = $"recent-{index}";
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal recent draw {index + 1}/{draws.Length} on " +
                    $"{draw.TargetView}: program " +
                    $"#{draw.Program.ProbeId}, state=[{draw.Details}]."
                );
                DumpProbeProgram(draw.Program, dumpedPrograms);
                DumpProbeBuffers(
                    texture,
                    draw.Program,
                    draw.Buffers,
                    role,
                    dumpedBufferPrograms
                );
                foreach (SolMetalGalTexture sampled in draw.SampledTextures)
                {
                    if (sampled.ProbeId == 0 ||
                        !inspectedTextures.Add(sampled.ProbeId))
                    {
                        continue;
                    }
                    Logger.Notice.Print(
                        LogClass.Gpu,
                        $"SolMetal recent draw {index + 1} sampled " +
                        sampled.DescribeProbe()
                    );
                    if (!sampled.CanProbeRaw)
                    {
                        continue;
                    }
                    try
                    {
                        using PinnedSpan<byte> data = sampled.GetData();
                        LogRawProbe(
                            data.Get(),
                            $"recent draw {index + 1} sampled texture " +
                            $"#{sampled.ProbeId}"
                        );
                    }
                    catch (Exception exception)
                    {
                        Logger.Warning?.Print(
                            LogClass.Gpu,
                            $"SolMetal could not inspect recent sampled " +
                            $"texture #{sampled.ProbeId}: " +
                            exception.Message
                        );
                    }
                }
            }
        }

        private static void DumpFrameProbeTarget(
            FrameProbeTarget target,
            HashSet<long> dumpedPrograms,
            HashSet<string> dumpedBufferPrograms
        )
        {
            SolMetalGalTexture texture = target.Texture;
            Logger.Notice.Print(
                LogClass.Gpu,
                $"SolMetal retained frame target ({target.Role}, " +
                $"elements={target.ElementCount}): {texture.DescribeProbe()}"
            );
            DumpProbeProgram(texture, dumpedPrograms);
            DumpProbeBuffers(texture, dumpedBufferPrograms);
            DumpLargestProbeDraw(
                texture,
                dumpedPrograms,
                dumpedBufferPrograms
            );
            DumpRecentProbeDraws(
                texture,
                dumpedPrograms,
                dumpedBufferPrograms
            );
            try
            {
                using PinnedSpan<byte> data = texture.GetData();
                ReadOnlySpan<byte> bytes = data.Get();
                LogRawProbe(
                    bytes,
                    $"retained frame target #{texture.ProbeId}"
                );
                string directory = Path.Combine(
                    Path.GetTempPath(),
                    $"SolMetalFrameProbe-{Environment.ProcessId}"
                );
                Directory.CreateDirectory(directory);
                string path = Path.Combine(
                    directory,
                    $"texture-{texture.ProbeId}-" +
                    $"{texture.NativeFormat}-" +
                    $"{texture.Width}x{texture.Height}.bin"
                );
                File.WriteAllBytes(path, bytes.ToArray());
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal retained frame target #{texture.ProbeId} " +
                    $"written to {path}."
                );
            }
            catch (Exception exception)
            {
                Logger.Warning?.Print(
                    LogClass.Gpu,
                    $"SolMetal could not inspect retained frame target " +
                    $"#{texture.ProbeId}: {exception.Message}"
                );
            }
        }

        private static byte[] CropCapturedFrame(
            byte[] source,
            int sourceWidth,
            int sourceHeight,
            ImageCrop crop,
            out int width,
            out int height
        )
        {
            int left = crop.Left == 0 && crop.Right == 0 ? 0 : crop.Left;
            int right = crop.Left == 0 && crop.Right == 0
                ? sourceWidth
                : crop.Right;
            int top = crop.Top == 0 && crop.Bottom == 0 ? 0 : crop.Top;
            int bottom = crop.Top == 0 && crop.Bottom == 0
                ? sourceHeight
                : crop.Bottom;
            if (left < 0 || top < 0 || right <= left || bottom <= top ||
                right > sourceWidth || bottom > sourceHeight)
            {
                throw new ArgumentOutOfRangeException(
                    nameof(crop),
                    "The presentation crop must be inside the source texture."
                );
            }
            width = right - left;
            height = bottom - top;
            if (left == 0 && top == 0 &&
                width == sourceWidth && height == sourceHeight)
            {
                return source;
            }

            int sourceStride = checked(sourceWidth * 4);
            int destinationStride = checked(width * 4);
            byte[] cropped = new byte[checked(destinationStride * height)];
            for (int row = 0; row < height; row++)
            {
                Buffer.BlockCopy(
                    source,
                    checked((top + row) * sourceStride + left * 4),
                    cropped,
                    row * destinationStride,
                    destinationStride
                );
            }
            return cropped;
        }

        public void Present(
            ITexture texture,
            ImageCrop crop,
            Action swapBuffersCallback
        )
        {
            if (_metalLayer == 0 || texture is not SolMetalGalTexture source)
            {
                throw Unsupported("presentation without the embedded Metal surface");
            }
            bool screenshotRequested = Interlocked.Exchange(
                ref _renderer._screenshotRequested,
                0
            ) != 0;
            bool frameProbeRequested = _renderer._frameProbeEnabled &&
                Interlocked.CompareExchange(
                    ref _renderer._frameProbeCompleted,
                    1,
                    0
                ) == 0;
            FrameProbeTarget[] frameProbeTargets =
                _renderer.TakeFrameProbeTargets();
            byte[]? capturedFrame = null;
            bool capturedFrameIsBgra = false;
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                _renderer._session.PresentTexture(
                    _metalLayer,
                    source.Native,
                    crop.Left,
                    crop.Top,
                    crop.Right,
                    crop.Bottom,
                    crop.IsStretched ? 0.0f : crop.AspectRatioX,
                    crop.IsStretched ? 0.0f : crop.AspectRatioY,
                    crop.FlipX,
                    crop.FlipY
                );
                if (screenshotRequested || frameProbeRequested)
                {
                    using PinnedSpan<byte> frame = source.GetData();
                    int expectedBytes = checked(
                        source.Width * source.Height * 4
                    );
                    ReadOnlySpan<byte> pixels = frame.Get();
                    if (pixels.Length < expectedBytes)
                    {
                        throw new InvalidOperationException(
                            $"SolMetal screenshot returned {pixels.Length} " +
                            $"bytes for a {source.Width}x{source.Height} frame."
                        );
                    }
                    capturedFrame = pixels[..expectedBytes].ToArray();
                    capturedFrameIsBgra = source.IsBgra;
                }
            }
            if (capturedFrame is not null)
            {
                long capturedPresentation = checked(
                    Interlocked.Read(ref _renderer._presentedFrameCount) + 1
                );
                if (frameProbeRequested)
                {
                    LogFrameProbe(
                        capturedFrame,
                        source.Width,
                        source.Height,
                        capturedFrameIsBgra
                    );
                }
                if (_renderer._frameProbeEnabled)
                {
                    DumpPresentedFrameProbe(
                        capturedFrame,
                        source.Width,
                        source.Height,
                        source.NativeFormat,
                        capturedPresentation,
                        "presented-source"
                    );
                }
                if (frameProbeRequested || screenshotRequested)
                {
                    Logger.Notice.Print(
                        LogClass.Gpu,
                        $"SolMetal presented source provenance: " +
                        source.DescribeProbe()
                    );
                    SolMetalGalTexture? upstream = source.GetProbeSource();
                    if (upstream is not null && upstream.CanProbeColor)
                    {
                        try
                        {
                            using PinnedSpan<byte> upstreamFrame =
                                upstream.GetData();
                            int expectedBytes = checked(
                                upstream.Width * upstream.Height * 4
                            );
                            ReadOnlySpan<byte> upstreamPixels =
                                upstreamFrame.Get();
                            if (upstreamPixels.Length >= expectedBytes)
                            {
                                ReadOnlySpan<byte> upstreamProbe =
                                    upstreamPixels[..expectedBytes];
                                if (upstream.CanProbeRgba8)
                                {
                                    LogFrameProbe(
                                        upstreamProbe,
                                        upstream.Width,
                                        upstream.Height,
                                        upstream.IsBgra,
                                        "upstream copy-source"
                                    );
                                }
                                else
                                {
                                    LogRawProbe(
                                        upstreamProbe,
                                        "upstream copy-source " +
                                        upstream.NativeFormat
                                    );
                                }
                                if (_renderer._frameProbeEnabled)
                                {
                                    DumpPresentedFrameProbe(
                                        upstreamProbe,
                                        upstream.Width,
                                        upstream.Height,
                                        upstream.NativeFormat,
                                        capturedPresentation,
                                        "upstream-copy-source"
                                    );
                                }
                            }
                        }
                        catch (Exception exception)
                        {
                            Logger.Warning?.Print(
                                LogClass.Gpu,
                                $"SolMetal could not inspect the upstream " +
                                $"copy source: {exception.Message}"
                            );
                        }
                    }
                    if (screenshotRequested)
                    {
                        HashSet<long> dumpedPrograms = [];
                        HashSet<string> dumpedBufferPrograms = [];
                        foreach (FrameProbeTarget target in frameProbeTargets)
                        {
                            DumpFrameProbeTarget(
                                target,
                                dumpedPrograms,
                                dumpedBufferPrograms
                            );
                        }
                        Queue<(SolMetalGalTexture Texture, int Depth)> pending =
                            new();
                        if (upstream is not null)
                        {
                            DumpProbeProgram(upstream, dumpedPrograms);
                            DumpProbeBuffers(upstream, dumpedBufferPrograms);
                            DumpLargestProbeDraw(
                                upstream,
                                dumpedPrograms,
                                dumpedBufferPrograms
                            );
                            DumpRecentProbeDraws(
                                upstream,
                                dumpedPrograms,
                                dumpedBufferPrograms
                            );
                            foreach (SolMetalGalTexture input in
                                     upstream.GetProbeSampledTextures())
                            {
                                pending.Enqueue((input, 1));
                            }
                        }
                        HashSet<long> visited = [];
                        int inspected = 0;
                        while (pending.Count > 0 && inspected < 16)
                        {
                            (SolMetalGalTexture input, int depth) =
                                pending.Dequeue();
                            if (input.ProbeId == 0 ||
                                !visited.Add(input.ProbeId))
                            {
                                continue;
                            }
                            inspected++;
                            Logger.Notice.Print(
                                LogClass.Gpu,
                                $"SolMetal fragment input depth {depth}: " +
                                input.DescribeProbe()
                            );
                            DumpProbeProgram(input, dumpedPrograms);
                            DumpProbeBuffers(input, dumpedBufferPrograms);
                            DumpLargestProbeDraw(
                                input,
                                dumpedPrograms,
                                dumpedBufferPrograms
                            );
                            DumpRecentProbeDraws(
                                input,
                                dumpedPrograms,
                                dumpedBufferPrograms
                            );
                            if (input.CanProbeRgba8)
                            {
                                try
                                {
                                    using PinnedSpan<byte> inputFrame =
                                        input.GetData();
                                    int expectedBytes = checked(
                                        input.Width * input.Height * 4
                                    );
                                    ReadOnlySpan<byte> inputPixels =
                                        inputFrame.Get();
                                    if (inputPixels.Length >= expectedBytes)
                                    {
                                        LogFrameProbe(
                                            inputPixels[..expectedBytes],
                                            input.Width,
                                            input.Height,
                                            input.IsBgra,
                                            $"fragment-input depth {depth} " +
                                            $"#{input.ProbeId}"
                                        );
                                    }
                                }
                                catch (Exception exception)
                                {
                                    Logger.Warning?.Print(
                                        LogClass.Gpu,
                                        $"SolMetal could not inspect fragment " +
                                        $"input #{input.ProbeId}: " +
                                        exception.Message
                                    );
                                }
                            }
                            else if (input.CanProbeRaw)
                            {
                                try
                                {
                                    using PinnedSpan<byte> inputFrame =
                                        input.GetData();
                                    LogRawProbe(
                                        inputFrame.Get(),
                                        $"fragment-input depth {depth} " +
                                        $"#{input.ProbeId}"
                                    );
                                }
                                catch (Exception exception)
                                {
                                    Logger.Warning?.Print(
                                        LogClass.Gpu,
                                        $"SolMetal could not inspect raw " +
                                        $"fragment input #{input.ProbeId}: " +
                                        exception.Message
                                    );
                                }
                            }
                            if (depth < 4)
                            {
                                foreach (SolMetalGalTexture child in
                                         input.GetProbeSampledTextures())
                                {
                                    pending.Enqueue((child, depth + 1));
                                }
                                foreach (ProbeDrawRecord draw in
                                         input.GetRecentProbeDraws())
                                {
                                    foreach (SolMetalGalTexture child in
                                             draw.SampledTextures)
                                    {
                                        pending.Enqueue((child, depth + 1));
                                    }
                                }
                            }
                        }
                    }
                }
                if (screenshotRequested)
                {
                    byte[] screenshotFrame = CropCapturedFrame(
                        capturedFrame,
                        source.Width,
                        source.Height,
                        crop,
                        out int screenshotWidth,
                        out int screenshotHeight
                    );
                    Logger.Notice.Print(
                        LogClass.Gpu,
                        $"SolMetal captured a {screenshotWidth}x" +
                        $"{screenshotHeight} " +
                        "screenshot frame."
                    );
                    _renderer.OnScreenCaptured(new ScreenCaptureImageInfo(
                        screenshotWidth,
                        screenshotHeight,
                        capturedFrameIsBgra,
                        screenshotFrame,
                        crop.FlipX,
                        crop.FlipY
                    ));
                }
            }
            NativeEmbeddedEntrypoint.NotifyFirstMetalFramePresented(
                source.Width,
                source.Height
            );
            long presented = Interlocked.Increment(
                ref _renderer._presentedFrameCount
            );
            _renderer.ExpireStructuredTargetedProbeSelectors(presented);
            if (presented == 1)
            {
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal presented its first native guest frame " +
                    $"({source.Width}x{source.Height})."
                );
            }
            else if (presented == 60)
            {
                Logger.Notice.Print(
                    LogClass.Gpu,
                    "SolMetal sustained 60 native guest presentations."
                );
            }
            if (_renderer._frameProbeEnabled &&
                _renderer._autoProbeD16SequenceRequested &&
                _renderer._autoProbeD16SequenceKeys.Length != 3 &&
                presented == 1)
            {
                Logger.Warning?.Print(
                    LogClass.Gpu,
                    "SolMetal ignored malformed " +
                    "SOL_METAL_AUTO_PROBE_D16_SEQUENCE_KEYS; expected " +
                    "exactly three comma-separated SHA-256 keys."
                );
                Volatile.Write(ref _renderer._autoD16ProbeArmed, -1);
            }
            else if (_renderer._frameProbeEnabled &&
                !_renderer._autoProbeD16SequenceRequested &&
                presented == _renderer._autoProbeAfterPresentations)
            {
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal automatically armed its frame probe after " +
                    $"{presented} presentations."
                );
                _renderer.Screenshot();
            }
            else if (_renderer._frameProbeEnabled &&
                     _renderer._autoProbeD16SequenceKeys.Length == 3 &&
                     Interlocked.CompareExchange(
                         ref _renderer._autoD16ProbeArmed,
                         2,
                         1
                     ) == 1)
            {
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal armed its stable D16 sequence probe after " +
                    $"presentation {presented}."
                );
                _renderer.Screenshot();
            }
            else if (_renderer._frameProbeEnabled &&
                     _renderer._autoProbeD16SequenceKeys.Length == 3 &&
                     _renderer._autoProbeTimeoutPresentations > 0 &&
                     presented == _renderer._autoProbeTimeoutPresentations &&
                     Interlocked.CompareExchange(
                         ref _renderer._autoD16ProbeArmed,
                         -1,
                         0
                     ) == 0)
            {
                Logger.Warning?.Print(
                    LogClass.Gpu,
                    $"SolMetal did not recognize two stable D16 " +
                    $"writer/replay sequences within {presented} " +
                    "presentations; no automatic probe was armed."
                );
            }
            swapBuffersCallback();
        }

        public void SetSize(int width, int height)
        {
            if (width <= 0 || height <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(width));
            }
        }
        public void ChangeVSyncMode(VSyncMode vSyncMode) { }
        public void SetAntiAliasing(AntiAliasing antialiasing)
        {
            if (antialiasing != AntiAliasing.None)
            {
                throw Unsupported($"presentation anti-aliasing {antialiasing}");
            }
        }
        public void SetScalingFilter(ScalingFilter type)
        {
            if (type != ScalingFilter.Bilinear)
            {
                throw Unsupported($"presentation scaling filter {type}");
            }
        }
        public void SetScalingFilterLevel(float level) { }
        public void SetColorSpacePassthrough(bool colorSpacePassThroughEnabled)
        {
            if (colorSpacePassThroughEnabled)
            {
                throw Unsupported("color-space passthrough");
            }
        }
    }

    private sealed class SolMetalGalPipeline : IPipeline
    {
        private readonly SolMetalGalRenderer _renderer;
        private const int MaxColorAttachments = 8;
        private const int QuadVerticesPerPrimitive = 4;
        private const int QuadTriangleIndicesPerPrimitive = 6;
        private const int MinimumCachedQuadPrimitiveCapacity = 64;
        private const int MaximumQuadScratchBytes = 64 * 1024 * 1024;
        private const int MaximumQuadPrimitiveCapacity =
            MaximumQuadScratchBytes /
                (QuadTriangleIndicesPerPrimitive * sizeof(uint));
        private static ReadOnlySpan<uint> QuadTrianglePattern =>
            [0, 1, 2, 0, 2, 3];
        private SolMetalGalProgram? _program;
        private readonly SolMetalGalTexture?[] _colorTargets =
            new SolMetalGalTexture?[MaxColorAttachments];
        private readonly SolMetalGalTexture?[] _unfilteredColorTargets =
            new SolMetalGalTexture?[MaxColorAttachments];
        private SolMetalGalTexture? _depthStencilTarget;
        private Viewport? _viewport;
        private Rectangle<int>? _scissor;
        private PrimitiveTopology _topology = PrimitiveTopology.Triangles;
        private readonly uint[] _colorWriteMasks = new uint[MaxColorAttachments];
        private readonly SolMetalNativeBridge.GalBlendState[] _blendStates =
            new SolMetalNativeBridge.GalBlendState[MaxColorAttachments];
        private ColorF _blendConstant = new(0, 0, 0, 0);
        private DepthTestDescriptor _depthTest = new(
            false,
            false,
            CompareOp.Always
        );
        private StencilTestDescriptor _stencilTest = new(
            false,
            CompareOp.Always,
            StencilOp.Keep,
            StencilOp.Keep,
            StencilOp.Keep,
            0,
            -1,
            -1,
            CompareOp.Always,
            StencilOp.Keep,
            StencilOp.Keep,
            StencilOp.Keep,
            0,
            -1,
            -1
        );
        private SolMetalNativeBridge.GalFrontFaceWinding _frontFace =
            SolMetalNativeBridge.GalFrontFaceWinding.Clockwise;
        private SolMetalNativeBridge.GalCullMode _cullMode =
            SolMetalNativeBridge.GalCullMode.None;
        private SolMetalNativeBridge.GalTriangleFillMode _fillMode =
            SolMetalNativeBridge.GalTriangleFillMode.Fill;
        private SolMetalNativeBridge.GalDepthClipMode _depthClipMode =
            SolMetalNativeBridge.GalDepthClipMode.Clip;
        private DepthMode _depthMode = DepthMode.ZeroToOne;
        private float _depthBias;
        private float _depthBiasSlopeScale;
        private float _depthBiasClamp;
        private float _lineWidth = 1;
        private bool _lineSmooth;
        private bool _alphaToCoverageEnabled;
        private bool _alphaToCoverageDitherEnabled;
        private bool _alphaToOneEnabled;
        private readonly SolMetalNativeBridge.GalRenderLoadAction[]
            _colorLoadActions =
                new SolMetalNativeBridge.GalRenderLoadAction[
                    MaxColorAttachments
                ];
        private readonly ColorF[] _clearColors =
            new ColorF[MaxColorAttachments];
        private SolMetalNativeBridge.GalRenderColorAttachmentState[]
            _cachedColorAttachments = [];
        private SolMetalNativeBridge.GalRenderColorTarget[]
            _cachedNativeColorTargets = [];
        private bool _colorBindingStateDirty = true;
        private SolMetalNativeBridge.GalRenderLoadAction _depthLoadAction =
            SolMetalNativeBridge.GalRenderLoadAction.Load;
        private SolMetalNativeBridge.GalRenderLoadAction _stencilLoadAction =
            SolMetalNativeBridge.GalRenderLoadAction.Load;
        private double _clearDepth = 1;
        private uint _clearStencil;
        private VertexBufferDescriptor[] _vertexBuffers = [];
        private VertexAttribDescriptor[] _vertexAttributes = [];
        private SolMetalNativeBridge.GalVertexBufferLayout[]
            _cachedVertexLayouts = [];
        private SolMetalNativeBridge.GalVertexAttribute[]
            _cachedVertexAttributes = [];
        private SolMetalNativeBridge.GalBufferBinding[]
            _cachedVertexInputBindings = [];
        private int[] _cachedVertexBufferIndices = [];
        private bool _cachedVertexNeedsZeroBuffer;
        private bool _vertexPipelineStateDirty = true;
        private BufferRange? _indexBuffer;
        private IndexType _indexType;
        private BufferHandle _sequentialQuadIndexBuffer;
        private int _sequentialQuadPrimitiveCapacity;
        private BufferHandle _expandedQuadIndexBuffer;
        private int _expandedQuadPrimitiveCapacity;
        private long _indexedQuadConversionCount;
        private long _indexedQuadPrimitiveCount;
        private long _indexedQuadConversionBytes;
        private long _expandedQuadScratchGrowthCount;
        private long _indirectQuadRejectionCount;
        private long _indexedQuadCpuReadbackCount;
        private long _indexedQuadCpuUploadCount;
        private readonly Dictionary<int, BufferRange> _uniformBuffers = [];
        private readonly Dictionary<int, BufferRange> _storageBuffers = [];
        private readonly Dictionary<
            (ShaderStage Stage, int Binding),
            (SolMetalGalTexture Texture, SolMetalGalSampler? Sampler)
        > _texturesAndSamplers = [];
        private readonly Dictionary<
            (ShaderStage Stage, int Binding),
            SolMetalGalTexture
        > _images = [];
        private SolMetalNativeBridge.GalStageBindings _cachedVertexBindings =
            SolMetalNativeBridge.GalStageBindings.Empty;
        private SolMetalNativeBridge.GalStageBindings _cachedFragmentBindings =
            SolMetalNativeBridge.GalStageBindings.Empty;
        private SolMetalNativeBridge.GalStageBindings _cachedComputeBindings =
            SolMetalNativeBridge.GalStageBindings.Empty;
        private bool _vertexBindingsDirty = true;
        private bool _fragmentBindingsDirty = true;
        private bool _computeBindingsDirty = true;
        private int _lastFragmentDummyTextureBindings;
        private int _lastVertexDummyTextureBindings;
        private int _lastVertexDummyBufferBindings;
        private int _lastFragmentDummyBufferBindings;
        private long _stageBindingRebuildCount;
        private long _avoidedStageBindingInvalidationCount;
        private long _colorBindingRebuildCount;
        private long _avoidedColorBindingRebuildCount;

        internal long StageBindingRebuildCount => _stageBindingRebuildCount;
        internal long AvoidedStageBindingInvalidationCount =>
            _avoidedStageBindingInvalidationCount;
        internal long ColorBindingRebuildCount => _colorBindingRebuildCount;
        internal long AvoidedColorBindingRebuildCount =>
            _avoidedColorBindingRebuildCount;
        internal BufferHandle SequentialQuadIndexBuffer =>
            _sequentialQuadIndexBuffer;
        internal BufferHandle ExpandedQuadIndexBuffer =>
            _expandedQuadIndexBuffer;
        internal long IndexedQuadConversionCount =>
            _indexedQuadConversionCount;
        internal long IndexedQuadPrimitiveCount => _indexedQuadPrimitiveCount;
        internal long IndexedQuadConversionBytes => _indexedQuadConversionBytes;
        internal long ExpandedQuadScratchGrowthCount =>
            _expandedQuadScratchGrowthCount;
        internal long IndirectQuadRejectionCount =>
            _indirectQuadRejectionCount;
        internal long IndexedQuadCpuReadbackCount =>
            _indexedQuadCpuReadbackCount;
        internal long IndexedQuadCpuUploadCount =>
            _indexedQuadCpuUploadCount;

        public SolMetalGalPipeline(SolMetalGalRenderer renderer)
        {
            _renderer = renderer;
            SolMetalNativeBridge.GalBlendState defaultBlend = new(
                false,
                SolMetalNativeBridge.GalBlendOperation.Add,
                SolMetalNativeBridge.GalBlendOperation.Add,
                SolMetalNativeBridge.GalBlendFactor.One,
                SolMetalNativeBridge.GalBlendFactor.Zero,
                SolMetalNativeBridge.GalBlendFactor.One,
                SolMetalNativeBridge.GalBlendFactor.Zero
            );
            for (int index = 0; index < MaxColorAttachments; index++)
            {
                _colorWriteMasks[index] = 0xf;
                _blendStates[index] = defaultBlend;
                _colorLoadActions[index] =
                    SolMetalNativeBridge.GalRenderLoadAction.Load;
                _clearColors[index] = new ColorF(0, 0, 0, 0);
            }
        }

        private static int GetQuadPrimitiveCount(int elementCount)
        {
            if (elementCount < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(elementCount));
            }
            return elementCount / QuadVerticesPerPrimitive;
        }

        private static int GetQuadTriangleIndexCount(int elementCount)
        {
            long count = (long)GetQuadPrimitiveCount(elementCount) *
                QuadTriangleIndicesPerPrimitive;
            if (count * sizeof(uint) > MaximumQuadScratchBytes)
            {
                throw Unsupported(
                    "a quad conversion whose generated index buffer exceeds " +
                    $"the {MaximumQuadScratchBytes / (1024 * 1024)} MiB " +
                    "scratch limit"
                );
            }
            return (int)count;
        }

        private static int GetQuadStripNativeElementCount(int elementCount)
        {
            if (elementCount < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(elementCount));
            }

            // A quad strip needs two vertex pairs for its first quad. Any
            // unmatched final vertex is not part of a primitive and must not
            // become an extra triangle when the draw is remapped to Metal's
            // triangle-strip topology.
            return elementCount < 4 ? 0 : elementCount & ~1;
        }

        private static int GetIndexByteSize(IndexType type) => type switch
        {
            IndexType.UByte => sizeof(byte),
            IndexType.UShort => sizeof(ushort),
            IndexType.UInt => sizeof(uint),
            _ => throw Unsupported($"index type {type}"),
        };

        private static int GrowQuadPrimitiveCapacity(
            int current,
            int required
        )
        {
            int maximum = MaximumQuadPrimitiveCapacity;
            if (required <= 0 || required > maximum)
            {
                throw Unsupported(
                    $"quad conversion outside the " +
                    $"{MaximumQuadScratchBytes / (1024 * 1024)} MiB " +
                    "scratch limit"
                );
            }
            if (current >= required)
            {
                return current;
            }

            int capacity = current == 0
                ? Math.Min(MinimumCachedQuadPrimitiveCapacity, maximum)
                : current;
            while (capacity < required)
            {
                capacity = capacity > maximum / 2
                    ? maximum
                    : capacity * 2;
            }
            return capacity;
        }

        private static void FillSequentialQuadIndices(
            Span<uint> destination,
            int primitiveCount
        )
        {
            int required = checked(
                primitiveCount * QuadTriangleIndicesPerPrimitive
            );
            if (primitiveCount < 0 || destination.Length < required)
            {
                throw new ArgumentOutOfRangeException(nameof(destination));
            }

            ReadOnlySpan<uint> pattern = QuadTrianglePattern;
            int output = 0;
            uint first = 0;
            for (int primitive = 0; primitive < primitiveCount; primitive++)
            {
                for (int index = 0; index < pattern.Length; index++)
                {
                    destination[output++] = first + pattern[index];
                }
                first += QuadVerticesPerPrimitive;
            }
        }

        private static uint ReadIndex(
            ReadOnlySpan<byte> source,
            IndexType type,
            int index
        ) => type switch
        {
            IndexType.UByte => source[index],
            IndexType.UShort => BinaryPrimitives.ReadUInt16LittleEndian(
                source.Slice(index * sizeof(ushort), sizeof(ushort))
            ),
            IndexType.UInt => BinaryPrimitives.ReadUInt32LittleEndian(
                source.Slice(index * sizeof(uint), sizeof(uint))
            ),
            _ => throw Unsupported($"index type {type}"),
        };

        private static void ExpandQuadIndices(
            ReadOnlySpan<byte> source,
            IndexType type,
            int primitiveCount,
            Span<uint> destination
        )
        {
            int sourceElements = checked(
                primitiveCount * QuadVerticesPerPrimitive
            );
            int sourceBytes = checked(sourceElements * GetIndexByteSize(type));
            int destinationElements = checked(
                primitiveCount * QuadTriangleIndicesPerPrimitive
            );
            if (primitiveCount < 0 || source.Length < sourceBytes ||
                destination.Length < destinationElements)
            {
                throw new ArgumentOutOfRangeException(nameof(source));
            }

            int input = 0;
            int output = 0;
            for (int primitive = 0; primitive < primitiveCount; primitive++)
            {
                uint first = ReadIndex(source, type, input);
                uint second = ReadIndex(source, type, input + 1);
                uint third = ReadIndex(source, type, input + 2);
                uint fourth = ReadIndex(source, type, input + 3);
                destination[output] = first;
                destination[output + 1] = second;
                destination[output + 2] = third;
                destination[output + 3] = first;
                destination[output + 4] = third;
                destination[output + 5] = fourth;
                input += QuadVerticesPerPrimitive;
                output += QuadTriangleIndicesPerPrimitive;
            }
        }

        private BufferHandle EnsureSequentialQuadIndexBuffer(
            int primitiveCount
        )
        {
            if (_sequentialQuadIndexBuffer != BufferHandle.Null &&
                _sequentialQuadPrimitiveCapacity >= primitiveCount)
            {
                return _sequentialQuadIndexBuffer;
            }

            int capacity = GrowQuadPrimitiveCapacity(
                _sequentialQuadPrimitiveCapacity,
                primitiveCount
            );
            int indexCount = checked(
                capacity * QuadTriangleIndicesPerPrimitive
            );
            int byteCount = checked(indexCount * sizeof(uint));
            uint[] indices = ArrayPool<uint>.Shared.Rent(indexCount);
            BufferHandle replacement = BufferHandle.Null;
            try
            {
                FillSequentialQuadIndices(
                    indices.AsSpan(0, indexCount),
                    capacity
                );
                replacement = _renderer.CreateBuffer(
                    byteCount,
                    BufferAccess.DeviceMemory
                );
                _renderer.SetBufferData(
                    replacement,
                    0,
                    MemoryMarshal.AsBytes(indices.AsSpan(0, indexCount))
                );
            }
            catch
            {
                if (replacement != BufferHandle.Null)
                {
                    _renderer.DeleteBuffer(replacement);
                }
                throw;
            }
            finally
            {
                ArrayPool<uint>.Shared.Return(indices);
            }

            // Keep superseded buffers renderer-owned until disposal. A prior
            // draw may still reference one from an open Metal command buffer.
            _sequentialQuadIndexBuffer = replacement;
            _sequentialQuadPrimitiveCapacity = capacity;
            return replacement;
        }

        private BufferHandle EnsureExpandedQuadIndexBuffer(int primitiveCount)
        {
            if (_expandedQuadIndexBuffer != BufferHandle.Null &&
                _expandedQuadPrimitiveCapacity >= primitiveCount)
            {
                return _expandedQuadIndexBuffer;
            }

            int capacity = GrowQuadPrimitiveCapacity(
                _expandedQuadPrimitiveCapacity,
                primitiveCount
            );
            int byteCount = checked(
                capacity * QuadTriangleIndicesPerPrimitive * sizeof(uint)
            );
            BufferHandle replacement = _renderer.CreateBuffer(
                byteCount,
                BufferAccess.DeviceMemory
            );
            // As above, replacement is intentionally non-destructive for any
            // already-encoded draw that still owns the previous MTLBuffer.
            _expandedQuadIndexBuffer = replacement;
            _expandedQuadPrimitiveCapacity = capacity;
            _expandedQuadScratchGrowthCount++;
            return replacement;
        }

        private (int Offset, int ByteCount) ResolveQuadIndexSourceRange(
            BufferRange range,
            IndexType type,
            int firstIndex,
            int indexCount
        )
        {
            int indexSize = GetIndexByteSize(type);
            long relativeOffset = (long)firstIndex * indexSize;
            long byteCount = (long)indexCount * indexSize;
            long absoluteOffset = (long)range.Offset + relativeOffset;
            if (range.Handle == BufferHandle.Null || range.Offset < 0 ||
                range.Size < 0 || firstIndex < 0 || indexCount < 0 ||
                relativeOffset > range.Size ||
                byteCount > range.Size - relativeOffset ||
                absoluteOffset < 0 || absoluteOffset > int.MaxValue ||
                byteCount > int.MaxValue)
            {
                throw Unsupported(
                    "a quad conversion outside the bound index-buffer range"
                );
            }
            return ((int)absoluteOffset, (int)byteCount);
        }

        private SolMetalNativeBridge.GalIndexBinding
            PrepareSequentialQuadIndexBinding(
                int primitiveCount,
                int firstVertex,
                int firstInstance
            )
        {
            int indexCount = checked(
                primitiveCount * QuadTriangleIndicesPerPrimitive
            );
            BufferHandle handle = EnsureSequentialQuadIndexBuffer(
                primitiveCount
            );
            SolMetalNativeBridge.GalBufferBinding binding =
                _renderer.ResolveBufferBinding(
                    0,
                    new BufferRange(
                        handle,
                        0,
                        checked(indexCount * sizeof(uint))
                    )
                );
            return new SolMetalNativeBridge.GalIndexBinding(
                binding.Buffer,
                binding.Offset,
                SolMetalNativeBridge.GalIndexType.Uint32,
                firstVertex,
                checked((uint)firstInstance)
            );
        }

        private SolMetalNativeBridge.GalIndexBinding
            PrepareExpandedQuadIndexBinding(
                BufferRange sourceRange,
                IndexType sourceType,
                int indexCount,
                int firstIndex,
                int baseVertex,
                int firstInstance,
                int primitiveCount
            )
        {
            long bufferReadbacksBefore = _renderer.BufferReadbackCallCount;
            long bufferUploadsBefore = _renderer.BufferUploadCallCount;
            (int sourceOffset, int sourceByteCount) =
                ResolveQuadIndexSourceRange(
                    sourceRange,
                    sourceType,
                    firstIndex,
                    indexCount
                );
            int convertedCount = checked(
                primitiveCount * QuadTriangleIndicesPerPrimitive
            );
            int convertedBytes = checked(convertedCount * sizeof(uint));
            BufferHandle handle = EnsureExpandedQuadIndexBuffer(
                primitiveCount
            );
            SolMetalNativeBridge.GalIndexType nativeSourceType = sourceType switch
            {
                IndexType.UByte => SolMetalNativeBridge.GalIndexType.Uint8,
                IndexType.UShort => SolMetalNativeBridge.GalIndexType.Uint16,
                IndexType.UInt => SolMetalNativeBridge.GalIndexType.Uint32,
                _ => throw Unsupported($"index type {sourceType}"),
            };
            _renderer.ExpandQuadIndices(
                sourceRange.Handle,
                sourceOffset,
                sourceByteCount,
                nativeSourceType,
                primitiveCount,
                handle,
                0,
                convertedBytes
            );
            _indexedQuadCpuReadbackCount +=
                _renderer.BufferReadbackCallCount - bufferReadbacksBefore;
            _indexedQuadCpuUploadCount +=
                _renderer.BufferUploadCallCount - bufferUploadsBefore;
            _indexedQuadConversionCount++;
            _indexedQuadPrimitiveCount += primitiveCount;
            _indexedQuadConversionBytes += convertedBytes;

            SolMetalNativeBridge.GalBufferBinding binding =
                _renderer.ResolveBufferBinding(
                    0,
                    new BufferRange(handle, 0, convertedBytes)
                );
            return new SolMetalNativeBridge.GalIndexBinding(
                binding.Buffer,
                binding.Offset,
                SolMetalNativeBridge.GalIndexType.Uint32,
                baseVertex,
                checked((uint)firstInstance)
            );
        }

        internal static void ValidateQuadTopologyConversion()
        {
            uint[] sequential = new uint[12];
            FillSequentialQuadIndices(sequential, primitiveCount: 2);
            if (!sequential.AsSpan().SequenceEqual(new uint[]
                {
                    0, 1, 2, 0, 2, 3,
                    4, 5, 6, 4, 6, 7,
                }) ||
                GetQuadTriangleIndexCount(3) != 0 ||
                GetQuadTriangleIndexCount(7) != 6 ||
                GetQuadStripNativeElementCount(3) != 0 ||
                GetQuadStripNativeElementCount(4) != 4 ||
                GetQuadStripNativeElementCount(5) != 4 ||
                GetQuadStripNativeElementCount(7) != 6)
            {
                throw new InvalidOperationException(
                    "SolMetal changed the quad-to-triangle conversion pattern."
                );
            }

            byte[] byteSource = [3, 7, 11, 19];
            ushort[] shortSource = [300, 700, 1100, 1900];
            uint[] intSource = [70_000, 700_000, 7_000_000, 70_000_000];
            uint[] output = new uint[6];
            foreach ((IndexType Type, byte[] Source, uint[] Expected) fixture in
                new[]
                {
                    (
                        IndexType.UByte,
                        byteSource,
                        new uint[] { 3, 7, 11, 3, 11, 19 }
                    ),
                    (
                        IndexType.UShort,
                        MemoryMarshal.AsBytes(shortSource.AsSpan()).ToArray(),
                        new uint[] { 300, 700, 1100, 300, 1100, 1900 }
                    ),
                    (
                        IndexType.UInt,
                        MemoryMarshal.AsBytes(intSource.AsSpan()).ToArray(),
                        new uint[]
                        {
                            70_000,
                            700_000,
                            7_000_000,
                            70_000,
                            7_000_000,
                            70_000_000,
                        }
                    ),
                })
            {
                output.AsSpan().Clear();
                ExpandQuadIndices(
                    fixture.Source,
                    fixture.Type,
                    primitiveCount: 1,
                    output
                );
                if (!output.AsSpan().SequenceEqual(fixture.Expected))
                {
                    throw new InvalidOperationException(
                        $"SolMetal changed {fixture.Type} quad index expansion."
                    );
                }
            }

            int maximumElementCount = checked(
                MaximumQuadPrimitiveCapacity * QuadVerticesPerPrimitive
            );
            if (GetQuadTriangleIndexCount(maximumElementCount) !=
                MaximumQuadPrimitiveCapacity *
                    QuadTriangleIndicesPerPrimitive)
            {
                throw new InvalidOperationException(
                    "SolMetal rejected its exact quad scratch-buffer limit."
                );
            }
            try
            {
                _ = GetQuadTriangleIndexCount(checked(
                    maximumElementCount + QuadVerticesPerPrimitive
                ));
            }
            catch (NotSupportedException exception) when (
                exception.Message.Contains("scratch limit", StringComparison.Ordinal)
            )
            {
                return;
            }
            throw new InvalidOperationException(
                "SolMetal accepted a quad conversion above its scratch limit."
            );
        }

        internal void InvalidateTextureBindings(SolMetalGalTexture texture)
        {
            foreach (((ShaderStage stage, int _), var pair) in
                     _texturesAndSamplers)
            {
                if (ReferenceEquals(pair.Texture, texture))
                {
                    MarkStageBindingsDirty(stage);
                }
            }
            foreach (((ShaderStage stage, int _), SolMetalGalTexture image) in
                     _images)
            {
                if (ReferenceEquals(image, texture))
                {
                    MarkStageBindingsDirty(stage);
                }
            }
        }

        public void Barrier() => _renderer.EncodeBarrier();
        public void CommandBufferBarrier() => _renderer.EncodeBarrier();
        public void TextureBarrier() => _renderer.EncodeBarrier();
        public void TextureBarrierTiled() => _renderer.EncodeBarrier();

        public void CopyBuffer(
            BufferHandle source,
            BufferHandle destination,
            int srcOffset,
            int dstOffset,
            int size
        ) => _renderer.CopyBuffer(source, destination, srcOffset, dstOffset, size);

        public void BeginTransformFeedback(PrimitiveTopology topology) => Fail("transform feedback");
        public void ClearBuffer(
            BufferHandle destination,
            int offset,
            int size,
            uint value
        ) => _renderer.ClearBuffer(destination, offset, size, value);
        public void ClearRenderTargetColor(
            int index,
            int layer,
            int layerCount,
            uint componentMask,
            ColorF color
        )
        {
            if ((uint)index >= MaxColorAttachments)
            {
                Fail($"color clear attachment {index}");
            }
            // GAL backends treat a clear against an unattached slot as a
            // no-op. Guest command streams legitimately emit these while
            // transitioning between attachmentless and color passes.
            if (_colorTargets[index] is null)
            {
                return;
            }
            if (layer < 0 || layerCount <= 0 ||
                layer > _colorTargets[index]!.Layers - layerCount ||
                (componentMask & ~0xfu) != 0)
            {
                Fail(
                    $"invalid color clear " +
                    $"(attachment={index}, layer={layer}, " +
                    $"layers={layerCount}, mask=0x{componentMask:x})"
                );
            }
            if (componentMask == 0)
            {
                return;
            }
            SolMetalGalTexture target = _colorTargets[index]!;
            Rectangle<int> clearRegion = ResolveClearRegion(
                target.Width,
                target.Height
            );
            if (clearRegion.Width == 0 || clearRegion.Height == 0)
            {
                return;
            }
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                _renderer._session.ClearColorTexture(
                    target.Native,
                    layer,
                    layerCount,
                    componentMask,
                    clearRegion.X,
                    clearRegion.Y,
                    clearRegion.Width,
                    clearRegion.Height,
                    color.Red,
                    color.Green,
                    color.Blue,
                    color.Alpha,
                    unchecked((uint)BitConverter.SingleToInt32Bits(color.Red)),
                    unchecked((uint)BitConverter.SingleToInt32Bits(color.Green)),
                    unchecked((uint)BitConverter.SingleToInt32Bits(color.Blue)),
                    unchecked((uint)BitConverter.SingleToInt32Bits(color.Alpha))
                );
            }
            target.MarkProbeColorClear(clearRegion, componentMask, color);
            _clearColors[index] = color;
            _colorLoadActions[index] =
                SolMetalNativeBridge.GalRenderLoadAction.Load;
            _colorBindingStateDirty = true;
        }
        public void ClearRenderTargetDepthStencil(
            int layer,
            int layerCount,
            float depthValue,
            bool depthMask,
            int stencilValue,
            int stencilMask
        )
        {
            // Match the established GAL contract: clearing depth/stencil with
            // no bound depth attachment is harmless and must not abort the
            // guest render loop.
            if (_depthStencilTarget is null)
            {
                return;
            }
            if (layer < 0 || layerCount <= 0 ||
                layer > _depthStencilTarget.Layers - layerCount ||
                !float.IsFinite(depthValue) || depthValue < 0 || depthValue > 1)
            {
                Fail(
                    $"layered or invalid depth/stencil clear " +
                    $"(layer={layer}, layers={layerCount}, " +
                    $"depth={depthValue}, depthMask={depthMask}, " +
                    $"stencil={stencilValue}, stencilMask=0x{stencilMask:x})"
                );
            }
            uint clearStencil = unchecked((uint)stencilValue);
            if (!depthMask && stencilMask == 0)
            {
                return;
            }
            SolMetalGalTexture target = _depthStencilTarget;
            Rectangle<int> clearRegion = ResolveClearRegion(
                target.Width,
                target.Height
            );
            if (clearRegion.Width == 0 || clearRegion.Height == 0)
            {
                return;
            }
            lock (_renderer._gate)
            {
                _renderer.ThrowIfDisposed();
                _renderer._session.ClearDepthStencilTexture(
                    target.Native,
                    layer,
                    layerCount,
                    depthMask,
                    stencilMask,
                    clearRegion.X,
                    clearRegion.Y,
                    clearRegion.Width,
                    clearRegion.Height,
                    depthValue,
                    clearStencil
                );
            }
            _clearDepth = depthValue;
            _clearStencil = clearStencil;
            _depthLoadAction = SolMetalNativeBridge.GalRenderLoadAction.Load;
            _stencilLoadAction = SolMetalNativeBridge.GalRenderLoadAction.Load;
            target.MarkProbeDepthClear(depthValue, depthMask);
        }

        private Rectangle<int> ResolveClearRegion(int width, int height)
        {
            Rectangle<int> requested = _scissor ?? new Rectangle<int>(
                0,
                0,
                width,
                height
            );
            int left = Math.Clamp(requested.X, 0, width);
            int top = Math.Clamp(requested.Y, 0, height);
            long requestedRight = (long)requested.X + requested.Width;
            long requestedBottom = (long)requested.Y + requested.Height;
            int right = (int)Math.Clamp(requestedRight, 0L, width);
            int bottom = (int)Math.Clamp(requestedBottom, 0L, height);
            return right <= left || bottom <= top
                ? new Rectangle<int>(0, 0, 0, 0)
                : new Rectangle<int>(left, top, right - left, bottom - top);
        }
        public void DispatchCompute(int groupsX, int groupsY, int groupsZ)
        {
            if (groupsX < 0 || groupsY < 0 || groupsZ < 0)
            {
                throw Unsupported(
                    $"a negative compute dispatch " +
                    $"({groupsX}, {groupsY}, {groupsZ})"
                );
            }
            // Vulkan accepts a zero workgroup count as a no-op, and guest QMD
            // streams rely on that contract. Metal does not accept a zero
            // dispatchThreads grid, so contain it at the GAL boundary.
            if (groupsX == 0 || groupsY == 0 || groupsZ == 0)
            {
                return;
            }
            if (_program is null || !_program.IsCompute)
            {
                throw Unsupported(
                    $"the requested compute dispatch state " +
                    $"({groupsX}, {groupsY}, {groupsZ}, " +
                    $"program={_program?.IsCompute.ToString() ?? "missing"})"
                );
            }
            (uint X, uint Y, uint Z) local = _program.ComputeLocalSize;
            ulong groupThreads = (ulong)local.X * local.Y * local.Z;
            if (groupThreads == 0 ||
                groupThreads > _renderer._session.MaxThreadsPerThreadgroup)
            {
                throw Unsupported("the compute shader's threadgroup size");
            }
            SolMetalNativeBridge.GalStageBindings bindings =
                BuildStageBindings(ShaderStage.Compute, []);
            _renderer._session.DispatchCompute(
                _program.GetComputePipeline(),
                checked((uint)groupsX * local.X),
                checked((uint)groupsY * local.Y),
                checked((uint)groupsZ * local.Z),
                local.X,
                local.Y,
                local.Z,
                bindings
            );
            foreach (SolMetalGalTexture image in _images.Values.Distinct())
            {
                image.MarkProbeWrite(TextureProbeWriteKind.Compute);
            }
        }
        public void Draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance)
        {
            DrawInternal(
                vertexCount,
                instanceCount,
                firstVertex,
                firstInstance,
                indexed: false,
                baseVertex: 0,
                indirectBuffer: null
            );
        }

        public void DrawIndexed(
            int indexCount,
            int instanceCount,
            int firstIndex,
            int firstVertex,
            int firstInstance
        )
        {
            DrawInternal(
                indexCount,
                instanceCount,
                firstIndex,
                firstInstance,
                indexed: true,
                baseVertex: firstVertex,
                indirectBuffer: null
            );
        }

        private void DrawInternal(
            int elementCount,
            int instanceCount,
            int firstElement,
            int firstInstance,
            bool indexed,
            int baseVertex,
            BufferRange? indirectBuffer,
            BufferRange? indirectCountBuffer = null,
            int maxDrawCount = 0,
            int indirectStride = 0
        )
        {
            bool indirect = indirectBuffer.HasValue;
            bool convertQuads = _topology == PrimitiveTopology.Quads;
            bool remapQuadStrip = _topology == PrimitiveTopology.QuadStrip;
            PrimitiveTopology nativeTopology = _topology switch
            {
                PrimitiveTopology.Quads => PrimitiveTopology.Triangles,
                PrimitiveTopology.QuadStrip => PrimitiveTopology.TriangleStrip,
                _ => _topology,
            };
            int nativeElementCount = elementCount;
            int nativeFirstElement = firstElement;
            SolMetalGalTexture? primaryColorTarget = null;
            int primaryColorTargetIndex = -1;
            SolMetalGalTexture? hdrColorTarget = null;
            int hdrColorTargetIndex = -1;
            for (int index = 0; index < MaxColorAttachments; index++)
            {
                if (_colorTargets[index] is not SolMetalGalTexture target)
                {
                    continue;
                }
                primaryColorTarget ??= target;
                if (primaryColorTargetIndex < 0)
                {
                    primaryColorTargetIndex = index;
                }
                if (hdrColorTarget is null &&
                    target.NativeFormat ==
                        SolMetalNativeBridge.GalTextureFormat.Rg11B10Float &&
                    target.CanProbeRaw && target.Width >= 1280 &&
                    target.Height >= 720)
                {
                    hdrColorTarget = target;
                    hdrColorTargetIndex = index;
                }
            }
            SolMetalGalTexture? renderTarget =
                primaryColorTarget ?? _depthStencilTarget;
            if (!indirect && (elementCount == 0 || instanceCount == 0))
            {
                return;
            }
            if (_program is null ||
                (!indirect &&
                 (elementCount < 0 || instanceCount < 0 ||
                  firstElement < 0 || firstInstance < 0)))
            {
                throw Unsupported("the requested draw state");
            }
            if (convertQuads && indirect)
            {
                _indirectQuadRejectionCount++;
                throw Unsupported(
                    indirectCountBuffer.HasValue
                        ? "counted indirect quad topology conversion"
                        : "indirect quad topology conversion"
                );
            }
            if (remapQuadStrip && indirect)
            {
                throw Unsupported(
                    indirectCountBuffer.HasValue
                        ? "counted indirect quad-strip topology conversion"
                        : "indirect quad-strip topology conversion"
                );
            }
            if (_renderer._debugSkipPrograms.Contains(_program.ProbeId) ||
                _renderer._debugSkipProgramKeys.Contains(_program.StableKey))
            {
                return;
            }
            int quadPrimitiveCount = convertQuads
                ? GetQuadPrimitiveCount(elementCount)
                : 0;
            if (convertQuads && quadPrimitiveCount == 0)
            {
                if (indexed)
                {
                    if (_indexBuffer is not BufferRange indexRange)
                    {
                        throw new InvalidOperationException(
                            "SolMetal indexed drawing requires an index buffer."
                        );
                    }
                    _ = ResolveQuadIndexSourceRange(
                        indexRange,
                        _indexType,
                        firstElement,
                        elementCount
                    );
                }
                return;
            }
            if (convertQuads)
            {
                nativeElementCount = GetQuadTriangleIndexCount(elementCount);
                nativeFirstElement = 0;
            }
            else if (remapQuadStrip)
            {
                nativeElementCount = GetQuadStripNativeElementCount(
                    elementCount
                );
                if (nativeElementCount == 0)
                {
                    return;
                }
            }
            if (renderTarget is null && (_viewport is null || _scissor is null))
            {
                throw Unsupported(
                    "an attachmentless draw without explicit viewport and scissor state"
                );
            }
            if (_topology is PrimitiveTopology.Lines or PrimitiveTopology.LineStrip)
            {
                if (_lineSmooth || MathF.Abs(_lineWidth - 1) > 0.0001f)
                {
                    throw Unsupported("wide or smoothed line drawing");
                }
            }

            Viewport viewport = _viewport ?? new Viewport(
                new Rectangle<float>(
                    0,
                    0,
                    renderTarget!.Width,
                    renderTarget.Height
                ),
                ViewportSwizzle.PositiveX,
                ViewportSwizzle.PositiveY,
                ViewportSwizzle.PositiveZ,
                ViewportSwizzle.PositiveW,
                0,
                1
            );
            Rectangle<int> scissor = _scissor ?? new Rectangle<int>(
                0,
                0,
                renderTarget!.Width,
                renderTarget.Height
            );
            int renderWidth;
            int renderHeight;
            if (renderTarget is not null)
            {
                renderWidth = renderTarget.Width;
                renderHeight = renderTarget.Height;
            }
            else
            {
                double viewportRight = Math.Max(
                    viewport.Region.X,
                    viewport.Region.X + viewport.Region.Width
                );
                double viewportBottom = Math.Max(
                    viewport.Region.Y,
                    viewport.Region.Y + viewport.Region.Height
                );
                long scissorRightEdge = (long)scissor.X + scissor.Width;
                long scissorBottomEdge = (long)scissor.Y + scissor.Height;
                double requiredWidth = Math.Max(viewportRight, scissorRightEdge);
                double requiredHeight = Math.Max(viewportBottom, scissorBottomEdge);
                if (!double.IsFinite(requiredWidth) ||
                    !double.IsFinite(requiredHeight) ||
                    requiredWidth <= 0 || requiredHeight <= 0 ||
                    requiredWidth > 16_384 || requiredHeight > 16_384)
                {
                    throw Unsupported("invalid attachmentless render dimensions");
                }
                renderWidth = checked((int)Math.Ceiling(requiredWidth));
                renderHeight = checked((int)Math.Ceiling(requiredHeight));
            }
            int scissorX = Math.Clamp(scissor.X, 0, renderWidth);
            int scissorY = Math.Clamp(scissor.Y, 0, renderHeight);
            int scissorRight = (int)Math.Min(
                renderWidth,
                (long)scissor.X + scissor.Width
            );
            int scissorBottom = (int)Math.Min(
                renderHeight,
                (long)scissor.Y + scissor.Height
            );
            if (scissorRight <= scissorX || scissorBottom <= scissorY)
            {
                throw Unsupported("an empty clipped scissor");
            }
            scissor = new Rectangle<int>(
                scissorX,
                scissorY,
                scissorRight - scissorX,
                scissorBottom - scissorY
            );
            BuildVertexState(
                out SolMetalNativeBridge.GalVertexBufferLayout[] layouts,
                out SolMetalNativeBridge.GalVertexAttribute[] attributes,
                out SolMetalNativeBridge.GalBufferBinding[] vertexInputs
            );
            SolMetalNativeBridge.GalStageBindings vertexBindings =
                BuildStageBindings(ShaderStage.Vertex, vertexInputs);
            SolMetalNativeBridge.GalStageBindings fragmentBindings =
                BuildStageBindings(ShaderStage.Fragment, []);
            SolMetalNativeBridge.GalIndexBinding? nativeIndex = null;
            if (convertQuads && indexed)
            {
                if (_indexBuffer is not BufferRange indexRange)
                {
                    throw new InvalidOperationException(
                        "SolMetal indexed drawing requires an index buffer."
                    );
                }
                nativeIndex = PrepareExpandedQuadIndexBinding(
                    indexRange,
                    _indexType,
                    elementCount,
                    firstElement,
                    baseVertex,
                    firstInstance,
                    quadPrimitiveCount
                );
            }
            else if (convertQuads)
            {
                nativeIndex = PrepareSequentialQuadIndexBinding(
                    quadPrimitiveCount,
                    firstElement,
                    firstInstance
                );
            }
            else if (indexed)
            {
                if (_indexBuffer is not BufferRange indexRange)
                {
                    throw new InvalidOperationException(
                        "SolMetal indexed drawing requires an index buffer."
                    );
                }
                SolMetalNativeBridge.GalBufferBinding index =
                    _renderer.ResolveBufferBinding(0, indexRange);
                SolMetalNativeBridge.GalIndexType indexType = _indexType switch
                {
                    IndexType.UByte => SolMetalNativeBridge.GalIndexType.Uint8,
                    IndexType.UShort => SolMetalNativeBridge.GalIndexType.Uint16,
                    IndexType.UInt => SolMetalNativeBridge.GalIndexType.Uint32,
                    _ => throw Unsupported($"index type {_indexType}"),
                };
                nativeIndex = new SolMetalNativeBridge.GalIndexBinding(
                    index.Buffer,
                    index.Offset,
                    indexType,
                    indirect ? 0 : baseVertex,
                    indirect ? 0 : checked((uint)firstInstance)
                );
            }
            SolMetalNativeBridge.GalIndirectBinding? nativeIndirect = null;
            SolMetalNativeBridge.GalIndirectCountBinding? nativeIndirectCount = null;
            if (indirectBuffer is BufferRange indirectRange)
            {
                SolMetalNativeBridge.GalBufferBinding commandBinding =
                    _renderer.ResolveBufferBinding(0, indirectRange);
                nativeIndirect = new SolMetalNativeBridge.GalIndirectBinding(
                    commandBinding.Buffer,
                    commandBinding.Offset,
                    checked((ulong)indirectRange.Size)
                );
            }
            if (indirectCountBuffer is BufferRange countRange)
            {
                if (maxDrawCount <= 0 || indirectStride <= 0)
                {
                    throw Unsupported("invalid counted indirect draw bounds");
                }
                SolMetalNativeBridge.GalBufferBinding countBinding =
                    _renderer.ResolveBufferBinding(0, countRange);
                nativeIndirectCount =
                    new SolMetalNativeBridge.GalIndirectCountBinding(
                        countBinding.Buffer,
                        countBinding.Offset,
                        checked((ulong)countRange.Size),
                        checked((uint)maxDrawCount),
                        checked((uint)indirectStride)
                    );
            }
            SolMetalNativeBridge.GalDepthStencilState guestDepthStencilState =
                BuildDepthStencilState();
            SolMetalNativeBridge.GalDepthStencilState depthStencilState =
                guestDepthStencilState;
            if (_renderer._debugForceDepthAlwaysPrograms.Contains(
                    _program.ProbeId) ||
                _renderer._debugForceDepthAlwaysProgramKeys.Contains(
                    _program.StableKey))
            {
                depthStencilState = depthStencilState with
                {
                    DepthCompareFunction =
                        SolMetalNativeBridge.GalCompareFunction.Always,
                };
            }
            SolMetalNativeBridge.GalFrontFaceWinding drawFrontFace =
                _frontFace;
            if (_renderer._debugInvertAllFrontFaces)
            {
                drawFrontFace = drawFrontFace ==
                    SolMetalNativeBridge.GalFrontFaceWinding.Clockwise
                        ? SolMetalNativeBridge.GalFrontFaceWinding.CounterClockwise
                        : SolMetalNativeBridge.GalFrontFaceWinding.Clockwise;
            }
            if (_renderer._debugInvertNegativeViewportFrontFace &&
                viewport.Region.Height < 0)
            {
                drawFrontFace = drawFrontFace ==
                    SolMetalNativeBridge.GalFrontFaceWinding.Clockwise
                        ? SolMetalNativeBridge.GalFrontFaceWinding.CounterClockwise
                        : SolMetalNativeBridge.GalFrontFaceWinding.Clockwise;
            }
            if (_renderer._debugInvertPositiveViewportFrontFace &&
                viewport.Region.Height > 0)
            {
                drawFrontFace = drawFrontFace ==
                    SolMetalNativeBridge.GalFrontFaceWinding.Clockwise
                        ? SolMetalNativeBridge.GalFrontFaceWinding.CounterClockwise
                        : SolMetalNativeBridge.GalFrontFaceWinding.Clockwise;
            }
            SolMetalNativeBridge.GalCullMode drawCullMode =
                _renderer._debugDisableFaceCulling
                    ? SolMetalNativeBridge.GalCullMode.None
                    : _cullMode;
            if (_renderer._debugSwapFaceCulling)
            {
                drawCullMode = drawCullMode switch
                {
                    SolMetalNativeBridge.GalCullMode.Front =>
                        SolMetalNativeBridge.GalCullMode.Back,
                    SolMetalNativeBridge.GalCullMode.Back =>
                        SolMetalNativeBridge.GalCullMode.Front,
                    _ => drawCullMode,
                };
            }
            SolMetalNativeBridge.GalDepthClipMode drawDepthClipMode =
                _renderer._debugForceDepthClamp
                    ? SolMetalNativeBridge.GalDepthClipMode.Clamp
                    : _depthClipMode;
            RebuildColorBindingStateIfNeeded();
            bool debugDisableColorWrites =
                _renderer._debugDisableColorWriteProgramKeys.Contains(
                    _program.StableKey
                );
            SolMetalNativeBridge.GalRenderColorAttachmentState[]
                colorAttachments = debugDisableColorWrites
                    ? _cachedColorAttachments.Select(attachment =>
                        attachment with { ColorWriteMask = 0 }).ToArray()
                    : _cachedColorAttachments;
            SolMetalNativeBridge.GalRenderColorTarget[] nativeColorTargets =
                _cachedNativeColorTargets;
            SolMetalNativeBridge.GalRenderPipelineState pipelineState = new(
                colorAttachments,
                _depthStencilTarget?.NativeFormat ?? 0,
                depthStencilState,
                _alphaToCoverageEnabled,
                _alphaToCoverageDitherEnabled,
                _alphaToOneEnabled,
                MapPrimitiveTopologyClass(nativeTopology)
            );
            IntPtr pipeline = _program.GetPipeline(
                pipelineState,
                layouts,
                attributes
            );
            bool hasStencil = _depthStencilTarget?.NativeFormat is
                SolMetalNativeBridge.GalTextureFormat.Depth32FloatStencil8 or
                SolMetalNativeBridge.GalTextureFormat.D24UnormStencil8;
            SolMetalNativeBridge.GalRenderPassState? renderPass =
                _depthStencilTarget is null
                    ? null
                    : new SolMetalNativeBridge.GalRenderPassState(
                        _depthStencilTarget.Native,
                        _depthLoadAction,
                        SolMetalNativeBridge.GalRenderStoreAction.Store,
                        hasStencil
                            ? _stencilLoadAction
                            : (SolMetalNativeBridge.GalRenderLoadAction)0,
                        hasStencil
                            ? SolMetalNativeBridge.GalRenderStoreAction.Store
                            : (SolMetalNativeBridge.GalRenderStoreAction)0,
                        _clearDepth,
                        hasStencil ? _clearStencil : 0,
                        hasStencil
                            ? unchecked((uint)_stencilTest.FrontFuncRef)
                            : 0,
                        hasStencil
                            ? unchecked((uint)_stencilTest.BackFuncRef)
                            : 0
                    );
            int descriptorColorIndex = Math.Max(primaryColorTargetIndex, 0);
            SolMetalNativeBridge.GalRenderLoadAction descriptorColorLoad =
                primaryColorTargetIndex < 0
                    ? SolMetalNativeBridge.GalRenderLoadAction.DontCare
                    : _colorLoadActions[primaryColorTargetIndex];
            ColorF descriptorClear = primaryColorTargetIndex < 0
                ? new ColorF(0, 0, 0, 0)
                : _clearColors[primaryColorTargetIndex];
            SolMetalNativeBridge.GalRenderDrawState drawState = new(
                MapPrimitiveType(nativeTopology),
                checked((uint)descriptorColorIndex),
                descriptorColorLoad,
                SolMetalNativeBridge.GalRenderStoreAction.Store,
                indirect ? 0 : checked((uint)nativeFirstElement),
                indirect ? 0 : checked((uint)nativeElementCount),
                indirect ? 0 : checked((uint)instanceCount),
                indirect ? 0 : checked((uint)firstInstance),
                descriptorClear.Red,
                descriptorClear.Green,
                descriptorClear.Blue,
                descriptorClear.Alpha,
                viewport.Region.X,
                viewport.Region.Y,
                viewport.Region.Width,
                viewport.Region.Height,
                viewport.DepthNear,
                viewport.DepthFar,
                checked((uint)scissor.X),
                checked((uint)scissor.Y),
                checked((uint)scissor.Width),
                checked((uint)scissor.Height),
                _blendConstant.Red,
                _blendConstant.Green,
                _blendConstant.Blue,
                _blendConstant.Alpha,
                renderPass,
                new SolMetalNativeBridge.GalRasterizerState(
                    drawFrontFace,
                    drawCullMode,
                    _fillMode,
                    drawDepthClipMode,
                    _depthBias,
                    _depthBiasSlopeScale,
                    _depthBiasClamp
                )
            );
            bool isHdrLargeProbeCandidate =
                hdrColorTarget is not null && elementCount >= 100_000;
            SolMetalGalTexture? postDrawProbeTarget =
                isHdrLargeProbeCandidate
                    ? hdrColorTarget
                    : primaryColorTarget is
                {
                    CanProbeRaw: true,
                    Width: >= 1280,
                    Height: >= 720,
                } candidateProbeTarget
                    ? candidateProbeTarget
                    : null;
            bool isInstancedProbeCandidate = instanceCount > 1;
            bool isLargeProbeCandidate = elementCount >= 1_024;
            bool isFullscreenProbeCandidate =
                instanceCount == 1 &&
                elementCount == 3 &&
                _depthStencilTarget is null &&
                _cullMode == SolMetalNativeBridge.GalCullMode.None;
            bool collectPostDrawProbe = false;
            string postDrawProbeRole = "draw";
            if (!indirect && _renderer._frameProbeEnabled &&
                postDrawProbeTarget is not null)
            {
                if (isHdrLargeProbeCandidate &&
                    Interlocked.Decrement(
                        ref _renderer._postHdrLargeDrawProbeBudget
                    ) >= 0)
                {
                    collectPostDrawProbe = true;
                    postDrawProbeRole = $"HDR-large-slot-{hdrColorTargetIndex}";
                }
                else if (isLargeProbeCandidate &&
                    Interlocked.Decrement(
                        ref _renderer._postLargeDrawProbeBudget
                    ) >= 0)
                {
                    collectPostDrawProbe = true;
                    postDrawProbeRole = "large";
                }
                else if (isInstancedProbeCandidate &&
                    Interlocked.Decrement(
                        ref _renderer._postInstancedDrawProbeBudget
                    ) >= 0)
                {
                    collectPostDrawProbe = true;
                    postDrawProbeRole = "instanced";
                }
                else if (isFullscreenProbeCandidate &&
                    Interlocked.Decrement(
                        ref _renderer._postFullscreenDrawProbeBudget
                    ) >= 0)
                {
                    collectPostDrawProbe = true;
                    postDrawProbeRole = "fullscreen";
                }
            }
            IntPtr sampleCounterQuery = _renderer._sampleCounterQuery;
            bool collectSampleCounter = !indirect &&
                sampleCounterQuery != IntPtr.Zero;
            TargetedProbeSelection targetedProbeSelection = default;
            bool collectTargetedVisibility = !indirect &&
                _renderer._frameProbeEnabled &&
                _renderer.TryTakeTargetedVisibilityProbe(
                    _program,
                    _colorTargets,
                    _depthStencilTarget,
                    guestDepthStencilState,
                    elementCount,
                    instanceCount,
                    () => BuildTargetedD16ReplaySnapshot(
                        _depthStencilTarget,
                        guestDepthStencilState
                    ),
                    out targetedProbeSelection
                );
            bool collectVisibility = collectPostDrawProbe ||
                collectTargetedVisibility;
            bool collectTargetedTextureProbe = collectTargetedVisibility &&
                targetedProbeSelection.CaptureTextures;
            SolMetalGalTexture? selectedProbeDepthTarget =
                collectTargetedVisibility ? _depthStencilTarget : null;
            string? selectedProbeDepthIdentity = selectedProbeDepthTarget is null
                ? null
                : $"#{selectedProbeDepthTarget.ProbeId}/view " +
                    $"#{selectedProbeDepthTarget.ProbeViewId}:" +
                    $"{selectedProbeDepthTarget.Format}/" +
                    $"{selectedProbeDepthTarget.NativeFormat}:" +
                    $"{selectedProbeDepthTarget.Width}x" +
                    $"{selectedProbeDepthTarget.Height}";
            ProbeDrawDepthSnapshot targetedProbeDepth = new(
                selectedProbeDepthTarget,
                selectedProbeDepthIdentity,
                _depthLoadAction,
                _clearDepth,
                depthStencilState.DepthCompareFunction,
                depthStencilState.DepthWriteEnabled
            );
            if (collectTargetedTextureProbe)
            {
                CaptureTargetedTextureProbe(
                    targetedProbeSelection,
                    targetedProbeDepth,
                    phase: "before-draw",
                    includeInputs: true,
                    includeOutputs: true
                );
            }
            ulong? visibleSamples = collectVisibility
                ? _renderer._session.DrawWithVisibility(
                    pipeline,
                    nativeColorTargets,
                    drawState,
                    vertexBindings,
                    fragmentBindings,
                    nativeIndex
                )
                : null;
            if (nativeIndirect is SolMetalNativeBridge.GalIndirectBinding indirectCommand &&
                nativeIndirectCount is SolMetalNativeBridge.GalIndirectCountBinding countCommand)
            {
                _renderer._session.DrawIndirectCount(
                    pipeline,
                    nativeColorTargets,
                    drawState,
                    vertexBindings,
                    fragmentBindings,
                    indirectCommand,
                    countCommand,
                    nativeIndex
                );
            }
            else if (nativeIndirect is SolMetalNativeBridge.GalIndirectBinding singleIndirectCommand)
            {
                _renderer._session.DrawIndirect(
                    pipeline,
                    nativeColorTargets,
                    drawState,
                    vertexBindings,
                    fragmentBindings,
                    singleIndirectCommand,
                    nativeIndex
                );
            }
            else if (!collectVisibility && collectSampleCounter)
            {
                _renderer._session.DrawWithVisibilityQuery(
                    pipeline,
                    nativeColorTargets,
                    drawState,
                    vertexBindings,
                    fragmentBindings,
                    nativeIndex,
                    sampleCounterQuery
                );
            }
            else if (!collectVisibility)
            {
                _renderer._session.Draw(
                    pipeline,
                    nativeColorTargets,
                    drawState,
                    vertexBindings,
                    fragmentBindings,
                    nativeIndex
                );
            }
            if (!indirect)
            {
                _renderer.ObserveAutoD16ProbeSequence(
                    _program,
                    _depthStencilTarget,
                    guestDepthStencilState,
                    elementCount,
                    instanceCount
                );
            }
            if (collectTargetedVisibility)
            {
                CaptureTargetedD16Probe(
                    targetedProbeSelection,
                    targetedProbeDepth,
                    depthStencilState,
                    instanceCount
                );
                if (collectTargetedTextureProbe)
                {
                    CaptureTargetedTextureProbe(
                        targetedProbeSelection,
                        targetedProbeDepth,
                        phase: "after-draw",
                        includeInputs: false,
                        includeOutputs: true
                    );
                }
                Logger.Notice.Print(
                    LogClass.Gpu,
                    "SolMetal targeted draw visibility for program " +
                    $"#{_program.ProbeId} (key={_program.StableKey}): " +
                    $"capture={targetedProbeSelection.CaptureId}, " +
                    $"selector={targetedProbeSelection.Name}, " +
                    $"{visibleSamples ?? 0} samples; " +
                    $"elements={elementCount}, instances={instanceCount}, " +
                    $"depth=[{targetedProbeDepth.Description}]."
                );
            }
            if (collectPostDrawProbe &&
                postDrawProbeTarget is SolMetalGalTexture probeTarget)
            {
                try
                {
                    using PinnedSpan<byte> data = probeTarget.GetData();
                    Logger.Notice.Print(
                        LogClass.Gpu,
                        $"SolMetal post-{postDrawProbeRole} draw visibility " +
                        "for program " +
                        $"#{_program.ProbeId} on target " +
                        $"#{probeTarget.ProbeId}: {visibleSamples ?? 0} " +
                        "samples passed clipping, culling, depth, and stencil; " +
                        "depth=[" +
                        (_depthStencilTarget?.DescribeDepthProbe() ?? "none") +
                        "]."
                    );
                    LogRawProbe(
                        data.Get(),
                        $"post-{postDrawProbeRole} draw program " +
                        $"#{_program.ProbeId} " +
                        $"target #{probeTarget.ProbeId}"
                    );
                    _renderer.DumpPostDrawProbe(
                        data.Get(),
                        probeTarget,
                        _program,
                        postDrawProbeRole
                    );
                }
                catch (Exception exception)
                {
                    Logger.Warning?.Print(
                        LogClass.Gpu,
                        $"SolMetal could not inspect the post-" +
                        $"{postDrawProbeRole} draw target: {exception.Message}"
                    );
                }
            }
            ProbeBufferBinding[] probeBuffers = _renderer._frameProbeEnabled
                ? BuildProbeBufferBindings()
                : [];
            _depthStencilTarget?.MarkProbeDepthPass(
                _depthLoadAction,
                _clearDepth,
                depthStencilState.DepthCompareFunction,
                depthStencilState.DepthWriteEnabled
            );
            string? depthTargetDetails = _renderer._frameProbeEnabled
                ? _depthStencilTarget?.DescribeDepthProbe() ?? "none"
                : null;
            for (int index = 0; index < MaxColorAttachments; index++)
            {
                if (_colorTargets[index] is SolMetalGalTexture target)
                {
                    SolMetalGalTexture[] sampledTextures =
                        RecordProbeSampledTextures(target);
                    string? drawDetails = null;
                    if (_renderer._frameProbeEnabled)
                    {
                        int feedbackAliasCount = sampledTextures.Count(
                            texture => texture.ProbeId == target.ProbeId
                        );
                        string sampledTextureDetails = string.Join(
                            "|",
                            sampledTextures.Select(texture =>
                                $"#{texture.ProbeId}/v{texture.ProbeViewId}:" +
                                $"{texture.NativeFormat}:" +
                                $"{texture.Width}x{texture.Height}"
                            )
                        );
                        string targetFeedbackDetails = string.Join(
                            "|",
                            sampledTextures
                                .Where(texture =>
                                    texture.ProbeId == target.ProbeId
                                )
                                .Select(texture =>
                                    $"#{texture.ProbeId}/v" +
                                    $"{texture.ProbeViewId}:" +
                                    $"{texture.NativeFormat}:" +
                                    $"{texture.Width}x{texture.Height}"
                                )
                        );
                        SolMetalNativeBridge.GalBlendState blend =
                            _blendStates[index];
                        string layoutDetails = string.Join(
                            "|",
                            layouts.Select(layout =>
                                $"b{layout.BufferIndex}:s{layout.Stride}:" +
                                $"{layout.StepFunction}:r{layout.StepRate}"
                            )
                        );
                        string attributeDetails = string.Join(
                            "|",
                            attributes.Select(attribute =>
                                $"l{attribute.Location}:b{attribute.BufferIndex}:" +
                                $"{attribute.Format}:o{attribute.Offset}"
                            )
                        );
                        string targetDetails = string.Join(
                            "|",
                            _colorTargets.Select((color, slot) =>
                                color is null
                                    ? null
                                    : $"s{slot}:#{color.ProbeId}:" +
                                      $"{color.NativeFormat}:m" +
                                      $"{(debugDisableColorWrites ? 0 : _colorWriteMasks[slot]):X}"
                            ).Where(value => value is not null)
                        );
                        drawDetails =
                            $"primitive={_topology}, indexed={indexed}, " +
                            $"elements={elementCount}, first={firstElement}, " +
                            $"instances={instanceCount}, first-instance={firstInstance}, " +
                            $"base-vertex={baseVertex}, viewport=" +
                            $"({viewport.Region.X:0.###},{viewport.Region.Y:0.###}," +
                            $"{viewport.Region.Width:0.###},{viewport.Region.Height:0.###}," +
                            $"{viewport.DepthNear:0.###}-{viewport.DepthFar:0.###}), " +
                            $"scissor=({scissor.X},{scissor.Y}," +
                            $"{scissor.Width},{scissor.Height}), " +
                            $"depth-target=[{depthTargetDetails}], " +
                            $"depth-test={_depthTest.TestEnable}, " +
                            $"depth-func={depthStencilState.DepthCompareFunction}, " +
                            $"depth-write={depthStencilState.DepthWriteEnabled}, " +
                            $"depth-load={_depthLoadAction}, " +
                            $"depth-mode={_depthMode}, " +
                            $"depth-bias=({_depthBias:0.######}," +
                            $"{_depthBiasSlopeScale:0.######}," +
                            $"{_depthBiasClamp:0.######}), " +
                            $"stencil={depthStencilState.StencilEnabled}, " +
                            $"blend={blend.Enabled}:" +
                            $"{blend.SourceRgbFactor}/{blend.DestinationRgbFactor}/" +
                            $"{blend.RgbOperation}, front={drawFrontFace}, " +
                            $"cull={drawCullMode}, targets=[{targetDetails}], " +
                            $"fill={_fillMode}, clip={drawDepthClipMode}, " +
                            $"layouts=[{layoutDetails}], " +
                            $"attributes=[{attributeDetails}], " +
                            $"feedback-aliases={feedbackAliasCount}, " +
                            $"sampled=[{sampledTextureDetails}], " +
                            $"target-feedback=[{targetFeedbackDetails}], " +
                            $"buffers(v/f)={vertexBindings.Buffers.Length}/" +
                            $"{fragmentBindings.Buffers.Length}";
                    }
                    target.MarkProbeDraw(
                        _colorLoadActions[index],
                        debugDisableColorWrites
                            ? 0
                            : _colorWriteMasks[index],
                        drawCullMode,
                        _lastVertexDummyTextureBindings,
                        _lastFragmentDummyTextureBindings,
                        _lastVertexDummyBufferBindings,
                        _lastFragmentDummyBufferBindings,
                        drawDetails,
                        _program,
                        probeBuffers,
                        elementCount,
                        sampledTextures
                    );
                    if (elementCount >= 1_024 ||
                        target.NativeFormat is
                            SolMetalNativeBridge.GalTextureFormat.Rgba16Float or
                            SolMetalNativeBridge.GalTextureFormat.Rgba32Float)
                    {
                        _renderer.RecordFrameProbeTarget(
                            target,
                            target.NativeFormat is
                                SolMetalNativeBridge.GalTextureFormat.Rgba16Float or
                                SolMetalNativeBridge.GalTextureFormat.Rgba32Float
                                    ? $"HDR-slot-{index}"
                                    : $"large-slot-{index}",
                            elementCount
                        );
                    }
                }
            }
            long submitted = Interlocked.Increment(
                ref _renderer._successfulDrawCount
            );
            if (submitted == 1)
            {
                Logger.Notice.Print(
                    LogClass.Gpu,
                    "SolMetal accepted its first native guest draw."
                );
            }
            else if (submitted == 1_000)
            {
                SolMetalNativeBridge.TimelineSnapshot batch =
                    _renderer._session.QueryTimeline();
                SolMetalNativeBridge.RuntimeBatchSnapshot? runtimeBatch =
                    _renderer._session.QueryRuntimeBatch();
                ulong excludedBatchedDraws = batch.PendingDrawCount;
                if (runtimeBatch is { } recovery)
                {
                    excludedBatchedDraws = ulong.MaxValue -
                            excludedBatchedDraws <
                            recovery.DiscardedPendingDrawCount
                        ? ulong.MaxValue
                        : excludedBatchedDraws +
                            recovery.DiscardedPendingDrawCount;
                }
                ulong submittedBatchedDraws = batch.BatchedDrawCount >=
                    excludedBatchedDraws
                        ? batch.BatchedDrawCount - excludedBatchedDraws
                        : 0;
                double averageBatch = batch.DrawCommandBufferCount == 0
                    ? 0
                    : submittedBatchedDraws /
                        (double)batch.DrawCommandBufferCount;
                string runtimeBatchDetails = runtimeBatch is { } direct
                    ? $", directMutationBatching=" +
                        $"{(direct.DirectMutationBatchingEnabled ? "on" : "off")}, " +
                        $"drawCommandBuffers={direct.DrawCommandBufferCount}, " +
                        $"borrowedMutations={direct.BorrowedMutationCount}, " +
                        $"borrowedMutationEncoders={direct.BorrowedMutationEncoderCount}, " +
                        $"borrowedMutationBytes={direct.BorrowedMutationTransientBytes}, " +
                        $"standaloneMutations={direct.StandaloneMutationCount}, " +
                        $"mutationPeak={direct.MaximumMutationCount}/" +
                        $"{direct.MaximumMutationEncoderCount}/" +
                        $"{direct.MaximumMutationTransientBytes}, " +
                        $"mutationPending={direct.PendingMutationCount}/" +
                        $"{direct.PendingMutationEncoderCount}/" +
                        $"{direct.PendingMutationTransientBytes}, " +
                        $"mutationCaps={direct.MutationEncoderLimit}/" +
                        $"{direct.MutationTransientByteLimit}, " +
                        $"discardedMutationCommandBuffers=" +
                        $"{direct.DiscardedPendingCommandBufferCount}, " +
                        $"discardedMutationDraws=" +
                        $"{direct.DiscardedPendingDrawCount}, " +
                        $"mutationFlushes=drawLimit:" +
                        $"{direct.DrawLimitFlushCount}|ordered:" +
                        $"{direct.OrderedSubmissionFlushCount}|sync:" +
                        $"{direct.SynchronousSubmissionFlushCount}|timeline:" +
                        $"{direct.TimelineFlushCount}|destroy:" +
                        $"{direct.ContextDestroyFlushCount}|encoderCap:" +
                        $"{direct.MutationEncoderLimitFlushCount}|byteCap:" +
                        $"{direct.MutationTransientLimitFlushCount}"
                    : ", directMutationBatching=unavailable";
                string quadDetails =
                    $", indexedQuadConversions={IndexedQuadConversionCount}, " +
                    $"indexedQuadPrimitives={IndexedQuadPrimitiveCount}, " +
                    $"quadConversionBytes={IndexedQuadConversionBytes}, " +
                    $"quadScratchGrowths={ExpandedQuadScratchGrowthCount}, " +
                    $"quadCpuReadbacks={IndexedQuadCpuReadbackCount}, " +
                    $"quadCpuUploads={IndexedQuadCpuUploadCount}, " +
                    $"indirectQuadRejections={IndirectQuadRejectionCount}";
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal accepted 1,000 native guest draws " +
                    $"(batched={batch.BatchedDrawCount}, " +
                    $"commandBuffers={batch.DrawCommandBufferCount}, " +
                    $"renderPasses={batch.DrawRenderPassCount}, " +
                    $"average={averageBatch:F1}, " +
                    $"peak={batch.MaximumDrawBatchSize}, " +
                    $"boundaryFlushes={batch.DrawBoundaryFlushCount}, " +
                    $"pending={batch.PendingDrawCount}, " +
                    $"bindingRebuilds={StageBindingRebuildCount}, " +
                    "avoidedBindingInvalidations=" +
                    $"{AvoidedStageBindingInvalidationCount}, " +
                    $"colorBindingRebuilds={ColorBindingRebuildCount}, " +
                    "avoidedColorBindingRebuilds=" +
                    $"{AvoidedColorBindingRebuildCount}" +
                    $"{runtimeBatchDetails}{quadDetails})."
                );
            }
            for (int index = 0; index < MaxColorAttachments; index++)
            {
                if (_colorTargets[index] is not null)
                {
                    if (_colorLoadActions[index] !=
                        SolMetalNativeBridge.GalRenderLoadAction.Load)
                    {
                        _colorBindingStateDirty = true;
                    }
                    _colorLoadActions[index] =
                        SolMetalNativeBridge.GalRenderLoadAction.Load;
                }
            }
            _depthLoadAction = SolMetalNativeBridge.GalRenderLoadAction.Load;
            _stencilLoadAction = SolMetalNativeBridge.GalRenderLoadAction.Load;
        }
        public void DrawIndexedIndirect(BufferRange indirectBuffer)
        {
            DrawInternal(
                0,
                0,
                0,
                0,
                indexed: true,
                baseVertex: 0,
                indirectBuffer: indirectBuffer
            );
        }
        public void DrawIndexedIndirectCount(
            BufferRange indirectBuffer,
            BufferRange parameterBuffer,
            int maxDrawCount,
            int stride
        )
        {
            DrawInternal(
                0,
                0,
                0,
                0,
                indexed: true,
                baseVertex: 0,
                indirectBuffer: indirectBuffer,
                indirectCountBuffer: parameterBuffer,
                maxDrawCount: maxDrawCount,
                indirectStride: stride
            );
        }
        public void DrawIndirect(BufferRange indirectBuffer)
        {
            DrawInternal(
                0,
                0,
                0,
                0,
                indexed: false,
                baseVertex: 0,
                indirectBuffer: indirectBuffer
            );
        }
        public void DrawIndirectCount(
            BufferRange indirectBuffer,
            BufferRange parameterBuffer,
            int maxDrawCount,
            int stride
        )
        {
            DrawInternal(
                0,
                0,
                0,
                0,
                indexed: false,
                baseVertex: 0,
                indirectBuffer: indirectBuffer,
                indirectCountBuffer: parameterBuffer,
                maxDrawCount: maxDrawCount,
                indirectStride: stride
            );
        }
        public void DrawTexture(ITexture texture, ISampler sampler, Extents2DF srcRegion, Extents2DF dstRegion) => Fail("texture drawing");
        public void EndTransformFeedback() => Fail("transform feedback");
        public void SetAlphaTest(bool enable, float reference, CompareOp op)
        {
            // As on Ryujinx's Vulkan path, alpha test is specialized into the
            // guest fragment shader rather than represented by host API state.
            if (!float.IsFinite(reference))
            {
                Fail("a non-finite alpha-test reference");
            }
            _ = MapCompare(op);
        }
        public void SetBlendState(AdvancedBlendDescriptor blend) => Fail("advanced blend state");
        public void SetBlendState(int index, BlendDescriptor blend)
        {
            if ((uint)index >= MaxColorAttachments)
            {
                Fail("blend state for an invalid color target");
            }
            if (!float.IsFinite(blend.BlendConstant.Red) ||
                !float.IsFinite(blend.BlendConstant.Green) ||
                !float.IsFinite(blend.BlendConstant.Blue) ||
                !float.IsFinite(blend.BlendConstant.Alpha))
            {
                Fail("a non-finite blend constant");
            }
            SolMetalNativeBridge.GalBlendState nextBlendState = new(
                blend.Enable,
                MapBlendOperation(blend.ColorOp),
                MapBlendOperation(blend.AlphaOp),
                MapBlendFactor(blend.ColorSrcFactor),
                MapBlendFactor(blend.ColorDstFactor),
                MapBlendFactor(blend.AlphaSrcFactor),
                MapBlendFactor(blend.AlphaDstFactor)
            );
            _blendConstant = blend.BlendConstant;
            if (_blendStates[index] == nextBlendState)
            {
                // Metal's blend constant is dynamic draw state. Updating it
                // must not rebuild attachment tables or revisit the render
                // pipeline cache when the actual blend equation is unchanged.
                _avoidedColorBindingRebuildCount++;
                return;
            }
            _blendStates[index] = nextBlendState;
            _colorBindingStateDirty = true;
        }
        public void SetDepthBias(
            PolygonModeMask enables,
            float factor,
            float units,
            float clamp
        )
        {
            if (!float.IsFinite(factor) || !float.IsFinite(units) ||
                !float.IsFinite(clamp))
            {
                Fail("non-finite depth bias state");
            }
            bool applies = (_fillMode ==
                    SolMetalNativeBridge.GalTriangleFillMode.Fill &&
                    enables.HasFlag(PolygonModeMask.Fill)) ||
                (_fillMode == SolMetalNativeBridge.GalTriangleFillMode.Lines &&
                    enables.HasFlag(PolygonModeMask.Line));
            _depthBiasSlopeScale = applies ? factor : 0;
            _depthBias = applies ? units : 0;
            _depthBiasClamp = applies ? clamp : 0;
        }
        public void SetDepthClamp(bool clamp) => _depthClipMode = clamp
            ? SolMetalNativeBridge.GalDepthClipMode.Clamp
            : SolMetalNativeBridge.GalDepthClipMode.Clip;
        public void SetDepthMode(DepthMode mode)
        {
            if (mode is not DepthMode.MinusOneToOne and not DepthMode.ZeroToOne)
            {
                Fail($"depth mode {mode}");
            }
            _depthMode = mode;
            // GetCapabilities reports no host depth-clip control, so the
            // shader translator performs the required -1...1 to 0...1
            // conversion. There is no matching dynamic Metal state here.
        }
        public void SetDepthTest(DepthTestDescriptor depthTest)
        {
            _ = MapCompare(depthTest.Func);
            _depthTest = depthTest;
        }
        public void SetFaceCulling(bool enable, Face face)
        {
            _cullMode = !enable
                ? SolMetalNativeBridge.GalCullMode.None
                : face switch
                {
                    Face.Front => SolMetalNativeBridge.GalCullMode.Front,
                    Face.Back => SolMetalNativeBridge.GalCullMode.Back,
                    Face.FrontAndBack =>
                        SolMetalNativeBridge.GalCullMode.FrontAndBack,
                    _ => throw Unsupported($"cull face {face}"),
                };
        }
        public void SetFrontFace(FrontFace frontFace)
        {
            // SPIRV-Cross flips vertex Y when producing MSL. Metal's host
            // origin consequently observes the opposite winding from GAL.
            // Ryubing's Vulkan backend performs the same conversion in its
            // FrontFace enum mapping.
            _frontFace = frontFace switch
            {
                FrontFace.Clockwise =>
                    SolMetalNativeBridge.GalFrontFaceWinding.CounterClockwise,
                FrontFace.CounterClockwise =>
                    SolMetalNativeBridge.GalFrontFaceWinding.Clockwise,
                _ => throw Unsupported($"front face {frontFace}"),
            };
        }
        public void SetIndexBuffer(BufferRange buffer, IndexType type)
        {
            if (buffer.Handle == BufferHandle.Null)
            {
                _indexBuffer = null;
                return;
            }
            _indexBuffer = buffer;
            _indexType = type;
        }
        public void SetImage(ShaderStage stage, int binding, ITexture texture)
        {
            if (stage is not ShaderStage.Vertex and
                not ShaderStage.Fragment and
                not ShaderStage.Compute)
            {
                throw Unsupported($"storage image stage {stage}");
            }
            if (texture is null)
            {
                if (_images.Remove((stage, binding)))
                {
                    MarkStageBindingsDirty(stage);
                }
                else
                {
                    _avoidedStageBindingInvalidationCount++;
                }
                return;
            }
            if (texture is not SolMetalGalTexture nativeTexture)
            {
                throw Unsupported("foreign storage images");
            }
            if (_images.TryGetValue(
                    (stage, binding),
                    out SolMetalGalTexture? existingImage
                ) && ReferenceEquals(existingImage, nativeTexture))
            {
                _avoidedStageBindingInvalidationCount++;
                return;
            }
            _images[(stage, binding)] = nativeTexture;
            MarkStageBindingsDirty(stage);
        }
        public void SetImageArray(ShaderStage stage, int binding, IImageArray array) => Fail("image arrays");
        public void SetImageArraySeparate(ShaderStage stage, int setIndex, IImageArray array) => Fail("image arrays");
        public void SetLineParameters(float width, bool smooth)
        {
            if (!float.IsFinite(width) || width <= 0)
            {
                Fail("invalid line state");
            }
            _lineWidth = width;
            _lineSmooth = smooth;
        }
        public void SetLogicOpState(bool enable, LogicalOp op)
        {
            if (enable)
            {
                Fail($"enabled logic operation {op}");
            }
        }
        public void SetMultisampleState(MultisampleDescriptor multisample)
        {
            _alphaToCoverageEnabled = multisample.AlphaToCoverageEnable;
            _alphaToCoverageDitherEnabled =
                multisample.AlphaToCoverageDitherEnable;
            _alphaToOneEnabled = multisample.AlphaToOneEnable;
        }
        public void SetPatchParameters(
            int vertices,
            ReadOnlySpan<float> defaultOuterLevel,
            ReadOnlySpan<float> defaultInnerLevel
        )
        {
            // Ryujinx updates the complete guest tessellation state table even
            // for ordinary vertex/fragment draws. SolMetal rejects real patch
            // programs in CreateProgram and patch topologies in MapPrimitiveType,
            // so accepting a well-formed inactive state update is safe and
            // avoids aborting a non-tessellated draw before its program is known.
            if (vertices is < 1 or > 32 || defaultOuterLevel.Length != 4 ||
                defaultInnerLevel.Length != 2)
            {
                Fail("invalid tessellation patch state");
            }
            foreach (float level in defaultOuterLevel)
            {
                if (!float.IsFinite(level))
                {
                    Fail("non-finite tessellation outer levels");
                }
            }
            foreach (float level in defaultInnerLevel)
            {
                if (!float.IsFinite(level))
                {
                    Fail("non-finite tessellation inner levels");
                }
            }
        }
        public void SetPointParameters(
            float size,
            bool isProgramPointSize,
            bool enablePointSprite,
            Origin origin
        )
        {
            // Point size and sprite behavior are part of Ryujinx's shader
            // specialization state. This callback carries no additional Metal
            // state, matching the upstream Vulkan backend.
            if (!float.IsFinite(size) || size <= 0 ||
                origin is not Origin.LowerLeft and not Origin.UpperLeft)
            {
                Fail("invalid point state");
            }
        }
        public void SetPolygonMode(PolygonMode frontMode, PolygonMode backMode)
        {
            if (frontMode != backMode)
            {
                Fail("different front and back polygon modes");
            }
            _fillMode = frontMode switch
            {
                PolygonMode.Fill => SolMetalNativeBridge.GalTriangleFillMode.Fill,
                PolygonMode.Line => SolMetalNativeBridge.GalTriangleFillMode.Lines,
                _ => throw Unsupported($"polygon mode {frontMode}"),
            };
        }
        public void SetPrimitiveRestart(bool enable, int index)
        {
            if (enable)
            {
                Fail($"enabled primitive restart with index {index}");
            }
        }
        public void SetPrimitiveTopology(PrimitiveTopology topology)
        {
            _ = MapPrimitiveType(topology);
            _topology = topology;
        }
        public void SetProgram(IProgram program)
        {
            SolMetalGalProgram nativeProgram = program as SolMetalGalProgram ??
                throw new ArgumentException("Program does not belong to SolMetal.", nameof(program));
            if (ReferenceEquals(_program, nativeProgram))
            {
                _avoidedStageBindingInvalidationCount++;
                return;
            }
            _program = nativeProgram;
            _vertexBindingsDirty = true;
            _fragmentBindingsDirty = true;
            _computeBindingsDirty = true;
        }
        public void SetRasterizerDiscard(bool discard)
        {
            if (discard)
            {
                Fail("rasterizer discard");
            }
        }
        public void SetRenderTargetColorMasks(ReadOnlySpan<uint> componentMask)
        {
            if (componentMask.IsEmpty ||
                componentMask.Length > MaxColorAttachments)
            {
                Fail("a missing or oversized color-mask table");
            }
            bool changed = false;
            for (int index = 0; index < componentMask.Length; index++)
            {
                if ((componentMask[index] & ~0xfu) != 0)
                {
                    Fail("an invalid color write mask");
                }
                if (_colorWriteMasks[index] != componentMask[index])
                {
                    _colorWriteMasks[index] = componentMask[index];
                    changed = true;
                }
            }
            if (!changed)
            {
                _avoidedColorBindingRebuildCount++;
                return;
            }
            RebuildEffectiveColorTargets();
        }
        public void SetRenderTargets(Span<ITexture> colors, ITexture depthStencil)
        {
            SolMetalGalTexture? primaryColor = null;
            for (int index = 0; index < colors.Length; index++)
            {
                if (colors[index] is null)
                {
                    continue;
                }
                if (index >= MaxColorAttachments ||
                    colors[index] is not SolMetalGalTexture nativeColor ||
                    nativeColor.IsDepthStencil)
                {
                    throw Unsupported(
                        "an out-of-range or invalid color render target"
                    );
                }
                primaryColor ??= nativeColor;
                if (nativeColor.Width != primaryColor.Width ||
                    nativeColor.Height != primaryColor.Height)
                {
                    throw Unsupported("mismatched color render targets");
                }
            }
            SolMetalGalTexture? nativeDepth = null;
            if (depthStencil is not null)
            {
                nativeDepth = depthStencil as SolMetalGalTexture;
                if (nativeDepth is null || !nativeDepth.IsDepthStencil ||
                    (primaryColor is not null &&
                     (nativeDepth.Width != primaryColor.Width ||
                      nativeDepth.Height != primaryColor.Height)))
                {
                    throw Unsupported("foreign or mismatched depth/stencil targets");
                }
            }

            bool unchanged = ReferenceEquals(
                _depthStencilTarget,
                nativeDepth
            );
            for (int index = 0; index < MaxColorAttachments; index++)
            {
                SolMetalGalTexture? next = index < colors.Length
                    ? colors[index] as SolMetalGalTexture
                    : null;
                unchanged &= ReferenceEquals(
                    _unfilteredColorTargets[index],
                    next
                );
            }
            if (unchanged)
            {
                _avoidedColorBindingRebuildCount++;
                return;
            }

            Array.Clear(
                _unfilteredColorTargets,
                0,
                _unfilteredColorTargets.Length
            );
            for (int index = 0;
                 index < colors.Length && index < MaxColorAttachments;
                 index++)
            {
                _unfilteredColorTargets[index] =
                    colors[index] as SolMetalGalTexture;
            }
            RebuildEffectiveColorTargets();
            _depthStencilTarget = nativeDepth;
        }

        private void RebuildColorBindingStateIfNeeded()
        {
            if (!_colorBindingStateDirty)
            {
                return;
            }
            _colorBindingRebuildCount++;

            int targetCount = 0;
            for (int index = 0; index < MaxColorAttachments; index++)
            {
                if (_colorTargets[index] is not null)
                {
                    targetCount++;
                }
            }

            var attachments =
                new SolMetalNativeBridge.GalRenderColorAttachmentState[
                    targetCount
                ];
            var targets = new SolMetalNativeBridge.GalRenderColorTarget[
                targetCount
            ];
            int position = 0;
            for (int index = 0; index < MaxColorAttachments; index++)
            {
                if (_colorTargets[index] is not SolMetalGalTexture target)
                {
                    continue;
                }

                attachments[position] = new(
                    checked((uint)index),
                    target.NativeFormat,
                    _colorWriteMasks[index],
                    _blendStates[index]
                );
                ColorF clear = _clearColors[index];
                targets[position] = new(
                    checked((uint)index),
                    target.Native,
                    _colorLoadActions[index],
                    SolMetalNativeBridge.GalRenderStoreAction.Store,
                    clear.Red,
                    clear.Green,
                    clear.Blue,
                    clear.Alpha
                );
                position++;
            }

            _cachedColorAttachments = attachments;
            _cachedNativeColorTargets = targets;
            _colorBindingStateDirty = false;
        }

        private void RebuildEffectiveColorTargets()
        {
            Array.Copy(
                _unfilteredColorTargets,
                _colorTargets,
                MaxColorAttachments
            );

            // Apple GPUs are tile-based. Binding the same texture to two MRT
            // slots makes the attachments act like independent tile copies.
            // Ryujinx's Vulkan backend handles the same case by dropping the
            // duplicate slot whose write mask is zero, and rebuilding when the
            // guest changes those masks.
            for (int index = 0; index < MaxColorAttachments; index++)
            {
                SolMetalGalTexture? target = _unfilteredColorTargets[index];
                if (target is null)
                {
                    continue;
                }

                for (int previous = 0; previous < index; previous++)
                {
                    if (!ReferenceEquals(
                            _unfilteredColorTargets[previous],
                            target
                        ))
                    {
                        continue;
                    }

                    if (_colorWriteMasks[index] == 0)
                    {
                        _colorTargets[index] = null;
                    }
                    else if (_colorWriteMasks[previous] == 0)
                    {
                        _colorTargets[previous] = null;
                    }
                }
            }
            _colorBindingStateDirty = true;
        }
        public void SetScissors(ReadOnlySpan<Rectangle<int>> regions)
        {
            // SolMetal advertises no viewport-index support, so guest shaders
            // can only address viewport/scissor zero. Ryujinx still supplies
            // the complete fixed-size viewport table here.
            if (regions.IsEmpty || regions[0].X < 0 || regions[0].Y < 0 ||
                regions[0].Width <= 0 || regions[0].Height <= 0)
            {
                throw Unsupported("a missing or invalid primary scissor");
            }
            _scissor = regions[0];
        }
        public void SetStencilTest(StencilTestDescriptor stencilTest)
        {
            _ = MapCompare(stencilTest.FrontFunc);
            _ = MapCompare(stencilTest.BackFunc);
            _ = MapStencil(stencilTest.FrontSFail);
            _ = MapStencil(stencilTest.FrontDpFail);
            _ = MapStencil(stencilTest.FrontDpPass);
            _ = MapStencil(stencilTest.BackSFail);
            _ = MapStencil(stencilTest.BackDpFail);
            _ = MapStencil(stencilTest.BackDpPass);
            _stencilTest = stencilTest;
        }
        public void SetStorageBuffers(ReadOnlySpan<BufferAssignment> buffers)
        {
            bool changed = false;
            foreach (BufferAssignment assignment in buffers)
            {
                if (assignment.Range.Handle == BufferHandle.Null)
                {
                    changed |= _storageBuffers.Remove(assignment.Binding);
                }
                else if (!_storageBuffers.TryGetValue(
                             assignment.Binding,
                             out BufferRange existing
                         ) || !existing.Equals(assignment.Range))
                {
                    _storageBuffers[assignment.Binding] = assignment.Range;
                    changed = true;
                }
            }
            if (!changed)
            {
                _avoidedStageBindingInvalidationCount++;
                return;
            }
            _vertexBindingsDirty = true;
            _fragmentBindingsDirty = true;
            _computeBindingsDirty = true;
        }
        public void SetTextureAndSampler(
            ShaderStage stage,
            int binding,
            ITexture texture,
            ISampler sampler
        )
        {
            if (stage is not ShaderStage.Vertex and
                not ShaderStage.Fragment and
                not ShaderStage.Compute)
            {
                throw Unsupported($"texture binding stage {stage}");
            }
            if (texture is null)
            {
                if (_texturesAndSamplers.Remove((stage, binding)))
                {
                    MarkStageBindingsDirty(stage);
                }
                else
                {
                    _avoidedStageBindingInvalidationCount++;
                }
                return;
            }
            if (texture is not SolMetalGalTexture nativeTexture)
            {
                throw new ArgumentException(
                    "Texture must belong to the SolMetal renderer."
                );
            }
            SolMetalGalSampler? nativeSampler = sampler switch
            {
                null when nativeTexture.IsBufferTexture => null,
                SolMetalGalSampler value => value,
                _ => throw new ArgumentException(
                    "Sampler must belong to the SolMetal renderer."
                ),
            };
            if (_texturesAndSamplers.TryGetValue(
                    (stage, binding),
                    out var existingBinding
                ) && ReferenceEquals(existingBinding.Texture, nativeTexture) &&
                ReferenceEquals(existingBinding.Sampler, nativeSampler))
            {
                _avoidedStageBindingInvalidationCount++;
                return;
            }
            _texturesAndSamplers[(stage, binding)] =
                (nativeTexture, nativeSampler);
            MarkStageBindingsDirty(stage);
        }
        public void SetTextureArray(ShaderStage stage, int binding, ITextureArray array) => Fail("texture arrays");
        public void SetTextureArraySeparate(ShaderStage stage, int setIndex, ITextureArray array) => Fail("texture arrays");
        public void SetTransformFeedbackBuffers(ReadOnlySpan<BufferRange> buffers) => Fail("transform feedback");
        public void SetUniformBuffers(ReadOnlySpan<BufferAssignment> buffers)
        {
            bool changed = false;
            foreach (BufferAssignment assignment in buffers)
            {
                if (assignment.Range.Handle == BufferHandle.Null)
                {
                    changed |= _uniformBuffers.Remove(assignment.Binding);
                }
                else if (!_uniformBuffers.TryGetValue(
                             assignment.Binding,
                             out BufferRange existing
                         ) || !existing.Equals(assignment.Range))
                {
                    _uniformBuffers[assignment.Binding] = assignment.Range;
                    changed = true;
                }
            }
            if (!changed)
            {
                _avoidedStageBindingInvalidationCount++;
                return;
            }
            _vertexBindingsDirty = true;
            _fragmentBindingsDirty = true;
            _computeBindingsDirty = true;
        }
        public void SetUserClipDistance(int index, bool enableClip)
        {
            if ((uint)index >= 8)
            {
                Fail("an invalid user clip-distance index");
            }
            if (enableClip)
            {
                Fail($"enabled user clip distance {index}");
            }
        }
        public void SetVertexAttribs(ReadOnlySpan<VertexAttribDescriptor> vertexAttribs)
        {
            if (vertexAttribs.Length > 32)
            {
                throw Unsupported("more than 32 vertex attributes");
            }
            _vertexAttributes = vertexAttribs.ToArray();
            _vertexPipelineStateDirty = true;
            _vertexBindingsDirty = true;
        }
        public void SetVertexBuffers(ReadOnlySpan<VertexBufferDescriptor> vertexBuffers)
        {
            if (vertexBuffers.Length > MaximumGuestVertexBuffers)
            {
                throw Unsupported(
                    $"more than {MaximumGuestVertexBuffers} direct vertex buffers"
                );
            }
            _vertexBuffers = vertexBuffers.ToArray();
            _vertexPipelineStateDirty = true;
            _vertexBindingsDirty = true;
        }
        public void SetViewports(ReadOnlySpan<Viewport> viewports)
        {
            if (viewports.IsEmpty)
            {
                throw Unsupported("a missing primary viewport");
            }
            Viewport primary = viewports[0];
            Rectangle<float> region = primary.Region;
            if (!float.IsFinite(region.X) || !float.IsFinite(region.Y) ||
                !float.IsFinite(region.Width) || !float.IsFinite(region.Height) ||
                region.Width == 0 || region.Height == 0 ||
                !float.IsFinite(primary.DepthNear) ||
                !float.IsFinite(primary.DepthFar))
            {
                throw Unsupported("a malformed primary viewport");
            }
            // Metal accepts signed viewport extents. Preserving them is
            // important because Ryujinx uses a negative height for guest Y
            // inversion and the sign also participates in face orientation.
            _viewport = primary;
        }
        public bool TryHostConditionalRendering(
            ICounterEvent value,
            ulong compare,
            bool isEqual
        ) => false;
        public bool TryHostConditionalRendering(
            ICounterEvent value,
            ICounterEvent compare,
            bool isEqual
        ) => false;
        public void EndHostConditionalRendering() => Fail("conditional rendering");

        private SolMetalNativeBridge.GalDepthStencilState BuildDepthStencilState()
        {
            SolMetalNativeBridge.GalStencilFaceState disabledFace = new(
                SolMetalNativeBridge.GalCompareFunction.Always,
                SolMetalNativeBridge.GalStencilOperation.Keep,
                SolMetalNativeBridge.GalStencilOperation.Keep,
                SolMetalNativeBridge.GalStencilOperation.Keep,
                uint.MaxValue,
                uint.MaxValue
            );
            if (_depthStencilTarget is null)
            {
                return new SolMetalNativeBridge.GalDepthStencilState(
                    SolMetalNativeBridge.GalCompareFunction.Always,
                    false,
                    false,
                    disabledFace,
                    disabledFace
                );
            }
            if (_stencilTest.TestEnable &&
                _depthStencilTarget.NativeFormat is not
                    (SolMetalNativeBridge.GalTextureFormat.Depth32FloatStencil8 or
                     SolMetalNativeBridge.GalTextureFormat.D24UnormStencil8))
            {
                throw Unsupported("stencil testing without a stencil target");
            }
            SolMetalNativeBridge.GalStencilFaceState front = new(
                MapCompare(_stencilTest.FrontFunc),
                MapStencil(_stencilTest.FrontSFail),
                MapStencil(_stencilTest.FrontDpFail),
                MapStencil(_stencilTest.FrontDpPass),
                unchecked((uint)_stencilTest.FrontFuncMask),
                unchecked((uint)_stencilTest.FrontMask)
            );
            SolMetalNativeBridge.GalStencilFaceState back = new(
                MapCompare(_stencilTest.BackFunc),
                MapStencil(_stencilTest.BackSFail),
                MapStencil(_stencilTest.BackDpFail),
                MapStencil(_stencilTest.BackDpPass),
                unchecked((uint)_stencilTest.BackFuncMask),
                unchecked((uint)_stencilTest.BackMask)
            );
            SolMetalNativeBridge.GalCompareFunction depthCompare =
                MapCompare(_depthTest.Func);
            if (depthCompare == SolMetalNativeBridge.GalCompareFunction.Equal)
            {
                if (_renderer._debugMapDepthEqualToLessEqual)
                {
                    depthCompare =
                        SolMetalNativeBridge.GalCompareFunction.LessEqual;
                }
                else if (_renderer._debugMapDepthEqualToGreaterEqual)
                {
                    depthCompare =
                        SolMetalNativeBridge.GalCompareFunction.GreaterEqual;
                }
            }
            return new SolMetalNativeBridge.GalDepthStencilState(
                !_renderer._debugDisableDepthTest && _depthTest.TestEnable &&
                    !_renderer._debugForceDepthAlways
                        ? depthCompare
                        : SolMetalNativeBridge.GalCompareFunction.Always,
                !_renderer._debugDisableDepthTest && _depthTest.WriteEnable,
                _stencilTest.TestEnable,
                front,
                back
            );
        }

        private void BuildVertexState(
            out SolMetalNativeBridge.GalVertexBufferLayout[] layouts,
            out SolMetalNativeBridge.GalVertexAttribute[] attributes,
            out SolMetalNativeBridge.GalBufferBinding[] bindings
        )
        {
            if (_vertexAttributes.Length == 0)
            {
                layouts = Array.Empty<
                    SolMetalNativeBridge.GalVertexBufferLayout
                >();
                attributes = Array.Empty<
                    SolMetalNativeBridge.GalVertexAttribute
                >();
                bindings = Array.Empty<SolMetalNativeBridge.GalBufferBinding>();
                return;
            }

            if (_vertexPipelineStateDirty)
            {
                HashSet<int> requiredBuffers = [];
                bool needsZeroBuffer = false;
                SolMetalNativeBridge.GalVertexAttribute[] rebuiltAttributes =
                    new SolMetalNativeBridge.GalVertexAttribute[
                        _vertexAttributes.Length
                    ];
                for (
                    int location = 0;
                    location < _vertexAttributes.Length;
                    location++
                )
                {
                    VertexAttribDescriptor attribute =
                        _vertexAttributes[location];
                    uint metalBufferIndex;
                    if (attribute.IsZero)
                    {
                        needsZeroBuffer = true;
                        metalBufferIndex = 0;
                    }
                    else
                    {
                        if (attribute.BufferIndex < 0 ||
                            attribute.BufferIndex >= _vertexBuffers.Length ||
                            attribute.BufferIndex >= MaximumGuestVertexBuffers)
                        {
                            throw Unsupported("an out-of-range vertex attribute");
                        }
                        requiredBuffers.Add(attribute.BufferIndex);
                        metalBufferIndex = checked(
                            (uint)attribute.BufferIndex + VertexBufferBase
                        );
                    }
                    rebuiltAttributes[location] = new(
                        checked((uint)location),
                        metalBufferIndex,
                        MapVertexFormat(attribute.Format),
                        checked((uint)attribute.Offset)
                    );
                }

                int[] bufferIndices = requiredBuffers
                    .OrderBy(index => index)
                    .ToArray();
                SolMetalNativeBridge.GalVertexBufferLayout[] rebuiltLayouts =
                    new SolMetalNativeBridge.GalVertexBufferLayout[
                        bufferIndices.Length + (needsZeroBuffer ? 1 : 0)
                    ];
                int layoutPosition = 0;
                if (needsZeroBuffer)
                {
                    rebuiltLayouts[layoutPosition++] = new(
                        0,
                        16,
                        SolMetalNativeBridge.GalVertexStepFunction.Constant,
                        0
                    );
                }
                foreach (int bufferIndex in bufferIndices)
                {
                    VertexBufferDescriptor descriptor =
                        _vertexBuffers[bufferIndex];
                    rebuiltLayouts[layoutPosition++] = BuildVertexBufferLayout(
                        bufferIndex,
                        descriptor.Stride,
                        descriptor.Divisor
                    );
                }

                _cachedVertexLayouts = rebuiltLayouts;
                _cachedVertexAttributes = rebuiltAttributes;
                _cachedVertexBufferIndices = bufferIndices;
                _cachedVertexNeedsZeroBuffer = needsZeroBuffer;
                _vertexPipelineStateDirty = false;
            }

            layouts = _cachedVertexLayouts;
            attributes = _cachedVertexAttributes;
            if (_vertexBindingsDirty)
            {
                SolMetalNativeBridge.GalBufferBinding[] rebuiltBindings =
                    new SolMetalNativeBridge.GalBufferBinding[layouts.Length];
                int output = 0;
                if (_cachedVertexNeedsZeroBuffer)
                {
                    rebuiltBindings[output++] = new(
                        0,
                        _renderer._zeroVertexBuffer,
                        0
                    );
                }
                foreach (int bufferIndex in _cachedVertexBufferIndices)
                {
                    VertexBufferDescriptor descriptor =
                        _vertexBuffers[bufferIndex];
                    rebuiltBindings[output++] = _renderer.ResolveBufferBinding(
                        checked((uint)bufferIndex + VertexBufferBase),
                        descriptor.Buffer
                    );
                }
                _cachedVertexInputBindings = rebuiltBindings;
            }
            bindings = _cachedVertexInputBindings;
        }

        private static SolMetalNativeBridge.GalVertexBufferLayout
            BuildVertexBufferLayout(int bufferIndex, int stride, int divisor)
        {
            if (bufferIndex < 0 ||
                bufferIndex >= MaximumGuestVertexBuffers ||
                stride < 0 ||
                divisor < 0)
            {
                throw Unsupported(
                    $"invalid vertex-buffer layout (index={bufferIndex}, " +
                    $"stride={stride}, divisor={divisor})"
                );
            }

            uint metalBufferIndex = checked(
                (uint)bufferIndex + VertexBufferBase
            );
            if (stride == 0)
            {
                return new(
                    metalBufferIndex,
                    ConstantVertexFetchStride,
                    SolMetalNativeBridge.GalVertexStepFunction.Constant,
                    0
                );
            }

            return new(
                metalBufferIndex,
                checked((uint)stride),
                divisor == 0
                    ? SolMetalNativeBridge.GalVertexStepFunction.PerVertex
                    : SolMetalNativeBridge.GalVertexStepFunction.PerInstance,
                checked((uint)Math.Max(1, divisor))
            );
        }

        internal static void ValidateZeroStrideVertexLayout()
        {
            SolMetalNativeBridge.GalVertexBufferLayout constant =
                BuildVertexBufferLayout(3, 0, 7);
            if (constant.BufferIndex != VertexBufferBase + 3 ||
                constant.Stride != ConstantVertexFetchStride ||
                constant.StepFunction !=
                    SolMetalNativeBridge.GalVertexStepFunction.Constant ||
                constant.StepRate != 0)
            {
                throw new InvalidOperationException(
                    "SolMetal did not map a zero-stride guest vertex stream " +
                    "to a constant Metal vertex fetch."
                );
            }

            SolMetalNativeBridge.GalVertexBufferLayout instanced =
                BuildVertexBufferLayout(2, 24, 4);
            if (instanced.Stride != 24 ||
                instanced.StepFunction !=
                    SolMetalNativeBridge.GalVertexStepFunction.PerInstance ||
                instanced.StepRate != 4)
            {
                throw new InvalidOperationException(
                    "SolMetal changed a non-zero instanced vertex layout."
                );
            }
        }

        private SolMetalTargetedProbeD16Replay?
            BuildTargetedD16ReplaySnapshot(
                SolMetalGalTexture? depthTarget,
                SolMetalNativeBridge.GalDepthStencilState depthStencilState
            )
        {
            if (_program is null || depthTarget is null ||
                depthTarget.NativeFormat !=
                    SolMetalNativeBridge.GalTextureFormat.Depth16Unorm ||
                depthStencilState.DepthWriteEnabled ||
                depthStencilState.DepthCompareFunction !=
                    SolMetalNativeBridge.GalCompareFunction.Equal ||
                !TryGetProbeBuffer(
                    ShaderStage.Vertex,
                    ResourceType.UniformBuffer,
                    metalBuffer: 18,
                    out BufferRange c4Constants,
                    out _) ||
                !TryGetProbeBuffer(
                    ShaderStage.Vertex,
                    ResourceType.UniformBuffer,
                    metalBuffer: 19,
                    out BufferRange c11Constants,
                    out _))
            {
                return null;
            }

            byte[]? c4BiasBytes = ReadProbeBuffer(
                c4Constants,
                relativeOffset: 147 * 16 + 8,
                length: sizeof(float)
            );
            byte[]? c11TagBytes = ReadProbeBuffer(
                c11Constants,
                relativeOffset: 25 * 16,
                length: sizeof(float)
            );
            if (c4BiasBytes is null || c11TagBytes is null)
            {
                return null;
            }

            float depthBias = MemoryMarshal.Read<float>(c4BiasBytes);
            float rawTagFloat = MemoryMarshal.Read<float>(c11TagBytes);
            if (!float.IsFinite(depthBias) || !float.IsFinite(rawTagFloat))
            {
                return null;
            }
            float truncatedTag = MathF.Truncate(rawTagFloat);
            uint rawTag = !float.IsFinite(truncatedTag) || truncatedTag <= 0
                ? 0
                : truncatedTag >= uint.MaxValue
                    ? uint.MaxValue
                    : (uint)truncatedTag;
            int expectedCode = D16CodeForTag(rawTag, depthBias);
            TargetedD16WriterProbe? writerProbe = Volatile.Read(
                ref _renderer._targetedD16WriterProbe
            );
            bool matchingWriter = writerProbe is not null &&
                writerProbe.DepthTextureId == depthTarget.ProbeId;
            ulong writerCodeCount = matchingWriter
                ? writerProbe!.Histogram[expectedCode]
                : 0;
            return new SolMetalTargetedProbeD16Replay(
                rawTag,
                expectedCode,
                matchingWriter,
                writerCodeCount
            );
        }

        private void CaptureTargetedD16Probe(
            TargetedProbeSelection selection,
            ProbeDrawDepthSnapshot currentDepth,
            SolMetalNativeBridge.GalDepthStencilState depthStencilState,
            int instanceCount
        )
        {
            if (!_renderer._frameProbeEnabled || _program is null ||
                currentDepth.Target is not SolMetalGalTexture depthTarget ||
                depthTarget.NativeFormat !=
                    SolMetalNativeBridge.GalTextureFormat.Depth16Unorm ||
                !depthTarget.IsSingleLevelTexture2D)
            {
                return;
            }

            try
            {
                if (depthStencilState.DepthWriteEnabled &&
                    CaptureTargetedD16Writer(
                        selection,
                        depthTarget,
                        depthStencilState
                    ))
                {
                    return;
                }
                CaptureTargetedD16Replay(
                    selection,
                    depthTarget,
                    depthStencilState,
                    instanceCount
                );
            }
            catch (Exception exception)
            {
                Logger.Warning?.Print(
                    LogClass.Gpu,
                    $"SolMetal could not capture targeted D16 program " +
                    $"#{_program.ProbeId} (capture={selection.CaptureId}, " +
                    $"selector={selection.Name}): {exception.Message}"
                );
            }
        }

        private void CaptureTargetedTextureProbe(
            TargetedProbeSelection selection,
            ProbeDrawDepthSnapshot currentDepth,
            string phase,
            bool includeInputs,
            bool includeOutputs
        )
        {
            if (!_renderer._frameProbeEnabled || _program is null)
            {
                return;
            }

            try
            {
                const long MaximumCaptureBytes = 128L * 1024 * 1024;
                string directory = TargetedProbeDirectory(selection);
                HashSet<long> dumpedPrograms = [];
                SolMetalGalWindow.DumpProbeProgram(
                    _program,
                    dumpedPrograms,
                    directory
                );
                if (includeInputs)
                {
                    SolMetalGalTexture? bufferReader =
                        _colorTargets.FirstOrDefault(texture => texture is not null) ??
                        _depthStencilTarget ??
                        _texturesAndSamplers.Values
                            .Select(binding => binding.Texture)
                            .FirstOrDefault();
                    if (bufferReader is not null)
                    {
                        SolMetalGalWindow.DumpProbeBuffers(
                            bufferReader,
                            _program,
                            BuildProbeBufferBindings(),
                            "before-draw",
                            [],
                            directory
                        );
                    }
                }
                StringBuilder report = new();
                report.AppendLine($"captureId={selection.CaptureId}");
                report.AppendLine($"selector={selection.Name}");
                report.AppendLine($"selectorSpec={selection.Description}");
                report.AppendLine($"program={_program.ProbeId}");
                report.AppendLine($"stableKey={_program.StableKey}");
                report.AppendLine($"phase={phase}");
                report.AppendLine(
                    $"presentation={Interlocked.Read(ref _renderer._presentedFrameCount)}"
                );
                HashSet<long> capturedViews = [];
                long capturedBytes = 0;
                int artifactIndex = 0;

                void CaptureTexture(
                    string role,
                    SolMetalGalTexture texture,
                    SolMetalGalSampler? sampler
                )
                {
                    report.AppendLine($"[{role}]");
                    report.AppendLine($"texture={texture.DescribeProbe()}");
                    report.AppendLine(
                        $"sampler={sampler?.DescribeProbe() ?? "none"}"
                    );
                    ProbeColorClearRecord[] clears =
                        texture.GetRecentProbeColorClears();
                    report.AppendLine($"recentColorClears={clears.Length}");
                    for (int clearIndex = 0;
                         clearIndex < clears.Length;
                         clearIndex++)
                    {
                        ProbeColorClearRecord clear = clears[clearIndex];
                        report.AppendLine(
                            $"clear[{clearIndex}]=presentation" +
                            $"{clear.Presentation},draws={clear.Draws}," +
                            $"target={clear.TargetView},region=({clear.X}," +
                            $"{clear.Y},{clear.Width},{clear.Height})," +
                            $"mask=0x{clear.ComponentMask:X},rgba=(" +
                            $"{clear.Red:R},{clear.Green:R}," +
                            $"{clear.Blue:R},{clear.Alpha:R})"
                        );
                    }
                    ProbeDrawRecord[] recentDraws =
                        texture.GetRecentProbeDraws();
                    report.AppendLine($"recentDraws={recentDraws.Length}");
                    for (int drawIndex = 0;
                         drawIndex < recentDraws.Length;
                         drawIndex++)
                    {
                        ProbeDrawRecord draw = recentDraws[drawIndex];
                        SolMetalGalWindow.DumpProbeProgram(
                            draw.Program,
                            dumpedPrograms,
                            directory
                        );
                        report.AppendLine(
                            $"draw[{drawIndex}]=program" +
                            $"{draw.Program?.ProbeId ?? 0},key=" +
                            $"{draw.Program?.StableKey ?? "none"}," +
                            $"target={draw.TargetView},state=[" +
                            $"{draw.Details ?? "none"}]"
                        );
                        for (int sampledIndex = 0;
                             sampledIndex < draw.SampledTextures.Length;
                             sampledIndex++)
                        {
                            report.AppendLine(
                                $"draw[{drawIndex}].sampled[" +
                                $"{sampledIndex}]=" +
                                draw.SampledTextures[sampledIndex]
                                    .DescribeProbeViewIdentity()
                            );
                        }
                    }
                    if (!texture.CanProbeRaw)
                    {
                        report.AppendLine("capture=unsupported-texture-kind");
                        return;
                    }
                    if (!capturedViews.Add(texture.ProbeViewId))
                    {
                        report.AppendLine("capture=reused-view-artifacts-above");
                        return;
                    }

                    for (int level = 0; level < texture.Levels; level++)
                    {
                        int slices = texture.GetProbeSliceCount(level);
                        int subresourceBytes =
                            texture.GetProbeSubresourceSize(level);
                        for (int layer = 0; layer < slices; layer++)
                        {
                            if (capturedBytes >
                                MaximumCaptureBytes - subresourceBytes)
                            {
                                report.AppendLine(
                                    $"capture=budget-exhausted-at-mip{level}-" +
                                    $"layer{layer}, capturedBytes={capturedBytes}"
                                );
                                return;
                            }
                            try
                            {
                                byte[] bytes = texture.ReadProbeSubresource(
                                    layer,
                                    level
                                );
                                capturedBytes = checked(
                                    capturedBytes + bytes.Length
                                );
                                int sequence = artifactIndex++;
                                string artifactPath = Path.Combine(
                                    directory,
                                    $"texture-{phase}-{sequence:D2}-view-" +
                                    $"{texture.ProbeViewId}-mip-{level}-" +
                                    $"layer-{layer}.bin"
                                );
                                File.WriteAllBytes(artifactPath, bytes);
                                report.AppendLine(
                                    $"subresource={texture.DescribeProbeSubresource(layer, level)}"
                                );
                                report.AppendLine($"path={artifactPath}");
                                report.AppendLine(
                                    $"bytes={SummarizeProbeBytes(bytes)}"
                                );
                            }
                            catch (Exception exception)
                            {
                                report.AppendLine(
                                    $"capture-error=mip{level}/layer{layer}: " +
                                    exception.Message
                                );
                            }
                        }
                    }
                }

                void CaptureDepth()
                {
                    report.AppendLine("[output-depth]");
                    report.AppendLine(
                        $"currentDrawDepth={currentDepth.Description}"
                    );
                    if (currentDepth.Target is not SolMetalGalTexture depthTarget)
                    {
                        return;
                    }
                    if (!depthTarget.CanProbeDepth32)
                    {
                        report.AppendLine(
                            "depth32Capture=unsupported-or-extension-missing"
                        );
                        return;
                    }

                    int depthBytes = depthTarget.BaseLevelSize;
                    if (capturedBytes > MaximumCaptureBytes - depthBytes)
                    {
                        report.AppendLine(
                            "depth32Capture=budget-exhausted," +
                            $"capturedBytes={capturedBytes}"
                        );
                        return;
                    }
                    try
                    {
                        byte[] bytes = depthTarget.ReadProbeDepth32();
                        capturedBytes = checked(capturedBytes + bytes.Length);
                        int sequence = artifactIndex++;
                        string artifactPath = Path.Combine(
                            directory,
                            $"depth-{phase}-{sequence:D2}-view-" +
                            $"{depthTarget.ProbeViewId}.bin"
                        );
                        File.WriteAllBytes(artifactPath, bytes);
                        report.AppendLine($"depth32Path={artifactPath}");
                        report.AppendLine(
                            "depth32Bytes=" + SummarizeProbeBytes(bytes)
                        );
                        report.AppendLine(
                            "depth32Values=" + SummarizeDepth32ProbeBytes(
                                bytes,
                                depthTarget.Width,
                                depthTarget.Height,
                                depthTarget.BaseLevelStride
                            )
                        );
                    }
                    catch (Exception exception)
                    {
                        report.AppendLine(
                            "depth32CaptureError=" + exception.Message
                        );
                    }
                }

                // The selector-qualified evidence is mandatory. Capture the
                // exact depth and requested color target before optional input
                // textures can consume the bounded diagnostic budget.
                if (includeOutputs)
                {
                    CaptureDepth();
                    int preferredSlot = selection.PreferredColorSlot;
                    if (preferredSlot >= 0 &&
                        preferredSlot < _colorTargets.Length &&
                        _colorTargets[preferredSlot] is
                            SolMetalGalTexture preferredTarget)
                    {
                        string role = $"output-color-{preferredSlot}-mask-" +
                            $"0x{_colorWriteMasks[preferredSlot]:X}-load-" +
                            $"{_colorLoadActions[preferredSlot]}";
                        CaptureTexture(role, preferredTarget, null);
                    }
                }

                if (includeInputs)
                {
                    foreach (ProgramResourceBinding resource in
                             _program.ResourceBindings)
                    {
                        string role =
                            $"input-{resource.Stage}-set" +
                            $"{resource.DescriptorSet}-binding" +
                            $"{resource.Binding}-{resource.Type}-metal-t" +
                            $"{resource.MetalTexture}-s" +
                            $"{resource.MetalSampler}";
                        if (resource.Type is ResourceType.TextureAndSampler or
                            ResourceType.Texture or ResourceType.Sampler or
                            ResourceType.BufferTexture)
                        {
                            if (_texturesAndSamplers.TryGetValue(
                                    (resource.Stage, resource.Binding),
                                    out var pair))
                            {
                                if (resource.Type == ResourceType.Sampler)
                                {
                                    report.AppendLine($"[{role}]");
                                    report.AppendLine(
                                        $"sampler={pair.Sampler?.DescribeProbe() ?? "none"}"
                                    );
                                }
                                else
                                {
                                    CaptureTexture(
                                        role,
                                        pair.Texture,
                                        pair.Sampler
                                    );
                                }
                            }
                            else
                            {
                                report.AppendLine($"[{role}]");
                                report.AppendLine("binding=missing-dummy-used");
                            }
                        }
                        else if (resource.Type is ResourceType.Image or
                                 ResourceType.BufferImage)
                        {
                            if (_images.TryGetValue(
                                    (resource.Stage, resource.Binding),
                                    out SolMetalGalTexture? image))
                            {
                                CaptureTexture(role, image, null);
                            }
                            else
                            {
                                report.AppendLine($"[{role}]");
                                report.AppendLine("binding=missing-dummy-used");
                            }
                        }
                    }
                }

                if (includeOutputs)
                {
                    for (int slot = 0; slot < _colorTargets.Length; slot++)
                    {
                        if (slot == selection.PreferredColorSlot)
                        {
                            continue;
                        }
                        if (_colorTargets[slot] is not SolMetalGalTexture target)
                        {
                            continue;
                        }
                        string role = $"output-color-{slot}-mask-" +
                            $"0x{_colorWriteMasks[slot]:X}-load-" +
                            $"{_colorLoadActions[slot]}";
                        CaptureTexture(role, target, null);
                    }
                }

                report.AppendLine($"capturedBytes={capturedBytes}");
                string reportPath = Path.Combine(
                    directory,
                    $"texture-probe-{phase}.txt"
                );
                File.WriteAllText(reportPath, report.ToString());
                Logger.Notice.Print(
                    LogClass.Gpu,
                    $"SolMetal captured targeted texture state for program " +
                    $"#{_program.ProbeId} (key={_program.StableKey}, " +
                    $"capture={selection.CaptureId}, " +
                    $"selector={selection.Name}, " +
                    $"phase={phase}, bytes={capturedBytes}); " +
                    $"report={reportPath}."
                );
            }
            catch (Exception exception)
            {
                Logger.Warning?.Print(
                    LogClass.Gpu,
                    $"SolMetal could not capture targeted texture state for " +
                    $"program #{_program.ProbeId} (capture=" +
                    $"{selection.CaptureId}, selector={selection.Name}, " +
                    $"{phase}): " +
                    exception.Message
                );
            }
        }

        private bool CaptureTargetedD16Writer(
            TargetedProbeSelection selection,
            SolMetalGalTexture depthTarget,
            SolMetalNativeBridge.GalDepthStencilState depthStencilState
        )
        {
            if (_program is null ||
                !TryGetProbeTexture(
                    ShaderStage.Fragment,
                    metalTexture: 0,
                    out SolMetalGalTexture sourceTexture,
                    out SolMetalGalSampler? sourceSampler,
                    out ProgramResourceBinding sourceResource) ||
                !TryGetProbeBuffer(
                    ShaderStage.Fragment,
                    ResourceType.UniformBuffer,
                    metalBuffer: 1,
                    out BufferRange fragmentConstants,
                    out ProgramResourceBinding fragmentConstantResource))
            {
                return false;
            }

            byte[]? constantPrefix = ReadProbeBuffer(
                fragmentConstants,
                relativeOffset: 0,
                length: 124
            );
            if (constantPrefix is null)
            {
                return false;
            }
            int tagMask = MemoryMarshal.Read<int>(
                constantPrefix.AsSpan(16, sizeof(int))
            );
            float depthBias = MemoryMarshal.Read<float>(
                constantPrefix.AsSpan(120, sizeof(float))
            );
            float? texelOffset = null;
            if (TryGetProbeBuffer(
                    ShaderStage.Vertex,
                    ResourceType.UniformBuffer,
                    metalBuffer: 18,
                    out BufferRange vertexConstants,
                    out _) &&
                ReadProbeBuffer(
                    vertexConstants,
                    relativeOffset: 0,
                    length: sizeof(float)
                ) is byte[] vertexPrefix)
            {
                texelOffset = MemoryMarshal.Read<float>(vertexPrefix);
            }

            string directory = TargetedProbeDirectory(selection);
            using PinnedSpan<byte> sourceReadback = sourceTexture.GetData();
            ReadOnlySpan<byte> allSourceBytes = sourceReadback.Get();
            int sourceLength = Math.Min(
                sourceTexture.BaseLevelSize,
                allSourceBytes.Length
            );
            byte[] sourceBytes = allSourceBytes[..sourceLength].ToArray();
            ulong[] rawSourceHistogram = BuildTightByteHistogram(
                sourceTexture,
                sourceBytes
            );
            ulong[]? sourceTexelHistogram = BuildSourceTexelHistogram(
                sourceTexture,
                sourceBytes
            );
            string sourcePath = Path.Combine(
                directory,
                $"program-{_program.ProbeId}-d16-writer-source-" +
                $"texture-{sourceTexture.ProbeId}-{sourceTexture.NativeFormat}-" +
                $"{sourceTexture.Width}x{sourceTexture.Height}.bin"
            );
            File.WriteAllBytes(sourcePath, sourceBytes);

            using PinnedSpan<byte> depthReadback = depthTarget.GetData();
            ReadOnlySpan<byte> allDepthBytes = depthReadback.Get();
            int depthLength = Math.Min(
                depthTarget.BaseLevelSize,
                allDepthBytes.Length
            );
            byte[] depthBytes = allDepthBytes[..depthLength].ToArray();
            ulong[] depthHistogram = BuildD16Histogram(
                depthBytes,
                depthTarget.Width,
                depthTarget.Height,
                depthTarget.BaseLevelStride
            );
            string sidecarPath = Path.Combine(
                directory,
                $"program-{_program.ProbeId}-d16-writer-sidecar-" +
                $"texture-{depthTarget.ProbeId}-" +
                $"{depthTarget.Width}x{depthTarget.Height}.bin"
            );
            File.WriteAllBytes(sidecarPath, depthBytes);

            ulong[]? predictedDepthHistogram = null;
            if (sourceTexelHistogram is not null && float.IsFinite(depthBias))
            {
                predictedDepthHistogram = new ulong[ushort.MaxValue + 1];
                for (int rawTag = 0; rawTag < sourceTexelHistogram.Length; rawTag++)
                {
                    ulong count = sourceTexelHistogram[rawTag];
                    if (count == 0)
                    {
                        continue;
                    }
                    uint maskedTag = unchecked((uint)(rawTag & tagMask));
                    predictedDepthHistogram[
                        D16CodeForTag(maskedTag, depthBias)
                    ] += count;
                }
            }

            string capturePath = Path.Combine(
                directory,
                $"program-{_program.ProbeId}-d16-writer-histogram.txt"
            );
            StringBuilder report = new();
            report.AppendLine($"captureId={selection.CaptureId}");
            report.AppendLine($"selector={selection.Name}");
            report.AppendLine($"selectorSpec={selection.Description}");
            report.AppendLine($"program={_program.ProbeId}");
            report.AppendLine($"stableKey={_program.StableKey}");
            report.AppendLine("role=fragment-depth-writer");
            report.AppendLine(
                $"depthState={depthStencilState.DepthCompareFunction}/" +
                $"write={depthStencilState.DepthWriteEnabled}"
            );
            report.AppendLine(
                $"depthTexture={depthTarget.DescribeProbe()}"
            );
            report.AppendLine($"depthSidecarPath={sidecarPath}");
            report.AppendLine(
                $"sourceResource={sourceResource.Stage}/" +
                $"set{sourceResource.DescriptorSet}/binding" +
                $"{sourceResource.Binding}->metalTexture" +
                $"{sourceResource.MetalTexture}"
            );
            report.AppendLine(
                $"sourceTexture={sourceTexture.DescribeProbe()}"
            );
            report.AppendLine($"sourcePath={sourcePath}");
            report.AppendLine(
                $"sourceSampler={sourceSampler?.DescribeProbe() ?? "missing"}"
            );
            report.AppendLine(
                $"sourcePointSampled={sourceSampler?.IsPointSampled ?? false}"
            );
            report.AppendLine(
                $"sourceBaseLevelStride={sourceTexture.BaseLevelStride}"
            );
            ProbeColorClearRecord[] sourceColorClears =
                sourceTexture.GetRecentProbeColorClears();
            report.AppendLine("[source-recent-color-clears]");
            if (sourceColorClears.Length == 0)
            {
                report.AppendLine("none");
            }
            else
            {
                foreach (ProbeColorClearRecord clear in sourceColorClears)
                {
                    report.AppendLine(
                        $"presentation={clear.Presentation},draws={clear.Draws}," +
                        $"target={clear.TargetView}," +
                        $"region=({clear.X},{clear.Y},{clear.Width}," +
                        $"{clear.Height}),mask=0x{clear.ComponentMask:X}," +
                        $"rgba=({clear.Red:R},{clear.Green:R}," +
                        $"{clear.Blue:R},{clear.Alpha:R})"
                    );
                }
            }
            report.AppendLine(
                $"fragmentConstants={fragmentConstantResource.Stage}/" +
                $"set{fragmentConstantResource.DescriptorSet}/binding" +
                $"{fragmentConstantResource.Binding}->metalBuffer" +
                $"{fragmentConstantResource.MetalBuffer}"
            );
            report.AppendLine($"tagMask=0x{unchecked((uint)tagMask):X8}");
            report.AppendLine($"depthBias={depthBias:R}");
            report.AppendLine(
                $"texelOffset={(texelOffset.HasValue ? texelOffset.Value.ToString("R") : "unavailable")}"
            );
            report.AppendLine(
                $"sourceTag32Count={sourceTexelHistogram?[32] ?? 0}"
            );
            report.AppendLine(
                $"sourceTag35Count={sourceTexelHistogram?[35] ?? 0}"
            );
            report.AppendLine(
                $"d16Clear32768Count={depthHistogram[32_768]}"
            );
            report.AppendLine(
                $"d16Tag32Code={D16CodeForTag(unchecked((uint)(32 & tagMask)), depthBias)}"
            );
            report.AppendLine(
                $"d16Tag35Code={D16CodeForTag(unchecked((uint)(35 & tagMask)), depthBias)}"
            );
            report.AppendLine("[source-raw-byte-histogram]");
            report.AppendLine(FormatNonZeroHistogram(rawSourceHistogram));
            if (sourceTexelHistogram is not null)
            {
                report.AppendLine("[source-texel-x-histogram]");
                report.AppendLine(FormatNonZeroHistogram(sourceTexelHistogram));
            }
            else
            {
                report.AppendLine("sourceTexelHistogram=unsupported-format");
            }
            if (predictedDepthHistogram is not null)
            {
                report.AppendLine("[source-texel-predicted-d16-histogram]");
                report.AppendLine(FormatNonZeroHistogram(predictedDepthHistogram));
            }
            report.AppendLine("[d16-sidecar-histogram]");
            report.AppendLine(FormatNonZeroHistogram(depthHistogram));
            File.WriteAllText(capturePath, report.ToString());

            Volatile.Write(
                ref _renderer._targetedD16WriterProbe,
                new TargetedD16WriterProbe(
                    _program.ProbeId,
                    depthTarget.ProbeId,
                    depthHistogram,
                    capturePath,
                    sidecarPath
                )
            );
            LogRawProbe(
                sourceBytes,
                $"targeted D16 writer program #{_program.ProbeId} source"
            );
            LogRawProbe(
                depthBytes,
                $"targeted D16 writer program #{_program.ProbeId} sidecar"
            );
            Logger.Notice.Print(
                LogClass.Gpu,
                $"SolMetal captured targeted D16 writer program " +
                $"#{_program.ProbeId} (key={_program.StableKey}, " +
                $"capture={selection.CaptureId}, selector={selection.Name}); " +
                "source tags=" +
                $"[{(sourceTexelHistogram is null ? "unavailable" : SummarizeHistogram(sourceTexelHistogram))}], " +
                $"sidecar codes=[{SummarizeHistogram(depthHistogram)}], " +
                $"report={capturePath}."
            );
            return true;
        }

        private void CaptureTargetedD16Replay(
            TargetedProbeSelection selection,
            SolMetalGalTexture depthTarget,
            SolMetalNativeBridge.GalDepthStencilState depthStencilState,
            int instanceCount
        )
        {
            if (_program is null ||
                !TryGetProbeBuffer(
                    ShaderStage.Vertex,
                    ResourceType.UniformBuffer,
                    metalBuffer: 18,
                    out BufferRange c4Constants,
                    out ProgramResourceBinding c4Resource) ||
                !TryGetProbeBuffer(
                    ShaderStage.Vertex,
                    ResourceType.UniformBuffer,
                    metalBuffer: 19,
                    out BufferRange c11Constants,
                    out ProgramResourceBinding c11Resource))
            {
                return;
            }

            bool hasClassifier = TryGetProbeBuffer(
                ShaderStage.Vertex,
                ResourceType.StorageBuffer,
                metalBuffer: 20,
                out BufferRange classifierBuffer,
                out ProgramResourceBinding classifierResource
            );

            byte[]? c4BiasBytes = ReadProbeBuffer(
                c4Constants,
                relativeOffset: 147 * 16 + 8,
                length: sizeof(float)
            );
            byte[]? c11TagBytes = ReadProbeBuffer(
                c11Constants,
                relativeOffset: 25 * 16,
                length: sizeof(float)
            );
            byte[]? classifierBaseBytes = hasClassifier
                ? ReadProbeBuffer(
                    classifierBuffer,
                    relativeOffset: 100 * sizeof(uint),
                    length: sizeof(int)
                )
                : null;
            if (c4BiasBytes is null || c11TagBytes is null)
            {
                return;
            }
            float depthBias = MemoryMarshal.Read<float>(c4BiasBytes);
            float rawTagFloat = MemoryMarshal.Read<float>(c11TagBytes);
            float truncatedTag = MathF.Truncate(rawTagFloat);
            uint rawTag = !float.IsFinite(truncatedTag) || truncatedTag <= 0
                ? 0
                : truncatedTag >= uint.MaxValue
                    ? uint.MaxValue
                    : (uint)truncatedTag;
            int expectedCode = D16CodeForTag(rawTag, depthBias);
            int? classifierBase = classifierBaseBytes is null
                ? null
                : MemoryMarshal.Read<int>(classifierBaseBytes);

            int flagEqualOne = 0;
            int flagOther = 0;
            int flagUnavailable = 0;
            List<int> equalOneInstances = [];
            if (instanceCount > 0 && classifierBase.HasValue)
            {
                long classifierOffset = (long)classifierBase.Value * 16 + 460;
                long classifierLength = (long)(instanceCount - 1) * 16 +
                    sizeof(int);
                if (classifierOffset >= 0 && classifierLength > 0 &&
                    classifierOffset <= int.MaxValue &&
                    classifierLength <= int.MaxValue &&
                    ReadProbeBuffer(
                        classifierBuffer,
                        (int)classifierOffset,
                        (int)classifierLength
                    ) is byte[] classifierBytes)
                {
                    for (int instance = 0; instance < instanceCount; instance++)
                    {
                        int flag = MemoryMarshal.Read<int>(
                            classifierBytes.AsSpan(instance * 16, sizeof(int))
                        );
                        if (flag == 1)
                        {
                            flagEqualOne++;
                            if (equalOneInstances.Count < 32)
                            {
                                equalOneInstances.Add(instance);
                            }
                        }
                        else
                        {
                            flagOther++;
                        }
                    }
                }
                else
                {
                    flagUnavailable = instanceCount;
                }
            }
            else if (instanceCount > 0)
            {
                flagUnavailable = instanceCount;
            }

            TargetedD16WriterProbe? writerProbe = Volatile.Read(
                ref _renderer._targetedD16WriterProbe
            );
            bool matchingWriter = writerProbe is not null &&
                writerProbe.DepthTextureId == depthTarget.ProbeId;
            ulong writerCodeCount = matchingWriter
                ? writerProbe!.Histogram[expectedCode]
                : 0;
            string directory = TargetedProbeDirectory(selection);
            string capturePath = Path.Combine(
                directory,
                $"program-{_program.ProbeId}-d16-replay.txt"
            );
            StringBuilder report = new();
            report.AppendLine($"captureId={selection.CaptureId}");
            report.AppendLine($"selector={selection.Name}");
            report.AppendLine($"selectorSpec={selection.Description}");
            report.AppendLine($"program={_program.ProbeId}");
            report.AppendLine($"stableKey={_program.StableKey}");
            report.AppendLine("role=early-test-replay");
            report.AppendLine(
                $"depthState={depthStencilState.DepthCompareFunction}/" +
                $"write={depthStencilState.DepthWriteEnabled}"
            );
            report.AppendLine(
                $"depthTexture={depthTarget.DescribeProbe()}"
            );
            report.AppendLine(
                $"c4Resource={c4Resource.Stage}/set{c4Resource.DescriptorSet}/" +
                $"binding{c4Resource.Binding}->metalBuffer" +
                $"{c4Resource.MetalBuffer}"
            );
            report.AppendLine(
                $"c11Resource={c11Resource.Stage}/set{c11Resource.DescriptorSet}/" +
                $"binding{c11Resource.Binding}->metalBuffer" +
                $"{c11Resource.MetalBuffer}"
            );
            report.AppendLine(hasClassifier
                ? $"classifierResource={classifierResource.Stage}/" +
                    $"set{classifierResource.DescriptorSet}/binding" +
                    $"{classifierResource.Binding}->metalBuffer" +
                    $"{classifierResource.MetalBuffer}"
                : "classifierResource=unavailable");
            report.AppendLine($"rawTagFloat={rawTagFloat:R}");
            report.AppendLine($"rawTag={rawTag}");
            report.AppendLine($"decodedTag={DecodeNibbleSwappedTag(rawTag)}");
            report.AppendLine($"depthBias={depthBias:R}");
            report.AppendLine($"expectedD16Code={expectedCode}");
            report.AppendLine(
                $"classifierBase={classifierBase?.ToString() ?? "unavailable"}"
            );
            report.AppendLine($"instances={instanceCount}");
            report.AppendLine($"flagsEqualOne={flagEqualOne}");
            report.AppendLine($"flagsOther={flagOther}");
            report.AppendLine($"flagsUnavailable={flagUnavailable}");
            report.AppendLine(
                $"classifierCoveredInstances={flagEqualOne + flagOther}"
            );
            report.AppendLine(
                $"classifierCoverageComplete=" +
                $"{flagUnavailable == 0 && flagEqualOne + flagOther == instanceCount}"
            );
            report.AppendLine(
                $"equalOneInstancePrefix={string.Join(",", equalOneInstances)}"
            );
            report.AppendLine($"matchingWriterCapture={matchingWriter}");
            report.AppendLine(
                $"writerProgram={writerProbe?.ProgramId.ToString() ?? "unavailable"}"
            );
            report.AppendLine(
                $"writerCapture={writerProbe?.CapturePath ?? "unavailable"}"
            );
            report.AppendLine(
                $"writerDepthSidecar=" +
                $"{writerProbe?.SidecarPath ?? "unavailable"}"
            );
            report.AppendLine($"writerExpectedCodeCount={writerCodeCount}");
            File.WriteAllText(capturePath, report.ToString());
            Logger.Notice.Print(
                LogClass.Gpu,
                $"SolMetal captured targeted D16 replay program " +
                $"#{_program.ProbeId} (key={_program.StableKey}, " +
                $"capture={selection.CaptureId}, selector={selection.Name}): " +
                $"rawTag={rawTag}, code={expectedCode}, " +
                $"writer-count={writerCodeCount}, flags(1/other/unavailable)=" +
                $"{flagEqualOne}/{flagOther}/{flagUnavailable}, " +
                $"report={capturePath}."
            );
        }

        private bool TryGetProbeTexture(
            ShaderStage stage,
            uint metalTexture,
            out SolMetalGalTexture texture,
            out SolMetalGalSampler? sampler,
            out ProgramResourceBinding matchedResource
        )
        {
            texture = null!;
            sampler = null;
            matchedResource = default;
            if (_program is null)
            {
                return false;
            }

            foreach (ProgramResourceBinding resource in
                     _program.ResourceBindings)
            {
                if (resource.Stage != stage ||
                    resource.MetalTexture != metalTexture ||
                    resource.Type is not ResourceType.TextureAndSampler and
                        not ResourceType.Texture)
                {
                    continue;
                }
                if (_texturesAndSamplers.TryGetValue(
                        (resource.Stage, resource.Binding),
                        out var pair) &&
                    !pair.Texture.IsBufferTexture)
                {
                    texture = pair.Texture;
                    sampler = pair.Sampler;
                    matchedResource = resource;
                    return true;
                }
            }
            return false;
        }

        private bool TryGetProbeBuffer(
            ShaderStage stage,
            ResourceType type,
            uint metalBuffer,
            out BufferRange range,
            out ProgramResourceBinding matchedResource
        )
        {
            range = default;
            matchedResource = default;
            if (_program is null)
            {
                return false;
            }

            Dictionary<int, BufferRange> source = type switch
            {
                ResourceType.UniformBuffer => _uniformBuffers,
                ResourceType.StorageBuffer => _storageBuffers,
                _ => throw new ArgumentOutOfRangeException(nameof(type)),
            };
            foreach (ProgramResourceBinding resource in
                     _program.ResourceBindings)
            {
                if (resource.Stage == stage && resource.Type == type &&
                    resource.MetalBuffer == metalBuffer &&
                    source.TryGetValue(resource.Binding, out range))
                {
                    matchedResource = resource;
                    return true;
                }
            }
            return false;
        }

        private byte[]? ReadProbeBuffer(
            BufferRange range,
            int relativeOffset,
            int length
        )
        {
            if (relativeOffset < 0 || length <= 0 ||
                relativeOffset > range.Size || length > range.Size - relativeOffset)
            {
                return null;
            }
            using PinnedSpan<byte> data = _renderer.GetBufferData(
                range.Handle,
                checked(range.Offset + relativeOffset),
                length
            );
            return data.Get().ToArray();
        }

        private static ulong[] BuildTightByteHistogram(
            SolMetalGalTexture texture,
            ReadOnlySpan<byte> bytes
        )
        {
            int blockColumns = checked(
                (texture.Width + texture.BlockWidth - 1) / texture.BlockWidth
            );
            int blockRows = checked(
                (texture.Height + texture.BlockHeight - 1) / texture.BlockHeight
            );
            int tightBytesPerRow = checked(blockColumns * texture.BytesPerPixel);
            if (texture.BaseLevelStride < tightBytesPerRow ||
                bytes.Length < checked(texture.BaseLevelStride * blockRows))
            {
                throw new ArgumentException("Invalid source texture probe layout.");
            }

            ulong[] histogram = new ulong[byte.MaxValue + 1];
            for (int row = 0; row < blockRows; row++)
            {
                ReadOnlySpan<byte> tightRow = bytes.Slice(
                    row * texture.BaseLevelStride,
                    tightBytesPerRow
                );
                foreach (byte value in tightRow)
                {
                    histogram[value]++;
                }
            }
            return histogram;
        }

        private static ulong[]? BuildSourceTexelHistogram(
            SolMetalGalTexture texture,
            ReadOnlySpan<byte> bytes
        )
        {
            if (!texture.IsSingleLevelTexture2D || texture.BlockWidth != 1 ||
                texture.BlockHeight != 1 ||
                !TryGetUnorm8ComponentLayout(
                    texture.Format,
                    out int redOffset,
                    out int greenOffset,
                    out int blueOffset,
                    out int alphaOffset))
            {
                return null;
            }

            int tightBytesPerRow = checked(
                texture.Width * texture.BytesPerPixel
            );
            if (texture.BaseLevelStride < tightBytesPerRow ||
                bytes.Length < checked(texture.BaseLevelStride * texture.Height))
            {
                throw new ArgumentException("Invalid source texel probe layout.");
            }

            int selectedOffset = texture.SwizzleR switch
            {
                SwizzleComponent.Red => redOffset,
                SwizzleComponent.Green => greenOffset,
                SwizzleComponent.Blue => blueOffset,
                SwizzleComponent.Alpha => alphaOffset,
                SwizzleComponent.Zero => -2,
                SwizzleComponent.One => -1,
                _ => int.MinValue,
            };
            if (selectedOffset == int.MinValue)
            {
                return null;
            }
            ulong[] histogram = new ulong[byte.MaxValue + 1];
            for (int y = 0; y < texture.Height; y++)
            {
                int rowOffset = y * texture.BaseLevelStride;
                for (int x = 0; x < texture.Width; x++)
                {
                    byte code = selectedOffset switch
                    {
                        -2 => 0,
                        -1 => byte.MaxValue,
                        >= 0 => bytes[
                            rowOffset + x * texture.BytesPerPixel + selectedOffset
                        ],
                        _ => 0,
                    };
                    histogram[code]++;
                }
            }
            return histogram;
        }

        private static bool TryGetUnorm8ComponentLayout(
            Format format,
            out int redOffset,
            out int greenOffset,
            out int blueOffset,
            out int alphaOffset
        )
        {
            redOffset = 0;
            greenOffset = -2;
            blueOffset = -2;
            alphaOffset = -1;
            switch (format)
            {
                case Format.R8Unorm:
                    return true;
                case Format.R8G8Unorm:
                    greenOffset = 1;
                    return true;
                case Format.R8G8B8A8Unorm:
                    greenOffset = 1;
                    blueOffset = 2;
                    alphaOffset = 3;
                    return true;
                case Format.B8G8R8A8Unorm:
                    redOffset = 2;
                    greenOffset = 1;
                    blueOffset = 0;
                    alphaOffset = 3;
                    return true;
                default:
                    return false;
            }
        }

        private static string TargetedProbeDirectory()
        {
            string directory = Path.Combine(
                Path.GetTempPath(),
                $"SolMetalFrameProbe-{Environment.ProcessId}"
            );
            Directory.CreateDirectory(directory);
            return directory;
        }

        private static string TargetedProbeDirectory(
            TargetedProbeSelection selection
        )
        {
            string directory = Path.Combine(
                TargetedProbeDirectory(),
                SolMetalTargetedProbeSelector.CaptureDirectoryName(
                    selection.CaptureId,
                    selection.Name
                )
            );
            Directory.CreateDirectory(directory);
            return directory;
        }

        private static string SummarizeProbeBytes(ReadOnlySpan<byte> bytes)
        {
            long nonZeroBytes = 0;
            byte minimum = byte.MaxValue;
            byte maximum = byte.MinValue;
            ulong checksum = 14695981039346656037UL;
            foreach (byte value in bytes)
            {
                if (value != 0)
                {
                    nonZeroBytes++;
                }
                minimum = Math.Min(minimum, value);
                maximum = Math.Max(maximum, value);
                checksum ^= value;
                checksum *= 1099511628211UL;
            }
            if (bytes.IsEmpty)
            {
                minimum = 0;
                maximum = 0;
            }
            return $"{bytes.Length}, nonZero={nonZeroBytes}, " +
                $"range={minimum}-{maximum}, fnv1a=0x{checksum:X16}";
        }

        private static string SummarizeDepth32ProbeBytes(
            ReadOnlySpan<byte> bytes,
            int width,
            int height,
            int bytesPerRow
        )
        {
            if (width <= 0 || height <= 0 || bytesPerRow < width * 4 ||
                bytes.Length < checked(bytesPerRow * height))
            {
                return "invalid-layout";
            }

            long finite = 0;
            long nan = 0;
            long positiveInfinity = 0;
            long negativeInfinity = 0;
            long zero = 0;
            long half = 0;
            long one = 0;
            float minimum = float.PositiveInfinity;
            float maximum = float.NegativeInfinity;
            for (int y = 0; y < height; y++)
            {
                ReadOnlySpan<byte> row = bytes.Slice(
                    checked(y * bytesPerRow),
                    checked(width * 4)
                );
                for (int x = 0; x < width; x++)
                {
                    float value = MemoryMarshal.Read<float>(row[(x * 4)..]);
                    if (float.IsNaN(value))
                    {
                        nan++;
                        continue;
                    }
                    if (float.IsPositiveInfinity(value))
                    {
                        positiveInfinity++;
                        continue;
                    }
                    if (float.IsNegativeInfinity(value))
                    {
                        negativeInfinity++;
                        continue;
                    }
                    finite++;
                    minimum = Math.Min(minimum, value);
                    maximum = Math.Max(maximum, value);
                    if (value == 0f)
                    {
                        zero++;
                    }
                    else if (value == 0.5f)
                    {
                        half++;
                    }
                    else if (value == 1f)
                    {
                        one++;
                    }
                }
            }

            string range = finite == 0
                ? "none"
                : $"{minimum:R}-{maximum:R}";
            return $"pixels={checked(width * height)}, finite={finite}, " +
                $"nan={nan}, +inf={positiveInfinity}, " +
                $"-inf={negativeInfinity}, range={range}, zero={zero}, " +
                $"half={half}, one={one}";
        }

        private SolMetalGalTexture[] RecordProbeSampledTextures(
            SolMetalGalTexture target
        )
        {
            if (!_renderer._frameProbeEnabled || _program is null)
            {
                target.CompleteProbeSampledTextures(0);
                return [];
            }

            int count = 0;
            HashSet<SolMetalGalTexture> seen = [];
            foreach (ProgramResourceBinding resource in
                     _program.ResourceBindings)
            {
                if (resource.Stage is not ShaderStage.Vertex and
                    not ShaderStage.Fragment ||
                    count >= TextureProbeState.MaximumSampledTextures)
                {
                    continue;
                }

                SolMetalGalTexture? texture = null;
                if (resource.Type is ResourceType.TextureAndSampler or
                    ResourceType.Texture or ResourceType.BufferTexture)
                {
                    if (_texturesAndSamplers.TryGetValue(
                            (resource.Stage, resource.Binding),
                            out var pair))
                    {
                        texture = pair.Texture;
                    }
                }
                else if (resource.Type is ResourceType.Image or
                         ResourceType.BufferImage)
                {
                    _images.TryGetValue(
                        (resource.Stage, resource.Binding),
                        out texture
                    );
                }

                if (texture is null || texture.IsBufferTexture)
                {
                    continue;
                }
                if (!seen.Add(texture))
                {
                    continue;
                }
                target.SetProbeSampledTexture(count++, texture);
            }
            target.CompleteProbeSampledTextures(count);
            return target.GetProbeSampledTextures();
        }

        private ProbeBufferBinding[] BuildProbeBufferBindings()
        {
            if (_program is null)
            {
                return [];
            }

            List<ProbeBufferBinding> bindings = [];
            foreach (ProgramResourceBinding resource in
                     _program.ResourceBindings)
            {
                Dictionary<int, BufferRange>? source = resource.Type switch
                {
                    ResourceType.UniformBuffer => _uniformBuffers,
                    ResourceType.StorageBuffer => _storageBuffers,
                    _ => null,
                };
                if (source is null ||
                    !source.TryGetValue(resource.Binding, out BufferRange range))
                {
                    continue;
                }
                bindings.Add(new ProbeBufferBinding(
                    $"{resource.Stage} {resource.Type} " +
                    $"set{resource.DescriptorSet}/binding{resource.Binding}" +
                    $"->metal{resource.MetalBuffer}",
                    range
                ));
            }

            foreach (int bufferIndex in _cachedVertexBufferIndices)
            {
                VertexBufferDescriptor descriptor = _vertexBuffers[bufferIndex];
                bindings.Add(new ProbeBufferBinding(
                    $"vertex-input{bufferIndex}/stride{descriptor.Stride}/" +
                    $"divisor{descriptor.Divisor}",
                    descriptor.Buffer
                ));
            }
            if (_indexBuffer is BufferRange indexRange)
            {
                bindings.Add(new ProbeBufferBinding(
                    $"index/{_indexType}",
                    indexRange
                ));
            }
            return bindings.ToArray();
        }

        private SolMetalNativeBridge.GalStageBindings BuildStageBindings(
            ShaderStage stage,
            SolMetalNativeBridge.GalBufferBinding[] vertexInputs
        )
        {
            if (_program is null)
            {
                throw new InvalidOperationException("SolMetal has no active program.");
            }
            bool dirty = stage switch
            {
                ShaderStage.Vertex => _vertexBindingsDirty,
                ShaderStage.Fragment => _fragmentBindingsDirty,
                ShaderStage.Compute => _computeBindingsDirty,
                _ => throw Unsupported($"resource binding stage {stage}"),
            };
            if (!dirty)
            {
                return stage switch
                {
                    ShaderStage.Vertex => _cachedVertexBindings,
                    ShaderStage.Fragment => _cachedFragmentBindings,
                    ShaderStage.Compute => _cachedComputeBindings,
                    _ => SolMetalNativeBridge.GalStageBindings.Empty,
                };
            }
            _stageBindingRebuildCount++;
            List<SolMetalNativeBridge.GalBufferBinding> buffers =
                [.. vertexInputs];
            List<SolMetalNativeBridge.GalTextureBinding> textures = [];
            List<SolMetalNativeBridge.GalSamplerBinding> samplers = [];
            HashSet<(uint ArgumentBuffer, uint Index)> bufferIndices =
                [.. buffers.Select(item => (item.ArgumentBuffer, item.Index))];
            HashSet<(uint ArgumentBuffer, uint Index)> textureIndices = [];
            HashSet<(uint ArgumentBuffer, uint Index)> samplerIndices = [];
            int dummyTextureBindings = 0;
            int dummyBufferBindings = 0;

            foreach (ProgramResourceBinding resource in
                     _program.ResourceBindings.Where(item => item.Stage == stage))
            {
                switch (resource.Type)
                {
                    case ResourceType.UniformBuffer:
                        if (!_uniformBuffers.TryGetValue(
                                resource.Binding,
                                out BufferRange uniformRange))
                        {
                            dummyBufferBindings++;
                            AddUnique(
                                buffers,
                                bufferIndices,
                                new SolMetalNativeBridge.GalBufferBinding(
                                    resource.MetalBuffer,
                                    _renderer._zeroVertexBuffer,
                                    0,
                                    resource.ArgumentBuffer
                                )
                            );
                            break;
                        }
                        AddUnique(
                            buffers,
                            bufferIndices,
                            _renderer.ResolveBufferBinding(
                                resource.MetalBuffer,
                                uniformRange,
                                resource.ArgumentBuffer
                            )
                        );
                        break;
                    case ResourceType.StorageBuffer:
                        if (!_storageBuffers.TryGetValue(
                                resource.Binding,
                                out BufferRange storageRange))
                        {
                            dummyBufferBindings++;
                            AddUnique(
                                buffers,
                                bufferIndices,
                                new SolMetalNativeBridge.GalBufferBinding(
                                    resource.MetalBuffer,
                                    _renderer._zeroVertexBuffer,
                                    0,
                                    resource.ArgumentBuffer
                                )
                            );
                            break;
                        }
                        AddUnique(
                            buffers,
                            bufferIndices,
                            _renderer.ResolveBufferBinding(
                                resource.MetalBuffer,
                                storageRange,
                                resource.ArgumentBuffer
                            )
                        );
                        break;
                    case ResourceType.TextureAndSampler:
                    case ResourceType.Texture:
                    case ResourceType.Sampler:
                        if (!_texturesAndSamplers.TryGetValue(
                                (stage, resource.Binding),
                                out (SolMetalGalTexture Texture, SolMetalGalSampler? Sampler) pair))
                        {
                            if (resource.Type != ResourceType.Sampler)
                            {
                                dummyTextureBindings++;
                                AddUnique(
                                    textures,
                                    textureIndices,
                                    new SolMetalNativeBridge.GalTextureBinding(
                                        resource.MetalTexture,
                                        _renderer._dummyTexture,
                                        resource.ArgumentBuffer
                                    )
                                );
                            }
                            if (resource.Type != ResourceType.Texture)
                            {
                                AddUnique(
                                    samplers,
                                    samplerIndices,
                                    new SolMetalNativeBridge.GalSamplerBinding(
                                        resource.MetalSampler,
                                        _renderer._dummySampler,
                                        resource.ArgumentBuffer
                                    )
                                );
                            }
                            break;
                        }
                        if (resource.Type != ResourceType.Sampler)
                        {
                            AddUnique(
                                textures,
                                textureIndices,
                                new SolMetalNativeBridge.GalTextureBinding(
                                    resource.MetalTexture,
                                    pair.Texture.Native,
                                    resource.ArgumentBuffer
                                )
                            );
                        }
                        if (resource.Type != ResourceType.Texture)
                        {
                            AddUnique(
                                samplers,
                                samplerIndices,
                                new SolMetalNativeBridge.GalSamplerBinding(
                                    resource.MetalSampler,
                                    pair.Sampler?.Native ??
                                        _renderer._dummySampler,
                                    resource.ArgumentBuffer
                                )
                            );
                        }
                        break;
                    case ResourceType.BufferTexture:
                        if (!_texturesAndSamplers.TryGetValue(
                                (stage, resource.Binding),
                                out (SolMetalGalTexture Texture, SolMetalGalSampler? Sampler) bufferPair))
                        {
                            dummyTextureBindings++;
                            AddUnique(
                                textures,
                                textureIndices,
                                new SolMetalNativeBridge.GalTextureBinding(
                                    resource.MetalTexture,
                                    _renderer._dummyBufferTexture,
                                    resource.ArgumentBuffer
                                )
                            );
                            break;
                        }
                        AddUnique(
                            textures,
                            textureIndices,
                            new SolMetalNativeBridge.GalTextureBinding(
                                resource.MetalTexture,
                                bufferPair.Texture.Native,
                                resource.ArgumentBuffer
                            )
                        );
                        break;
                    case ResourceType.Image:
                    case ResourceType.BufferImage:
                        if (!_images.TryGetValue(
                                (stage, resource.Binding),
                                out SolMetalGalTexture? image))
                        {
                            dummyTextureBindings++;
                            AddUnique(
                                textures,
                                textureIndices,
                                new SolMetalNativeBridge.GalTextureBinding(
                                    resource.MetalTexture,
                                    resource.Type == ResourceType.BufferImage
                                        ? _renderer._dummyBufferTexture
                                        : _renderer._dummyTexture,
                                    resource.ArgumentBuffer
                                )
                            );
                            break;
                        }
                        AddUnique(
                            textures,
                            textureIndices,
                            new SolMetalNativeBridge.GalTextureBinding(
                                resource.MetalTexture,
                                image.Native,
                                resource.ArgumentBuffer
                            )
                        );
                        break;
                    default:
                        throw Unsupported($"resource binding {resource.Type}");
                }
            }

            buffers.Sort(CompareBindings);
            textures.Sort(CompareBindings);
            samplers.Sort(CompareBindings);
            if (stage == ShaderStage.Fragment)
            {
                _lastFragmentDummyTextureBindings = dummyTextureBindings;
                _lastFragmentDummyBufferBindings = dummyBufferBindings;
            }
            else if (stage == ShaderStage.Vertex)
            {
                _lastVertexDummyTextureBindings = dummyTextureBindings;
                _lastVertexDummyBufferBindings = dummyBufferBindings;
            }
            SolMetalNativeBridge.GalStageBindings rebuilt = new(
                buffers.ToArray(),
                textures.ToArray(),
                samplers.ToArray()
            );
            switch (stage)
            {
                case ShaderStage.Vertex:
                    _cachedVertexBindings = rebuilt;
                    _vertexBindingsDirty = false;
                    break;
                case ShaderStage.Fragment:
                    _cachedFragmentBindings = rebuilt;
                    _fragmentBindingsDirty = false;
                    break;
                case ShaderStage.Compute:
                    _cachedComputeBindings = rebuilt;
                    _computeBindingsDirty = false;
                    break;
            }
            return rebuilt;
        }

        private void MarkStageBindingsDirty(ShaderStage stage)
        {
            switch (stage)
            {
                case ShaderStage.Vertex:
                    _vertexBindingsDirty = true;
                    break;
                case ShaderStage.Fragment:
                    _fragmentBindingsDirty = true;
                    break;
                case ShaderStage.Compute:
                    _computeBindingsDirty = true;
                    break;
                default:
                    throw Unsupported($"resource binding stage {stage}");
            }
        }

        private static void AddUnique(
            List<SolMetalNativeBridge.GalBufferBinding> bindings,
            HashSet<(uint ArgumentBuffer, uint Index)> indices,
            SolMetalNativeBridge.GalBufferBinding binding
        )
        {
            if (!indices.Add((binding.ArgumentBuffer, binding.Index)))
            {
                throw new InvalidOperationException(
                    $"SolMetal buffer slot {binding.Index} is bound twice " +
                    $"(argument buffer {binding.ArgumentBuffer})."
                );
            }
            bindings.Add(binding);
        }

        private static void AddUnique(
            List<SolMetalNativeBridge.GalTextureBinding> bindings,
            HashSet<(uint ArgumentBuffer, uint Index)> indices,
            SolMetalNativeBridge.GalTextureBinding binding
        )
        {
            if (!indices.Add((binding.ArgumentBuffer, binding.Index)))
            {
                throw new InvalidOperationException(
                    $"SolMetal texture slot {binding.Index} is bound twice."
                );
            }
            bindings.Add(binding);
        }

        private static void AddUnique(
            List<SolMetalNativeBridge.GalSamplerBinding> bindings,
            HashSet<(uint ArgumentBuffer, uint Index)> indices,
            SolMetalNativeBridge.GalSamplerBinding binding
        )
        {
            if (!indices.Add((binding.ArgumentBuffer, binding.Index)))
            {
                throw new InvalidOperationException(
                    $"SolMetal sampler slot {binding.Index} is bound twice."
                );
            }
            bindings.Add(binding);
        }

        private static int CompareBindings(
            SolMetalNativeBridge.GalBufferBinding left,
            SolMetalNativeBridge.GalBufferBinding right
        ) => CompareBindingIndices(
            left.ArgumentBuffer,
            left.Index,
            right.ArgumentBuffer,
            right.Index
        );

        private static int CompareBindings(
            SolMetalNativeBridge.GalTextureBinding left,
            SolMetalNativeBridge.GalTextureBinding right
        ) => CompareBindingIndices(
            left.ArgumentBuffer,
            left.Index,
            right.ArgumentBuffer,
            right.Index
        );

        private static int CompareBindings(
            SolMetalNativeBridge.GalSamplerBinding left,
            SolMetalNativeBridge.GalSamplerBinding right
        ) => CompareBindingIndices(
            left.ArgumentBuffer,
            left.Index,
            right.ArgumentBuffer,
            right.Index
        );

        private static int CompareBindingIndices(
            uint leftArgumentBuffer,
            uint leftIndex,
            uint rightArgumentBuffer,
            uint rightIndex
        )
        {
            int argumentBufferOrder = leftArgumentBuffer.CompareTo(
                rightArgumentBuffer
            );
            return argumentBufferOrder != 0
                ? argumentBufferOrder
                : leftIndex.CompareTo(rightIndex);
        }

        private static void Fail(string feature) => throw Unsupported(feature);
    }
}
