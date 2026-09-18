namespace KubeShell.Backends.Kubectl;

internal sealed class KubectlWireException : Exception
{
    internal KubectlWireException(WireError error) : base(error.Message) => Error = error;
    internal WireError Error { get; }
}
