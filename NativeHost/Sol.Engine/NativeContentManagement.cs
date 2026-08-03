#nullable enable

using LibHac.Common;
using LibHac.Fs;
using LibHac.Fs.Fsa;
using LibHac.Ncm;
using LibHac.Tools.FsSystem;
using LibHac.Tools.FsSystem.NcaUtils;
using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Utilities;
using Ryujinx.HLE.FileSystem;
using Ryujinx.HLE.Loaders.Processes.Extensions;
using Ryujinx.HLE.Utilities;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using ContentType = LibHac.Ncm.ContentType;
using Path = System.IO.Path;

namespace Ryujinx.Headless;

internal readonly record struct NativeContentInventory(int DlcCount, int UpdateCount);

internal readonly record struct NativeContentScanResult(
    int DlcCount,
    int UpdateCount,
    int DirectoryCount,
    int AddedCount,
    int RemovedCount
);

/// <summary>
/// Native, UI-free equivalent of Ryujinx's library content autoloader.
/// It writes the same per-title updates.json and dlc.json documents consumed
/// by the HLE loader, while preserving an existing user's enabled DLC state.
/// </summary>
internal static class NativeContentManagement
{
    private readonly record struct UpdateCandidate(
        ulong TitleIdBase,
        ulong Version,
        string Path
    );

    private readonly record struct DlcCandidate(
        ulong TitleIdBase,
        ulong TitleId,
        string ContainerPath,
        string FullPath
    );

    private static readonly TitleUpdateMetadataJsonSerializerContext UpdateSerializer =
        new(JsonHelper.GetDefaultSerializerOptions());
    private static readonly DownloadableContentJsonSerializerContext DlcSerializer =
        new(JsonHelper.GetDefaultSerializerOptions());

    internal static NativeContentScanResult Scan(IEnumerable<string> configuredDirectories)
    {
        string[] directories = configuredDirectories
            .Where(path => !string.IsNullOrWhiteSpace(path))
            .Select(path => Path.GetFullPath(path))
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .Where(Directory.Exists)
            .ToArray();

        Dictionary<ulong, List<UpdateCandidate>> updates = [];
        Dictionary<ulong, List<DlcCandidate>> dlcs = [];

        using VirtualFileSystem fileSystem = VirtualFileSystem.CreateInstance();

        IEnumerable<string> contentPaths = directories
            .SelectMany(EnumerateContentFiles)
            .Distinct(StringComparer.OrdinalIgnoreCase);

        foreach (string path in contentPaths)
        {
            TryDiscoverContainer(fileSystem, path, updates, dlcs);
        }

        int added = 0;
        int removed = 0;
        SaveUpdates(updates, ref added, ref removed);
        SaveDownloadableContent(dlcs, ref added, ref removed);

        NativeContentInventory inventory = Inventory();
        return new NativeContentScanResult(
            inventory.DlcCount,
            inventory.UpdateCount,
            directories.Length,
            added,
            removed
        );
    }

    internal static NativeContentInventory Inventory()
    {
        int dlcCount = 0;
        int updateCount = 0;

        if (!Directory.Exists(AppDataManager.GamesDirPath))
        {
            return new NativeContentInventory(0, 0);
        }

        foreach (string titleDirectory in Directory.EnumerateDirectories(AppDataManager.GamesDirPath))
        {
            string updatesPath = Path.Combine(titleDirectory, "updates.json");
            if (File.Exists(updatesPath))
            {
                try
                {
                    TitleUpdateMetadata metadata = JsonHelper.DeserializeFromFile(
                        updatesPath,
                        UpdateSerializer.TitleUpdateMetadata
                    );
                    updateCount += metadata.Paths?.Distinct(StringComparer.OrdinalIgnoreCase).Count() ?? 0;
                }
                catch
                {
                    // A malformed title metadata file should not hide the
                    // inventory for every other title.
                }
            }

            string dlcPath = Path.Combine(titleDirectory, "dlc.json");
            if (File.Exists(dlcPath))
            {
                try
                {
                    List<DownloadableContentContainer> containers =
                        JsonHelper.DeserializeFromFile(
                            dlcPath,
                            DlcSerializer.ListDownloadableContentContainer
                        ) ?? [];
                    dlcCount += containers.Sum(container =>
                        container.DownloadableContentNcaList?.Count ?? 0);
                }
                catch
                {
                    // Keep reporting the rest of the registered content.
                }
            }
        }

        return new NativeContentInventory(dlcCount, updateCount);
    }

    private static IEnumerable<string> EnumerateContentFiles(string directory)
    {
        EnumerationOptions options = new()
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            ReturnSpecialDirectories = false,
        };

        IEnumerable<string> files;
        try
        {
            files = Directory.EnumerateFiles(directory, "*.nsp", options).ToArray();
        }
        catch
        {
            return [];
        }

        return files.Select(path =>
        {
            try
            {
                FileInfo info = new(path);
                return info.ResolveLinkTarget(true)?.FullName ?? info.FullName;
            }
            catch
            {
                return Path.GetFullPath(path);
            }
        });
    }

    private static void TryDiscoverContainer(
        VirtualFileSystem fileSystem,
        string path,
        Dictionary<ulong, List<UpdateCandidate>> updates,
        Dictionary<ulong, List<DlcCandidate>> dlcs)
    {
        try
        {
            using IFileSystem partition =
                PartitionFileSystemUtils.OpenApplicationFileSystem(path, fileSystem);

            try
            {
                Dictionary<ulong, ContentMetaData> patchData = partition.GetContentData(
                    ContentMetaType.Patch,
                    fileSystem,
                    Ryujinx.Ava.Systems.Configuration.ConfigurationState
                        .Instance.System.IntegrityCheckLevel
                );

                foreach (ContentMetaData content in patchData.Values)
                {
                    Nca? patchNca = content.GetNcaByType(fileSystem.KeySet, ContentType.Program);
                    if (patchNca is null)
                    {
                        continue;
                    }

                    ulong titleIdBase = content.ApplicationId & ~0x1FFFUL;
                    Add(
                        updates,
                        titleIdBase,
                        new UpdateCandidate(
                            titleIdBase,
                            content.Version.Version,
                            path
                        )
                    );
                }
            }
            catch
            {
                // An NSP may contain DLC without being a title update.
            }

            try
            {
                foreach (var entry in partition.EnumerateEntries("/", "*.nca"))
                {
                    using UniqueRef<IFile> ncaFile = new();
                    partition.OpenFile(
                        ref ncaFile.Ref,
                        entry.FullPath.ToU8Span(),
                        OpenMode.Read
                    ).ThrowIfFailure();

                    Nca nca;
                    try
                    {
                        nca = new Nca(fileSystem.KeySet, ncaFile.Get.AsStorage());
                    }
                    catch
                    {
                        continue;
                    }

                    if (nca.Header.ContentType != NcaContentType.PublicData)
                    {
                        continue;
                    }

                    ulong titleIdBase = nca.Header.TitleId & ~0x1FFFUL;
                    Add(
                        dlcs,
                        titleIdBase,
                        new DlcCandidate(
                            titleIdBase,
                            nca.Header.TitleId,
                            path,
                            entry.FullPath
                        )
                    );
                }
            }
            catch
            {
                // An NSP may contain an update without DLC.
            }
        }
        catch
        {
            // Invalid or key-incompatible containers are skipped; the
            // operation remains useful for every valid file in the folder.
        }
    }

    private static void SaveUpdates(
        Dictionary<ulong, List<UpdateCandidate>> discovered,
        ref int added,
        ref int removed)
    {
        foreach ((ulong titleIdBase, List<UpdateCandidate> candidates) in discovered)
        {
            string titleDirectory = TitleDirectory(titleIdBase);
            string metadataPath = Path.Combine(titleDirectory, "updates.json");
            TitleUpdateMetadata metadata = ReadUpdateMetadata(metadataPath);
            HashSet<string> paths = new(
                metadata.Paths ?? [],
                StringComparer.OrdinalIgnoreCase
            );

            foreach (string missingPath in paths.Where(path => !File.Exists(path)).ToArray())
            {
                paths.Remove(missingPath);
                removed++;
            }

            foreach (UpdateCandidate candidate in candidates)
            {
                if (paths.Add(candidate.Path))
                {
                    added++;
                }
            }

            UpdateCandidate newest = candidates
                .OrderByDescending(candidate => candidate.Version)
                .ThenBy(candidate => candidate.Path, StringComparer.OrdinalIgnoreCase)
                .First();
            ulong selectedVersion = candidates
                .Where(candidate =>
                    string.Equals(
                        candidate.Path,
                        metadata.Selected,
                        StringComparison.OrdinalIgnoreCase
                    ))
                .Select(candidate => candidate.Version)
                .DefaultIfEmpty(0UL)
                .Max();

            if (string.IsNullOrWhiteSpace(metadata.Selected) ||
                !File.Exists(metadata.Selected) ||
                newest.Version > selectedVersion)
            {
                metadata.Selected = newest.Path;
            }

            metadata.Paths = paths
                .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
                .ToList();
            Directory.CreateDirectory(titleDirectory);
            JsonHelper.SerializeToFile(
                metadataPath,
                metadata,
                UpdateSerializer.TitleUpdateMetadata
            );
        }
    }

    private static void SaveDownloadableContent(
        Dictionary<ulong, List<DlcCandidate>> discovered,
        ref int added,
        ref int removed)
    {
        foreach ((ulong titleIdBase, List<DlcCandidate> candidates) in discovered)
        {
            string titleDirectory = TitleDirectory(titleIdBase);
            string metadataPath = Path.Combine(titleDirectory, "dlc.json");
            List<DownloadableContentContainer> existing = ReadDlcMetadata(metadataPath);
            Dictionary<string, DownloadableContentNca> entries =
                new(StringComparer.OrdinalIgnoreCase);
            Dictionary<string, string> containerPaths =
                new(StringComparer.OrdinalIgnoreCase);

            foreach (DownloadableContentContainer container in existing)
            {
                if (!File.Exists(container.ContainerPath))
                {
                    removed += container.DownloadableContentNcaList?.Count ?? 0;
                    continue;
                }

                foreach (DownloadableContentNca nca in container.DownloadableContentNcaList ?? [])
                {
                    string key = DlcKey(container.ContainerPath, nca.FullPath);
                    entries[key] = nca;
                    containerPaths[key] = container.ContainerPath;
                }
            }

            foreach (DlcCandidate candidate in candidates)
            {
                string key = DlcKey(candidate.ContainerPath, candidate.FullPath);
                if (!entries.ContainsKey(key))
                {
                    entries[key] = new DownloadableContentNca
                    {
                        Enabled = true,
                        TitleId = candidate.TitleId,
                        FullPath = candidate.FullPath,
                    };
                    containerPaths[key] = candidate.ContainerPath;
                    added++;
                }
            }

            List<DownloadableContentContainer> containers = entries
                .GroupBy(
                    pair => containerPaths[pair.Key],
                    StringComparer.OrdinalIgnoreCase
                )
                .OrderBy(group => group.Key, StringComparer.OrdinalIgnoreCase)
                .Select(group => new DownloadableContentContainer
                {
                    ContainerPath = group.Key,
                    DownloadableContentNcaList = group
                        .Select(pair => pair.Value)
                        .OrderBy(nca => nca.TitleId)
                        .ToList(),
                })
                .ToList();

            Directory.CreateDirectory(titleDirectory);
            JsonHelper.SerializeToFile(
                metadataPath,
                containers,
                DlcSerializer.ListDownloadableContentContainer
            );
        }
    }

    private static TitleUpdateMetadata ReadUpdateMetadata(string path)
    {
        if (File.Exists(path))
        {
            try
            {
                TitleUpdateMetadata metadata = JsonHelper.DeserializeFromFile(
                    path,
                    UpdateSerializer.TitleUpdateMetadata
                );
                metadata.Paths ??= [];
                metadata.Selected ??= string.Empty;
                return metadata;
            }
            catch
            {
                // Rebuild only this title's invalid metadata.
            }
        }

        return new TitleUpdateMetadata
        {
            Selected = string.Empty,
            Paths = [],
        };
    }

    private static List<DownloadableContentContainer> ReadDlcMetadata(string path)
    {
        if (File.Exists(path))
        {
            try
            {
                return JsonHelper.DeserializeFromFile(
                    path,
                    DlcSerializer.ListDownloadableContentContainer
                ) ?? [];
            }
            catch
            {
                // Rebuild only this title's invalid metadata.
            }
        }

        return [];
    }

    private static void Add<T>(
        Dictionary<ulong, List<T>> values,
        ulong titleIdBase,
        T value)
    {
        if (!values.TryGetValue(titleIdBase, out List<T>? list))
        {
            list = [];
            values.Add(titleIdBase, list);
        }

        list.Add(value);
    }

    private static string TitleDirectory(ulong titleIdBase) =>
        Path.Combine(AppDataManager.GamesDirPath, titleIdBase.ToString("x16"));

    private static string DlcKey(string containerPath, string fullPath) =>
        $"{containerPath}\0{fullPath}";
}
