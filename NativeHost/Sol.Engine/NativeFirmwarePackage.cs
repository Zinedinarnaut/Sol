#nullable enable

using Ryujinx.Common.Configuration;
using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;

namespace Ryujinx.Headless;

/// <summary>
/// Normalizes firmware input before LibHac inspects it. In particular, ZIP
/// entries are streamed to a private staging directory instead of being copied
/// into one large managed MemoryStream per NCA. This keeps firmware setup
/// bounded and uses the same filesystem path as an extracted firmware folder.
/// </summary>
internal sealed class NativeFirmwarePackage : IDisposable
{
    private const int MaximumArchiveEntries = 4_096;
    private const long MaximumSingleNcaBytes = 2L * 1_024 * 1_024 * 1_024;
    private const long MaximumExpandedBytes = 8L * 1_024 * 1_024 * 1_024;
    private const long MinimumFreeSpaceReserveBytes = 256L * 1_024 * 1_024;
    private static readonly TimeSpan StaleStagingAge = TimeSpan.FromHours(24);

    private readonly string? _stagingDirectory;

    public string SourcePath { get; }
    public int NcaCount { get; }
    public bool WasStaged => _stagingDirectory is not null;

    private NativeFirmwarePackage(
        string sourcePath,
        string? stagingDirectory,
        int ncaCount
    )
    {
        SourcePath = sourcePath;
        _stagingDirectory = stagingDirectory;
        NcaCount = ncaCount;
    }

    public static NativeFirmwarePackage Prepare(string sourcePath)
    {
        if (Directory.Exists(sourcePath))
        {
            string resolvedDirectory = ResolveFirmwareDirectory(sourcePath);
            return new NativeFirmwarePackage(
                resolvedDirectory,
                stagingDirectory: null,
                CountDirectNcas(resolvedDirectory)
            );
        }

        if (!File.Exists(sourcePath))
        {
            throw new FileNotFoundException("The selected firmware source no longer exists.");
        }

        string extension = Path.GetExtension(sourcePath);
        if (extension.Equals(".xci", StringComparison.OrdinalIgnoreCase))
        {
            return new NativeFirmwarePackage(sourcePath, stagingDirectory: null, ncaCount: 0);
        }

        if (!extension.Equals(".zip", StringComparison.OrdinalIgnoreCase))
        {
            throw new InvalidDataException(
                "Choose a firmware ZIP, an untrimmed XCI, or an extracted firmware folder."
            );
        }

        return StageZip(sourcePath);
    }

    public void Dispose()
    {
        if (_stagingDirectory is null || !Directory.Exists(_stagingDirectory))
        {
            return;
        }

        try
        {
            Directory.Delete(_stagingDirectory, recursive: true);
        }
        catch
        {
            // A stale staging directory is safe to remove on the next launch;
            // cleanup must not turn a completed installation into a failure.
        }
    }

    private static NativeFirmwarePackage StageZip(string sourcePath)
    {
        string stagingRoot = Path.Combine(
            AppDataManager.BaseDirPath,
            "cache",
            "firmware-staging"
        );
        Directory.CreateDirectory(stagingRoot);
        RemoveStaleStagingDirectories(stagingRoot);

        string stagingDirectory = Path.Combine(stagingRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stagingDirectory);

        try
        {
            using ZipArchive archive = ZipFile.OpenRead(sourcePath);
            long expandedBytes = 0;
            HashSet<string> destinations = new(StringComparer.OrdinalIgnoreCase);
            List<(ZipArchiveEntry Entry, string Destination)> ncaEntries = [];

            foreach (ZipArchiveEntry entry in archive.Entries)
            {
                if (!TryGetNcaDestination(entry.FullName, out string? relativeDestination))
                {
                    continue;
                }

                if (ncaEntries.Count >= MaximumArchiveEntries)
                {
                    throw new InvalidDataException(
                        $"The firmware package contains more than {MaximumArchiveEntries} NCA files."
                    );
                }

                if (entry.Length <= 0 || entry.Length > MaximumSingleNcaBytes)
                {
                    throw new InvalidDataException(
                        $"Firmware archive '{Path.GetFileName(entry.FullName)}' has an invalid size."
                    );
                }

                expandedBytes = checked(expandedBytes + entry.Length);
                if (expandedBytes > MaximumExpandedBytes)
                {
                    throw new InvalidDataException(
                        "The expanded firmware package is larger than Sol's 8 GiB safety limit."
                    );
                }

                if (!destinations.Add(relativeDestination!))
                {
                    throw new InvalidDataException(
                        $"The firmware package contains duplicate archive '{relativeDestination}'."
                    );
                }

                ncaEntries.Add((entry, relativeDestination!));
            }

            if (ncaEntries.Count == 0)
            {
                throw new InvalidDataException(
                    "The selected ZIP contains no firmware NCA files."
                );
            }

            EnsureStagingSpace(stagingDirectory, expandedBytes);

            foreach ((ZipArchiveEntry entry, string relativeDestination) in ncaEntries)
            {
                string destination = Path.Combine(stagingDirectory, relativeDestination);
                string? parent = Path.GetDirectoryName(destination);
                if (parent is not null)
                {
                    Directory.CreateDirectory(parent);
                }

                using Stream input = entry.Open();
                using FileStream output = new(
                    destination,
                    FileMode.CreateNew,
                    FileAccess.Write,
                    FileShare.None,
                    bufferSize: 1_024 * 1_024,
                    FileOptions.SequentialScan
                );
                input.CopyTo(output);
                output.Flush();

                if (output.Length != entry.Length)
                {
                    throw new InvalidDataException(
                        $"Firmware archive '{Path.GetFileName(entry.FullName)}' was truncated while staging."
                    );
                }
            }

            return new NativeFirmwarePackage(
                stagingDirectory,
                stagingDirectory,
                ncaEntries.Count
            );
        }
        catch
        {
            try
            {
                Directory.Delete(stagingDirectory, recursive: true);
            }
            catch
            {
            }

            throw;
        }
    }

    private static string ResolveFirmwareDirectory(string sourcePath)
    {
        if (CountDirectNcas(sourcePath) > 0)
        {
            return sourcePath;
        }

        EnumerationOptions options = new()
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            ReturnSpecialDirectories = false,
            MaxRecursionDepth = 4,
            AttributesToSkip = FileAttributes.ReparsePoint,
        };

        IEnumerable<string?> fileParents = Directory
            .EnumerateFiles(sourcePath, "*", options)
            .Where(path => IsNcaName(Path.GetFileName(path)))
            .Select(Path.GetDirectoryName);
        IEnumerable<string?> fragmentedParents = Directory
            .EnumerateDirectories(sourcePath, "*", options)
            .Where(path => IsNcaName(Path.GetFileName(path)))
            .Where(path => File.Exists(Path.Combine(path, "00")))
            .Select(Path.GetDirectoryName);

        string[] candidateDirectories = fileParents
            .Concat(fragmentedParents)
            .Where(path => path is not null)
            .Select(path => path!)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Take(2)
            .ToArray();

        if (candidateDirectories.Length == 1 && CountDirectNcas(candidateDirectories[0]) > 0)
        {
            return candidateDirectories[0];
        }

        throw new InvalidDataException(
            "The selected folder does not directly contain an extracted firmware package."
        );
    }

    private static int CountDirectNcas(string directory)
    {
        int count = 0;

        foreach (string path in Directory.EnumerateFileSystemEntries(
                     directory,
                     "*",
                     SearchOption.TopDirectoryOnly
                 ))
        {
            string name = Path.GetFileName(path);
            bool isDirectNca = File.Exists(path) && IsNcaName(name);
            bool isFragmentedNca = Directory.Exists(path) &&
                IsNcaName(name) &&
                File.Exists(Path.Combine(path, "00"));

            if (!isDirectNca && !isFragmentedNca)
            {
                continue;
            }

            if (++count > MaximumArchiveEntries)
            {
                throw new InvalidDataException(
                    $"The firmware folder contains more than {MaximumArchiveEntries} NCA files."
                );
            }
        }

        return count;
    }

    private static void EnsureStagingSpace(string stagingDirectory, long expandedBytes)
    {
        long? availableBytes = null;
        try
        {
            string? root = Path.GetPathRoot(Path.GetFullPath(stagingDirectory));
            if (!string.IsNullOrEmpty(root))
            {
                DriveInfo drive = new(root);
                if (drive.IsReady)
                {
                    availableBytes = drive.AvailableFreeSpace;
                }
            }
        }
        catch (Exception exception) when (
            exception is ArgumentException or IOException or UnauthorizedAccessException
        )
        {
            // Some mounted volumes do not expose free-space information. The
            // streaming copy will still report a normal I/O error if they fill.
        }

        long requiredBytes = checked(expandedBytes + MinimumFreeSpaceReserveBytes);
        if (availableBytes is not long available || available >= requiredBytes)
        {
            return;
        }

        long requiredMiB = (requiredBytes + (1L << 20) - 1) >> 20;
        long availableMiB = available >> 20;
        throw new IOException(
            $"Firmware staging needs about {requiredMiB} MiB free, but this disk has " +
            $"only {availableMiB} MiB available."
        );
    }

    private static void RemoveStaleStagingDirectories(string stagingRoot)
    {
        DateTime cutoff = DateTime.UtcNow - StaleStagingAge;

        foreach (string directory in Directory.EnumerateDirectories(stagingRoot))
        {
            string name = Path.GetFileName(directory);
            FileAttributes attributes;
            try
            {
                attributes = File.GetAttributes(directory);
            }
            catch (Exception exception) when (
                exception is IOException or UnauthorizedAccessException
            )
            {
                continue;
            }

            if ((attributes & FileAttributes.ReparsePoint) != 0 ||
                !Guid.TryParseExact(name, "N", out _) ||
                Directory.GetLastWriteTimeUtc(directory) >= cutoff)
            {
                continue;
            }

            try
            {
                Directory.Delete(directory, recursive: true);
            }
            catch
            {
                // A concurrent or permission-blocked directory is harmless;
                // it can be retried by a later firmware operation.
            }
        }
    }

    private static bool TryGetNcaDestination(
        string entryName,
        out string? relativeDestination
    )
    {
        relativeDestination = null;
        string normalizedEntryName = entryName.Replace('\\', '/');
        if (normalizedEntryName.EndsWith('/'))
        {
            return false;
        }

        string[] components = normalizedEntryName
            .Split('/', StringSplitOptions.RemoveEmptyEntries);

        if (components.Length == 0)
        {
            return false;
        }

        string ncaName;
        bool fragmented = components.Length >= 2 &&
            components[^1].Equals("00", StringComparison.OrdinalIgnoreCase) &&
            components[^2].EndsWith(".nca", StringComparison.OrdinalIgnoreCase);

        if (fragmented)
        {
            ncaName = components[^2];
        }
        else if (components[^1].EndsWith(".nca", StringComparison.OrdinalIgnoreCase))
        {
            ncaName = components[^1];
        }
        else
        {
            return false;
        }

        if (!IsNcaName(ncaName))
        {
            throw new InvalidDataException(
                $"Firmware archive '{ncaName}' does not have a valid NCA filename."
            );
        }

        relativeDestination = fragmented ? Path.Combine(ncaName, "00") : ncaName;
        return true;
    }

    private static bool IsNcaName(string name)
    {
        string identifier;
        if (name.EndsWith(".cnmt.nca", StringComparison.OrdinalIgnoreCase))
        {
            identifier = name[..^".cnmt.nca".Length];
        }
        else if (name.EndsWith(".nca", StringComparison.OrdinalIgnoreCase))
        {
            identifier = name[..^".nca".Length];
        }
        else
        {
            return false;
        }

        return identifier.Length == 32 && identifier.All(Uri.IsHexDigit);
    }
}
