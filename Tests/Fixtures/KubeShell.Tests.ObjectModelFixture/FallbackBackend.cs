using KubeShell.Runtime;

namespace KubeShell.Backends.KubectlProcess;

// Loaded from the fixture assembly by KubeShellHost.FindLoadedType. This avoids depending on a
// real kubectl executable while exercising optional-adapter composition and fallback behavior.
public sealed class KubectlProcessBackend : IKubeBackend, IDisposable
{
    public static int Instances { get; private set; }
    public static int DisposeCalls { get; private set; }
    public static void ResetCounters() { Instances = 0; DisposeCalls = 0; }

    public KubectlProcessBackend(string executable)
    {
        if (string.IsNullOrWhiteSpace(executable)) throw new ArgumentException("Executable is required.", nameof(executable));
        Instances++;
    }

    public string Id => "fixture-process";

    public ValueTask<KubeOperationSupport> EvaluateAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default) =>
        ValueTask.FromResult(KubeOperationSupport.Unsupported("fixture.unsupported", "Fixture backend is composition-only."));

    public ValueTask<KubeOperationResult> ExecuteAsync(
        KubeOperation operation,
        KubeTarget target,
        KubeExecutionContext executionContext,
        CancellationToken cancellationToken = default) =>
        ValueTask.FromException<KubeOperationResult>(new KubeException(KubeErrorKind.Unsupported, "Fixture backend does not execute operations."));

    public void Dispose() => DisposeCalls++;
}
