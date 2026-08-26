#nullable enable

using Ryujinx.Ava.Systems.Configuration;
using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Configuration.Hid;
using Ryujinx.Common.Configuration.Hid.Controller;
using Ryujinx.Common.Configuration.Hid.Controller.Motion;
using Ryujinx.Input;
using Ryujinx.Input.SDL3;
using Ryujinx.HLE.FileSystem;
using System;
using System.Collections.Generic;
using System.IO;
using System.Globalization;
using System.Linq;

namespace Ryujinx.Headless;

internal static class NativeBackendManagement
{
    private const string StatusArgument = "--native-status";
    private const string InstallKeysArgument = "--native-install-keys";
    private const string VerifyFirmwareArgument = "--native-verify-firmware";
    private const string InstallFirmwareArgument = "--native-install-firmware";
    private const string ScanContentArgument = "--native-scan-content";
    private const string ListInputsArgument = "--native-list-inputs";
    private const string SetInputArgument = "--native-set-input";
    private const string SetInputBindingArgument = "--native-set-input-binding";
    private const string ResetInputBindingsArgument = "--native-reset-input-bindings";
    private const string SetInputTuningArgument = "--native-set-input-tuning";
    private const string TestInputRumbleArgument = "--native-test-input-rumble";
    private const string InputBridgeSmokeArgument = "--native-input-bridge-smoke";
    private const string BindingArgument = "--native-binding";
    private const string ListProfilesArgument = "--native-list-profiles";
    private const string SetProfileArgument = "--native-set-profile";
    private const string CreateProfileArgument = "--native-create-profile";
    private const string RenameProfileArgument = "--native-rename-profile";
    private const string DeleteProfileArgument = "--native-delete-profile";
    private const string SetProfileImageArgument = "--native-set-profile-image";
    private const string SolMetalStatusArgument = "--native-solmetal-status";
    private const string SolMetalGalSmokeArgument = "--native-solmetal-gal-smoke";
    private const string ProfileNameArgument = "--native-profile-name";
    private const string ProfileImageBase64Argument = "--native-profile-image-base64";
    private const string PlayerArgument = "--native-player";
    private const string RootDataArgument = "--root-data-dir";
    private const string DeadzoneLeftArgument = "--deadzone-left";
    private const string DeadzoneRightArgument = "--deadzone-right";
    private const string RangeLeftArgument = "--range-left";
    private const string RangeRightArgument = "--range-right";
    private const string TriggerThresholdArgument = "--trigger-threshold";
    private const string MotionEnabledArgument = "--motion-enabled";
    private const string MotionSensitivityArgument = "--motion-sensitivity";
    private const string GyroDeadzoneArgument = "--gyro-deadzone";
    private const string RumbleEnabledArgument = "--rumble-enabled";
    private const string StrongRumbleArgument = "--strong-rumble";
    private const string WeakRumbleArgument = "--weak-rumble";
    private const string HdRumbleArgument = "--hd-rumble";
    private const string LedEnabledArgument = "--led-enabled";
    private const string LedOffArgument = "--led-off";
    private const string LedRainbowArgument = "--led-rainbow";
    private const string LedColorArgument = "--led-color";

    public static bool TryRun(string[] args, out int exitCode)
    {
        string? operation = FindOperation(args, out string? source);

        if (operation is null)
        {
            exitCode = 0;
            return false;
        }

        try
        {
            AppDataManager.Initialize(ValueAfter(args, RootDataArgument));
            EnsureConfiguration();

            switch (operation)
            {
                case StatusArgument:
                    PublishStatus();
                    PublishProfiles(includeCompletion: false);
                    break;
                case InstallKeysArgument:
                    RequireSource(source, operation);
                    Directory.CreateDirectory(AppDataManager.KeysDirPath);
                    ContentManager.InstallKeys(source!, AppDataManager.KeysDirPath);
                    string installedProdKeys = Path.Combine(
                        AppDataManager.KeysDirPath,
                        "prod.keys"
                    );
                    if (!File.Exists(installedProdKeys) ||
                        new FileInfo(installedProdKeys).Length == 0)
                    {
                        throw new InvalidDataException(
                            "The selected source did not register a non-empty prod.keys file."
                        );
                    }
                    NativeSessionProtocol.Publish(new NativeSessionEvent
                    {
                        Event = "backend.operation",
                        Operation = "install-keys",
                        Success = true,
                        Message = "Production keys installed and registered.",
                    });
                    PublishStatus();
                    break;
                case VerifyFirmwareArgument:
                    RequireSource(source, operation);
                    PublishFirmwarePreparation("verify-firmware");
                    using (NativeFirmwarePackage package = NativeFirmwarePackage.Prepare(source!))
                    using (VirtualFileSystem fileSystem = VirtualFileSystem.CreateInstance())
                    {
                        ContentManager manager = new(fileSystem);
                        PublishPreparedFirmware(package, "verify-firmware");
                        string? version = manager.VerifyFirmwarePackage(package.SourcePath)?.VersionString;
                        if (string.IsNullOrWhiteSpace(version))
                        {
                            throw new InvalidDataException(
                                "The selected package did not contain valid firmware."
                            );
                        }
                        NativeSessionProtocol.Publish(new NativeSessionEvent
                        {
                            Event = "backend.operation",
                            Operation = "verify-firmware",
                            Success = true,
                            FirmwareVersion = version,
                            Message = $"Firmware {version ?? "unknown"} is valid.",
                        });
                    }
                    break;
                case InstallFirmwareArgument:
                    RequireSource(source, operation);
                    PublishFirmwarePreparation("install-firmware");
                    using (NativeFirmwarePackage package = NativeFirmwarePackage.Prepare(source!))
                    using (VirtualFileSystem fileSystem = VirtualFileSystem.CreateInstance())
                    {
                        ContentManager manager = new(fileSystem);
                        PublishPreparedFirmware(package, "install-firmware");
                        string? version = manager.VerifyFirmwarePackage(package.SourcePath)?.VersionString;
                        if (string.IsNullOrWhiteSpace(version))
                        {
                            throw new InvalidDataException(
                                "The selected package did not contain valid firmware."
                            );
                        }
                        NativeSessionProtocol.Publish(new NativeSessionEvent
                        {
                            Event = "backend.operation",
                            Operation = "install-firmware",
                            Success = null,
                            FirmwareVersion = version,
                            Message = $"Installing firmware {version ?? "unknown"}…",
                        });
                        manager.InstallFirmware(package.SourcePath);
                        string? registeredVersion =
                            manager.GetCurrentFirmwareVersion()?.VersionString;
                        if (!string.Equals(
                                registeredVersion,
                                version,
                                StringComparison.OrdinalIgnoreCase
                            ))
                        {
                            throw new InvalidDataException(
                                $"Firmware installation finished, but Sol registered " +
                                $"{registeredVersion ?? "no firmware"} instead of {version}."
                            );
                        }
                        NativeSessionProtocol.Publish(new NativeSessionEvent
                        {
                            Event = "backend.operation",
                            Operation = "install-firmware",
                            Success = true,
                            FirmwareVersion = version,
                            Message = $"Firmware {version} installed and registered.",
                        });
                        PublishStatus(manager);
                    }
                    break;
                case ScanContentArgument:
                    LoadConfiguration();
                    NativeContentScanResult result = NativeContentManagement.Scan(
                        ConfigurationState.Instance.UI.AutoloadDirs.Value ?? []
                    );
                    NativeSessionProtocol.Publish(new NativeSessionEvent
                    {
                        Event = "backend.operation",
                        Operation = "scan-content",
                        Success = true,
                        DlcCount = result.DlcCount,
                        UpdateCount = result.UpdateCount,
                        DirectoryCount = result.DirectoryCount,
                        AddedCount = result.AddedCount,
                        RemovedCount = result.RemovedCount,
                        Message =
                            $"Registered {result.DlcCount} DLC item(s) and " +
                            $"{result.UpdateCount} title update(s) from " +
                            $"{result.DirectoryCount} folder(s).",
                    });
                    PublishStatus();
                    break;
                case ListInputsArgument:
                    ListInputDevices();
                    break;
                case SetInputArgument:
                    RequireSource(source, operation);
                    SetPlayerInput(source!, ValueAfter(args, PlayerArgument) ?? nameof(PlayerIndex.Player1));
                    break;
                case SetInputBindingArgument:
                    RequireSource(source, operation);
                    SetControllerBinding(
                        source!,
                        ValueAfter(args, BindingArgument),
                        ValueAfter(args, PlayerArgument) ?? nameof(PlayerIndex.Player1)
                    );
                    break;
                case ResetInputBindingsArgument:
                    ResetControllerBindings(
                        ValueAfter(args, PlayerArgument) ?? nameof(PlayerIndex.Player1)
                    );
                    break;
                case SetInputTuningArgument:
                    SetControllerTuning(
                        ValueAfter(args, PlayerArgument) ?? nameof(PlayerIndex.Player1),
                        args
                    );
                    break;
                case TestInputRumbleArgument:
                    TestControllerRumble(
                        ValueAfter(args, PlayerArgument) ?? nameof(PlayerIndex.Player1)
                    );
                    break;
                case InputBridgeSmokeArgument:
                    RunInputBridgeSmoke();
                    break;
                case ListProfilesArgument:
                    PublishProfiles(includeCompletion: true);
                    break;
                case SetProfileArgument:
                    RequireSource(source, operation);
                    NativeProfileBridge.SetDefaultProfile(source!);
                    NativeSessionProtocol.Publish(new NativeSessionEvent
                    {
                        Event = "backend.operation",
                        Operation = "set-profile",
                        Success = true,
                        ProfileId = source,
                        Message = "Default Sol profile updated.",
                    });
                    PublishProfiles(includeCompletion: false);
                    break;
                case CreateProfileArgument:
                    RequireSource(source, operation);
                    string createdProfileId = NativeProfileBridge.CreateProfile(
                        source!,
                        ValueAfter(args, ProfileImageBase64Argument)
                    );
                    PublishProfileOperation(
                        "create-profile",
                        createdProfileId,
                        "Game user created."
                    );
                    break;
                case RenameProfileArgument:
                    RequireSource(source, operation);
                    NativeProfileBridge.RenameProfile(
                        source!,
                        ValueAfter(args, ProfileNameArgument) ?? string.Empty
                    );
                    PublishProfileOperation(
                        "rename-profile",
                        source!,
                        "Game user renamed."
                    );
                    break;
                case DeleteProfileArgument:
                    RequireSource(source, operation);
                    NativeProfileBridge.DeleteProfile(source!);
                    PublishProfileOperation(
                        "delete-profile",
                        source!,
                        "Game user removed. Its save data was preserved."
                    );
                    break;
                case SetProfileImageArgument:
                    RequireSource(source, operation);
                    NativeProfileBridge.SetProfileImage(
                        source!,
                        ValueAfter(args, ProfileImageBase64Argument)
                    );
                    PublishProfileOperation(
                        "set-profile-image",
                        source!,
                        "Game user picture updated."
                    );
                    break;
                case SolMetalStatusArgument:
                    PublishSolMetalStatus();
                    break;
                case SolMetalGalSmokeArgument:
                    RunSolMetalGalSmoke();
                    break;
            }

            exitCode = 0;
        }
        catch (Exception exception)
        {
            NativeSessionProtocol.Publish(new NativeSessionEvent
            {
                Event = "backend.operation",
                Operation = OperationName(operation),
                Success = false,
                Message = UserFacingError(operation, exception),
            });
            exitCode = 1;
        }

        return true;
    }

    private static void PublishFirmwarePreparation(string operation)
    {
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.operation",
            Operation = operation,
            Success = null,
            Message = "Preparing firmware package…",
        });
    }

    private static void PublishPreparedFirmware(
        NativeFirmwarePackage package,
        string operation
    )
    {
        if (!package.WasStaged)
        {
            return;
        }

        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.operation",
            Operation = operation,
            Success = null,
            Count = package.NcaCount,
            Message = $"Prepared {package.NcaCount} firmware archive(s) for verification.",
        });
    }

    private static string UserFacingError(string? operation, Exception exception)
    {
        if ((operation == VerifyFirmwareArgument || operation == InstallFirmwareArgument) &&
            ExceptionChainContains(exception, "ResultFsOutOfRange"))
        {
            return
                "Sol could not read one or more firmware archives. The package may be " +
                "incomplete, or the installed prod.keys may not match this firmware dump. " +
                "Re-dump both from the same console and try the ZIP or extracted folder again.";
        }

        return exception.Message;
    }

    private static bool ExceptionChainContains(Exception exception, string value)
    {
        for (Exception? current = exception; current is not null; current = current.InnerException)
        {
            if (current.Message.Contains(value, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static void EnsureConfiguration()
    {
        string configurationPath = Path.Combine(AppDataManager.BaseDirPath, ReleaseInformation.ConfigName);

        if (File.Exists(configurationPath))
        {
            return;
        }

        Directory.CreateDirectory(AppDataManager.BaseDirPath);
        InitializeConfigurationState();
        ConfigurationState.Instance.LoadDefault();
        ConfigurationState.Instance.ToFileFormat().SaveConfig(configurationPath);
    }

    private static void InitializeConfigurationState()
    {
        if (ConfigurationState.Instance is null)
        {
            ConfigurationState.Initialize();
        }
    }

    private static string LoadConfiguration()
    {
        string configurationPath = Path.Combine(AppDataManager.BaseDirPath, ReleaseInformation.ConfigName);
        InitializeConfigurationState();

        if (ConfigurationFileFormat.TryLoad(configurationPath, out ConfigurationFileFormat configuration))
        {
            ConfigurationState.Instance.Load(configuration, configurationPath);
        }
        else
        {
            ConfigurationState.Instance.LoadDefault();
        }

        return configurationPath;
    }

    private static void ListInputDevices()
    {
        int count = 0;
        HashSet<string> publishedInputIds = new(StringComparer.Ordinal);

        LoadConfiguration();
        List<InputConfig> inputConfigs =
            ConfigurationState.Instance.Hid.InputConfig.Value?
                .Where(config => config is not null)
                .ToList() ?? [];
        Dictionary<string, string[]> assignedPlayersByInputId =
            inputConfigs
                .Where(config => config is not null && !string.IsNullOrWhiteSpace(config.Id))
                .GroupBy(config => config.Id)
                .ToDictionary(
                    group => group.Key,
                    group => group
                        .Select(config => config.PlayerIndex.ToString())
                        .Distinct(StringComparer.Ordinal)
                        .ToArray(),
                    StringComparer.Ordinal
                ) ?? new Dictionary<string, string[]>(StringComparer.Ordinal);

        using SDL3KeyboardDriver keyboardDriver = new();
        using SDL3GamepadDriver gamepadDriver = new();

        foreach (string id in keyboardDriver.GamepadsIds)
        {
            using IGamepad? gamepad = keyboardDriver.GetGamepad(id);

            if (gamepad is null)
            {
                continue;
            }

            PublishInputDevice(
                id,
                gamepad.Name,
                "keyboard",
                usesEastConfirmButton: false,
                AssignmentsFor(id),
                isConnected: true
            );
            publishedInputIds.Add(id);
            count++;
        }

        foreach (string id in gamepadDriver.GamepadsIds)
        {
            using IGamepad? gamepad = gamepadDriver.GetGamepad(id);

            if (gamepad is null)
            {
                continue;
            }

            bool usesEastConfirmButton =
                gamepad is SDL3Gamepad sdlGamepad
                    ? sdlGamepad.VendorId == 0x057E
                    : gamepad.Name.Contains("Nintendo", StringComparison.OrdinalIgnoreCase);
            PublishInputDevice(
                id,
                gamepad.Name,
                "controller",
                usesEastConfirmButton,
                AssignmentsFor(id),
                isConnected: true
            );
            publishedInputIds.Add(id);
            count++;
        }

        foreach (InputConfig inputConfig in inputConfigs)
        {
            if (string.IsNullOrWhiteSpace(inputConfig.Id) ||
                !publishedInputIds.Add(inputConfig.Id))
            {
                continue;
            }

            bool isController = inputConfig is StandardControllerInputConfig;
            PublishInputDevice(
                inputConfig.Id,
                inputConfig.Name,
                isController ? "controller" : "keyboard",
                usesEastConfirmButton: isController && inputConfig.Name.Contains(
                    "Nintendo",
                    StringComparison.OrdinalIgnoreCase
                ),
                AssignmentsFor(inputConfig.Id),
                isConnected: false
            );
            count++;
        }

        foreach (StandardControllerInputConfig inputConfig in inputConfigs.OfType<StandardControllerInputConfig>())
        {
            PublishControllerMapping(inputConfig);
        }

        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.operation",
            Operation = "list-inputs",
            Success = true,
            Count = count,
            Message = count == 1 ? "Found 1 Sol Engine input device." : $"Found {count} Sol Engine input devices.",
        });

        string[] AssignmentsFor(string id) =>
            assignedPlayersByInputId.TryGetValue(id, out string[]? players)
                ? players
                : [];
    }

    private static void PublishInputDevice(
        string id,
        string name,
        string kind,
        bool usesEastConfirmButton,
        string[] assignedPlayers,
        bool isConnected
    )
    {
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "input.device",
            InputId = id,
            InputName = name,
            InputKind = kind,
            AssignedPlayers = assignedPlayers,
            UsesEastConfirmButton = usesEastConfirmButton,
            IsConnected = isConnected,
        });
    }

    private static void RunInputBridgeSmoke()
    {
        const int SdlScancodeZ = 0x1d;
        int assertions = 0;

        SDL3Keyboard.SetExternalInputMode(true);
        try
        {
            using SDL3KeyboardDriver keyboardDriver = new();
            using IGamepad? gamepad = keyboardDriver.GetGamepad("0");
            if (gamepad is not SDL3Keyboard keyboard)
            {
                throw new InvalidOperationException(
                    "Sol Engine could not create its external keyboard bridge."
                );
            }

            SDL3Keyboard.SetExternalKeyState(SdlScancodeZ, true);
            SDL3Keyboard.SetExternalKeyState(SdlScancodeZ, false);
            Assert(
                keyboard.GetKeyboardStateSnapshot().IsPressed(PhysicalKey.Z),
                "A press released between polls was lost."
            );
            Assert(
                !keyboard.GetKeyboardStateSnapshot().IsPressed(PhysicalKey.Z),
                "A consumed quick press remained latched."
            );

            SDL3Keyboard.SetExternalKeyState(SdlScancodeZ, true);
            Assert(
                keyboard.GetKeyboardStateSnapshot().IsPressed(PhysicalKey.Z),
                "A held key was not observed."
            );
            Assert(
                keyboard.GetKeyboardStateSnapshot().IsPressed(PhysicalKey.Z),
                "A held key expired after one poll."
            );
            SDL3Keyboard.SetExternalKeyState(SdlScancodeZ, false);
            Assert(
                !keyboard.GetKeyboardStateSnapshot().IsPressed(PhysicalKey.Z),
                "A released held key remained active."
            );

            SDL3Keyboard.SetExternalKeyState(SdlScancodeZ, true);
            SDL3Keyboard.SetExternalKeyState(SdlScancodeZ, false);
            SDL3Keyboard.ClearExternalKeyState();
            Assert(
                !keyboard.GetKeyboardStateSnapshot().IsPressed(PhysicalKey.Z),
                "Reset did not clear an unconsumed press."
            );

            NativeSessionProtocol.Publish(new NativeSessionEvent
            {
                Event = "input.bridge-smoke",
                Operation = "input-bridge-smoke",
                Success = true,
                Count = assertions,
                Message =
                    "External keyboard taps, holds, releases, and reset passed.",
            });
        }
        finally
        {
            SDL3Keyboard.SetExternalInputMode(false);
        }

        void Assert(bool condition, string failure)
        {
            assertions++;
            if (!condition)
            {
                throw new InvalidOperationException(failure);
            }
        }
    }

    private static void PublishProfiles(bool includeCompletion)
    {
        IReadOnlyList<NativeProfileBridge.ProfileSummary> profiles =
            NativeProfileBridge.GetProfiles();

        foreach (NativeProfileBridge.ProfileSummary profile in profiles)
        {
            NativeSessionProtocol.Publish(new NativeSessionEvent
            {
                Event = "profile.item",
                ProfileId = profile.UserId,
                ProfileName = profile.Name,
                ProfileImageBase64 = profile.Image.Length > 0
                    ? Convert.ToBase64String(profile.Image)
                    : null,
                IsDefault = profile.IsDefault,
            });
        }

        if (includeCompletion)
        {
            NativeSessionProtocol.Publish(new NativeSessionEvent
            {
                Event = "backend.operation",
                Operation = "list-profiles",
                Success = true,
                Count = profiles.Count,
                Message = profiles.Count == 1
                    ? "Found 1 Sol profile."
                    : $"Found {profiles.Count} Sol profiles.",
            });
        }
    }

    private static void PublishProfileOperation(
        string operation,
        string profileId,
        string message
    )
    {
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.operation",
            Operation = operation,
            Success = true,
            ProfileId = profileId,
            Message = message,
        });
        PublishProfiles(includeCompletion: false);
    }

    private static void SetPlayerInput(string inputId, string playerName)
    {
        if (!Enum.TryParse(playerName, ignoreCase: true, out PlayerIndex playerIndex) ||
            playerIndex is PlayerIndex.Unknown or PlayerIndex.Auto)
        {
            throw new ArgumentException($"Unknown player index '{playerName}'.");
        }

        string? inputName = null;
        bool isKeyboard = false;
        bool usesEastConfirmButton = false;

        using (SDL3KeyboardDriver keyboardDriver = new())
        using (SDL3GamepadDriver gamepadDriver = new())
        {
            using IGamepad? keyboard = keyboardDriver.GetGamepad(inputId);

            if (keyboard is not null)
            {
                inputName = keyboard.Name;
                isKeyboard = true;
            }
            else
            {
                using IGamepad? gamepad = gamepadDriver.GetGamepad(inputId);

                if (gamepad is not null)
                {
                    inputName = gamepad.Name;
                    usesEastConfirmButton =
                        gamepad is SDL3Gamepad sdlGamepad
                            ? sdlGamepad.VendorId == 0x057E
                            : gamepad.Name.Contains("Nintendo", StringComparison.OrdinalIgnoreCase);
                }
            }
        }

        if (inputName is null)
        {
            throw new ArgumentException($"Input device '{inputId}' is not connected.");
        }

        ControllerType controllerType = playerIndex == PlayerIndex.Handheld
            ? ControllerType.Handheld
            : ControllerType.ProController;
        InputConfig inputConfig = isKeyboard
            ? InputConfigDefaults.CreateDefaultKeyboardConfiguration(
                inputId,
                inputName,
                controllerType,
                playerIndex
            )
            : InputConfigDefaults.CreateDefaultControllerConfiguration(
                inputId,
                inputName,
                controllerType,
                playerIndex,
                usesEastConfirmButton
            );

        string configurationPath = LoadConfiguration();
        List<InputConfig> inputConfigs =
            ConfigurationState.Instance.Hid.InputConfig.Value?
                .Where(config => config is not null)
                .ToList() ?? [];
        int existingIndex = inputConfigs.FindIndex(config => config.PlayerIndex == playerIndex);

        if (existingIndex >= 0)
        {
            inputConfigs[existingIndex] = inputConfig;
        }
        else
        {
            inputConfigs.Add(inputConfig);
        }

        ConfigurationState.Instance.Hid.InputConfig.Value = inputConfigs;
        ConfigurationState.Instance.Hid.PlayerInputAssignments.Value?.RemoveAll(
            assignment => assignment?.PlayerIndex == playerIndex
        );
        ConfigurationState.Instance.ToFileFormat().SaveConfig(configurationPath);

        if (inputConfig is StandardControllerInputConfig controllerInputConfig)
        {
            PublishControllerMapping(controllerInputConfig);
        }

        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.operation",
            Operation = "set-input",
            Success = true,
            InputId = inputId,
            InputName = inputName,
            InputKind = isKeyboard ? "keyboard" : "controller",
            PlayerIndex = playerIndex.ToString(),
            Message = $"{inputName} is now the default input for {FriendlyPlayerName(playerIndex)}.",
        });
    }

    private static void SetControllerBinding(
        string bindingName,
        string? bindingValue,
        string playerName
    )
    {
        PlayerIndex playerIndex = ParsePlayerIndex(playerName);

        if (string.IsNullOrWhiteSpace(bindingValue) ||
            !Enum.TryParse(bindingValue, ignoreCase: true, out GamepadInputId physicalButton) ||
            physicalButton == GamepadInputId.Count)
        {
            throw new ArgumentException($"Unknown controller button '{bindingValue ?? ""}'.");
        }

        string configurationPath = LoadConfiguration();
        List<InputConfig> inputConfigs =
            ConfigurationState.Instance.Hid.InputConfig.Value?
                .Where(config => config is not null)
                .ToList() ?? [];
        StandardControllerInputConfig inputConfig = inputConfigs
            .OfType<StandardControllerInputConfig>()
            .FirstOrDefault(config => config.PlayerIndex == playerIndex)
            ?? throw new InvalidOperationException(
                $"Assign a controller to {FriendlyPlayerName(playerIndex)} before editing its buttons."
            );

        ApplyControllerBinding(inputConfig, bindingName, physicalButton);
        ConfigurationState.Instance.Hid.InputConfig.Value = inputConfigs;
        ConfigurationState.Instance.ToFileFormat().SaveConfig(configurationPath);
        PublishControllerMapping(inputConfig);

        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.operation",
            Operation = "set-input-binding",
            Success = true,
            InputId = inputConfig.Id,
            InputName = inputConfig.Name,
            PlayerIndex = playerIndex.ToString(),
            BindingName = bindingName,
            BindingValue = CanonicalButtonName(physicalButton),
            Message = $"Updated {FriendlyBindingName(bindingName)} for {FriendlyPlayerName(playerIndex)}.",
        });
    }

    private static void ResetControllerBindings(string playerName)
    {
        PlayerIndex playerIndex = ParsePlayerIndex(playerName);
        string configurationPath = LoadConfiguration();
        List<InputConfig> inputConfigs =
            ConfigurationState.Instance.Hid.InputConfig.Value?
                .Where(config => config is not null)
                .ToList() ?? [];
        StandardControllerInputConfig inputConfig = inputConfigs
            .OfType<StandardControllerInputConfig>()
            .FirstOrDefault(config => config.PlayerIndex == playerIndex)
            ?? throw new InvalidOperationException(
                $"Assign a controller to {FriendlyPlayerName(playerIndex)} before restoring its buttons."
            );
        bool usesEastConfirmButton = inputConfig.Name.Contains(
            "Nintendo",
            StringComparison.OrdinalIgnoreCase
        );
        StandardControllerInputConfig defaults =
            InputConfigDefaults.CreateDefaultControllerConfiguration(
                inputConfig.Id,
                inputConfig.Name,
                inputConfig.ControllerType,
                inputConfig.PlayerIndex,
                usesEastConfirmButton
            );

        inputConfig.LeftJoycon = defaults.LeftJoycon;
        inputConfig.LeftJoyconStick = defaults.LeftJoyconStick;
        inputConfig.RightJoycon = defaults.RightJoycon;
        inputConfig.RightJoyconStick = defaults.RightJoyconStick;
        ConfigurationState.Instance.Hid.InputConfig.Value = inputConfigs;
        ConfigurationState.Instance.ToFileFormat().SaveConfig(configurationPath);
        PublishControllerMapping(inputConfig);

        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.operation",
            Operation = "reset-input-bindings",
            Success = true,
            InputId = inputConfig.Id,
            InputName = inputConfig.Name,
            PlayerIndex = playerIndex.ToString(),
            Message = $"Restored the recommended controller layout for {FriendlyPlayerName(playerIndex)}.",
        });
    }

    private static void SetControllerTuning(string playerName, string[] args)
    {
        PlayerIndex playerIndex = ParsePlayerIndex(playerName);
        string configurationPath = LoadConfiguration();
        List<InputConfig> inputConfigs =
            ConfigurationState.Instance.Hid.InputConfig.Value?
                .Where(config => config is not null)
                .ToList() ?? [];
        StandardControllerInputConfig inputConfig = inputConfigs
            .OfType<StandardControllerInputConfig>()
            .FirstOrDefault(config => config.PlayerIndex == playerIndex)
            ?? throw new InvalidOperationException(
                $"Assign a controller to {FriendlyPlayerName(playerIndex)} before tuning it."
            );

        inputConfig.DeadzoneLeft = RequiredFloat(args, DeadzoneLeftArgument, 0f, 0.95f);
        inputConfig.DeadzoneRight = RequiredFloat(args, DeadzoneRightArgument, 0f, 0.95f);
        inputConfig.RangeLeft = RequiredFloat(args, RangeLeftArgument, 0.5f, 1.5f);
        inputConfig.RangeRight = RequiredFloat(args, RangeRightArgument, 0.5f, 1.5f);
        inputConfig.TriggerThreshold = RequiredFloat(args, TriggerThresholdArgument, 0f, 1f);

        inputConfig.Motion ??= new StandardMotionConfigController();
        inputConfig.Motion.EnableMotion = RequiredBool(args, MotionEnabledArgument);
        inputConfig.Motion.Sensitivity = RequiredInt(args, MotionSensitivityArgument, 1, 200);
        inputConfig.Motion.GyroDeadzone = RequiredDouble(args, GyroDeadzoneArgument, 0, 10);

        inputConfig.Rumble ??= new RumbleConfigController();
        inputConfig.Rumble.EnableRumble = RequiredBool(args, RumbleEnabledArgument);
        inputConfig.Rumble.StrongRumble = RequiredFloat(args, StrongRumbleArgument, 0f, 1f);
        inputConfig.Rumble.WeakRumble = RequiredFloat(args, WeakRumbleArgument, 0f, 1f);
        inputConfig.Rumble.UseHDRumble = RequiredBool(args, HdRumbleArgument);

        inputConfig.Led ??= new LedConfigController();
        inputConfig.Led.EnableLed = RequiredBool(args, LedEnabledArgument);
        inputConfig.Led.TurnOffLed = RequiredBool(args, LedOffArgument);
        inputConfig.Led.UseRainbow = RequiredBool(args, LedRainbowArgument);
        inputConfig.Led.LedColor = RequiredUInt(args, LedColorArgument, 0, 0xFFFFFF);

        ConfigurationState.Instance.Hid.InputConfig.Value = inputConfigs;
        ConfigurationState.Instance.ToFileFormat().SaveConfig(configurationPath);
        PublishControllerMapping(inputConfig);

        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.operation",
            Operation = "set-input-tuning",
            Success = true,
            InputId = inputConfig.Id,
            InputName = inputConfig.Name,
            PlayerIndex = playerIndex.ToString(),
            Message = $"Saved controller tuning for {FriendlyPlayerName(playerIndex)}.",
        });
    }

    private static void TestControllerRumble(string playerName)
    {
        PlayerIndex playerIndex = ParsePlayerIndex(playerName);
        LoadConfiguration();
        StandardControllerInputConfig inputConfig =
            ConfigurationState.Instance.Hid.InputConfig.Value?
                .OfType<StandardControllerInputConfig>()
                .FirstOrDefault(config => config.PlayerIndex == playerIndex)
            ?? throw new InvalidOperationException(
                $"Assign a controller to {FriendlyPlayerName(playerIndex)} before testing rumble."
            );

        using SDL3GamepadDriver gamepadDriver = new();
        using IGamepad? gamepad = gamepadDriver.GetGamepad(inputConfig.Id);

        if (gamepad is null)
        {
            throw new InvalidOperationException(
                $"{inputConfig.Name} is not connected. Wake it and try again."
            );
        }

        gamepad.SetConfiguration(inputConfig);
        float strong = inputConfig.Rumble?.StrongRumble ?? 1f;
        float weak = inputConfig.Rumble?.WeakRumble ?? 1f;

        if (!gamepad.Rumble(strong, weak, 450))
        {
            throw new NotSupportedException(
                $"{inputConfig.Name} did not accept a rumble request."
            );
        }

        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.operation",
            Operation = "test-input-rumble",
            Success = true,
            InputId = inputConfig.Id,
            InputName = inputConfig.Name,
            PlayerIndex = playerIndex.ToString(),
            Message = $"Played a rumble preview on {inputConfig.Name}.",
        });
    }

    private static PlayerIndex ParsePlayerIndex(string playerName)
    {
        if (!Enum.TryParse(playerName, ignoreCase: true, out PlayerIndex playerIndex) ||
            playerIndex is PlayerIndex.Unknown or PlayerIndex.Auto)
        {
            throw new ArgumentException($"Unknown player index '{playerName}'.");
        }

        return playerIndex;
    }

    private static void PublishControllerMapping(StandardControllerInputConfig inputConfig)
    {
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "input.mapping",
            InputId = inputConfig.Id,
            InputName = inputConfig.Name,
            InputKind = "controller",
            PlayerIndex = inputConfig.PlayerIndex.ToString(),
            Bindings = ControllerBindings(inputConfig),
            DeadzoneLeft = inputConfig.DeadzoneLeft,
            DeadzoneRight = inputConfig.DeadzoneRight,
            RangeLeft = inputConfig.RangeLeft,
            RangeRight = inputConfig.RangeRight,
            TriggerThreshold = inputConfig.TriggerThreshold,
            MotionEnabled = inputConfig.Motion?.EnableMotion ?? false,
            MotionSensitivity = inputConfig.Motion?.Sensitivity ?? 100,
            GyroDeadzone = inputConfig.Motion?.GyroDeadzone ?? 1,
            RumbleEnabled = inputConfig.Rumble?.EnableRumble ?? false,
            StrongRumble = inputConfig.Rumble?.StrongRumble ?? 1,
            WeakRumble = inputConfig.Rumble?.WeakRumble ?? 1,
            HdRumble = inputConfig.Rumble?.UseHDRumble ?? false,
            LedEnabled = inputConfig.Led?.EnableLed ?? false,
            LedOff = inputConfig.Led?.TurnOffLed ?? false,
            LedRainbow = inputConfig.Led?.UseRainbow ?? false,
            LedColor = inputConfig.Led?.LedColor ?? 0x007AFF,
        });
    }

    private static Dictionary<string, string> ControllerBindings(
        StandardControllerInputConfig inputConfig
    ) => new(StringComparer.Ordinal)
    {
        ["buttonA"] = CanonicalButtonName(inputConfig.RightJoycon.ButtonA),
        ["buttonB"] = CanonicalButtonName(inputConfig.RightJoycon.ButtonB),
        ["buttonX"] = CanonicalButtonName(inputConfig.RightJoycon.ButtonX),
        ["buttonY"] = CanonicalButtonName(inputConfig.RightJoycon.ButtonY),
        ["buttonL"] = CanonicalButtonName(inputConfig.LeftJoycon.ButtonL),
        ["buttonR"] = CanonicalButtonName(inputConfig.RightJoycon.ButtonR),
        ["buttonZL"] = CanonicalButtonName(inputConfig.LeftJoycon.ButtonZl),
        ["buttonZR"] = CanonicalButtonName(inputConfig.RightJoycon.ButtonZr),
        ["buttonMinus"] = CanonicalButtonName(inputConfig.LeftJoycon.ButtonMinus),
        ["buttonPlus"] = CanonicalButtonName(inputConfig.RightJoycon.ButtonPlus),
        ["leftStick"] = CanonicalButtonName(inputConfig.LeftJoyconStick.StickButton),
        ["rightStick"] = CanonicalButtonName(inputConfig.RightJoyconStick.StickButton),
        ["dpadUp"] = CanonicalButtonName(inputConfig.LeftJoycon.DpadUp),
        ["dpadDown"] = CanonicalButtonName(inputConfig.LeftJoycon.DpadDown),
        ["dpadLeft"] = CanonicalButtonName(inputConfig.LeftJoycon.DpadLeft),
        ["dpadRight"] = CanonicalButtonName(inputConfig.LeftJoycon.DpadRight),
    };

    private static void ApplyControllerBinding(
        StandardControllerInputConfig inputConfig,
        string bindingName,
        GamepadInputId physicalButton
    )
    {
        switch (bindingName)
        {
            case "buttonA": inputConfig.RightJoycon.ButtonA = physicalButton; break;
            case "buttonB": inputConfig.RightJoycon.ButtonB = physicalButton; break;
            case "buttonX": inputConfig.RightJoycon.ButtonX = physicalButton; break;
            case "buttonY": inputConfig.RightJoycon.ButtonY = physicalButton; break;
            case "buttonL": inputConfig.LeftJoycon.ButtonL = physicalButton; break;
            case "buttonR": inputConfig.RightJoycon.ButtonR = physicalButton; break;
            case "buttonZL": inputConfig.LeftJoycon.ButtonZl = physicalButton; break;
            case "buttonZR": inputConfig.RightJoycon.ButtonZr = physicalButton; break;
            case "buttonMinus": inputConfig.LeftJoycon.ButtonMinus = physicalButton; break;
            case "buttonPlus": inputConfig.RightJoycon.ButtonPlus = physicalButton; break;
            case "leftStick": inputConfig.LeftJoyconStick.StickButton = physicalButton; break;
            case "rightStick": inputConfig.RightJoyconStick.StickButton = physicalButton; break;
            case "dpadUp": inputConfig.LeftJoycon.DpadUp = physicalButton; break;
            case "dpadDown": inputConfig.LeftJoycon.DpadDown = physicalButton; break;
            case "dpadLeft": inputConfig.LeftJoycon.DpadLeft = physicalButton; break;
            case "dpadRight": inputConfig.LeftJoycon.DpadRight = physicalButton; break;
            default: throw new ArgumentException($"Unknown game control '{bindingName}'.");
        }
    }

    private static string CanonicalButtonName(GamepadInputId button) => button switch
    {
        GamepadInputId.Minus => nameof(GamepadInputId.Minus),
        GamepadInputId.Plus => nameof(GamepadInputId.Plus),
        _ => button.ToString(),
    };

    private static string FriendlyBindingName(string bindingName) => bindingName switch
    {
        "buttonA" => "A",
        "buttonB" => "B",
        "buttonX" => "X",
        "buttonY" => "Y",
        "buttonL" => "L",
        "buttonR" => "R",
        "buttonZL" => "ZL",
        "buttonZR" => "ZR",
        "buttonMinus" => "Minus",
        "buttonPlus" => "Plus",
        "leftStick" => "left stick click",
        "rightStick" => "right stick click",
        "dpadUp" => "D-pad up",
        "dpadDown" => "D-pad down",
        "dpadLeft" => "D-pad left",
        "dpadRight" => "D-pad right",
        _ => bindingName,
    };

    private static string FriendlyPlayerName(PlayerIndex playerIndex) =>
        playerIndex == PlayerIndex.Handheld
            ? "Handheld"
            : playerIndex.ToString().Replace("Player", "Player ");

    private static void PublishStatus()
    {
        try
        {
            using VirtualFileSystem fileSystem = VirtualFileSystem.CreateInstance();
            ContentManager manager = new(fileSystem);
            PublishStatus(manager);
        }
        catch
        {
            // Missing or incompatible keys can prevent firmware inspection. The
            // key status below still gives the native UI an actionable state.
            PublishStatus(null);
        }
    }

    private static void PublishStatus(ContentManager? manager)
    {
        string? firmwareVersion = null;

        if (manager is not null)
        {
            try
            {
                firmwareVersion = manager.GetCurrentFirmwareVersion()?.VersionString;
            }
            catch
            {
                // Missing or incompatible keys can prevent firmware inspection.
            }
        }

        bool hasProdKeys =
            File.Exists(Path.Combine(AppDataManager.KeysDirPath, "prod.keys")) ||
            File.Exists(Path.Combine(AppDataManager.KeysDirPathUser, "prod.keys"));
        NativeContentInventory inventory = NativeContentManagement.Inventory();
        int directoryCount = 0;

        try
        {
            LoadConfiguration();
            directoryCount = ConfigurationState.Instance.UI.AutoloadDirs.Value?.Count ?? 0;
        }
        catch
        {
            // Status remains useful even when a damaged config cannot be loaded.
        }

        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "backend.status",
            HasProdKeys = hasProdKeys,
            FirmwareVersion = firmwareVersion,
            DataDirectory = AppDataManager.BaseDirPath,
            DlcCount = inventory.DlcCount,
            UpdateCount = inventory.UpdateCount,
            DirectoryCount = directoryCount,
        });
    }

    private static void PublishSolMetalStatus()
    {
        SolMetalNativeBridge.ProbeResult result = SolMetalNativeBridge.Probe();
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "solmetal.status",
            Operation = "solmetal-status",
            Success = result.Success,
            Playable = result.Playable,
            AbiVersion = result.AbiVersion,
            DeviceName = result.DeviceName,
            AppleGpuFamily = result.AppleGpuFamily,
            ArgumentBufferTier = result.ArgumentBufferTier,
            UnifiedMemory = result.HasUnifiedMemory,
            SupportsBcTextureCompression = result.SupportsBcTextureCompression,
            SupportsRayTracing = result.SupportsRayTracing,
            SupportsBinaryArchives = result.SupportsBinaryArchives,
            SpirvTranslationReady = result.SpirvTranslationReady,
            BufferResourcesReady = result.BufferResourcesReady,
            TextureResourcesReady = result.TextureResourcesReady,
            SamplerResourcesReady = result.SamplerResourcesReady,
            ComputePipelinesReady = result.ComputePipelinesReady,
            RenderPipelinesReady = result.RenderPipelinesReady,
            RenderBindingsReady = result.RenderBindingsReady,
            IndexedDrawingReady = result.IndexedDrawingReady,
            DepthStencilReady = result.DepthStencilReady,
            BlendingReady = result.BlendingReady,
            RasterizerStateReady = result.RasterizerStateReady,
            TimelineSynchronizationReady = result.TimelineSynchronizationReady,
            RecommendedWorkingSetBytes = result.RecommendedWorkingSetBytes,
            TestsRun = result.TestsRun,
            TestsPassed = result.TestsPassed,
            BytesVerified = result.BytesVerified,
            ShaderCacheHits = result.ShaderCacheHits,
            ShaderCacheMisses = result.ShaderCacheMisses,
            BinaryArchivesCreated = result.BinaryArchivesCreated,
            GpuMilliseconds = result.GpuMilliseconds,
            OutputSignature = result.OutputSignature,
            Message = result.Success
                ? $"SolMetal passed {result.TestsPassed} native validation gates on {result.DeviceName}."
                : result.Failure,
        });
    }

    private static void RunSolMetalGalSmoke()
    {
        SolMetalGalRenderer.GalSmokeResult result =
            SolMetalGalRenderer.RunResourceSmoke();
        NativeSessionProtocol.Publish(new NativeSessionEvent
        {
            Event = "solmetal.gal-smoke",
            Operation = "solmetal-gal-smoke",
            Success = result.ReportsMetalApi,
            Playable = false,
            DeviceName = result.DeviceName,
            BytesVerified = (ulong)result.BytesVerified,
            BufferResourcesReady = true,
            TextureResourcesReady = true,
            SamplerResourcesReady = true,
            SpirvTranslationReady = true,
            ComputePipelinesReady = true,
            RenderPipelinesReady = true,
            RenderBindingsReady = true,
            IndexedDrawingReady = true,
            DepthStencilReady = true,
            BlendingReady = true,
            RasterizerStateReady = true,
            TimelineSynchronizationReady = true,
            Count = 16,
            Message = result.ReportsMetalApi
                ? $"SolMetal's GAL adapter passed buffers, 2D textures, samplers, copies, resource-bound indexed drawing with depth, blending, and raster state, compute dispatch, SPIR-V translation, readback, and ordered sync on {result.DeviceName}."
                : "SolMetal's GAL adapter did not report the native Metal target API.",
        });
    }

    private static string? FindOperation(string[] args, out string? source)
    {
        foreach (string operation in new[]
                 {
                     StatusArgument,
                     InstallKeysArgument,
                     VerifyFirmwareArgument,
                     InstallFirmwareArgument,
                     ScanContentArgument,
                     ListInputsArgument,
                     SetInputArgument,
                     SetInputBindingArgument,
                     ResetInputBindingsArgument,
                     SetInputTuningArgument,
                     TestInputRumbleArgument,
                     InputBridgeSmokeArgument,
                     ListProfilesArgument,
                     SetProfileArgument,
                     CreateProfileArgument,
                     RenameProfileArgument,
                     DeleteProfileArgument,
                     SetProfileImageArgument,
                     SolMetalStatusArgument,
                     SolMetalGalSmokeArgument,
                 })
        {
            int index = Array.IndexOf(args, operation);

            if (index < 0)
            {
                continue;
            }

            source = operation is StatusArgument or ScanContentArgument or ListInputsArgument or ResetInputBindingsArgument or SetInputTuningArgument or TestInputRumbleArgument or InputBridgeSmokeArgument or ListProfilesArgument or SolMetalStatusArgument or SolMetalGalSmokeArgument
                ? null
                : index + 1 < args.Length
                    ? args[index + 1]
                    : null;
            return operation;
        }

        source = null;
        return null;
    }

    private static string? ValueAfter(string[] args, string argument)
    {
        int index = Array.IndexOf(args, argument);
        return index >= 0 && index + 1 < args.Length ? args[index + 1] : null;
    }

    private static float RequiredFloat(
        string[] args,
        string argument,
        float minimum,
        float maximum
    )
    {
        string? value = ValueAfter(args, argument);
        if (!float.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out float parsed))
        {
            throw new ArgumentException($"{argument} requires a number.");
        }
        return Math.Clamp(parsed, minimum, maximum);
    }

    private static double RequiredDouble(
        string[] args,
        string argument,
        double minimum,
        double maximum
    )
    {
        string? value = ValueAfter(args, argument);
        if (!double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out double parsed))
        {
            throw new ArgumentException($"{argument} requires a number.");
        }
        return Math.Clamp(parsed, minimum, maximum);
    }

    private static int RequiredInt(string[] args, string argument, int minimum, int maximum)
    {
        string? value = ValueAfter(args, argument);
        if (!int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out int parsed))
        {
            throw new ArgumentException($"{argument} requires a whole number.");
        }
        return Math.Clamp(parsed, minimum, maximum);
    }

    private static uint RequiredUInt(string[] args, string argument, uint minimum, uint maximum)
    {
        string? value = ValueAfter(args, argument);
        if (!uint.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out uint parsed))
        {
            throw new ArgumentException($"{argument} requires an unsigned whole number.");
        }
        return Math.Clamp(parsed, minimum, maximum);
    }

    private static bool RequiredBool(string[] args, string argument)
    {
        string? value = ValueAfter(args, argument);
        if (!bool.TryParse(value, out bool parsed))
        {
            throw new ArgumentException($"{argument} requires true or false.");
        }
        return parsed;
    }

    private static void RequireSource(string? source, string operation)
    {
        if (string.IsNullOrWhiteSpace(source))
        {
            throw new ArgumentException($"{operation} requires a source path.");
        }
    }

    private static string OperationName(string operation) => operation.TrimStart('-').Replace("native-", string.Empty);
}
