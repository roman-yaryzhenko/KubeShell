using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using KubeShell.Runtime;

namespace KubeShell.Backends.KubectlProcess;

public sealed record KubectlProcessResult(int ExitCode, string StdOut, string StdErr, string[] Arguments)
{
    public bool IsSuccess => ExitCode == 0;
}

/// <summary>
/// Raw external-kubectl process transport. It owns executable invocation, target argument/environment
/// projection and process lifetime only; Kubernetes semantic support policy remains in KubectlProcessBackend.
/// </summary>
public sealed class KubectlProcessTransport
{
    public KubectlProcessTransport(string executable = "kubectl")
    {
        if (string.IsNullOrWhiteSpace(executable))
            throw new ArgumentException("kubectl executable cannot be empty.", nameof(executable));
        Executable = executable;
    }

    public string Executable { get; }

    public KubectlProcessResult Execute(
        KubeTarget target,
        IEnumerable<string> arguments,
        string? inputText = null,
        bool includeContext = true,
        bool includeNamespace = true) =>
        ExecuteAsync(target, arguments, inputText, includeContext, includeNamespace).GetAwaiter().GetResult();

    public async ValueTask<KubectlProcessResult> ExecuteAsync(
        KubeTarget target,
        IEnumerable<string> arguments,
        string? inputText = null,
        bool includeContext = true,
        bool includeNamespace = true,
        CancellationToken cancellationToken = default)
    {
        string[] effective = BuildEffectiveArguments(target, arguments, includeContext, includeNamespace);
        ProcessStartInfo psi = CreateProcessStartInfo(target, effective, false, true, true, inputText is not null, true);
        using Process process = new() { StartInfo = psi };
        try
        {
            if (!process.Start()) throw new KubeException(KubeErrorKind.Transport, "Failed to start kubectl.");
            Task<string> stdoutTask = process.StandardOutput.ReadToEndAsync();
            Task<string> stderrTask = process.StandardError.ReadToEndAsync();
            try
            {
                if (inputText is not null)
                {
                    await process.StandardInput.WriteAsync(inputText.AsMemory(), cancellationToken).ConfigureAwait(false);
                    process.StandardInput.Close();
                }
                await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException ex)
            {
                try { if (!process.HasExited) process.Kill(entireProcessTree: true); } catch { }
                throw new KubeException(KubeErrorKind.Cancelled, "kubectl operation was cancelled.", ex);
            }
            return new KubectlProcessResult(process.ExitCode, await stdoutTask.ConfigureAwait(false), await stderrTask.ConfigureAwait(false), effective);
        }
        catch (KubeException) { throw; }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
        {
            throw new KubeException(KubeErrorKind.Transport, "kubectl process failed: " + ex.Message, ex);
        }
    }

    public ProcessStartInfo CreateProcessStartInfo(
        KubeTarget target,
        IEnumerable<string> arguments,
        bool applyTargetArguments = true,
        bool redirectStandardOutput = false,
        bool redirectStandardError = false,
        bool redirectStandardInput = false,
        bool createNoWindow = false,
        bool includeContext = true,
        bool includeNamespace = true)
    {
        string[] args = applyTargetArguments ? BuildEffectiveArguments(target, arguments, includeContext, includeNamespace) : arguments.ToArray();
        ProcessStartInfo psi = new()
        {
            FileName = Executable,
            UseShellExecute = false,
            RedirectStandardOutput = redirectStandardOutput,
            RedirectStandardError = redirectStandardError,
            RedirectStandardInput = redirectStandardInput,
            CreateNoWindow = createNoWindow
        };
        ApplyEnvironment(target, psi);
        foreach (string arg in args) psi.ArgumentList.Add(arg);
        return psi;
    }

    public static string[] BuildEffectiveArguments(
        KubeTarget target,
        IEnumerable<string> arguments,
        bool includeContext = true,
        bool includeNamespace = true)
    {
        string[] original = arguments.Select(x => x ?? string.Empty).ToArray();
        if (original.Length > 0 && string.Equals(original[0], "config", StringComparison.Ordinal)) return original;
        List<string> effective = new();
        if (includeContext && !string.IsNullOrEmpty(target.Context) && !HasArgument(original, "--context"))
        { effective.Add("--context"); effective.Add(target.Context); }
        if (includeNamespace && !string.IsNullOrWhiteSpace(target.DefaultNamespace) && !HasArgument(original, "--namespace", "-n", "--all-namespaces", "-A"))
        { effective.Add("--namespace"); effective.Add(target.DefaultNamespace); }
        effective.AddRange(original);
        return effective.ToArray();
    }

    public static bool CanRepresentKubeConfigPaths(KubeTarget target)
    {
        ArgumentNullException.ThrowIfNull(target);
        return target.KubeConfigPaths.All(path => path.IndexOf(Path.PathSeparator) < 0);
    }

    public static void ApplyEnvironment(KubeTarget target, ProcessStartInfo processStartInfo)
    {
        ArgumentNullException.ThrowIfNull(target);
        ArgumentNullException.ThrowIfNull(processStartInfo);
        if (!CanRepresentKubeConfigPaths(target))
            throw new KubeException(
                KubeErrorKind.Unsupported,
                $"The external kubectl compatibility backend cannot encode a kubeconfig path containing '{Path.PathSeparator}' in KUBECONFIG.",
                target: target,
                code: "kubectl-process.kubeconfig-unrepresentable");
        if (target.KubeConfigPaths.Length > 0)
            processStartInfo.Environment["KUBECONFIG"] = string.Join(Path.PathSeparator, target.KubeConfigPaths);
    }

    private static bool HasArgument(IEnumerable<string> arguments, params string[] names)
    {
        foreach (string argument in arguments)
            foreach (string name in names)
                if (string.Equals(argument, name, StringComparison.Ordinal) || argument.StartsWith(name + "=", StringComparison.Ordinal)) return true;
        return false;
    }
}
