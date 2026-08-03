#nullable enable

using Ryujinx.Common.Configuration;
using Ryujinx.Common.SystemInterop;
using Ryujinx.Graphics.Vulkan;
using Ryujinx.Input.SDL3;
using Ryujinx.SDL3.Common;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Ryujinx.Headless;

public static unsafe class NativeEmbeddedEntrypoint
{
    private const int MinimumSurfaceDimension = 64;
    private const int MaximumSurfaceDimension = 8192;
    private const long MaximumSurfacePixelCount = 33_554_432;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int DlsmPresentCallback(
        nint context,
        DlsmFrameInfoV2* frame);

    [StructLayout(LayoutKind.Sequential, Pack = 8, Size = 144)]
    private struct DlsmFrameInfoV2
    {
        public const int AbiVersion = 2;
        public const int ExpectedSize = 144;

        public uint Version;
        public uint StructSize;
        public ulong FrameId;
        public ulong Flags;
        public nint MetalCommandQueue;
        public nint ColorTexture;
        public nint DepthTexture;
        public nint MotionTexture;
        public uint ColorWidth;
        public uint ColorHeight;
        public uint DepthWidth;
        public uint DepthHeight;
        public uint MotionWidth;
        public uint MotionHeight;
        public uint ColorFormat;
        public uint DepthFormat;
        public uint MotionFormat;
        public uint Reserved0;
        public float MotionVectorScaleX;
        public float MotionVectorScaleY;
        public float JitterOffsetX;
        public float JitterOffsetY;
        public float NearPlane;
        public float FarPlane;
        public float FieldOfViewDegrees;
        public float AspectRatio;
        public float DeltaTimeSeconds;
        public uint Reserved1;
        public ulong PresentationTimestampNanoseconds;

        public DlsmFrameInfoV2(in MetalFxFrame frame)
        {
            Version = AbiVersion;
            StructSize = ExpectedSize;
            FrameId = frame.FrameId;
            Flags = (ulong)frame.Flags;
            MetalCommandQueue = frame.MetalCommandQueue;
            ColorTexture = frame.ColorTexture;
            DepthTexture = frame.DepthTexture;
            MotionTexture = frame.MotionTexture;
            ColorWidth = (uint)Math.Max(0, frame.ColorWidth);
            ColorHeight = (uint)Math.Max(0, frame.ColorHeight);
            DepthWidth = (uint)Math.Max(0, frame.DepthWidth);
            DepthHeight = (uint)Math.Max(0, frame.DepthHeight);
            MotionWidth = (uint)Math.Max(0, frame.MotionWidth);
            MotionHeight = (uint)Math.Max(0, frame.MotionHeight);
            ColorFormat = (uint)frame.ColorFormat;
            DepthFormat = (uint)frame.DepthFormat;
            MotionFormat = (uint)frame.MotionFormat;
            Reserved0 = 0;
            MotionVectorScaleX = frame.MotionVectorScaleX;
            MotionVectorScaleY = frame.MotionVectorScaleY;
            JitterOffsetX = frame.JitterOffsetX;
            JitterOffsetY = frame.JitterOffsetY;
            NearPlane = frame.NearPlane;
            FarPlane = frame.FarPlane;
            FieldOfViewDegrees = frame.FieldOfViewDegrees;
            AspectRatio = frame.AspectRatio;
            DeltaTimeSeconds = frame.DeltaTimeSeconds;
            Reserved1 = 0;
            PresentationTimestampNanoseconds = frame.PresentationTimestampNanoseconds;
        }
    }

    private sealed class MainThreadWork(Action action)
    {
        public Action Action { get; } = action;
        public ManualResetEventSlim Completed { get; } = new(false);
        public Exception? Exception { get; set; }
    }

    private static readonly object SessionLock = new();
    private static readonly ConcurrentQueue<MainThreadWork> MainThreadWorkQueue = new();
    private static readonly ConcurrentQueue<string> EventQueue = new();
    private static Thread? _engineThread;
    private static int _mainThreadId;
    private static nint _cocoaView;
    private static nint _metalLayer;
    private static int _surfaceWidth = 1280;
    private static int _surfaceHeight = 720;
    private static volatile bool _running;
    private static volatile bool _starting;
    private static volatile bool _windowReady;
    private static volatile bool _stopRequested;
    private static int _stopDispatchPending;
    private static int _acceptDlsmCallbacks;
    private static int _dlsmCallbacksInFlight;
    private static int _firstFramePublished;
    private static bool _sdlHostReference;
    private static DlsmPresentCallback? _dlsmPresentCallback;
    private static nint _dlsmContext;

    internal static bool IsEmbedded => _cocoaView != 0;
    internal static nint CocoaView => _cocoaView;
    internal static nint MetalLayer => _metalLayer;
    internal static int SurfaceWidth => Math.Max(1, Volatile.Read(ref _surfaceWidth));
    internal static int SurfaceHeight => Math.Max(1, Volatile.Read(ref _surfaceHeight));

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Start(
        nint cocoaView,
        nint metalLayer,
        nint dlsmCallback,
        nint dlsmContext,
        byte* gamePathUtf8,
        byte* dataDirectoryUtf8,
        int width,
        int height)
    {
        if (sizeof(DlsmFrameInfoV2) != DlsmFrameInfoV2.ExpectedSize)
        {
            return -5;
        }

        if (cocoaView == 0 || metalLayer == 0 || gamePathUtf8 == null || dataDirectoryUtf8 == null)
        {
            return -1;
        }

        string? gamePath = Marshal.PtrToStringUTF8((nint)gamePathUtf8);
        string? dataDirectory = Marshal.PtrToStringUTF8((nint)dataDirectoryUtf8);

        if (string.IsNullOrWhiteSpace(gamePath) || string.IsNullOrWhiteSpace(dataDirectory))
        {
            return -2;
        }

        if (!TryNormalizeSurfaceSize(width, height, out int normalizedWidth, out int normalizedHeight))
        {
            return -6;
        }

        lock (SessionLock)
        {
            if (_running || _starting || _engineThread?.IsAlive == true)
            {
                return -3;
            }

            while (EventQueue.TryDequeue(out _))
            {
            }

            _mainThreadId = Environment.CurrentManagedThreadId;
            _cocoaView = cocoaView;
            _metalLayer = metalLayer;
            _surfaceWidth = normalizedWidth;
            _surfaceHeight = normalizedHeight;
            _dlsmContext = dlsmContext;
            _dlsmPresentCallback = dlsmCallback != 0 && dlsmContext != 0
                ? Marshal.GetDelegateForFunctionPointer<DlsmPresentCallback>(dlsmCallback)
                : null;
            _dlsmCallbacksInFlight = 0;
            _firstFramePublished = 0;
            Volatile.Write(
                ref _acceptDlsmCallbacks,
                _dlsmPresentCallback is null ? 0 : 1);
            MetalFxPresentation.Configure(
                PresentDlsmFrame,
                _dlsmPresentCallback is null ? null : PublishDlsmAttachmentLabels,
                _dlsmPresentCallback is null ? null : PublishDlsmProviderReadiness);
            if (_dlsmPresentCallback is not null)
            {
                Console.WriteLine(
                    $"[DLSM] Native frame ABI v{DlsmFrameInfoV2.AbiVersion} active; " +
                    "the generic presenter currently exports final color only.");
            }
            _starting = true;
            _windowReady = false;
            _stopRequested = false;
            _stopDispatchPending = 0;

            try
            {
                AppDataManager.Initialize(dataDirectory);
                SDL3Driver.MainThreadDispatcher = InvokeOnMainThread;
                SDL3Driver.UseExternalEventPump = true;

                if (!_sdlHostReference)
                {
                    SDL3Driver.Instance.Initialize();
                    _sdlHostReference = true;
                }

                NativeSessionProtocol.Start(readCommands: false, EventQueue.Enqueue);
                NativeSessionProtocol.MarkLaunching();
                NativeSessionProtocol.PublishLaunchProgress(
                    "surface-ready",
                    "Native Metal surface ready");

                _engineThread = new Thread(() => RunEngine(gamePath, dataDirectory))
                {
                    IsBackground = true,
                    Name = "Sol.Engine",
                };
                _running = true;
                _engineThread.Start();
                return 0;
            }
            catch (Exception exception)
            {
                MetalFxPresentation.Clear();
                Volatile.Write(ref _acceptDlsmCallbacks, 0);
                _dlsmPresentCallback = null;
                _dlsmContext = 0;
                _starting = false;
                _running = false;
                NativeSessionProtocol.PublishError($"Could not start the embedded engine: {exception}");
                return -4;
            }
        }
    }

    private static bool PresentDlsmFrame(in MetalFxFrame frame)
    {
        bool handled = false;
        if (Volatile.Read(ref _acceptDlsmCallbacks) != 0)
        {
            Interlocked.Increment(ref _dlsmCallbacksInFlight);
            try
            {
                if (Volatile.Read(ref _acceptDlsmCallbacks) != 0)
                {
                    DlsmPresentCallback? callback = _dlsmPresentCallback;
                    nint context = _dlsmContext;
                    if (callback is not null && context != 0)
                    {
                        DlsmFrameInfoV2 nativeFrame = new(in frame);
                        handled = callback(context, &nativeFrame) != 0;
                    }
                }
            }
            finally
            {
                Interlocked.Decrement(ref _dlsmCallbacksInFlight);
            }
        }

        if ((_dlsmPresentCallback is null || handled) &&
            Interlocked.CompareExchange(ref _firstFramePublished, 1, 0) == 0)
        {
            NativeSessionProtocol.Publish(new NativeSessionEvent
            {
                Event = "launch.first-frame",
                Message = "First Metal frame presented",
                Width = frame.ColorWidth,
                Height = frame.ColorHeight,
            });
        }

        return handled;
    }

    private static void PublishDlsmAttachmentLabels(string message)
    {
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "dlsm.attachment-labels",
            Message = message,
        });
    }

    private static void PublishDlsmProviderReadiness(
        in MetalFxProviderReadiness readiness)
    {
        string stage = readiness.CanonicalExportReady
            ? "export-ready"
            : readiness.RawExportReady
                ? "raw-export-ready"
            : readiness.MotionReady
                ? "attachment-candidates-ready"
                : readiness.DepthReady
                    ? "depth-candidate-ready"
                    : readiness.SceneReady
                        ? "scene-candidate-ready"
                        : "discovering";

        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "dlsm.provider-readiness",
            Message =
                $"DLSM provider {stage}: scene={readiness.SceneLabel}, " +
                $"depth={readiness.DepthLabel} ({readiness.DepthFormat}), " +
                $"motion={readiness.MotionLabel} ({readiness.MotionFormat}). " +
                (readiness.RawExportReady
                    ? "Raw Vulkan-to-Metal export is ready; native canonical motion/depth semantics remain locked."
                    : "Raw Vulkan-to-Metal attachment export is still being validated."),
            ProviderStage = stage,
            ProviderGeneration = readiness.Generation,
            SceneReady = readiness.SceneReady,
            DepthReady = readiness.DepthReady,
            MotionReady = readiness.MotionReady,
            RawExportReady = readiness.RawExportReady,
            ExportReady = readiness.CanonicalExportReady,
            SceneCut = readiness.SceneCut,
            SceneLabel = readiness.SceneLabel,
            DepthLabel = readiness.DepthLabel,
            MotionLabel = readiness.MotionLabel,
            DepthFormat = readiness.DepthFormat,
            MotionFormat = readiness.MotionFormat,
            Width = readiness.Width,
            Height = readiness.Height,
        });
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Pump()
    {
        // Swift owns this export and only calls it from AppKit's main thread.
        // Refresh the managed identity on every reverse-P/Invoke rather than
        // assuming CoreCLR preserves Environment.CurrentManagedThreadId across
        // separate unmanaged entry calls.
        _mainThreadId = Environment.CurrentManagedThreadId;

        int processed = 0;

        while (MainThreadWorkQueue.TryDequeue(out MainThreadWork? work))
        {
            try
            {
                work.Action();
            }
            catch (Exception exception)
            {
                work.Exception = exception;
                Console.Error.WriteLine($"[SolEngine] Main-thread request failed: {exception}");
            }
            finally
            {
                work.Completed.Set();
            }

            processed++;
        }

        if (_sdlHostReference && _windowReady)
        {
            SDL3Driver.Instance.PumpEvents();
        }

        WindowBase.ProcessMainThreadQueue();
        return processed;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int ReadEvent(byte* buffer, int capacity)
    {
        if (buffer == null || capacity <= 0 || !EventQueue.TryPeek(out string? json))
        {
            return 0;
        }

        int byteCount = Encoding.UTF8.GetByteCount(json);

        if (byteCount > capacity)
        {
            return -byteCount;
        }

        int written = Encoding.UTF8.GetBytes(json, new Span<byte>(buffer, capacity));
        EventQueue.TryDequeue(out _);
        return written;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int SendCommand(byte* jsonUtf8)
    {
        if (jsonUtf8 == null)
        {
            return -1;
        }

        string? json = Marshal.PtrToStringUTF8((nint)jsonUtf8);
        return !string.IsNullOrWhiteSpace(json) && NativeSessionProtocol.HandleCommandJson(json) ? 0 : -2;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Resize(int width, int height)
    {
        if (!TryNormalizeSurfaceSize(width, height, out int normalizedWidth, out int normalizedHeight))
        {
            return -2;
        }

        _surfaceWidth = normalizedWidth;
        _surfaceHeight = normalizedHeight;

        // Layout can change before SDL has created the embedded window. Keep
        // the latest dimensions for InitializeWindow and only touch the live
        // renderer once its window is ready.
        if (_windowReady)
        {
            HeadlessRyujinx.ResizeNativeSurface(_surfaceWidth, _surfaceHeight);
        }

        return 0;
    }

    private static bool TryNormalizeSurfaceSize(
        int width,
        int height,
        out int normalizedWidth,
        out int normalizedHeight)
    {
        normalizedWidth = 0;
        normalizedHeight = 0;

        if (width < MinimumSurfaceDimension || height < MinimumSurfaceDimension)
        {
            return false;
        }

        double aspectRatio = width / (double)height;
        if (!double.IsFinite(aspectRatio) || aspectRatio is < 0.2 or > 5)
        {
            return false;
        }

        double scale = Math.Min(
            1,
            MaximumSurfaceDimension / (double)Math.Max(width, height));
        long pixelCount = (long)width * height;
        if (pixelCount > MaximumSurfacePixelCount)
        {
            scale = Math.Min(
                scale,
                Math.Sqrt(MaximumSurfacePixelCount / (double)pixelCount));
        }

        normalizedWidth = Math.Max(
            MinimumSurfaceDimension,
            (int)Math.Round(width * scale));
        normalizedHeight = Math.Max(
            MinimumSurfaceDimension,
            (int)Math.Round(height * scale));
        return true;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int KeyEvent(int scancode, int pressed)
    {
        return SDL3Keyboard.SetExternalKeyState(scancode, pressed != 0) ? 0 : -1;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int ResetInput()
    {
        SDL3Keyboard.ClearExternalKeyState();
        return 0;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int SetHostFullscreen(int fullscreen)
    {
        HeadlessRyujinx.SetEmbeddedFullscreenState(fullscreen != 0);
        return 0;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int IsRunning()
    {
        return _running ? 1 : 0;
    }

    [UnmanagedCallersOnly(CallConvs = [typeof(CallConvCdecl)])]
    public static int Shutdown()
    {
        if (_running)
        {
            RequestStop();
        }

        return 0;
    }

    internal static void RequestStop()
    {
        _stopRequested = true;
        Volatile.Write(ref _acceptDlsmCallbacks, 0);
        MetalFxPresentation.Clear();
        if (_windowReady)
        {
            DispatchStopRequest();
        }
    }

    private static void DispatchStopRequest()
    {
        if (Interlocked.CompareExchange(ref _stopDispatchPending, 1, 0) != 0)
        {
            return;
        }

        Thread stopThread = new(() =>
        {
            try
            {
                while (Volatile.Read(ref _dlsmCallbacksInFlight) != 0)
                {
                    Thread.Sleep(1);
                }

                _dlsmPresentCallback = null;
                _dlsmContext = 0;

                // WindowBase.Exit waits for renderer and guest threads. Keep
                // that wait off AppKit's main thread so its teardown work can
                // continue to be pumped by the native host.
                HeadlessRyujinx.StopNativeSession();
            }
            catch (Exception exception)
            {
                NativeSessionProtocol.PublishError(
                    $"Could not stop the embedded engine: {exception}");
            }
            finally
            {
                Volatile.Write(ref _stopDispatchPending, 0);
            }
        })
        {
            IsBackground = true,
            Name = "Sol.Engine.Stop",
        };
        stopThread.Start();
    }

    internal static void InvokeOnMainThread(Action action)
    {
        if (_mainThreadId == 0 || Environment.CurrentManagedThreadId == _mainThreadId)
        {
            action();
            return;
        }

        MainThreadWork work = new(action);
        MainThreadWorkQueue.Enqueue(work);

        if (!work.Completed.Wait(TimeSpan.FromSeconds(30)))
        {
            throw new TimeoutException("The AppKit main thread did not service an embedded Sol Engine request.");
        }

        if (work.Exception is not null)
        {
            throw new InvalidOperationException("An embedded Sol Engine main-thread operation failed.", work.Exception);
        }
    }

    internal static T InvokeOnMainThread<T>(Func<T> action)
    {
        T? result = default;
        Action work = () =>
        {
            result = action();
        };
        InvokeOnMainThread(work);
        return result!;
    }

    internal static void SetWindowReady(bool ready)
    {
        _windowReady = ready;
        if (ready && _stopRequested)
        {
            DispatchStopRequest();
        }
    }

    private static void RunEngine(string gamePath, string dataDirectory)
    {
        int exitCode = 0;
        string? failure = null;

        try
        {
            _starting = false;
            if (_stopRequested)
            {
                return;
            }
            List<string> arguments =
            [
                "--use-main-config",
                "--use-hypervisor",
                "false",
                "--root-data-dir",
                dataDirectory,
            ];
            arguments.Add(gamePath);
            NativeSessionProtocol.PublishLaunchProgress(
                "starting-core",
                "Starting the emulation core");
            HeadlessRyujinx.Entrypoint([.. arguments]);
        }
        catch (Exception exception)
        {
            exitCode = 1;
            failure = exception.ToString();
            NativeSessionProtocol.PublishError(failure);
        }
        finally
        {
            Volatile.Write(ref _acceptDlsmCallbacks, 0);
            MetalFxPresentation.Clear();
            _dlsmPresentCallback = null;
            _dlsmContext = 0;
            SDL3Keyboard.ClearExternalKeyState();
            DisplaySleep.Restore();
            _running = false;
            _starting = false;
            _windowReady = false;
            _stopDispatchPending = 0;

            NativeSessionProtocol.CompletePlaytimeTracking();
            NativeSessionProtocol.Publish(new NativeSessionEvent
            {
                Event = "embedded.terminated",
                ExitCode = exitCode,
                Message = failure,
            });
            NativeSessionProtocol.Stop();

            lock (SessionLock)
            {
                _engineThread = null;
                _cocoaView = 0;
                _metalLayer = 0;
            }
        }
    }
}
