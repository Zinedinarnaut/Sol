#nullable enable

using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.HLE.HOS.Services.Account.Acc;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Ryujinx.Headless;

internal static class NativeProfileBridge
{
    private const string DefaultUserId = "00000000000000010000000000000000";
    private const string GuestUserId = "00000000000000000000000000000080";
    private const string DefaultUserImage =
        "Ryujinx.HLE/HOS/Services/Account/Acc/DefaultUserImage.jpg";
    private const string GuestUserImage =
        "Ryujinx.HLE/HOS/Services/Account/Acc/GuestUserImage.jpg";

    private sealed class ProfilesDocument
    {
        [JsonPropertyName("profiles")]
        public List<StoredProfile> Profiles { get; set; } = [];

        [JsonPropertyName("last_opened")]
        public string? LastOpened { get; set; }
    }

    private sealed class StoredProfile
    {
        [JsonPropertyName("user_id")]
        public string? UserId { get; init; }

        [JsonPropertyName("name")]
        public string? Name { get; init; }

        [JsonPropertyName("last_modified_timestamp")]
        public long LastModifiedTimestamp { get; init; }

        [JsonPropertyName("image")]
        public byte[]? Image { get; init; }
    }

    internal readonly record struct ProfileSummary(
        string UserId,
        string Name,
        byte[] Image,
        bool IsDefault
    );

    public static UserProfile? RequestProfile()
    {
        (List<UserProfile> profiles, string defaultUserId) = LoadProfiles();
        NativeDialogOption[] options = profiles
            .OrderBy(profile => profile.Name, StringComparer.CurrentCultureIgnoreCase)
            .Select(profile => new NativeDialogOption
            {
                Value = profile.UserId.ToString(),
                Label = profile.Name,
            })
            .Append(new NativeDialogOption
            {
                Value = GuestUserId,
                Label = "Guest",
            })
            .ToArray();

        if (!NativeDialogBridge.RequestChoice(
                "Choose a User",
                "Select the user profile for this game.",
                options,
                defaultUserId,
                out string? selectedId
            ))
        {
            return null;
        }

        if (selectedId == GuestUserId)
        {
            return new UserProfile(
                new UserId(GuestUserId),
                "Guest",
                ReadEmbeddedImage(GuestUserImage)
            );
        }

        return profiles.FirstOrDefault(
            profile => profile.UserId.ToString() == selectedId
        );
    }

    public static string GetDefaultProfileName()
    {
        (List<UserProfile> profiles, string defaultUserId) = LoadProfiles();
        return profiles.FirstOrDefault(
            profile => profile.UserId.ToString() == defaultUserId
        )?.Name ?? profiles[0].Name;
    }

    public static IReadOnlyList<ProfileSummary> GetProfiles()
    {
        (List<UserProfile> profiles, string defaultUserId) = LoadProfiles();
        return profiles
            .Select(profile => new ProfileSummary(
                profile.UserId.ToString(),
                profile.Name,
                profile.Image,
                profile.UserId.ToString() == defaultUserId
            ))
            .ToArray();
    }

    public static void SetDefaultProfile(string userId)
    {
        if (string.IsNullOrWhiteSpace(userId))
        {
            throw new ArgumentException("Choose a valid profile.", nameof(userId));
        }

        string normalizedUserId = new UserId(userId).ToString();
        (List<UserProfile> profiles, _) = LoadProfiles();
        if (!profiles.Any(profile => profile.UserId.ToString() == normalizedUserId))
        {
            throw new ArgumentException("That Sol profile no longer exists.", nameof(userId));
        }

        string profilesPath = GetProfilesPath();
        Directory.CreateDirectory(Path.GetDirectoryName(profilesPath)!);

        JsonObject root;
        if (File.Exists(profilesPath))
        {
            root = JsonNode.Parse(File.ReadAllText(profilesPath)) as JsonObject
                ?? throw new InvalidDataException("Profiles.json is not a JSON object.");
        }
        else
        {
            root = JsonSerializer.SerializeToNode(new ProfilesDocument
            {
                Profiles = profiles.Select(profile => new StoredProfile
                {
                    UserId = profile.UserId.ToString(),
                    Name = profile.Name,
                    LastModifiedTimestamp = profile.LastModifiedTimestamp,
                    Image = profile.Image,
                }).ToList(),
                LastOpened = normalizedUserId,
            }) as JsonObject ?? new JsonObject();
        }

        root["last_opened"] = normalizedUserId;
        string temporaryPath = profilesPath + ".sol.tmp";
        File.WriteAllText(
            temporaryPath,
            root.ToJsonString(new JsonSerializerOptions { WriteIndented = true })
        );
        File.Move(temporaryPath, profilesPath, overwrite: true);
    }

    private static (List<UserProfile> Profiles, string DefaultUserId) LoadProfiles()
    {
        string profilesPath = GetProfilesPath();

        try
        {
            if (File.Exists(profilesPath))
            {
                ProfilesDocument? document = JsonSerializer.Deserialize<ProfilesDocument>(
                    File.ReadAllText(profilesPath)
                );
                List<UserProfile> profiles = document?.Profiles
                    .Select(TryCreateProfile)
                    .Where(profile => profile is not null)
                    .Cast<UserProfile>()
                    .ToList() ?? [];

                if (profiles.Count > 0)
                {
                    string defaultUserId = profiles.Any(
                        profile => profile.UserId.ToString() == document?.LastOpened
                    )
                        ? document!.LastOpened!
                        : profiles[0].UserId.ToString();
                    return (profiles, defaultUserId);
                }
            }
        }
        catch (Exception exception)
        {
            NativeSessionProtocol.PublishError(
                $"Could not read Sol Engine profiles: {exception.Message}",
                "profile-select"
            );
        }

        UserProfile defaultProfile = new(
            new UserId(DefaultUserId),
            "RyuPlayer",
            ReadEmbeddedImage(DefaultUserImage)
        );
        return ([defaultProfile], DefaultUserId);
    }

    private static UserProfile? TryCreateProfile(StoredProfile stored)
    {
        if (string.IsNullOrWhiteSpace(stored.UserId))
        {
            return null;
        }

        try
        {
            return new UserProfile(
                new UserId(stored.UserId),
                string.IsNullOrWhiteSpace(stored.Name) ? "Player" : stored.Name,
                stored.Image is { Length: > 0 }
                    ? stored.Image
                    : ReadEmbeddedImage(DefaultUserImage),
                stored.LastModifiedTimestamp
            );
        }
        catch (ArgumentException)
        {
            return null;
        }
    }

    private static byte[] ReadEmbeddedImage(string path) =>
        EmbeddedResources.Read(path) ?? [];

    private static string GetProfilesPath() =>
        Path.Join(AppDataManager.BaseDirPath, "system", "Profiles.json");
}
