using System.Runtime.Versioning;

namespace Ryujinx.Cpu.AppleHv
{
    /// <summary>
    /// Exposes bounded lifecycle state for hosts that keep the emulation core
    /// loaded between game sessions.
    /// </summary>
    [SupportedOSPlatform("macos")]
    public static class HvLifecycleDiagnostics
    {
        public static int ActiveAddressSpaces => HvVm.ActiveAddressSpaces;

        public static int ActiveVcpus => HvVcpuPool.Instance.ActiveVcpus;
    }
}
