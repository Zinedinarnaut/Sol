#nullable enable

using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using System;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Ryujinx.Headless;

internal readonly record struct NativePlaytimeUpdate(
    string TitleId,
    double TotalSeconds,
    DateTime LastPlayedUtc
);

internal static class NativePlaytimeTracker
{
    private static readonly object Sync = new();

    private static string? _titleId;
    private static string? _title;
    private static TimeSpan _sessionPlaytime;
    private static long? _activeSegmentStarted;

    public static void Reset()
    {
        lock (Sync)
        {
            _titleId = null;
            _title = null;
            _sessionPlaytime = TimeSpan.Zero;
            _activeSegmentStarted = null;
        }
    }

    public static void Observe(in NativeSessionSnapshot snapshot)
    {
        string? normalizedTitleId = NormalizeTitleId(snapshot.TitleId);
        if (normalizedTitleId is null)
        {
            return;
        }

        bool shouldWritePreGame = false;
        lock (Sync)
        {
            if (_titleId is null)
            {
                _titleId = normalizedTitleId;
                _title = snapshot.Title;
                shouldWritePreGame = true;
            }
            else if (!string.Equals(_titleId, normalizedTitleId, StringComparison.OrdinalIgnoreCase))
            {
                // A single native host session normally owns one title. Avoid
                // attributing time to a different program if a guest swaps the
                // active application before the current session has completed.
                return;
            }
            else if (!string.IsNullOrWhiteSpace(snapshot.Title))
            {
                _title = snapshot.Title;
            }

            if (snapshot.Phase == "running")
            {
                _activeSegmentStarted ??= Stopwatch.GetTimestamp();
            }
            else
            {
                StopActiveSegmentLocked();
            }
        }

        if (shouldWritePreGame)
        {
            WritePreGame(normalizedTitleId, snapshot.Title);
        }
    }

    public static void Suspend()
    {
        lock (Sync)
        {
            StopActiveSegmentLocked();
        }
    }

    public static NativePlaytimeUpdate? Complete()
    {
        string? titleId;
        string? title;
        TimeSpan sessionPlaytime;

        lock (Sync)
        {
            StopActiveSegmentLocked();
            titleId = _titleId;
            title = _title;
            sessionPlaytime = _sessionPlaytime;

            _titleId = null;
            _title = null;
            _sessionPlaytime = TimeSpan.Zero;
            _activeSegmentStarted = null;
        }

        if (titleId is null)
        {
            return null;
        }

        return WritePostGame(titleId, title, sessionPlaytime);
    }

    private static void StopActiveSegmentLocked()
    {
        if (_activeSegmentStarted is not { } started)
        {
            return;
        }

        _sessionPlaytime += Stopwatch.GetElapsedTime(started);
        _activeSegmentStarted = null;
    }

    private static void WritePreGame(string titleId, string? title)
    {
        try
        {
            UpdateMetadata(titleId, title, TimeSpan.Zero, addPlaytime: false);
        }
        catch (Exception exception)
        {
            NativeSessionProtocol.PublishError(
                $"Could not start playtime tracking: {exception.Message}",
                "playtime"
            );
        }
    }

    private static NativePlaytimeUpdate? WritePostGame(
        string titleId,
        string? title,
        TimeSpan sessionPlaytime)
    {
        try
        {
            (TimeSpan total, DateTime lastPlayedUtc) = UpdateMetadata(
                titleId,
                title,
                sessionPlaytime,
                addPlaytime: true
            );
            return new NativePlaytimeUpdate(
                titleId,
                total.TotalSeconds,
                lastPlayedUtc
            );
        }
        catch (Exception exception)
        {
            NativeSessionProtocol.PublishError(
                $"Could not save playtime: {exception.Message}",
                "playtime"
            );
            return null;
        }
    }

    private static (TimeSpan Total, DateTime LastPlayedUtc) UpdateMetadata(
        string titleId,
        string? title,
        TimeSpan sessionPlaytime,
        bool addPlaytime)
    {
        string metadataDirectory = Path.Combine(
            AppDataManager.GamesDirPath,
            titleId,
            "gui"
        );
        string metadataPath = Path.Combine(metadataDirectory, "metadata.json");
        Directory.CreateDirectory(metadataDirectory);

        JsonObject root = ReadMetadataObject(metadataPath);
        TimeSpan total = ReadExistingPlaytime(root);
        if (addPlaytime)
        {
            total += sessionPlaytime;
        }

        DateTime now = DateTime.UtcNow;
        if (!string.IsNullOrWhiteSpace(title))
        {
            root["title"] = title;
        }
        root["timespan_played"] = total.ToString("c", CultureInfo.InvariantCulture);
        root["last_played_utc"] = now.ToString("O", CultureInfo.InvariantCulture);

        // Complete the upstream legacy migration without discarding any other
        // metadata fields that newer engine builds may add.
        root.Remove("time_played");
        root.Remove("last_played");

        string temporaryPath = metadataPath + ".sol.tmp";
        File.WriteAllText(
            temporaryPath,
            root.ToJsonString(new JsonSerializerOptions { WriteIndented = true })
        );
        File.Move(temporaryPath, metadataPath, overwrite: true);
        return (total, now);
    }

    private static JsonObject ReadMetadataObject(string metadataPath)
    {
        if (!File.Exists(metadataPath))
        {
            return new JsonObject();
        }

        try
        {
            return JsonNode.Parse(File.ReadAllText(metadataPath)) as JsonObject
                ?? new JsonObject();
        }
        catch (JsonException)
        {
            return new JsonObject();
        }
    }

    private static TimeSpan ReadExistingPlaytime(JsonObject root)
    {
        if (root["timespan_played"]?.GetValue<string>() is { } timespan &&
            TimeSpan.TryParse(
                timespan,
                CultureInfo.InvariantCulture,
                out TimeSpan parsedTimespan
            ))
        {
            return parsedTimespan;
        }

        if (root["time_played"] is JsonValue legacyNode &&
            legacyNode.TryGetValue(out double legacySeconds) &&
            double.IsFinite(legacySeconds) &&
            legacySeconds > 0)
        {
            return TimeSpan.FromSeconds(legacySeconds);
        }

        return TimeSpan.Zero;
    }

    private static string? NormalizeTitleId(string? value)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Length != 16)
        {
            return null;
        }

        return ulong.TryParse(
            value,
            NumberStyles.HexNumber,
            CultureInfo.InvariantCulture,
            out _
        )
            ? value.ToUpperInvariant()
            : null;
    }
}
