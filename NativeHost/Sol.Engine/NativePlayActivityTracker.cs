#nullable enable

using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Horizon;
using Ryujinx.Horizon.Prepo.Types;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Threading;

namespace Ryujinx.Headless;

internal static class NativePlayActivityTracker
{
    private const int MaximumEntriesPerTitle = 100;
    private static readonly object PersistenceLock = new();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };
    private static int _started;

    public static void Start()
    {
        if (Interlocked.Exchange(ref _started, 1) != 0)
        {
            return;
        }
        HorizonStatic.PlayReport += HandlePlayReport;
    }

    public static void Stop()
    {
        if (Interlocked.Exchange(ref _started, 0) == 0)
        {
            return;
        }
        HorizonStatic.PlayReport -= HandlePlayReport;
    }

    private static void HandlePlayReport(PlayReport report)
    {
        try
        {
            string? titleId = HeadlessRyujinx.GetNativeSessionSnapshot().TitleId?
                .Trim()
                .ToUpperInvariant();
            if (string.IsNullOrWhiteSpace(titleId) ||
                titleId.Length != 16 ||
                !ulong.TryParse(
                    titleId,
                    NumberStyles.AllowHexSpecifier,
                    CultureInfo.InvariantCulture,
                    out _
                ))
            {
                return;
            }

            ActivityEntry entry = new(
                Guid.NewGuid().ToString("N"),
                DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
                NormalizeRoom(report.Room),
                report.Kind.ToString(),
                report.Version
            );
            Persist(titleId, entry);

            NativeSessionProtocol.Publish(new NativeSessionEvent
            {
                Event = "activity.updated",
                TitleId = titleId,
                ActivityId = entry.Id,
                ActivityTimestamp = entry.TimestampUnixSeconds,
                ActivityRoom = entry.Room,
                ActivityKind = entry.Kind,
                ActivityVersion = entry.Version,
            });
        }
        catch (Exception exception)
        {
            NativeSessionProtocol.PublishError(
                $"Could not save play activity: {exception.Message}",
                "play-activity"
            );
        }
    }

    private static string NormalizeRoom(string? room)
    {
        string normalized = (room ?? "Activity")
            .Replace('\r', ' ')
            .Replace('\n', ' ')
            .Trim();
        if (string.IsNullOrEmpty(normalized))
        {
            return "Activity";
        }
        return normalized.Length <= 128 ? normalized : normalized[..128];
    }

    private static void Persist(string titleId, ActivityEntry entry)
    {
        lock (PersistenceLock)
        {
            string directory = Path.Combine(AppDataManager.GamesDirPath, titleId, "gui");
            string path = Path.Combine(directory, "activity.json");
            Directory.CreateDirectory(directory);

            ActivityFile file = Read(path, titleId);
            file.Entries.Insert(0, entry);
            if (file.Entries.Count > MaximumEntriesPerTitle)
            {
                file.Entries.RemoveRange(
                    MaximumEntriesPerTitle,
                    file.Entries.Count - MaximumEntriesPerTitle
                );
            }

            string temporaryPath = path + ".tmp";
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(file, JsonOptions));
            File.Move(temporaryPath, path, overwrite: true);
        }
    }

    private static ActivityFile Read(string path, string titleId)
    {
        try
        {
            if (File.Exists(path))
            {
                ActivityFile? existing = JsonSerializer.Deserialize<ActivityFile>(
                    File.ReadAllText(path),
                    JsonOptions
                );
                if (existing is not null)
                {
                    existing.TitleId = titleId;
                    existing.Entries ??= [];
                    return existing;
                }
            }
        }
        catch
        {
            // Preserve gameplay even when an old activity file is malformed.
        }
        return new ActivityFile { TitleId = titleId };
    }

    private sealed class ActivityFile
    {
        public int SchemaVersion { get; set; } = 1;
        public string TitleId { get; set; } = string.Empty;
        public List<ActivityEntry> Entries { get; set; } = [];
    }

    private sealed record ActivityEntry(
        string Id,
        long TimestampUnixSeconds,
        string Room,
        string Kind,
        uint Version
    );
}
