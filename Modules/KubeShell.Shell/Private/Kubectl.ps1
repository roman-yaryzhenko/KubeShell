# Internal implementation for KubeShell.Shell. Loaded into the parent module scope.

function Invoke-Kubectl {
    [CmdletBinding()]
    param([Parameter(Position=0,ValueFromRemainingArguments)][string[]]$ArgumentList)
    Invoke-KubectlNative $ArgumentList -IgnoreExitCode
}
