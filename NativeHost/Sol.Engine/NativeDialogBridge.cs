#nullable enable

using System;
using System.Collections.Concurrent;
using System.Linq;
using System.Text.Json;
using System.Threading;

namespace Ryujinx.Headless;

internal static class NativeDialogBridge
{
    private sealed class PendingDialog : IDisposable
    {
        public ManualResetEventSlim Completed { get; } = new(false);
        public bool Accepted { get; set; }
        public string? Value { get; set; }

        public void Dispose() => Completed.Dispose();
    }

    private static readonly ConcurrentDictionary<string, PendingDialog> Pending = new();

    public static bool RequestText(
        string title,
        string message,
        string? defaultValue,
        int minimumLength,
        int maximumLength,
        out string value
    ) => RequestText(
        title,
        message,
        defaultValue,
        minimumLength,
        maximumLength,
        inputMode: null,
        submitTitle: null,
        out value
    );

    public static bool RequestText(
        string title,
        string message,
        string? defaultValue,
        int minimumLength,
        int maximumLength,
        string? inputMode,
        string? submitTitle,
        out string value
    )
    {
        NativeSessionEvent request = new()
        {
            Event = "dialog.request",
            DialogKind = "text",
            Title = title,
            Message = message,
            InputMode = inputMode,
            DefaultValue = defaultValue,
            MinimumLength = Math.Max(0, minimumLength),
            MaximumLength = maximumLength <= 0 ? null : maximumLength,
            Buttons =
            [
                string.IsNullOrWhiteSpace(submitTitle) ? "Submit" : submitTitle,
                "Cancel",
            ],
        };

        bool accepted = WaitForResponse(request, out string? response);
        value = response ?? defaultValue ?? string.Empty;
        return accepted;
    }

    public static bool RequestMessage(string title, string message)
    {
        NativeSessionEvent request = new()
        {
            Event = "dialog.request",
            DialogKind = "message",
            Title = title,
            Message = message,
            Buttons = ["OK"],
        };
        return WaitForResponse(request, out _);
    }

    public static bool RequestConfirmation(
        string title,
        string message,
        string[]? buttons = null
    )
    {
        NativeSessionEvent request = new()
        {
            Event = "dialog.request",
            DialogKind = "confirmation",
            Title = title,
            Message = message,
            Buttons = buttons is { Length: > 0 } ? buttons : ["Continue", "Cancel"],
        };
        return WaitForResponse(request, out _);
    }

    public static bool RequestChoice(
        string title,
        string message,
        NativeDialogOption[] options,
        string? defaultValue,
        out string? selectedValue
    )
    {
        if (options.Length == 0)
        {
            selectedValue = null;
            return false;
        }

        NativeSessionEvent request = new()
        {
            Event = "dialog.request",
            DialogKind = "choice",
            Title = title,
            Message = message,
            DefaultValue = options.Any(option => option.Value == defaultValue)
                ? defaultValue
                : options[0].Value,
            Options = options,
            Buttons = ["Choose", "Cancel"],
        };
        return WaitForResponse(request, out selectedValue);
    }

    public static void Complete(JsonElement root)
    {
        string requestId = ReadRequiredString(root, "requestId");

        if (!Pending.TryGetValue(requestId, out PendingDialog? pending))
        {
            NativeSessionProtocol.PublishError($"Unknown native dialog request '{requestId}'.", "dialog-response");
            return;
        }

        pending.Accepted =
            root.TryGetProperty("accepted", out JsonElement accepted) &&
            accepted.ValueKind is JsonValueKind.True;
        pending.Value =
            root.TryGetProperty("value", out JsonElement value) &&
            value.ValueKind is JsonValueKind.String
                ? value.GetString()
                : null;
        pending.Completed.Set();
    }

    private static bool WaitForResponse(NativeSessionEvent request, out string? value)
    {
        string requestId = Guid.NewGuid().ToString("N");
        request.RequestId = requestId;
        using PendingDialog pending = new();

        if (!Pending.TryAdd(requestId, pending))
        {
            value = null;
            return false;
        }

        NativeSessionProtocol.Publish(request);
        bool received = pending.Completed.Wait(TimeSpan.FromMinutes(10));
        Pending.TryRemove(requestId, out _);

        value = pending.Value;
        return received && pending.Accepted;
    }

    private static string ReadRequiredString(JsonElement root, string name)
    {
        if (!root.TryGetProperty(name, out JsonElement value) ||
            value.ValueKind is not JsonValueKind.String)
        {
            throw new ArgumentException($"Native dialog response requires a string {name}.");
        }

        return value.GetString() ?? string.Empty;
    }
}
