Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Core/KubeShell.Core.psd1') -Scope Local
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Configuration/KubeShell.Configuration.psd1') -Scope Local
Import-Module (Join-Path $PSScriptRoot '../KubeShell.Resources/KubeShell.Resources.psd1') -Scope Local

$script:ContextStack = [Collections.Generic.Stack[object]]::new()
$script:Bookmarks = @{}
$script:CompletionEnabled = $false
$script:SchemaCompletionCache = @{}

# Shell features share one module scope; files separate persistent shell state, UI helpers, and completion.
$privateScripts = @(
    'Bookmarks.ps1'
    'Context.ps1'
    'Prompt.ps1'
    'Selection.ps1'
    'Kubectl.ps1'
    'Completion.ps1'
)
foreach ($privateScript in $privateScripts) {
    . (Join-Path $PSScriptRoot "Private/$privateScript")
}

Export-ModuleMember -Function @(
    'Get-KubeContext','Set-KubeContext','Get-KubeCurrentNamespace','Set-KubeNamespace','Push-KubeContext','Pop-KubeContext',
    'Get-KubePromptSegment','Enable-KubePrompt','Disable-KubePrompt','Set-KubeBookmark','Get-KubeBookmark','Remove-KubeBookmark','Use-KubeBookmark',
    'Select-KubeResource','Invoke-Kubectl','Enable-KubeCompletion'
)
