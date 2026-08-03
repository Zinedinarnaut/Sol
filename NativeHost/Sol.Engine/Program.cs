using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.Headless;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Ryujinx.Ava;

internal static class Program
{
    public static string Version { get; private set; } = ReleaseInformation.Version;

    [STAThread]
    public static int Main(string[] args)
    {
        Version = ReleaseInformation.Version;
        args = RemoveCompatibilityArgument(args, "--no-gui");
        args = RemoveCompatibilityArgument(args, "nogui");
        NativeSessionProtocol.Start();

        if (NativeBackendManagement.TryRun(args, out int managementExitCode))
        {
            NativeSessionProtocol.Stop();
            Environment.Exit(managementExitCode);
            return managementExitCode;
        }

        NativeSessionProtocol.MarkLaunching();
        int exitCode;

        try
        {
            HeadlessRyujinx.Entrypoint(args);
            exitCode = 0;
        }
        catch (Exception exception)
        {
            NativeSessionProtocol.PublishError(exception.ToString());
            exitCode = 1;
        }
        finally
        {
            NativeSessionProtocol.CompletePlaytimeTracking();
            NativeSessionProtocol.Stop();
        }

        // Some SDL input backends keep non-background worker threads alive
        // after a command-only run. The session has already shut down cleanly,
        // so finish the UI-free host deterministically.
        Environment.Exit(exitCode);
        return exitCode;
    }

    internal static void PrintSystemInfo()
    {
        Logger.Notice.Print(LogClass.Application, $"Sol Engine Version: {Version}");
        Logger.Notice.Print(LogClass.Application, $".NET Runtime: {RuntimeInformation.FrameworkDescription}");
        Logger.Notice.Print(
            LogClass.Application,
            $"Operating System: {RuntimeInformation.OSDescription} ({RuntimeInformation.OSArchitecture})"
        );
        Logger.Notice.Print(
            LogClass.Application,
            $"CPU: {Environment.ProcessorCount} logical cores"
        );
    }

    internal static void ProcessUnhandledException(
        object sender,
        Exception initialException,
        bool isTerminating
    )
    {
        Logger.Log log = Logger.Error ?? Logger.Notice;
        IEnumerable<Exception> exceptions = initialException is AggregateException aggregate
            ? aggregate.InnerExceptions
            : [initialException];

        foreach (Exception exception in exceptions)
        {
            log.PrintMsg(LogClass.Application, $"Unhandled exception caught: {exception}");
        }

        if (isTerminating)
        {
            Logger.Flush();
            Exit();
        }
    }

    internal static void Exit()
    {
        Ryujinx.Ava.Systems.DiscordIntegrationModule.Exit();
        Logger.Shutdown();
    }

    private static string[] RemoveCompatibilityArgument(string[] args, string value)
    {
        List<string> filtered = [.. args];
        filtered.Remove(value);
        return [.. filtered];
    }
}
