#nullable enable

using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Security.Cryptography;

namespace Ryujinx.Headless;

/// <summary>
/// Creates a process-independent identity for a translated render-program
/// source pair. The key intentionally describes the source SPIR-V rather than
/// a runtime creation index or translator-formatted MSL.
/// </summary>
internal static class SolMetalRenderProgramIdentity
{
    private const int Sha256HexLength = 64;
    private const byte VertexStageTag = 1;
    private const byte FragmentStageTag = 2;

    // The terminating zero and version suffix make this hash namespace
    // independent of other SolMetal SHA-256 uses and future identity formats.
    private static ReadOnlySpan<byte> Domain =>
        "SolMetal.RenderProgramIdentity.v1\0"u8;

    internal static string CreateKey(
        ReadOnlySpan<byte> vertexSpirv,
        ReadOnlySpan<byte> fragmentSpirv
    )
    {
        using IncrementalHash hash = IncrementalHash.CreateHash(
            HashAlgorithmName.SHA256
        );
        hash.AppendData(Domain);
        AppendStage(hash, VertexStageTag, vertexSpirv);
        AppendStage(hash, FragmentStageTag, fragmentSpirv);
        return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }

    internal static HashSet<string> ParseEnvironmentKeys(string? value)
    {
        HashSet<string> keys = new(StringComparer.Ordinal);
        if (string.IsNullOrWhiteSpace(value))
        {
            return keys;
        }

        foreach (string candidate in value.Split(','))
        {
            ReadOnlySpan<char> token = candidate.AsSpan().Trim();
            if (IsKey(token))
            {
                keys.Add(token.ToString().ToLowerInvariant());
            }
        }

        return keys;
    }

    internal static string[] ParseEnvironmentKeySequence(
        string? value,
        int expectedCount
    )
    {
        if (expectedCount <= 0 || string.IsNullOrWhiteSpace(value))
        {
            return [];
        }

        string[] candidates = value.Split(',');
        if (candidates.Length != expectedCount)
        {
            return [];
        }

        string[] keys = new string[expectedCount];
        for (int index = 0; index < candidates.Length; index++)
        {
            ReadOnlySpan<char> token = candidates[index].AsSpan().Trim();
            if (!IsKey(token))
            {
                return [];
            }
            keys[index] = token.ToString().ToLowerInvariant();
        }
        return keys;
    }

    /// <summary>
    /// Exercises the key framing and environment parser without requiring a
    /// renderer or native Metal session. Throws when any invariant regresses.
    /// </summary>
    internal static void Validate()
    {
        byte[] vertex = [0x03, 0x02, 0x23, 0x07, 0x01];
        byte[] fragment = [0x03, 0x02, 0x23, 0x07, 0x02, 0xff];
        string key = CreateKey(vertex, fragment);

        Require(
            key ==
                "a0252588542c71573b73910d0ede7f5c75759d4976135fb6d154d40ae53c0f95",
            "the version-one identity format changed"
        );
        Require(
            IsKey(key) && key == key.ToLowerInvariant(),
            "the generated key is not lowercase SHA-256 hex"
        );
        Require(
            key == CreateKey(vertex, fragment),
            "the same source pair produced different keys"
        );
        Require(
            key != CreateKey(fragment, vertex),
            "vertex and fragment stage order was not separated"
        );
        Require(
            CreateKey([0x01], [0x02, 0x03]) !=
                CreateKey([0x01, 0x02], [0x03]),
            "stage lengths were not framed"
        );
        Require(
            key != CreateKey(vertex, [.. fragment, 0x00]),
            "fragment source changes did not affect the key"
        );

        string secondKey = CreateKey([0x01, 0x02], [0x03, 0x04]);
        string invalidHex = new('g', Sha256HexLength);
        HashSet<string> parsed = ParseEnvironmentKeys(
            $"{key.ToUpperInvariant()}, {secondKey}, {key}, " +
            $"{key[..^1]}, {invalidHex}, 0x{key},,"
        );
        Require(
            parsed.Count == 2 && parsed.Contains(key) &&
                parsed.Contains(secondKey),
            "the environment key parser accepted malformed input or failed " +
                "to normalize valid input"
        );
        Require(
            ParseEnvironmentKeys(null).Count == 0 &&
                ParseEnvironmentKeys(" , \t, ").Count == 0,
            "the environment key parser accepted empty input"
        );
        string[] sequence = ParseEnvironmentKeySequence(
            $"{key.ToUpperInvariant()}, {secondKey}",
            expectedCount: 2
        );
        Require(
            sequence.Length == 2 && sequence[0] == key &&
                sequence[1] == secondKey,
            "the ordered environment key parser lost order or normalization"
        );
        Require(
            ParseEnvironmentKeySequence(key, expectedCount: 2).Length == 0 &&
                ParseEnvironmentKeySequence(
                    $"{key},not-a-key",
                    expectedCount: 2
                ).Length == 0,
            "the ordered environment key parser accepted an invalid sequence"
        );
    }

    private static void AppendStage(
        IncrementalHash hash,
        byte stageTag,
        ReadOnlySpan<byte> source
    )
    {
        Span<byte> frame = stackalloc byte[sizeof(byte) + sizeof(ulong)];
        frame[0] = stageTag;
        BinaryPrimitives.WriteUInt64BigEndian(
            frame[sizeof(byte)..],
            checked((ulong)source.Length)
        );
        hash.AppendData(frame);
        hash.AppendData(source);
    }

    internal static bool IsKey(ReadOnlySpan<char> value)
    {
        if (value.Length != Sha256HexLength)
        {
            return false;
        }

        foreach (char character in value)
        {
            if (!((character >= '0' && character <= '9') ||
                  (character >= 'a' && character <= 'f') ||
                  (character >= 'A' && character <= 'F')))
            {
                return false;
            }
        }

        return true;
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(
                $"SolMetal render-program identity validation failed: {message}."
            );
        }
    }
}
