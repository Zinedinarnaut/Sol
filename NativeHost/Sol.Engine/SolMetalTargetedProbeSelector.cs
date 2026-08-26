#nullable enable

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace Ryujinx.Headless;

internal readonly record struct SolMetalTargetedProbeColorTarget(
    int Slot,
    int Width,
    int Height,
    SolMetalNativeBridge.GalTextureFormat Format,
    long Draws,
    long Clears
);

internal readonly record struct SolMetalTargetedProbeDepthTarget(
    int Width,
    int Height,
    SolMetalNativeBridge.GalTextureFormat Format,
    long Passes,
    long Clears
);

internal readonly record struct SolMetalTargetedProbeD16Replay(
    uint RawTag,
    int ExpectedCode,
    bool MatchingWriterTarget,
    ulong WriterExpectedCodeCount
);

internal readonly record struct SolMetalTargetedProbeDraw(
    string ProgramKey,
    long Presentation,
    SolMetalTargetedProbeColorTarget[] ColorTargets,
    SolMetalTargetedProbeDepthTarget? DepthTarget,
    SolMetalTargetedProbeD16Replay? D16Replay
);

/// <summary>
/// Pure managed matcher for one-shot renderer diagnostics. A selector advances
/// its occurrence only after every structural and maturity constraint matches,
/// so an early use of the same shader cannot consume a later requested pass.
/// </summary>
internal sealed class SolMetalTargetedProbeSelector
{
    private const int MaximumEnvironmentBytes = 64 * 1024;
    private const int MaximumSelectors = 16;
    private const int MaximumDimension = 32_768;
    private const long MaximumCounter = 1_000_000_000;
    private const int MaximumEligibleOccurrence = 1_000_000;
    private const int MaximumNameLength = 32;

    private enum DepthPresence
    {
        Any,
        None,
        Present,
    }

    private readonly DepthPresence _depthPresence;
    private readonly int _depthWidth;
    private readonly int _depthHeight;
    private readonly SolMetalNativeBridge.GalTextureFormat _depthFormat;
    private readonly uint? _d16ReplayRawTag;
    private readonly int? _d16ReplayExpectedCode;
    private readonly ulong _d16ReplayMinimumWriterCodeCount;
    private long _eligibleMatches;

    private SolMetalTargetedProbeSelector(
        string name,
        string programKey,
        int colorSlot,
        int colorWidth,
        int colorHeight,
        SolMetalNativeBridge.GalTextureFormat colorFormat,
        DepthPresence depthPresence,
        int depthWidth,
        int depthHeight,
        SolMetalNativeBridge.GalTextureFormat depthFormat,
        long minPresentations,
        long minColorDraws,
        long minColorClears,
        long minDepthPasses,
        long minDepthClears,
        uint? d16ReplayRawTag,
        int? d16ReplayExpectedCode,
        ulong d16ReplayMinimumWriterCodeCount,
        int eligibleOccurrence,
        long maxWaitPresentations
    )
    {
        Name = name;
        ProgramKey = programKey;
        ColorSlot = colorSlot;
        ColorWidth = colorWidth;
        ColorHeight = colorHeight;
        ColorFormat = colorFormat;
        _depthPresence = depthPresence;
        _depthWidth = depthWidth;
        _depthHeight = depthHeight;
        _depthFormat = depthFormat;
        MinPresentations = minPresentations;
        MinColorDraws = minColorDraws;
        MinColorClears = minColorClears;
        MinDepthPasses = minDepthPasses;
        MinDepthClears = minDepthClears;
        _d16ReplayRawTag = d16ReplayRawTag;
        _d16ReplayExpectedCode = d16ReplayExpectedCode;
        _d16ReplayMinimumWriterCodeCount =
            d16ReplayMinimumWriterCodeCount;
        EligibleOccurrence = eligibleOccurrence;
        MaxWaitPresentations = maxWaitPresentations;
    }

    internal string Name { get; }
    internal string ProgramKey { get; }
    internal int ColorSlot { get; }
    internal int ColorWidth { get; }
    internal int ColorHeight { get; }
    internal SolMetalNativeBridge.GalTextureFormat ColorFormat { get; }
    internal long MinPresentations { get; }
    internal long MinColorDraws { get; }
    internal long MinColorClears { get; }
    internal long MinDepthPasses { get; }
    internal long MinDepthClears { get; }
    internal int EligibleOccurrence { get; }
    internal long MaxWaitPresentations { get; }
    internal bool RequiresD16Replay => _d16ReplayRawTag.HasValue;

    internal string Description
    {
        get
        {
            string depth = _depthPresence switch
            {
                DepthPresence.None => "none",
                DepthPresence.Present =>
                    $"{_depthWidth}x{_depthHeight}:{_depthFormat}",
                _ => "any",
            };
            string d16Replay = RequiresD16Replay
                ? $",d16-replay=raw{_d16ReplayRawTag}/" +
                    $"code{_d16ReplayExpectedCode}/same-writer/" +
                    $"count>={_d16ReplayMinimumWriterCodeCount}"
                : string.Empty;
            return $"{Name}:key={ProgramKey[..12]}," +
                $"color=s{ColorSlot}:{ColorWidth}x{ColorHeight}:" +
                $"{ColorFormat},depth={depth},min=" +
                $"p{MinPresentations}/cd{MinColorDraws}/" +
                $"cc{MinColorClears}/dp{MinDepthPasses}/" +
                $"dc{MinDepthClears},occurrence={EligibleOccurrence}," +
                $"maxWait={MaxWaitPresentations}{d16Replay}";
        }
    }

    internal SolMetalTargetedProbeSelector ClonePending() => new(
        Name,
        ProgramKey,
        ColorSlot,
        ColorWidth,
        ColorHeight,
        ColorFormat,
        _depthPresence,
        _depthWidth,
        _depthHeight,
        _depthFormat,
        MinPresentations,
        MinColorDraws,
        MinColorClears,
        MinDepthPasses,
        MinDepthClears,
        _d16ReplayRawTag,
        _d16ReplayExpectedCode,
        _d16ReplayMinimumWriterCodeCount,
        EligibleOccurrence,
        MaxWaitPresentations
    );

    internal bool TrySelect(in SolMetalTargetedProbeDraw draw)
    {
        if (!IsEligibleWithoutRuntimeConstraints(draw))
        {
            return false;
        }

        if (RequiresD16Replay &&
            (draw.D16Replay is not SolMetalTargetedProbeD16Replay replay ||
             replay.RawTag != _d16ReplayRawTag!.Value ||
             replay.ExpectedCode != _d16ReplayExpectedCode!.Value ||
             !replay.MatchingWriterTarget ||
             replay.WriterExpectedCodeCount <
                _d16ReplayMinimumWriterCodeCount))
        {
            return false;
        }

        _eligibleMatches++;
        return _eligibleMatches == EligibleOccurrence;
    }

    internal bool IsEligibleWithoutRuntimeConstraints(
        in SolMetalTargetedProbeDraw draw
    )
    {
        if (!Matches(draw, out SolMetalTargetedProbeColorTarget colorTarget))
        {
            return false;
        }

        if (draw.Presentation < MinPresentations ||
            colorTarget.Draws < MinColorDraws ||
            colorTarget.Clears < MinColorClears)
        {
            return false;
        }

        if (_depthPresence == DepthPresence.Present)
        {
            SolMetalTargetedProbeDepthTarget depthTarget =
                draw.DepthTarget!.Value;
            if (depthTarget.Passes < MinDepthPasses ||
                depthTarget.Clears < MinDepthClears)
            {
                return false;
            }
        }

        return true;
    }

    internal bool IsExpired(long presentation, long armedPresentation) =>
        MaxWaitPresentations > 0 && presentation >= armedPresentation &&
        presentation - armedPresentation >= MaxWaitPresentations;

    internal static string CaptureDirectoryName(long captureId, string name)
    {
        if (captureId <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(captureId));
        }
        if (!IsSafeName(name))
        {
            throw new ArgumentException(
                "The targeted-probe name is not path safe.",
                nameof(name)
            );
        }
        return $"capture-{captureId:D6}-{name}";
    }

    internal static SolMetalTargetedProbeSelector[] ParseEnvironment(
        string? value,
        out string? failure
    )
    {
        failure = null;
        if (string.IsNullOrWhiteSpace(value))
        {
            return [];
        }
        if (value.Length > MaximumEnvironmentBytes)
        {
            failure = $"configuration exceeds {MaximumEnvironmentBytes} characters";
            return [];
        }

        try
        {
            using JsonDocument document = JsonDocument.Parse(
                value,
                new JsonDocumentOptions
                {
                    AllowTrailingCommas = false,
                    CommentHandling = JsonCommentHandling.Disallow,
                    MaxDepth = 8,
                }
            );
            if (document.RootElement.ValueKind != JsonValueKind.Array)
            {
                throw new FormatException("the root must be a JSON array");
            }
            int count = document.RootElement.GetArrayLength();
            if (count > MaximumSelectors)
            {
                throw new FormatException(
                    $"at most {MaximumSelectors} selectors are allowed"
                );
            }

            List<SolMetalTargetedProbeSelector> selectors = new(count);
            HashSet<string> names = new(StringComparer.Ordinal);
            int index = 0;
            foreach (JsonElement element in document.RootElement.EnumerateArray())
            {
                SolMetalTargetedProbeSelector selector = ParseSelector(
                    element,
                    index
                );
                if (!names.Add(selector.Name))
                {
                    throw new FormatException(
                        $"selector {index} repeats name '{selector.Name}'"
                    );
                }
                selectors.Add(selector);
                index++;
            }
            return selectors.ToArray();
        }
        catch (Exception exception) when (
            exception is JsonException or FormatException or
            InvalidOperationException or OverflowException
        )
        {
            failure = exception.Message;
            return [];
        }
    }

    /// <summary>
    /// Exercises parsing, structural matching, maturity, ordered duplicate
    /// keys, occurrence handling, reset, expiry, and safe artifact naming.
    /// </summary>
    internal static void Validate()
    {
        string key = new('a', 64);
        string secondKey = new('b', 64);
        string json = "[" +
            "{\"name\":\"p27-mip0\",\"programKey\":\"" + key +
            "\",\"colorTarget\":{\"slot\":0,\"width\":400," +
            "\"height\":224,\"format\":\"Rg11B10Float\"}," +
            "\"depthTarget\":{\"presence\":\"none\"}," +
            "\"minPresentations\":500,\"minColorDraws\":128}," +
            "{\"name\":\"p27-mip1\",\"programKey\":\"" + key +
            "\",\"colorTarget\":{\"slot\":0,\"width\":200," +
            "\"height\":112,\"format\":\"Rg11B10Float\"}," +
            "\"depthTarget\":{\"presence\":\"present\"," +
            "\"width\":200,\"height\":112," +
            "\"format\":\"Depth32Float\"}," +
            "\"minDepthPasses\":128,\"minDepthClears\":8}," +
            "{\"name\":\"p45-gbuffer\",\"programKey\":\"" +
            secondKey + "\",\"colorTarget\":{\"slot\":5," +
            "\"width\":1600,\"height\":896," +
            "\"format\":\"Rg11B10Float\"}," +
            "\"eligibleOccurrence\":2,\"maxWaitPresentations\":50}" +
            "]";
        SolMetalTargetedProbeSelector[] parsed = ParseEnvironment(
            json,
            out string? failure
        );
        Require(failure is null && parsed.Length == 3, "valid JSON was rejected");
        Require(
            parsed[0].ProgramKey == parsed[1].ProgramKey,
            "duplicate stable keys were collapsed"
        );

        SolMetalTargetedProbeDraw early = Draw(
            key,
            900,
            Color(0, 64, 64, draws: 1_000),
            null
        );
        Require(
            !parsed[0].TrySelect(early) && !parsed[1].TrySelect(early),
            "an early 64x64 pass consumed a dimension-qualified selector"
        );

        SolMetalTargetedProbeDraw immature = Draw(
            key,
            499,
            Color(0, 400, 224, draws: 127),
            null
        );
        Require(
            !parsed[0].TrySelect(immature),
            "an immature color target consumed a selector"
        );
        SolMetalTargetedProbeDraw mip0 = Draw(
            key,
            500,
            Color(0, 400, 224, draws: 128),
            null
        );
        Require(
            parsed[0].TrySelect(mip0) && !parsed[1].TrySelect(mip0),
            "the exact 400x224 no-depth target was not isolated"
        );

        SolMetalTargetedProbeDepthTarget matureDepth = new(
            200,
            112,
            SolMetalNativeBridge.GalTextureFormat.Depth32Float,
            128,
            8
        );
        SolMetalTargetedProbeDraw wrongDepth = Draw(
            key,
            500,
            Color(0, 200, 112),
            matureDepth with { Width = 201 }
        );
        Require(
            !parsed[1].TrySelect(wrongDepth),
            "a wrong depth target consumed a selector"
        );
        SolMetalTargetedProbeDraw mip1 = Draw(
            key,
            500,
            Color(0, 200, 112),
            matureDepth
        );
        Require(
            parsed[1].TrySelect(mip1),
            "the exact 200x112 mature depth target did not match"
        );

        SolMetalTargetedProbeDraw p45WrongSlot = Draw(
            secondKey,
            600,
            Color(0, 1600, 896),
            null
        );
        SolMetalTargetedProbeDraw p45WrongFormat = Draw(
            secondKey,
            600,
            Color(5, 1600, 896) with
            {
                Format = SolMetalNativeBridge.GalTextureFormat.Rgba16Float,
            },
            null
        );
        SolMetalTargetedProbeDraw p45 = Draw(
            secondKey,
            600,
            Color(5, 1600, 896),
            null
        );
        Require(
            !parsed[2].TrySelect(p45WrongSlot) &&
            !parsed[2].TrySelect(p45WrongFormat) &&
            !parsed[2].TrySelect(p45) && parsed[2].TrySelect(p45),
            "eligible occurrence advanced on an ineligible draw or lost order"
        );

        SolMetalTargetedProbeSelector reset = parsed[2].ClonePending();
        Require(
            !reset.TrySelect(p45) && reset.TrySelect(p45),
            "cloning did not reset the eligible occurrence"
        );
        Require(
            !reset.IsExpired(149, 100) && reset.IsExpired(150, 100),
            "the relative presentation timeout changed"
        );

        string d16ReplayJson = "[{\"name\":\"d16-replay-128\"," +
            "\"programKey\":\"" + secondKey +
            "\",\"colorTarget\":{\"slot\":0,\"width\":1600," +
            "\"height\":896,\"format\":\"Rg11B10Float\"}," +
            "\"depthTarget\":{\"presence\":\"present\"," +
            "\"width\":1600,\"height\":896," +
            "\"format\":\"Depth16Unorm\"}," +
            "\"minDepthPasses\":128,\"minDepthClears\":8," +
            "\"d16Replay\":{\"rawTag\":128," +
            "\"expectedCode\":33796,\"minWriterCodeCount\":1}," +
            "\"maxWaitPresentations\":5000}]";
        SolMetalTargetedProbeSelector[] d16ReplaySelectors = ParseEnvironment(
            d16ReplayJson,
            out failure
        );
        Require(
            failure is null && d16ReplaySelectors.Length == 1 &&
            d16ReplaySelectors[0].RequiresD16Replay,
            "a valid D16 replay selector was rejected"
        );
        SolMetalTargetedProbeDepthTarget matureD16 = new(
            1600,
            896,
            SolMetalNativeBridge.GalTextureFormat.Depth16Unorm,
            128,
            8
        );
        SolMetalTargetedProbeDraw replayWithoutMetadata = Draw(
            secondKey,
            600,
            Color(0, 1600, 896),
            matureD16
        );
        SolMetalTargetedProbeDraw replayWrongTag = Draw(
            secondKey,
            600,
            Color(0, 1600, 896),
            matureD16,
            new SolMetalTargetedProbeD16Replay(0, 32_768, true, 100)
        );
        SolMetalTargetedProbeDraw replayWrongTarget = Draw(
            secondKey,
            600,
            Color(0, 1600, 896),
            matureD16,
            new SolMetalTargetedProbeD16Replay(128, 33_796, false, 100)
        );
        SolMetalTargetedProbeDraw replay128 = Draw(
            secondKey,
            600,
            Color(0, 1600, 896),
            matureD16,
            new SolMetalTargetedProbeD16Replay(128, 33_796, true, 100)
        );
        Require(
            !d16ReplaySelectors[0].TrySelect(replayWithoutMetadata) &&
            !d16ReplaySelectors[0].TrySelect(replayWrongTag) &&
            !d16ReplaySelectors[0].TrySelect(replayWrongTarget) &&
            d16ReplaySelectors[0].TrySelect(replay128),
            "the D16 replay constraint consumed a wrong replay or missed " +
            "the matching same-target replay"
        );

        string invalidD16Replay = "[{\"name\":\"bad-d16\"," +
            "\"programKey\":\"" + secondKey +
            "\",\"colorTarget\":{\"slot\":0,\"width\":1," +
            "\"height\":1,\"format\":\"Rgba8Unorm\"}," +
            "\"depthTarget\":{\"presence\":\"present\"," +
            "\"width\":1,\"height\":1," +
            "\"format\":\"Depth32Float\"}," +
            "\"d16Replay\":{\"rawTag\":128," +
            "\"expectedCode\":33796}}]";
        Require(
            ParseEnvironment(invalidD16Replay, out failure).Length == 0 &&
            failure is not null,
            "a D16 replay constraint accepted a non-D16 target"
        );

        string firstDirectory = CaptureDirectoryName(1, "p45-gbuffer");
        string secondDirectory = CaptureDirectoryName(2, "p45-gbuffer");
        Require(
            firstDirectory == "capture-000001-p45-gbuffer" &&
            firstDirectory != secondDirectory &&
            Path.GetFileName(firstDirectory) == firstDirectory,
            "capture directories are not unique and path safe"
        );

        string malformed = "[{\"name\":\"bad/name\",\"programKey\":\"" +
            key + "\",\"colorTarget\":{\"slot\":0,\"width\":1," +
            "\"height\":1,\"format\":\"Rgba8Unorm\"}}]";
        Require(
            ParseEnvironment(malformed, out failure).Length == 0 &&
            failure is not null,
            "a traversal-capable selector name was accepted"
        );
        Require(
            ParseEnvironment("{", out failure).Length == 0 &&
            failure is not null,
            "malformed JSON was accepted"
        );
        string unknown = "[{\"name\":\"unknown\",\"programKey\":\"" +
            key + "\",\"colorTarget\":{\"slot\":0,\"width\":1," +
            "\"height\":1,\"format\":\"Rgba8Unorm\"},\"typo\":1}]";
        Require(
            ParseEnvironment(unknown, out failure).Length == 0 &&
            failure is not null,
            "an unknown selector property was accepted"
        );
        string tooMany = "[" + string.Join(
            ",",
            Enumerable.Range(0, MaximumSelectors + 1).Select(index =>
                "{\"name\":\"s" + index + "\",\"programKey\":\"" +
                key + "\",\"colorTarget\":{\"slot\":0,\"width\":1," +
                "\"height\":1,\"format\":\"Rgba8Unorm\"}}"
            )
        ) + "]";
        Require(
            ParseEnvironment(tooMany, out failure).Length == 0 &&
            failure is not null,
            "an oversized selector array was accepted"
        );
    }

    private bool Matches(
        in SolMetalTargetedProbeDraw draw,
        out SolMetalTargetedProbeColorTarget colorTarget
    )
    {
        colorTarget = default;
        if (!string.Equals(
                draw.ProgramKey,
                ProgramKey,
                StringComparison.Ordinal
            ))
        {
            return false;
        }

        bool foundColor = false;
        foreach (SolMetalTargetedProbeColorTarget candidate in draw.ColorTargets)
        {
            if (candidate.Slot == ColorSlot)
            {
                colorTarget = candidate;
                foundColor = candidate.Width == ColorWidth &&
                    candidate.Height == ColorHeight &&
                    candidate.Format == ColorFormat;
                break;
            }
        }
        if (!foundColor)
        {
            return false;
        }

        return _depthPresence switch
        {
            DepthPresence.Any => true,
            DepthPresence.None => draw.DepthTarget is null,
            DepthPresence.Present => draw.DepthTarget is
                SolMetalTargetedProbeDepthTarget depth &&
                depth.Width == _depthWidth && depth.Height == _depthHeight &&
                depth.Format == _depthFormat,
            _ => false,
        };
    }

    private static SolMetalTargetedProbeSelector ParseSelector(
        JsonElement element,
        int index
    )
    {
        RequireObject(element, $"selector {index}");
        EnsureOnlyProperties(
            element,
            $"selector {index}",
            "name",
            "programKey",
            "colorTarget",
            "depthTarget",
            "minPresentations",
            "minColorDraws",
            "minColorClears",
            "minDepthPasses",
            "minDepthClears",
            "d16Replay",
            "eligibleOccurrence",
            "maxWaitPresentations"
        );

        string name = element.TryGetProperty("name", out JsonElement nameElement)
            ? ReadString(nameElement, $"selector {index} name")
            : $"selector-{index + 1:D2}";
        if (!IsSafeName(name))
        {
            throw new FormatException(
                $"selector {index} name must contain 1-{MaximumNameLength} " +
                "lowercase letters, digits, dots, underscores, or hyphens"
            );
        }

        string key = ReadString(
            Required(element, "programKey", $"selector {index}"),
            $"selector {index} programKey"
        );
        if (!SolMetalRenderProgramIdentity.IsKey(key))
        {
            throw new FormatException(
                $"selector {index} programKey must be SHA-256 hex"
            );
        }
        key = key.ToLowerInvariant();

        JsonElement color = Required(element, "colorTarget", $"selector {index}");
        RequireObject(color, $"selector {index} colorTarget");
        EnsureOnlyProperties(
            color,
            $"selector {index} colorTarget",
            "slot",
            "width",
            "height",
            "format"
        );
        int colorSlot = checked((int)ReadInteger(
            Required(color, "slot", $"selector {index} colorTarget"),
            $"selector {index} colorTarget slot",
            0,
            7
        ));
        int colorWidth = ReadDimension(color, "width", index, "colorTarget");
        int colorHeight = ReadDimension(color, "height", index, "colorTarget");
        SolMetalNativeBridge.GalTextureFormat colorFormat = ReadFormat(
            Required(color, "format", $"selector {index} colorTarget"),
            $"selector {index} colorTarget format"
        );
        if (IsDepthFormat(colorFormat))
        {
            throw new FormatException(
                $"selector {index} colorTarget format must be a color format"
            );
        }

        DepthPresence depthPresence = DepthPresence.Any;
        int depthWidth = 0;
        int depthHeight = 0;
        SolMetalNativeBridge.GalTextureFormat depthFormat = 0;
        if (element.TryGetProperty("depthTarget", out JsonElement depth))
        {
            RequireObject(depth, $"selector {index} depthTarget");
            EnsureOnlyProperties(
                depth,
                $"selector {index} depthTarget",
                "presence",
                "width",
                "height",
                "format"
            );
            string presence = ReadString(
                Required(depth, "presence", $"selector {index} depthTarget"),
                $"selector {index} depthTarget presence"
            );
            depthPresence = presence switch
            {
                "any" => DepthPresence.Any,
                "none" => DepthPresence.None,
                "present" => DepthPresence.Present,
                _ => throw new FormatException(
                    $"selector {index} depthTarget presence must be any, " +
                    "none, or present"
                ),
            };
            if (depthPresence == DepthPresence.Present)
            {
                depthWidth = ReadDimension(depth, "width", index, "depthTarget");
                depthHeight = ReadDimension(depth, "height", index, "depthTarget");
                depthFormat = ReadFormat(
                    Required(depth, "format", $"selector {index} depthTarget"),
                    $"selector {index} depthTarget format"
                );
                if (!IsDepthFormat(depthFormat))
                {
                    throw new FormatException(
                        $"selector {index} depthTarget format must be a depth format"
                    );
                }
            }
            else if (depth.TryGetProperty("width", out _) ||
                     depth.TryGetProperty("height", out _) ||
                     depth.TryGetProperty("format", out _))
            {
                throw new FormatException(
                    $"selector {index} depthTarget dimensions and format " +
                    "require presence 'present'"
                );
            }
        }

        long minPresentations = ReadOptionalCounter(
            element,
            "minPresentations",
            index
        );
        long minColorDraws = ReadOptionalCounter(element, "minColorDraws", index);
        long minColorClears = ReadOptionalCounter(
            element,
            "minColorClears",
            index
        );
        long minDepthPasses = ReadOptionalCounter(
            element,
            "minDepthPasses",
            index
        );
        long minDepthClears = ReadOptionalCounter(
            element,
            "minDepthClears",
            index
        );
        if ((minDepthPasses > 0 || minDepthClears > 0) &&
            depthPresence != DepthPresence.Present)
        {
            throw new FormatException(
                $"selector {index} depth maturity requires a present depth target"
            );
        }

        uint? d16ReplayRawTag = null;
        int? d16ReplayExpectedCode = null;
        ulong d16ReplayMinimumWriterCodeCount = 0;
        if (element.TryGetProperty("d16Replay", out JsonElement d16Replay))
        {
            RequireObject(d16Replay, $"selector {index} d16Replay");
            EnsureOnlyProperties(
                d16Replay,
                $"selector {index} d16Replay",
                "rawTag",
                "expectedCode",
                "minWriterCodeCount"
            );
            if (depthPresence != DepthPresence.Present ||
                depthFormat !=
                    SolMetalNativeBridge.GalTextureFormat.Depth16Unorm)
            {
                throw new FormatException(
                    $"selector {index} d16Replay requires a present " +
                    "Depth16Unorm depth target"
                );
            }
            d16ReplayRawTag = checked((uint)ReadInteger(
                Required(d16Replay, "rawTag", $"selector {index} d16Replay"),
                $"selector {index} d16Replay rawTag",
                0,
                uint.MaxValue
            ));
            d16ReplayExpectedCode = checked((int)ReadInteger(
                Required(
                    d16Replay,
                    "expectedCode",
                    $"selector {index} d16Replay"
                ),
                $"selector {index} d16Replay expectedCode",
                ushort.MinValue,
                ushort.MaxValue
            ));
            d16ReplayMinimumWriterCodeCount = checked((ulong)(
                d16Replay.TryGetProperty(
                    "minWriterCodeCount",
                    out JsonElement minimumWriterCount
                )
                    ? ReadInteger(
                        minimumWriterCount,
                        $"selector {index} d16Replay minWriterCodeCount",
                        1,
                        MaximumCounter
                    )
                    : 1
            ));
        }
        int eligibleOccurrence = checked((int)ReadOptionalInteger(
            element,
            "eligibleOccurrence",
            1,
            1,
            MaximumEligibleOccurrence,
            index
        ));
        long maxWaitPresentations = ReadOptionalInteger(
            element,
            "maxWaitPresentations",
            0,
            0,
            MaximumCounter,
            index
        );

        return new SolMetalTargetedProbeSelector(
            name,
            key,
            colorSlot,
            colorWidth,
            colorHeight,
            colorFormat,
            depthPresence,
            depthWidth,
            depthHeight,
            depthFormat,
            minPresentations,
            minColorDraws,
            minColorClears,
            minDepthPasses,
            minDepthClears,
            d16ReplayRawTag,
            d16ReplayExpectedCode,
            d16ReplayMinimumWriterCodeCount,
            eligibleOccurrence,
            maxWaitPresentations
        );
    }

    private static JsonElement Required(
        JsonElement element,
        string property,
        string context
    )
    {
        if (!element.TryGetProperty(property, out JsonElement value))
        {
            throw new FormatException($"{context} is missing '{property}'");
        }
        return value;
    }

    private static void RequireObject(JsonElement element, string context)
    {
        if (element.ValueKind != JsonValueKind.Object)
        {
            throw new FormatException($"{context} must be a JSON object");
        }
    }

    private static void EnsureOnlyProperties(
        JsonElement element,
        string context,
        params string[] allowed
    )
    {
        HashSet<string> seen = new(StringComparer.Ordinal);
        foreach (JsonProperty property in element.EnumerateObject())
        {
            if (!allowed.Contains(property.Name, StringComparer.Ordinal))
            {
                throw new FormatException(
                    $"{context} has unknown property '{property.Name}'"
                );
            }
            if (!seen.Add(property.Name))
            {
                throw new FormatException(
                    $"{context} repeats property '{property.Name}'"
                );
            }
        }
    }

    private static string ReadString(JsonElement element, string context)
    {
        if (element.ValueKind != JsonValueKind.String ||
            element.GetString() is not string value)
        {
            throw new FormatException($"{context} must be a string");
        }
        return value;
    }

    private static int ReadDimension(
        JsonElement element,
        string property,
        int selectorIndex,
        string target
    ) => checked((int)ReadInteger(
        Required(element, property, $"selector {selectorIndex} {target}"),
        $"selector {selectorIndex} {target} {property}",
        1,
        MaximumDimension
    ));

    private static SolMetalNativeBridge.GalTextureFormat ReadFormat(
        JsonElement element,
        string context
    )
    {
        string value = ReadString(element, context);
        if (!Enum.TryParse(
                value,
                ignoreCase: true,
                out SolMetalNativeBridge.GalTextureFormat format
            ) || !Enum.IsDefined(format))
        {
            throw new FormatException($"{context} is not a known SolMetal format");
        }
        return format;
    }

    private static long ReadOptionalCounter(
        JsonElement element,
        string property,
        int selectorIndex
    ) => ReadOptionalInteger(
        element,
        property,
        0,
        0,
        MaximumCounter,
        selectorIndex
    );

    private static long ReadOptionalInteger(
        JsonElement element,
        string property,
        long defaultValue,
        long minimum,
        long maximum,
        int selectorIndex
    ) => element.TryGetProperty(property, out JsonElement value)
        ? ReadInteger(
            value,
            $"selector {selectorIndex} {property}",
            minimum,
            maximum
        )
        : defaultValue;

    private static long ReadInteger(
        JsonElement element,
        string context,
        long minimum,
        long maximum
    )
    {
        if (element.ValueKind != JsonValueKind.Number ||
            !element.TryGetInt64(out long value) ||
            value < minimum || value > maximum)
        {
            throw new FormatException(
                $"{context} must be an integer from {minimum} to {maximum}"
            );
        }
        return value;
    }

    private static bool IsDepthFormat(
        SolMetalNativeBridge.GalTextureFormat format
    ) => format is
        SolMetalNativeBridge.GalTextureFormat.Depth16Unorm or
        SolMetalNativeBridge.GalTextureFormat.Depth32Float or
        SolMetalNativeBridge.GalTextureFormat.Depth32FloatStencil8 or
        SolMetalNativeBridge.GalTextureFormat.D24UnormStencil8;

    private static bool IsSafeName(string value)
    {
        if (value.Length is < 1 or > MaximumNameLength)
        {
            return false;
        }
        foreach (char character in value)
        {
            if (!((character >= 'a' && character <= 'z') ||
                  (character >= '0' && character <= '9') ||
                  character is '.' or '_' or '-'))
            {
                return false;
            }
        }
        return true;
    }

    private static SolMetalTargetedProbeColorTarget Color(
        int slot,
        int width,
        int height,
        long draws = 0,
        long clears = 0
    ) => new(
        slot,
        width,
        height,
        SolMetalNativeBridge.GalTextureFormat.Rg11B10Float,
        draws,
        clears
    );

    private static SolMetalTargetedProbeDraw Draw(
        string key,
        long presentation,
        SolMetalTargetedProbeColorTarget color,
        SolMetalTargetedProbeDepthTarget? depth,
        SolMetalTargetedProbeD16Replay? d16Replay = null
    ) => new(key, presentation, [color], depth, d16Replay);

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(
                $"SolMetal targeted-probe selector validation failed: {message}."
            );
        }
    }
}
