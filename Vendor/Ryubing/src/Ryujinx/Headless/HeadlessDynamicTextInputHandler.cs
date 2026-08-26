#nullable enable

using Ryujinx.HLE.UI;
using Ryujinx.Common.Configuration.Hid;
using System;
using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading;

namespace Ryujinx.Headless;

/// <summary>
/// Bridges the console's inline software keyboard to Sol's native macOS editor.
/// </summary>
internal sealed class HeadlessDynamicTextInputHandler : IDynamicTextInputHandler
{
    private readonly string _requestId = Guid.NewGuid().ToString("N");
    private bool _canProcessInput;
    private bool _disposed;
    private string _text = string.Empty;
    private int _cursorBegin;
    private int _cursorEnd;

    public event DynamicTextChangedHandler? TextChangedEvent;
    public event KeyPressedHandler? KeyPressedEvent;
    public event KeyReleasedHandler? KeyReleasedEvent;

    public bool TextProcessingEnabled
    {
        get => Volatile.Read(ref _canProcessInput);
        set
        {
            if (_disposed || Interlocked.Exchange(ref _canProcessInput, value) == value)
            {
                return;
            }

            if (value)
            {
                NativeDynamicTextInputBridge.Register(_requestId, this);
                Publish("inline-keyboard.shown");
            }
            else
            {
                Publish("inline-keyboard.hidden");
                NativeDynamicTextInputBridge.Unregister(_requestId, this);
            }
        }
    }

    public void SetText(string text, int cursorBegin) =>
        SetText(text, cursorBegin, cursorBegin);

    public void SetText(string text, int cursorBegin, int cursorEnd)
    {
        if (_disposed)
        {
            return;
        }

        _text = text ?? string.Empty;
        _cursorBegin = Math.Clamp(cursorBegin, 0, _text.Length);
        _cursorEnd = Math.Clamp(cursorEnd, 0, _text.Length);

        if (TextProcessingEnabled)
        {
            Publish("inline-keyboard.updated");
        }
    }

    internal void UpdateFromMac(string text, int cursorBegin, int cursorEnd, bool overwriteMode)
    {
        if (_disposed || !TextProcessingEnabled)
        {
            return;
        }

        _text = text ?? string.Empty;
        _cursorBegin = Math.Clamp(cursorBegin, 0, _text.Length);
        _cursorEnd = Math.Clamp(cursorEnd, 0, _text.Length);
        TextChangedEvent?.Invoke(_text, _cursorBegin, _cursorEnd, overwriteMode);
    }

    internal void SubmitFromMac(string? text)
    {
        if (text is not null)
        {
            UpdateFromMac(text, text.Length, text.Length, overwriteMode: false);
        }

        KeyPressedEvent?.Invoke(Key.Enter);
        KeyReleasedEvent?.Invoke(Key.Enter);
    }

    internal void CancelFromMac()
    {
        KeyPressedEvent?.Invoke(Key.Escape);
        KeyReleasedEvent?.Invoke(Key.Escape);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (TextProcessingEnabled)
        {
            Publish("inline-keyboard.hidden");
        }

        _disposed = true;
        Volatile.Write(ref _canProcessInput, false);
        NativeDynamicTextInputBridge.Unregister(_requestId, this);
    }

    private void Publish(string eventName)
    {
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = eventName,
            RequestId = _requestId,
            DefaultValue = _text,
            CursorBegin = _cursorBegin,
            CursorEnd = _cursorEnd,
            MaximumLength = 100,
        });
    }
}

internal static class NativeDynamicTextInputBridge
{
    private static readonly ConcurrentDictionary<
        string,
        WeakReference<HeadlessDynamicTextInputHandler>
    > Handlers = new(StringComparer.Ordinal);

    public static void Register(string requestId, HeadlessDynamicTextInputHandler handler) =>
        Handlers[requestId] = new WeakReference<HeadlessDynamicTextInputHandler>(handler);

    public static void Unregister(string requestId, HeadlessDynamicTextInputHandler handler)
    {
        if (TryGet(requestId, out HeadlessDynamicTextInputHandler? current) &&
            ReferenceEquals(current, handler))
        {
            Handlers.TryRemove(requestId, out _);
        }
    }

    public static void Update(JsonElement root)
    {
        HeadlessDynamicTextInputHandler handler = RequiredHandler(root);
        string text = ReadRequiredString(root, "value");
        int cursorBegin = ReadOptionalInt(root, "cursorBegin", text.Length);
        int cursorEnd = ReadOptionalInt(root, "cursorEnd", cursorBegin);
        bool overwriteMode = ReadOptionalBool(root, "overwriteMode", false);
        handler.UpdateFromMac(text, cursorBegin, cursorEnd, overwriteMode);
    }

    public static void Submit(JsonElement root)
    {
        HeadlessDynamicTextInputHandler handler = RequiredHandler(root);
        string? text = root.TryGetProperty("value", out JsonElement value) &&
                       value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;
        handler.SubmitFromMac(text);
    }

    public static void Cancel(JsonElement root) => RequiredHandler(root).CancelFromMac();

    private static HeadlessDynamicTextInputHandler RequiredHandler(JsonElement root)
    {
        string requestId = ReadRequiredString(root, "requestId");
        if (!TryGet(requestId, out HeadlessDynamicTextInputHandler? handler))
        {
            throw new InvalidOperationException(
                $"Inline keyboard request '{requestId}' is no longer active."
            );
        }
        return handler!;
    }

    private static bool TryGet(
        string requestId,
        out HeadlessDynamicTextInputHandler? handler
    )
    {
        handler = null;
        if (!Handlers.TryGetValue(requestId, out var reference) ||
            !reference.TryGetTarget(out handler))
        {
            Handlers.TryRemove(requestId, out _);
            return false;
        }
        return true;
    }

    private static string ReadRequiredString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out JsonElement value) ||
            value.ValueKind != JsonValueKind.String)
        {
            throw new ArgumentException($"Inline keyboard command requires a string {name}.");
        }
        return value.GetString() ?? string.Empty;
    }

    private static int ReadOptionalInt(JsonElement root, string name, int fallback) =>
        root.TryGetProperty(name, out JsonElement value) && value.TryGetInt32(out int result)
            ? result
            : fallback;

    private static bool ReadOptionalBool(JsonElement root, string name, bool fallback) =>
        root.TryGetProperty(name, out JsonElement value) &&
        value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : fallback;
}
