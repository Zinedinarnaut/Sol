#nullable enable

using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using SkiaSharp;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Threading;
using SDL;
using static SDL.SDL3;

namespace Ryujinx.Headless;

internal readonly record struct NativeSessionSnapshot(
    string Phase,
    bool IsPaused,
    bool IsFullscreen,
    float Volume,
    string? Title,
    string? TitleId
);

internal sealed class NativeSessionEvent
{
    public int Protocol { get; init; } = NativeSessionProtocol.ProtocolVersion;
    public required string Event { get; init; }
    public string? Phase { get; init; }
    public bool? Paused { get; init; }
    public bool? Fullscreen { get; init; }
    public float? Volume { get; init; }
    public string? VsyncMode { get; init; }
    public string? Title { get; init; }
    public string? TitleId { get; init; }
    public string? Message { get; init; }
    public string? Path { get; init; }
    public string? Command { get; init; }
    public string? Operation { get; init; }
    public string? FirmwareVersion { get; init; }
    public string? DataDirectory { get; init; }
    public bool? HasProdKeys { get; init; }
    public bool? Success { get; init; }
    public int? ExitCode { get; init; }
    public string? RequestId { get; set; }
    public string? DialogKind { get; init; }
    public string? InputMode { get; init; }
    public string? DefaultValue { get; init; }
    public int? MinimumLength { get; init; }
    public int? MaximumLength { get; init; }
    public string? InputId { get; init; }
    public string? InputName { get; init; }
    public string? InputKind { get; init; }
    public string? PlayerIndex { get; init; }
    public string[]? AssignedPlayers { get; init; }
    public bool? UsesEastConfirmButton { get; init; }
    public bool? IsConnected { get; init; }
    public Dictionary<string, string>? Bindings { get; init; }
    public string? BindingName { get; init; }
    public string? BindingValue { get; init; }
    public string? ProfileId { get; init; }
    public string? ProfileName { get; init; }
    public string? ProfileImageBase64 { get; init; }
    public bool? IsDefault { get; init; }
    public int? Count { get; init; }
    public int? DlcCount { get; init; }
    public int? UpdateCount { get; init; }
    public int? DirectoryCount { get; init; }
    public int? AddedCount { get; init; }
    public int? RemovedCount { get; init; }
    public string? ProviderStage { get; init; }
    public int? ProviderGeneration { get; init; }
    public bool? SceneReady { get; init; }
    public bool? DepthReady { get; init; }
    public bool? MotionReady { get; init; }
    public bool? RawExportReady { get; init; }
    public bool? ExportReady { get; init; }
    public bool? SceneCut { get; init; }
    public string? SceneLabel { get; init; }
    public string? DepthLabel { get; init; }
    public string? MotionLabel { get; init; }
    public string? DepthFormat { get; init; }
    public string? MotionFormat { get; init; }
    public int? Width { get; init; }
    public int? Height { get; init; }
    public string? LoadStage { get; init; }
    public int? ProgressCurrent { get; init; }
    public int? ProgressTotal { get; init; }
    public double? PlaytimeSeconds { get; init; }
    public string? LastPlayedUtc { get; init; }
    public NativeDialogOption[]? Options { get; init; }
    public string[]? Buttons { get; init; }
    public string[]? Capabilities { get; init; }
}

internal sealed class NativeDialogOption
{
    public required string Value { get; init; }
    public required string Label { get; init; }
}

internal static class NativeSessionProtocol
{
    public const int ProtocolVersion = 1;
    public const string Prefix = "@@SOL_ENGINE@@";

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
    private static readonly object OutputLock = new();
    private static CancellationTokenSource _lifetime = new();
    private static Action<string>? _eventSink;
    private static volatile bool _stopping;
    private static NativeSessionSnapshot? _lastSnapshot;
    private static IRenderer? _screenshotRenderer;

    public static void Start(bool readCommands = true, Action<string>? eventSink = null)
    {
        CancellationTokenSource lifetime;

        lock (OutputLock)
        {
            _lifetime.Cancel();
            _lifetime.Dispose();
            _lifetime = new CancellationTokenSource();
            lifetime = _lifetime;
            _eventSink = eventSink;
            _stopping = false;
            _lastSnapshot = null;
            _screenshotRenderer = null;
            NativePlaytimeTracker.Reset();
        }

        Publish(new NativeSessionEvent
        {
            Event = "host.ready",
            Capabilities =
            [
                "session-state",
                "pause",
                "resume",
                "stop",
                "fullscreen",
                "volume",
                "vsync",
                "screenshot",
                "native-cocoa-window",
                "backend-status",
                "install-keys",
                "install-firmware",
                "scan-content",
                "list-inputs",
                "set-player-input",
                "controller-bindings",
                "profiles",
                "set-profile",
                "native-dialogs",
                "playtime-tracking",
                "embedded-cocoa-view",
                "dlsm-attachment-discovery",
                "dlsm-provider-readiness",
                "launch-progress",
                "first-frame",
                "scan-amiibo",
            ],
        });

        if (readCommands)
        {
            new Thread(ReadCommands)
            {
                IsBackground = true,
                Name = "NativeHost.CommandReader",
            }.Start();
        }

        new Thread(() => MonitorSession(lifetime.Token))
        {
            IsBackground = true,
            Name = "NativeHost.SessionMonitor",
        }.Start();
    }

    public static void MarkLaunching()
    {
        Publish(new NativeSessionEvent
        {
            Event = "session.state",
            Phase = "launching",
        });
    }

    public static void PublishLaunchProgress(
        string stage,
        string message,
        int? current = null,
        int? total = null)
    {
        Publish(new NativeSessionEvent
        {
            Event = "launch.progress",
            LoadStage = stage,
            Message = message,
            ProgressCurrent = current,
            ProgressTotal = total,
        });
    }

    public static void Stop()
    {
        _stopping = true;
        _lifetime.Cancel();
        Publish(new NativeSessionEvent
        {
            Event = "host.stopping",
        });
    }

    public static void PublishError(string message, string? command = null)
    {
        Publish(new NativeSessionEvent
        {
            Event = "host.error",
            Message = message,
            Command = command,
        });
    }

    public static void Publish(NativeSessionEvent sessionEvent)
    {
        string json = JsonSerializer.Serialize(sessionEvent, JsonOptions);

        lock (OutputLock)
        {
            if (_eventSink is { } sink)
            {
                sink(json);
            }
            else
            {
                Console.Out.WriteLine(Prefix + json);
                Console.Out.Flush();
            }
        }
    }

    private static void ReadCommands()
    {
        string? line;

        while (!_stopping && (line = Console.In.ReadLine()) is not null)
        {
            if (string.IsNullOrWhiteSpace(line))
            {
                continue;
            }

            HandleCommandJson(line);
        }
    }

    public static bool HandleCommandJson(string json)
    {
        try
        {
            using JsonDocument document = JsonDocument.Parse(json);
            JsonElement root = document.RootElement;

            if (!root.TryGetProperty("command", out JsonElement commandElement))
            {
                PublishError("Native command is missing the command field.");
                return false;
            }

            string command = commandElement.GetString() ?? string.Empty;
            HandleCommand(command, root);
            return true;
        }
        catch (Exception exception)
        {
            PublishError($"Could not process native command: {exception.Message}");
            return false;
        }
    }

    private static void HandleCommand(string command, JsonElement root)
    {
        switch (command)
        {
            case "query-state":
                PublishSnapshot(HeadlessRyujinx.GetNativeSessionSnapshot(), force: true);
                break;
            case "pause":
                HeadlessRyujinx.SetNativePaused(true);
                break;
            case "resume":
                HeadlessRyujinx.SetNativePaused(false);
                break;
            case "stop":
                NativePlaytimeTracker.Suspend();
                Publish(new NativeSessionEvent
                {
                    Event = "session.state",
                    Phase = "stopping",
                });
                if (NativeEmbeddedEntrypoint.IsEmbedded)
                {
                    NativeEmbeddedEntrypoint.RequestStop();
                }
                else
                {
                    HeadlessRyujinx.StopNativeSession();
                }
                break;
            case "set-fullscreen":
                HeadlessRyujinx.SetNativeFullscreen(ReadRequiredBoolean(root, "value"));
                break;
            case "toggle-fullscreen":
                HeadlessRyujinx.SetNativeFullscreen(!HeadlessRyujinx.GetNativeSessionSnapshot().IsFullscreen);
                break;
            case "set-volume":
                HeadlessRyujinx.SetNativeVolume(ReadRequiredSingle(root, "value"));
                break;
            case "set-vsync":
                string value = ReadRequiredString(root, "value");

                if (!Enum.TryParse(value, ignoreCase: true, out VSyncMode mode))
                {
                    throw new ArgumentException($"Unknown VSync mode '{value}'.");
                }

                HeadlessRyujinx.SetNativeVSyncMode(mode);
                break;
            case "screenshot":
                HeadlessRyujinx.TakeNativeScreenshot();
                break;
            case "scan-amiibo":
                HeadlessRyujinx.ScanNativeAmiibo(
                    ReadRequiredString(root, "amiiboId"),
                    ReadRequiredBoolean(root, "useRandomUuid"));
                break;
            case "dialog-response":
                NativeDialogBridge.Complete(root);
                break;
            default:
                PublishError($"Unknown native command '{command}'.", command);
                break;
        }
    }

    private static bool ReadRequiredBoolean(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out JsonElement value) ||
            (value.ValueKind != JsonValueKind.True && value.ValueKind != JsonValueKind.False))
        {
            throw new ArgumentException($"Native command requires a boolean {name}.");
        }

        return value.GetBoolean();
    }

    private static float ReadRequiredSingle(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out JsonElement value) ||
            !value.TryGetSingle(out float result))
        {
            throw new ArgumentException($"Native command requires a numeric {name}.");
        }

        return result;
    }

    private static string ReadRequiredString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out JsonElement value) ||
            value.ValueKind != JsonValueKind.String)
        {
            throw new ArgumentException($"Native command requires a string {name}.");
        }

        return value.GetString() ?? string.Empty;
    }

    private static void MonitorSession(CancellationToken cancellationToken)
    {
        while (!_stopping && !cancellationToken.IsCancellationRequested)
        {
            NativeSessionSnapshot snapshot = HeadlessRyujinx.GetNativeSessionSnapshot();
            PublishSnapshot(snapshot);
            AttachScreenshotHandler();

            if (cancellationToken.WaitHandle.WaitOne(150))
            {
                break;
            }
        }
    }

    private static void PublishSnapshot(NativeSessionSnapshot snapshot, bool force = false)
    {
        NativePlaytimeTracker.Observe(snapshot);

        if (!force && _lastSnapshot == snapshot)
        {
            return;
        }

        _lastSnapshot = snapshot;
        Publish(new NativeSessionEvent
        {
            Event = "session.state",
            Phase = snapshot.Phase,
            Paused = snapshot.IsPaused,
            Fullscreen = snapshot.IsFullscreen,
            Volume = snapshot.Volume,
            Title = snapshot.Title,
            TitleId = snapshot.TitleId,
        });
    }

    internal static void CompletePlaytimeTracking()
    {
        if (NativePlaytimeTracker.Complete() is not { } update)
        {
            return;
        }

        Publish(new NativeSessionEvent
        {
            Event = "playtime.updated",
            TitleId = update.TitleId,
            PlaytimeSeconds = update.TotalSeconds,
            LastPlayedUtc = update.LastPlayedUtc.ToString("O"),
            Message = $"Saved {TimeSpan.FromSeconds(update.TotalSeconds):c} of playtime.",
        });
    }

    private static void AttachScreenshotHandler()
    {
        IRenderer? renderer = HeadlessRyujinx.GetNativeRenderer();

        if (renderer is null || ReferenceEquals(renderer, _screenshotRenderer))
        {
            return;
        }

        _screenshotRenderer = renderer;
        renderer.ScreenCaptured += RendererScreenCaptured;
    }

    private static void RendererScreenCaptured(object? sender, ScreenCaptureImageInfo image)
    {
        if (image.Data.Length == 0 || image.Width <= 0 || image.Height <= 0)
        {
            PublishError("Sol Engine returned an empty screenshot.");
            return;
        }

        try
        {
            string title = HeadlessRyujinx.GetNativeSessionSnapshot().Title ?? "Sol";
            string safeTitle = string.Join("_", title.Split(Path.GetInvalidFileNameChars()));
            string directory = Path.Combine(AppDataManager.BaseDirPath, "screenshots");
            string filename = $"{safeTitle}_{DateTime.Now:yyyy-MM-dd_HH-mm-ss}.png";
            string path = Path.Combine(directory, filename);
            Directory.CreateDirectory(directory);

            SKColorType colorType = image.IsBgra ? SKColorType.Bgra8888 : SKColorType.Rgba8888;
            using SKBitmap bitmap = new(new SKImageInfo(image.Width, image.Height, colorType, SKAlphaType.Premul));
            Marshal.Copy(image.Data, 0, bitmap.GetPixels(), image.Data.Length);
            using SKBitmap output = new(bitmap.Width, bitmap.Height);
            using (SKCanvas canvas = new(output))
            {
                canvas.Clear(SKColors.Black);
                float scaleX = image.FlipX ? -1 : 1;
                float scaleY = image.FlipY ? -1 : 1;
                canvas.SetMatrix(SKMatrix.CreateScale(scaleX, scaleY, bitmap.Width / 2f, bitmap.Height / 2f));
                canvas.DrawBitmap(bitmap, SKPoint.Empty);
            }

            using SKData data = output.Encode(SKEncodedImageFormat.Png, 100);
            using FileStream stream = File.Create(path);
            data.SaveTo(stream);

            Publish(new NativeSessionEvent
            {
                Event = "screenshot.saved",
                Path = path,
            });
        }
        catch (Exception exception)
        {
            PublishError($"Could not save screenshot: {exception.Message}", "screenshot");
        }
    }
}

public partial class HeadlessRyujinx
{
    internal static NativeSessionSnapshot GetNativeSessionSnapshot()
    {
        WindowBase? window = _window;
        Ryujinx.HLE.Switch? device = _emulationContext;
        bool running = window?.NativeIsRunning == true;
        string phase = running ? (device?.System?.IsPaused == true ? "paused" : "running") : "idle";
        string? title = null;
        string? titleId = null;

        try
        {
            title = device?.Processes.ActiveApplication?.Name;
            titleId = device?.Processes.ActiveApplication?.ProgramIdText;
        }
        catch
        {
            // The active application is populated incrementally while loading.
        }

        return new NativeSessionSnapshot(
            phase,
            device?.System?.IsPaused == true,
            window?.NativeIsFullscreen == true,
            device?.GetVolume() ?? 1,
            string.IsNullOrWhiteSpace(title) ? null : title,
            string.IsNullOrWhiteSpace(titleId) ? null : titleId
        );
    }

    internal static IRenderer? GetNativeRenderer() => _window?.Renderer;

    internal static void SetNativePaused(bool paused)
    {
        if (_emulationContext?.System is null)
        {
            NativeSessionProtocol.PublishError("No emulation session is running.", paused ? "pause" : "resume");
            return;
        }

        _emulationContext.System.TogglePauseEmulation(paused);
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "session.state",
            Phase = paused ? "paused" : "running",
            Paused = paused,
        });
    }

    internal static void StopNativeSession()
    {
        if (_window is null)
        {
            NativeSessionProtocol.PublishError("No emulation session is running.", "stop");
            return;
        }

        _window.Exit();
    }

    internal static void SetNativeFullscreen(bool fullscreen)
    {
        if (_window is null)
        {
            NativeSessionProtocol.PublishError("No emulation window is running.", "set-fullscreen");
            return;
        }

        if (NativeEmbeddedEntrypoint.IsEmbedded)
        {
            NativeSessionProtocol.Publish(new NativeSessionEvent
            {
                Event = "fullscreen.requested",
                Fullscreen = fullscreen,
            });
            return;
        }

        _window.SetNativeFullscreen(fullscreen);
    }

    internal static void SetEmbeddedFullscreenState(bool fullscreen)
    {
        _window?.SetEmbeddedFullscreenState(fullscreen);
    }

    internal static void ResizeNativeSurface(int width, int height)
    {
        _window?.ResizeEmbeddedSurface(width, height);
    }

    internal static void SetNativeVolume(float volume)
    {
        if (_emulationContext is null)
        {
            NativeSessionProtocol.PublishError("No emulation session is running.", "set-volume");
            return;
        }

        float clamped = Math.Clamp(volume, 0, 1);
        _emulationContext.SetVolume(clamped);
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "volume.changed",
            Volume = clamped,
        });
    }

    internal static void SetNativeVSyncMode(VSyncMode mode)
    {
        if (_emulationContext is null)
        {
            NativeSessionProtocol.PublishError("No emulation session is running.", "set-vsync");
            return;
        }

        _emulationContext.VSyncMode = mode;
        _emulationContext.UpdateVSyncInterval();
        _emulationContext.Gpu.Renderer.Window?.ChangeVSyncMode(mode);
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "vsync.changed",
            VsyncMode = mode.ToString(),
        });
    }

    internal static void TakeNativeScreenshot()
    {
        if (_window?.Renderer is null)
        {
            NativeSessionProtocol.PublishError("No renderer is running.", "screenshot");
            return;
        }

        _window.Renderer.Screenshot();
    }

    internal static void ScanNativeAmiibo(string amiiboId, bool useRandomUuid)
    {
        string normalizedId = amiiboId.Trim().ToUpperInvariant();
        if (normalizedId.Length != 16 ||
            normalizedId.Any(character => !Uri.IsHexDigit(character)))
        {
            NativeSessionProtocol.PublishError(
                "The selected Amiibo has an invalid identifier.",
                "scan-amiibo");
            return;
        }

        if (_emulationContext?.System is not { } system)
        {
            NativeSessionProtocol.PublishError(
                "No game is running.",
                "scan-amiibo");
            return;
        }

        if (!system.SearchingForAmiibo(out int deviceId))
        {
            NativeSessionProtocol.PublishError(
                "The game is not waiting for an Amiibo scan yet.",
                "scan-amiibo");
            return;
        }

        system.ScanAmiibo(deviceId, normalizedId, useRandomUuid);
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "amiibo.scanned",
            Message = "Amiibo scanned",
        });
    }
}

abstract unsafe partial class WindowBase
{
    internal bool NativeIsRunning => _isActive && !_isStopped && WindowHandle != null;
    internal bool NativeIsFullscreen => IsFullscreen || IsExclusiveFullscreen;

    internal void SetNativeFullscreen(bool fullscreen)
    {
        QueueMainThreadAction(() =>
        {
            if (WindowHandle == null)
            {
                NativeSessionProtocol.PublishError("The native Cocoa window is not ready.", "set-fullscreen");
                return;
            }

            if (!SDL_SetWindowFullscreen(WindowHandle, fullscreen))
            {
                NativeSessionProtocol.PublishError($"Could not change fullscreen mode: {SDL_GetError()}", "set-fullscreen");
                return;
            }

            IsFullscreen = fullscreen;
            IsExclusiveFullscreen = false;

            if (!fullscreen)
            {
                SDL_SetWindowBordered(WindowHandle, true);
                SDL_SetWindowResizable(WindowHandle, true);
            }

            int width;
            int height;
            SDL_GetWindowSizeInPixels(WindowHandle, &width, &height);
            Width = width;
            Height = height;
            Renderer?.Window.SetSize(width, height);
            MouseDriver.SetClientSize(width, height);

            NativeSessionProtocol.Publish(new NativeSessionEvent
            {
                Event = "fullscreen.changed",
                Fullscreen = fullscreen,
            });
        });
    }

    internal void SetEmbeddedFullscreenState(bool fullscreen)
    {
        IsFullscreen = fullscreen;
        IsExclusiveFullscreen = false;
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "fullscreen.changed",
            Fullscreen = fullscreen,
        });
    }

    internal void ResizeEmbeddedSurface(int width, int height)
    {
        if (!NativeEmbeddedEntrypoint.IsEmbedded)
        {
            return;
        }

        int surfaceWidth = Math.Max(1, width);
        int surfaceHeight = Math.Max(1, height);

        NativeEmbeddedEntrypoint.InvokeOnMainThread(() =>
        {
            Width = surfaceWidth;
            Height = surfaceHeight;
            if (Renderer?.Window is { } rendererWindow)
            {
                rendererWindow.SetSize(surfaceWidth, surfaceHeight);
            }
            MouseDriver.SetClientSize(surfaceWidth, surfaceHeight);
        });
    }
}
