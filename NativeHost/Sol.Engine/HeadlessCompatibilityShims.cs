namespace DiscordRPC
{
    public readonly struct Timestamps
    {
        public static Timestamps Now => new();
    }
}

namespace Ryujinx.Ava.Systems
{
    internal static class Updater
    {
        public static void CleanupUpdate()
        {
        }
    }

    public static class DiscordIntegrationModule
    {
        public static DiscordRPC.Timestamps EmulatorStartedAt { get; set; }

        public static void Initialize()
        {
        }

        public static void Exit()
        {
        }
    }
}
