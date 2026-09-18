# Internal implementation for KubeShell.Shell. Loaded into the parent module scope.

function Get-KubePromptSegment {
    [CmdletBinding()]
    param()
    $session = Get-KubeSession
    $context = $session.Context ?? '?'
    $namespace = $session.Namespace ?? 'default'
    if ($session.Profile) { return "[kube:$($session.Profile):$context/$namespace]" }
    if ($session.ConfigSet) { return "[kube:$($session.ConfigSet):$context/$namespace]" }
    return "[kube:$context/$namespace]"
}
function Enable-KubePrompt {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    if (Get-Variable -Name KubeShellOriginalPrompt -Scope Global -ErrorAction SilentlyContinue) { return }
    if (-not $PSCmdlet.ShouldProcess('global prompt','Add Kubernetes context/namespace segment')) { return }

    $global:KubeShellOriginalPrompt = (Get-Item Function:\prompt).ScriptBlock
    Set-Item Function:\global:prompt -Value {
        $segment = try { Get-KubePromptSegment } catch { '[kube:unavailable]' }
        $base = & $global:KubeShellOriginalPrompt
        "$segment $base"
    }
}
function Disable-KubePrompt {
    [CmdletBinding(SupportsShouldProcess)]
    param()
    $saved = Get-Variable -Name KubeShellOriginalPrompt -Scope Global -ErrorAction SilentlyContinue
    if (-not $saved) { return }
    if (-not $PSCmdlet.ShouldProcess('global prompt','Restore previous prompt')) { return }
    Set-Item Function:\global:prompt -Value $saved.Value
    Remove-Variable KubeShellOriginalPrompt -Scope Global -Force
}
