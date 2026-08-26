using Humanizer;
using LibHac.Ns;
using Ryujinx.Ava;
using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Configuration.Hid;
using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading;
using Ryujinx.Graphics.OpenGL;
using Ryujinx.HLE.HOS.Applets;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using Ryujinx.HLE.HOS.Services.Am.AppletOE.ApplicationProxyService.ApplicationProxy.Types;
using Ryujinx.HLE.Loaders.Processes;
using Ryujinx.HLE.UI;
using Ryujinx.Input;
using Ryujinx.Input.HLE;
using Ryujinx.Input.SDL3;
using Ryujinx.SDL3.Common;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using SDL;
using static SDL.SDL3;
using AntiAliasing = Ryujinx.Common.Configuration.AntiAliasing;
using ScalingFilter = Ryujinx.Common.Configuration.ScalingFilter;
using Switch = Ryujinx.HLE.Switch;
using UserProfile = Ryujinx.HLE.HOS.Services.Account.Acc.UserProfile;
using LibHac.Util;

namespace Ryujinx.Headless
{
    abstract unsafe partial class WindowBase : IHostUIHandler, IDisposable
    {
        protected const int DefaultWidth = 1280;
        protected const int DefaultHeight = 720;
        private const int TargetFps = 60;
        private SDL_WindowFlags DefaultFlags = SDL_WindowFlags.SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WindowFlags.SDL_WINDOW_RESIZABLE | SDL_WindowFlags.SDL_WINDOW_INPUT_FOCUS;
        private SDL_WindowFlags FullscreenFlag = 0;

        private static readonly ConcurrentQueue<Action> _mainThreadActions = new();

        public static void QueueMainThreadAction(Action action)
        {
            _mainThreadActions.Enqueue(action);
        }

        public NpadManager NpadManager { get; }
        public TouchScreenManager TouchScreenManager { get; }
        public Switch Device { get; private set; }
        public IRenderer Renderer { get; private set; }

        protected SDL_Window* WindowHandle { get; set; }

        public IHostUITheme HostUITheme { get; }
        public int Width { get; private set; }
        public int Height { get; private set; }
        public SDL_DisplayID DisplayId { get; set; }
        public bool IsFullscreen { get; set; }
        public bool IsExclusiveFullscreen { get; set; }
        public int ExclusiveFullscreenWidth { get; set; }
        public int ExclusiveFullscreenHeight { get; set; }
        public AntiAliasing AntiAliasing { get; set; }
        public ScalingFilter ScalingFilter { get; set; }
        public int ScalingFilterLevel { get; set; }

        protected SDL3MouseDriver MouseDriver;
        private readonly InputManager _inputManager;
        private readonly IKeyboard _keyboardInterface;
        protected readonly GraphicsDebugLevel GlLogLevel;
        private readonly Stopwatch _chrono;
        private readonly long _ticksPerFrame;
        private readonly CancellationTokenSource _gpuCancellationTokenSource;
        private readonly ManualResetEvent _exitEvent;
        private readonly ManualResetEvent _gpuDoneEvent;
        private Thread _renderLoopThread;

        private long _ticks;
        private bool _isActive;
        private bool _isStopped;
        private SDL_WindowID _windowId;

        private string _gpuDriverName;

        private readonly AspectRatio _aspectRatio;
        private readonly bool _enableMouse;
        private readonly bool _ignoreControllerApplet;

        public WindowBase(
            InputManager inputManager,
            GraphicsDebugLevel glLogLevel,
            AspectRatio aspectRatio,
            bool enableMouse,
            HideCursorMode hideCursorMode,
            bool ignoreControllerApplet)
        {
            MouseDriver = new SDL3MouseDriver(hideCursorMode);
            _inputManager = inputManager;
            _inputManager.SetMouseDriver(MouseDriver);
            NpadManager = _inputManager.CreateNpadManager();
            TouchScreenManager = _inputManager.CreateTouchScreenManager();
            _keyboardInterface = (IKeyboard)_inputManager.KeyboardDriver.GetGamepad("0");
            GlLogLevel = glLogLevel;
            _chrono = new Stopwatch();
            _ticksPerFrame = Stopwatch.Frequency / TargetFps;
            _gpuCancellationTokenSource = new CancellationTokenSource();
            _exitEvent = new ManualResetEvent(false);
            _gpuDoneEvent = new ManualResetEvent(false);
            _aspectRatio = aspectRatio;
            _enableMouse = enableMouse;
            _ignoreControllerApplet = ignoreControllerApplet;
            HostUITheme = new HeadlessHostUiTheme();

            SDL3Driver.Instance.Initialize();
        }

        public void Initialize(Switch device, List<InputConfig> inputConfigs, bool enableKeyboard, bool enableMouse)
        {
            Device = device;

            IRenderer renderer = Device.Gpu.Renderer;

            if (renderer is ThreadedRenderer tr)
            {
                renderer = tr.BaseRenderer;
            }

            Renderer = renderer;

            NpadManager.Initialize(device, inputConfigs, enableKeyboard, enableMouse);
            TouchScreenManager.Initialize(device);
        }

        private void SetWindowIcon()
        {
            Stream iconStream = EmbeddedResources.GetStream("Ryujinx/Assets/UIImages/Logo_Ryujinx.png");
            if (iconStream == null)
            {
                // Sol intentionally does not ship the upstream UI artwork.
                // A standalone developer window can use the system default
                // icon; missing optional branding must not abort emulation.
                Logger.Warning?.Print(LogClass.Application, "Standalone window icon is unavailable; using the system default.");
                return;
            }

            byte[] iconBytes = new byte[iconStream.Length];

            if (iconStream.Read(iconBytes, 0, iconBytes.Length) != iconBytes.Length)
            {
                Logger.Error?.Print(LogClass.Application, "Failed to read icon to byte array.");
                iconStream.Close();

                return;
            }

            iconStream.Close();

            unsafe
            {
                fixed (byte* iconPtr = iconBytes)
                {
                    SDL_IOStream* rwOpsStruct = SDL_IOFromConstMem((nint)iconPtr, (nuint)iconBytes.Length);
                    SDL_Surface* iconHandle = SDL_LoadBMP_IO(rwOpsStruct, true);

                    SDL_SetWindowIcon(WindowHandle, iconHandle);
                    SDL_DestroySurface(iconHandle);
                }
            }
        }

        private void InitializeWindow()
        {
            if (NativeEmbeddedEntrypoint.IsEmbedded)
            {
                NativeEmbeddedEntrypoint.InvokeOnMainThread(InitializeWindowCore);
            }
            else
            {
                InitializeWindowCore();
            }
        }

        private void InitializeWindowCore()
        {
            ProcessResult activeProcess = Device.Processes.ActiveApplication;
            ApplicationControlProperty nacp = activeProcess.ApplicationControlProperties;
            int desiredLanguage = (int)Device.System.State.DesiredTitleLanguage;

            string titleNameSection = string.IsNullOrWhiteSpace(nacp.Title[desiredLanguage].NameString.ToString()) ? string.Empty : $" - {nacp.Title[desiredLanguage].NameString.ToString()}";
            string titleVersionSection = string.IsNullOrWhiteSpace(nacp.DisplayVersionString.ToString()) ? string.Empty : $" v{nacp.DisplayVersionString.ToString()}";
            string titleIdSection = string.IsNullOrWhiteSpace(activeProcess.ProgramIdText) ? string.Empty : $" ({activeProcess.ProgramIdText.ToUpper()})";
            string titleArchSection = activeProcess.Is64Bit ? " (64-bit)" : " (32-bit)";

            if (NativeEmbeddedEntrypoint.IsEmbedded)
            {
                Width = NativeEmbeddedEntrypoint.SurfaceWidth;
                Height = NativeEmbeddedEntrypoint.SurfaceHeight;
                DefaultFlags = SDL_WindowFlags.SDL_WINDOW_HIGH_PIXEL_DENSITY;
                FullscreenFlag = 0;
            }
            else
            {
                Width = DefaultWidth;
                Height = DefaultHeight;

                if (IsExclusiveFullscreen)
                {
                    Width = ExclusiveFullscreenWidth;
                    Height = ExclusiveFullscreenHeight;

                    DefaultFlags = SDL_WindowFlags.SDL_WINDOW_HIGH_PIXEL_DENSITY;
                    FullscreenFlag = SDL_WindowFlags.SDL_WINDOW_FULLSCREEN;
                }
                else if (IsFullscreen)
                {
                    DefaultFlags = SDL_WindowFlags.SDL_WINDOW_HIGH_PIXEL_DENSITY;
                    FullscreenFlag = SDL_WindowFlags.SDL_WINDOW_BORDERLESS;
                }
            }

            SDL_PropertiesID props = SDL_CreateProperties();
            string windowTitle = NativeEmbeddedEntrypoint.IsEmbedded
                ? $"{(string.IsNullOrWhiteSpace(titleNameSection) ? "Game" : titleNameSection[3..])} — Sol"
                : $"Sol Engine {Program.Version}{titleNameSection}{titleVersionSection}{titleIdSection}{titleArchSection}";
            SDL_SetStringProperty(props, SDL_PROP_WINDOW_CREATE_TITLE_STRING, windowTitle);

            if (NativeEmbeddedEntrypoint.IsEmbedded)
            {
                ReadOnlySpan<byte> cocoaViewProperty = SDL_PROP_WINDOW_CREATE_COCOA_VIEW_POINTER;

                fixed (byte* propertyName = cocoaViewProperty)
                {
                    SDL_SetPointerProperty(props, propertyName, NativeEmbeddedEntrypoint.CocoaView);
                }
            }
            else
            {
                SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_X_NUMBER, SDL_WINDOWPOS_CENTERED_DISPLAY(DisplayId));
                SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_Y_NUMBER, SDL_WINDOWPOS_CENTERED_DISPLAY(DisplayId));
            }

            SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, Width);
            SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, Height);
            SDL_SetNumberProperty(props, SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER, (long)(DefaultFlags | FullscreenFlag | WindowFlags));

            WindowHandle = SDL_CreateWindowWithProperties(props);
            SDL_DestroyProperties(props);

            if (WindowHandle == null)
            {
                string errorMessage = $"SDL_CreateWindow failed with error \"{SDL_GetError()}\"";

                Logger.Error?.Print(LogClass.Application, errorMessage);

                throw new Exception(errorMessage);
            }

            if (!NativeEmbeddedEntrypoint.IsEmbedded)
            {
                SetWindowIcon();
            }

            _windowId = SDL_GetWindowID(WindowHandle);
            SDL3Driver.Instance.RegisterWindow(_windowId, HandleWindowEvent);
            NativeEmbeddedEntrypoint.SetWindowReady(true);
        }

        private void HandleWindowEvent(SDL_Event evnt)
        {
            if ((uint)evnt.Type >= (uint)SDL_EventType.SDL_EVENT_WINDOW_FIRST && (uint)evnt.Type <= (uint)SDL_EventType.SDL_EVENT_WINDOW_LAST)
            {
                switch (evnt.Type)
                {
                    case SDL_EventType.SDL_EVENT_WINDOW_RESIZED:
                        // The containing AppKit view owns embedded-surface
                        // geometry. SDL can briefly report 0x0 while SwiftUI
                        // transitions the representable into place, which
                        // would make the Vulkan guest create invalid
                        // zero-extent images. ResizeEmbeddedSurface forwards
                        // the stable backing-pixel size explicitly instead.
                        if (NativeEmbeddedEntrypoint.IsEmbedded)
                        {
                            break;
                        }

                        // Unlike on Windows, this event fires on macOS when triggering fullscreen mode.
                        // And promptly crashes the process because `Renderer?.window.SetSize` is undefined.
                        // As we don't need this to fire in either case we can test for fullscreen.
                        if (!IsFullscreen && !IsExclusiveFullscreen)
                        {
                            Width = evnt.window.data1;
                            Height = evnt.window.data2;
                            Renderer?.Window.SetSize(Width, Height);
                            MouseDriver.SetClientSize(Width, Height);
                        }

                        break;

                    case SDL_EventType.SDL_EVENT_WINDOW_CLOSE_REQUESTED:
                        Exit();
                        break;
                }
            }
            else
            {
                MouseDriver.Update(evnt);
            }
        }

        protected abstract void InitializeWindowRenderer();

        protected abstract void InitializeRenderer();

        protected abstract void FinalizeWindowRenderer();

        protected abstract void SwapBuffers();

        public abstract SDL_WindowFlags WindowFlags { get; }

        private string GetGpuDriverName()
        {
            return Renderer.GetHardwareInfo().GpuDriver;
        }

        private void SetAntiAliasing()
        {
            Renderer?.Window.SetAntiAliasing(AntiAliasing);
        }

        private void SetScalingFilter()
        {
            Renderer?.Window.SetScalingFilter(ScalingFilter);
            Renderer?.Window.SetScalingFilterLevel(ScalingFilterLevel);
        }

        public void Render()
        {
            InitializeWindowRenderer();

            Device.Gpu.Renderer.Initialize(GlLogLevel);

            InitializeRenderer();

            SetAntiAliasing();

            SetScalingFilter();

            _gpuDriverName = GetGpuDriverName();

            NativeBenchmarkRecorder.Begin(_gpuDriverName);

            Device.Gpu.Renderer.RunLoop(() =>
            {
                Device.Gpu.SetGpuThread();
                Device.Gpu.InitializeShaderCache(_gpuCancellationTokenSource.Token);

                while (_isActive)
                {
                    if (_isStopped)
                    {
                        break;
                    }

                    _ticks += _chrono.ElapsedTicks;

                    _chrono.Restart();

                    if (Device.WaitFifo())
                    {
                        Device.Statistics.RecordFifoStart();
                        Device.ProcessFrame();
                        Device.Statistics.RecordFifoEnd();
                    }

                    while (Device.ConsumeFrameAvailable())
                    {
                        Device.PresentFrame(SwapBuffers);
                        NativeBenchmarkRecorder.RecordPresentation(
                            Device.Statistics.GetGameFrameRate(),
                            Device.Statistics.GetFifoPercent());
                    }

                    if (_ticks >= _ticksPerFrame)
                    {
                        _ticks = Math.Min(_ticks - _ticksPerFrame, _ticksPerFrame);
                    }
                }

                // Make sure all commands in the run loop are fully executed before leaving the loop.
                if (Device.Gpu.Renderer is ThreadedRenderer threaded)
                {
                    threaded.FlushThreadedCommands();
                }

                _gpuDoneEvent.Set();
            });

            NativeBenchmarkRecorder.Complete();
            FinalizeWindowRenderer();
        }

        public void Exit()
        {
            TouchScreenManager?.Dispose();
            NpadManager?.Dispose();

            if (_isStopped)
            {
                return;
            }

            _gpuCancellationTokenSource.Cancel();

            _isStopped = true;
            _isActive = false;

            _exitEvent.WaitOne();
            _exitEvent.Dispose();
        }

        public static void ProcessMainThreadQueue()
        {
            while (_mainThreadActions.TryDequeue(out Action action))
            {
                action();
            }
        }

        public void MainLoop()
        {
            while (_isActive)
            {
                UpdateFrame();

                if (NativeEmbeddedEntrypoint.IsEmbedded)
                {
                    // The native AppKit host owns SDL event polling. Keeping a
                    // second synchronous pump here can starve Cocoa window
                    // creation behind the SDL event worker.
                }
                else
                {
                    SDL_PumpEvents();
                    ProcessMainThreadQueue();
                }

                // Polling becomes expensive if it's not slept
                Thread.Sleep(1);
            }

            _exitEvent.Set();
        }

        private void NvidiaStutterWorkaround()
        {
            while (_isActive)
            {
                // When NVIDIA Threaded Optimization is on, the driver will snapshot all threads in the system whenever the application creates any new ones.
                // The ThreadPool has something called a "GateThread" which terminates itself after some inactivity.
                // However, it immediately starts up again, since the rules regarding when to terminate and when to start differ.
                // This creates a new thread every second or so.
                // The main problem with this is that the thread snapshot can take 70ms, is on the OpenGL thread and will delay rendering any graphics.
                // This is a little over budget on a frame time of 16ms, so creates a large stutter.
                // The solution is to keep the ThreadPool active so that it never has a reason to terminate the GateThread.

                // TODO: This should be removed when the issue with the GateThread is resolved.

                ThreadPool.QueueUserWorkItem(state => { });
                Thread.Sleep(300);
            }
        }

        private bool UpdateFrame()
        {
            if (!_isActive)
            {
                return true;
            }

            if (_isStopped)
            {
                return false;
            }

            NpadManager.Update();

            // Touchscreen
            bool hasTouch = false;

            // Get screen touch position
            if (!_enableMouse)
            {
                hasTouch = TouchScreenManager.Update(true, (_inputManager.MouseDriver as SDL3MouseDriver).IsButtonPressed(MouseButton.Button1), _aspectRatio.ToFloat());
            }

            if (!hasTouch)
            {
                TouchScreenManager.Update(false);
            }

            Device.Hid.DebugPad.Update();

            // TODO: Replace this with MouseDriver.CheckIdle() when mouse motion events are received on every supported platform.
            MouseDriver.UpdatePosition();

            return true;
        }

        public void Execute()
        {
            _chrono.Restart();
            _isActive = true;

            InitializeWindow();

            _renderLoopThread = new Thread(Render)
            {
                Name = "GUI.RenderLoop",
            };
            _renderLoopThread.Start();

            Thread nvidiaStutterWorkaround = null;
            if (Renderer is OpenGLRenderer)
            {
                nvidiaStutterWorkaround = new Thread(NvidiaStutterWorkaround)
                {
                    Name = "GUI.NvidiaStutterWorkaround",
                };
                nvidiaStutterWorkaround.Start();
            }

            MainLoop();

            // The render loop stays alive until the renderer is disposed so it
            // can finish backend cleanup. Waiting for it here would deadlock:
            // ExecutionEntrypoint disposes the emulation context only after
            // Execute returns. Wait for submitted GPU work here, then join the
            // render loop after the context has been disposed.
            _gpuDoneEvent.WaitOne();
            _gpuDoneEvent.Dispose();
            nvidiaStutterWorkaround?.Join();

            Exit();
        }

        public void WaitForRendererShutdown()
        {
            _renderLoopThread?.Join();
            _renderLoopThread = null;
        }

        public void ShutdownEmbeddedRenderer()
        {
            if (!NativeEmbeddedEntrypoint.IsEmbedded)
            {
                throw new InvalidOperationException(
                    "External renderer shutdown is reserved for the embedded host.");
            }

            // ThreadedRenderer.Dispose stops and joins its backend loop before
            // destroying the Vulkan renderer. Calling it from the engine
            // thread breaks the otherwise circular dependency where the
            // backend loop waits for Dispose and Execute waits for the loop.
            Device.DisposeGpu();
        }

        public bool DisplayInputDialog(SoftwareKeyboardUIArgs args, out string userText)
        {
            string message = string.Join(
                Environment.NewLine,
                new[] { args.SubtitleText, args.GuideText }
                    .Where(text => !string.IsNullOrWhiteSpace(text))
            );
            return NativeDialogBridge.RequestText(
                string.IsNullOrWhiteSpace(args.HeaderText) ? "Software Keyboard" : args.HeaderText,
                message,
                args.InitialText,
                args.StringLengthMin,
                args.StringLengthMax,
                args.KeyboardMode.ToString(),
                args.SubmitText,
                out userText
            );
        }

        public bool DisplayMessageDialog(string title, string message)
        {
            return NativeDialogBridge.RequestMessage(title, message);
        }

        public bool DisplayCabinetDialog(out string userText)
        {
            return NativeDialogBridge.RequestText(
                "Amiibo Cabinet",
                "Enter a name for the Amiibo.",
                string.Empty,
                0,
                0,
                out userText
            );
        }

        public void DisplayCabinetMessageDialog()
        {
            NativeDialogBridge.RequestMessage("Amiibo Cabinet", "Please scan your Amiibo now.");
        }

        public bool DisplayMessageDialog(ControllerAppletUIArgs args)
        {
            if (_ignoreControllerApplet)
                return false;

            string playerCount = args.PlayerCountMin == args.PlayerCountMax ? $"exactly {args.PlayerCountMin}" : $"{args.PlayerCountMin}-{args.PlayerCountMax}";

            string message = $"Application requests {playerCount} {"player".ToQuantity(args.PlayerCountMin + args.PlayerCountMax, ShowQuantityAs.None)} with:\n\n"
                           + $"TYPES: {args.SupportedStyles}\n\n"
                           + $"PLAYERS: {string.Join(", ", args.SupportedPlayers)}\n\n"
                           + (args.IsDocked ? "Docked mode set. Handheld is also invalid.\n\n" : string.Empty)
                           + "Please reconfigure Input now and then press OK.";

            return NativeDialogBridge.RequestConfirmation(
                "Controller Applet",
                message,
                ["Continue", "Cancel"]
            );
        }

        public IDynamicTextInputHandler CreateDynamicTextInputHandler()
        {
            return new HeadlessDynamicTextInputHandler();
        }

        public void ExecuteProgram(Switch device, ProgramSpecifyKind kind, ulong value)
        {
            device.Configuration.UserChannelPersistence.ExecuteProgram(kind, value);

            Exit();
        }

        public unsafe bool DisplayErrorAppletDialog(string title, string message, string[] buttonsText, (uint Module, uint Description)? errorCode = null)
        {
            string detail = errorCode is { } code
                ? $"{message}{Environment.NewLine}{Environment.NewLine}Error {code.Module:X4}-{code.Description:X4}"
                : message;
            return NativeDialogBridge.RequestConfirmation(title, detail, buttonsText);
        }

        public void Dispose()
        {
            Dispose(true);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                _isActive = false;
                TouchScreenManager?.Dispose();
                NpadManager.Dispose();

                void DestroyWindow()
                {
                    NativeEmbeddedEntrypoint.SetWindowReady(false);
                    SDL3Driver.Instance.UnregisterWindow(_windowId);
                    SDL_DestroyWindow(WindowHandle);
                    WindowHandle = null;
                }

                if (NativeEmbeddedEntrypoint.IsEmbedded)
                {
                    NativeEmbeddedEntrypoint.InvokeOnMainThread(DestroyWindow);
                }
                else
                {
                    DestroyWindow();
                }

                SDL3Driver.Instance.Dispose();
            }
        }

        public UserProfile ShowPlayerSelectDialog()
        {
            return NativeProfileBridge.RequestProfile();
        }
        
        public void TakeScreenshot()
        {
            throw new NotImplementedException();
        }
    }
}
