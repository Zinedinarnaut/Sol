using System;
using System.Runtime.InteropServices;
using Ryujinx.Common.Configuration;

namespace Sol.Engine.NativeHost;

public static class NativeExports
{
    public const int ProtocolVersion = 1;

    [Flags]
    private enum Capability
    {
        Configuration = 1 << 0,
        HeadlessLaunch = 1 << 1,
        EmbeddedSurface = 1 << 2,
        SessionControl = 1 << 3,
        BackendManagement = 1 << 4,
        NativeCocoaWindow = 1 << 5,
        NativeDialogs = 1 << 6,
        NativeInputRouting = 1 << 7,
    }

    [UnmanagedCallersOnly(EntryPoint = "sol_engine_protocol_version")]
    public static int GetProtocolVersion() => ProtocolVersion;

    [UnmanagedCallersOnly(EntryPoint = "sol_engine_capabilities")]
    public static int GetCapabilities() =>
        (int)(
            Capability.Configuration |
            Capability.HeadlessLaunch |
            Capability.EmbeddedSurface |
            Capability.SessionControl |
            Capability.BackendManagement |
            Capability.NativeCocoaWindow |
            Capability.NativeDialogs |
            Capability.NativeInputRouting
        );

    [UnmanagedCallersOnly(EntryPoint = "sol_engine_default_vsync_mode")]
    public static int GetDefaultVSyncMode() => (int)VSyncMode.Switch;
}
