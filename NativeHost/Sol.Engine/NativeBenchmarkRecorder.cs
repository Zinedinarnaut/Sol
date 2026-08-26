#nullable enable

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace Ryujinx.Headless;

/// <summary>
/// Opt-in, session-scoped performance capture for controlled renderer comparisons.
/// The presentation hot path only reads the monotonic clock and appends to memory;
/// no telemetry is collected unless an explicit output path is provided.
/// </summary>
internal static class NativeBenchmarkRecorder
{
    private const double DefaultWarmupSeconds = 15;
    private const double DefaultDurationSeconds = 30;
    private const double MinimumDurationSeconds = 5;
    private const double MaximumDurationSeconds = 600;
    private const double HostSampleIntervalSeconds = 0.75;

    private static readonly object Sync = new();
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
    };

    private static Session? _session;
    private static bool _enabled;

    internal static void Begin(string rendererName)
    {
        string? outputPath = Environment.GetEnvironmentVariable("SOL_BENCHMARK_OUTPUT");
        if (string.IsNullOrWhiteSpace(outputPath))
        {
            _enabled = false;
            return;
        }

        string resolvedOutputPath;
        try
        {
            resolvedOutputPath = Path.GetFullPath(outputPath);
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"[Benchmark] Invalid output path: {exception.Message}");
            _enabled = false;
            return;
        }

        double warmupSeconds = ReadSeconds(
            "SOL_BENCHMARK_WARMUP_SECONDS",
            DefaultWarmupSeconds,
            minimum: 0,
            maximum: MaximumDurationSeconds);
        double durationSeconds = ReadSeconds(
            "SOL_BENCHMARK_DURATION_SECONDS",
            DefaultDurationSeconds,
            MinimumDurationSeconds,
            MaximumDurationSeconds);
        string backend = Environment.GetEnvironmentVariable("SOL_METAL_GAL_BACKEND") == "1"
            ? "SolMetal"
            : "MoltenVK";
        string label = Environment.GetEnvironmentVariable("SOL_BENCHMARK_LABEL")?.Trim() ?? backend;

        lock (Sync)
        {
            _session = new Session(
                resolvedOutputPath,
                string.IsNullOrWhiteSpace(label) ? backend : label,
                backend,
                rendererName,
                warmupSeconds,
                durationSeconds);
            _enabled = true;
        }

        Console.WriteLine(
            $"[Benchmark] Armed {backend}: {warmupSeconds:0.###} s warmup, " +
            $"{durationSeconds:0.###} s capture.");
    }

    internal static void RecordPresentation(double sourceFramesPerSecond, double fifoPercent)
    {
        if (!_enabled)
        {
            return;
        }

        BenchmarkReport? report = null;
        string? outputPath = null;

        lock (Sync)
        {
            Session? session = _session;
            if (session is null || session.ReportWritten)
            {
                return;
            }

            long now = Stopwatch.GetTimestamp();
            report = session.RecordPresentation(now, sourceFramesPerSecond, fifoPercent);
            if (report is not null)
            {
                outputPath = session.OutputPath;
                session.ReportWritten = true;
            }
        }

        if (report is not null && outputPath is not null)
        {
            WriteReport(outputPath, report);
        }
    }

    internal static void Complete()
    {
        if (!_enabled)
        {
            return;
        }

        BenchmarkReport? report = null;
        string? outputPath = null;

        lock (Sync)
        {
            Session? session = _session;
            if (session is not null && !session.ReportWritten)
            {
                report = session.BuildReport(Stopwatch.GetTimestamp(), completed: false);
                outputPath = session.OutputPath;
                session.ReportWritten = true;
            }

            _session = null;
            _enabled = false;
        }

        if (report is not null && outputPath is not null)
        {
            WriteReport(outputPath, report);
        }
    }

    private static double ReadSeconds(
        string environmentVariable,
        double fallback,
        double minimum,
        double maximum)
    {
        string? rawValue = Environment.GetEnvironmentVariable(environmentVariable);
        if (!double.TryParse(
                rawValue,
                NumberStyles.Float,
                CultureInfo.InvariantCulture,
                out double value) ||
            !double.IsFinite(value))
        {
            return fallback;
        }

        return Math.Clamp(value, minimum, maximum);
    }

    private static void WriteReport(string outputPath, BenchmarkReport report)
    {
        try
        {
            string? directory = Path.GetDirectoryName(outputPath);
            if (!string.IsNullOrWhiteSpace(directory))
            {
                Directory.CreateDirectory(directory);
            }

            string temporaryPath = outputPath + ".tmp";
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(report, JsonOptions));
            File.Move(temporaryPath, outputPath, overwrite: true);
            Console.WriteLine(
                $"[Benchmark] Wrote {(report.Completed ? "complete" : "partial")} report to {outputPath}");
        }
        catch (Exception exception)
        {
            Console.Error.WriteLine($"[Benchmark] Could not write report: {exception}");
        }
    }

    private sealed class Session
    {
        private readonly Process _process = Process.GetCurrentProcess();
        private readonly List<double> _presentIntervalsMilliseconds = [];
        private readonly List<double> _sourceFramesPerSecond = [];
        private readonly List<double> _fifoPercent = [];
        private readonly List<double> _processCpuPercent = [];
        private readonly List<long> _workingSetBytes = [];
        private readonly long _warmupTicks;
        private readonly long _durationTicks;

        private long _firstPresentationTimestamp;
        private long _measurementStartTimestamp;
        private long _lastPresentationTimestamp;
        private long _lastHostSampleTimestamp;
        private TimeSpan _lastProcessCpuTime;
        private long _presentedFrames;

        internal Session(
            string outputPath,
            string label,
            string backend,
            string rendererName,
            double warmupSeconds,
            double durationSeconds)
        {
            OutputPath = outputPath;
            Label = label;
            Backend = backend;
            RendererName = rendererName;
            WarmupSeconds = warmupSeconds;
            DurationSeconds = durationSeconds;
            StartedAtUtc = DateTimeOffset.UtcNow;
            _warmupTicks = SecondsToTicks(warmupSeconds);
            _durationTicks = SecondsToTicks(durationSeconds);
        }

        internal string OutputPath { get; }
        internal string Label { get; }
        internal string Backend { get; }
        internal string RendererName { get; }
        internal double WarmupSeconds { get; }
        internal double DurationSeconds { get; }
        internal DateTimeOffset StartedAtUtc { get; }
        internal bool ReportWritten { get; set; }

        internal BenchmarkReport? RecordPresentation(
            long now,
            double sourceFramesPerSecond,
            double fifoPercent)
        {
            if (_firstPresentationTimestamp == 0)
            {
                _firstPresentationTimestamp = now;
            }

            long warmupElapsed = now - _firstPresentationTimestamp;
            if (warmupElapsed < _warmupTicks)
            {
                return null;
            }

            if (_measurementStartTimestamp == 0)
            {
                _measurementStartTimestamp = now;
                _lastPresentationTimestamp = now;
                _lastHostSampleTimestamp = now;
                _lastProcessCpuTime = _process.TotalProcessorTime;
                _presentedFrames = 1;
                SampleGuest(sourceFramesPerSecond, fifoPercent);
                SampleMemory();
                return null;
            }

            _presentedFrames++;
            _presentIntervalsMilliseconds.Add(
                TicksToSeconds(now - _lastPresentationTimestamp) * 1000);
            _lastPresentationTimestamp = now;

            if (now - _lastHostSampleTimestamp >= SecondsToTicks(HostSampleIntervalSeconds))
            {
                SampleHost(now);
                SampleGuest(sourceFramesPerSecond, fifoPercent);
            }

            if (now - _measurementStartTimestamp < _durationTicks)
            {
                return null;
            }

            return BuildReport(now, completed: true);
        }

        internal BenchmarkReport BuildReport(long now, bool completed)
        {
            double measuredSeconds = _measurementStartTimestamp == 0
                ? 0
                : TicksToSeconds(Math.Max(0, _lastPresentationTimestamp - _measurementStartTimestamp));
            double presentedFramesPerSecond = measuredSeconds > 0 && _presentedFrames > 1
                ? (_presentedFrames - 1) / measuredSeconds
                : 0;

            return new BenchmarkReport(
                SchemaVersion: 1,
                Label,
                Backend,
                RendererName,
                StartedAtUtc,
                Completed: completed && measuredSeconds >= DurationSeconds * 0.98,
                ConfiguredWarmupSeconds: WarmupSeconds,
                ConfiguredDurationSeconds: DurationSeconds,
                MeasuredSeconds: measuredSeconds,
                PresentedFrames: _presentedFrames,
                PresentedFramesPerSecond: presentedFramesPerSecond,
                SourceFramesPerSecond: Distribution.From(_sourceFramesPerSecond),
                PresentFrameTimeMilliseconds: Distribution.From(_presentIntervalsMilliseconds),
                FifoPercent: Distribution.From(_fifoPercent),
                ProcessCpuPercent: Distribution.From(_processCpuPercent),
                WorkingSetBytes: IntegerDistribution.From(_workingSetBytes));
        }

        private void SampleHost(long now)
        {
            TimeSpan processCpuTime = _process.TotalProcessorTime;
            double elapsedSeconds = TicksToSeconds(now - _lastHostSampleTimestamp);
            if (elapsedSeconds > 0)
            {
                double cpuSeconds = (processCpuTime - _lastProcessCpuTime).TotalSeconds;
                _processCpuPercent.Add(Math.Max(0, cpuSeconds / elapsedSeconds * 100));
            }

            _lastProcessCpuTime = processCpuTime;
            _lastHostSampleTimestamp = now;
            SampleMemory();
        }

        private void SampleMemory()
        {
            _process.Refresh();
            _workingSetBytes.Add(_process.WorkingSet64);
        }

        private void SampleGuest(double sourceFramesPerSecond, double fifoPercent)
        {
            if (double.IsFinite(sourceFramesPerSecond) && sourceFramesPerSecond > 0)
            {
                _sourceFramesPerSecond.Add(sourceFramesPerSecond);
            }

            if (double.IsFinite(fifoPercent) && fifoPercent >= 0)
            {
                _fifoPercent.Add(fifoPercent);
            }
        }
    }

    private sealed record BenchmarkReport(
        int SchemaVersion,
        string Label,
        string Backend,
        string RendererName,
        DateTimeOffset StartedAtUtc,
        bool Completed,
        double ConfiguredWarmupSeconds,
        double ConfiguredDurationSeconds,
        double MeasuredSeconds,
        long PresentedFrames,
        double PresentedFramesPerSecond,
        Distribution SourceFramesPerSecond,
        Distribution PresentFrameTimeMilliseconds,
        Distribution FifoPercent,
        Distribution ProcessCpuPercent,
        IntegerDistribution WorkingSetBytes);

    private sealed record Distribution(
        int Samples,
        double Mean,
        double Median,
        double P95,
        double P99,
        double Minimum,
        double Maximum)
    {
        internal static Distribution From(List<double> values)
        {
            if (values.Count == 0)
            {
                return new Distribution(0, 0, 0, 0, 0, 0, 0);
            }

            double[] sorted = [.. values.Order()];
            return new Distribution(
                sorted.Length,
                sorted.Average(),
                Percentile(sorted, 0.50),
                Percentile(sorted, 0.95),
                Percentile(sorted, 0.99),
                sorted[0],
                sorted[^1]);
        }
    }

    private sealed record IntegerDistribution(
        int Samples,
        long Median,
        long P95,
        long Minimum,
        long Maximum)
    {
        internal static IntegerDistribution From(List<long> values)
        {
            if (values.Count == 0)
            {
                return new IntegerDistribution(0, 0, 0, 0, 0);
            }

            long[] sorted = [.. values.Order()];
            return new IntegerDistribution(
                sorted.Length,
                Percentile(sorted, 0.50),
                Percentile(sorted, 0.95),
                sorted[0],
                sorted[^1]);
        }
    }

    private static double Percentile(double[] sorted, double percentile)
    {
        if (sorted.Length == 1)
        {
            return sorted[0];
        }

        double index = percentile * (sorted.Length - 1);
        int lower = (int)Math.Floor(index);
        int upper = Math.Min(sorted.Length - 1, lower + 1);
        double fraction = index - lower;
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction;
    }

    private static long Percentile(long[] sorted, double percentile)
    {
        if (sorted.Length == 1)
        {
            return sorted[0];
        }

        double index = percentile * (sorted.Length - 1);
        int lower = (int)Math.Floor(index);
        int upper = Math.Min(sorted.Length - 1, lower + 1);
        double fraction = index - lower;
        return (long)Math.Round(sorted[lower] + (sorted[upper] - sorted[lower]) * fraction);
    }

    private static long SecondsToTicks(double seconds)
    {
        return (long)Math.Round(seconds * Stopwatch.Frequency);
    }

    private static double TicksToSeconds(long ticks)
    {
        return ticks / (double)Stopwatch.Frequency;
    }
}
