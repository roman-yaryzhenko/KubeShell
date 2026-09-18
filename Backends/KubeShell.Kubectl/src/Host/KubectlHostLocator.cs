using System.Reflection;
using System.Runtime.InteropServices;

namespace KubeShell.Backends.Kubectl;

/// <summary>
/// Resolves the bundled kubeshell-kubectl-host executable for both the long-lived IPC transport
/// and short-lived embedded-kubectl compatibility workers. Keeping one locator prevents the two
/// execution paths from silently selecting different binaries.
/// </summary>
public static class KubectlHostLocator
{
    public static string Resolve(string? explicitPath = null)
    {
        string? path = TryResolveBundled(explicitPath);
        return path ?? (OperatingSystem.IsWindows() ? "kubeshell-kubectl-host.exe" : "kubeshell-kubectl-host");
    }

    public static string? TryResolveBundled(string? explicitPath = null)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath)) return Prepare(explicitPath);

        string? environment = Environment.GetEnvironmentVariable("KUBESHELL_KUBECTL_HOST");
        if (!string.IsNullOrWhiteSpace(environment)) return Prepare(environment);

        string executable = OperatingSystem.IsWindows() ? "kubeshell-kubectl-host.exe" : "kubeshell-kubectl-host";
        string baseDirectory = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location) ?? AppContext.BaseDirectory;
        string runtimePack = Path.Combine(baseDirectory, "runtimes", PortableRuntimeIdentifier(), "native", executable);
        if (File.Exists(runtimePack)) return Prepare(runtimePack);

        string besideAssembly = Path.Combine(baseDirectory, executable);
        return File.Exists(besideAssembly) ? Prepare(besideAssembly) : null;
    }

    private static string PortableRuntimeIdentifier()
    {
        string os = OperatingSystem.IsWindows() ? "win" : OperatingSystem.IsMacOS() ? "osx" : "linux";
        string architecture = RuntimeInformation.OSArchitecture switch
        {
            Architecture.X64 => "x64",
            Architecture.X86 => "x86",
            Architecture.Arm64 => "arm64",
            Architecture.Arm => "arm",
            _ => RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant()
        };
        return $"{os}-{architecture}";
    }

    private static string Prepare(string path)
    {
        if (OperatingSystem.IsWindows() || !File.Exists(path)) return path;
        try
        {
            UnixFileMode mode = File.GetUnixFileMode(path);
            UnixFileMode execute = UnixFileMode.UserExecute | UnixFileMode.GroupExecute | UnixFileMode.OtherExecute;
            if ((mode & execute) == 0)
            {
                // ZIP extraction can drop the executable bit. Repair only our bundled helper.
                File.SetUnixFileMode(path, mode | UnixFileMode.UserExecute);
            }
        }
        catch (PlatformNotSupportedException) { }
        return path;
    }
}
