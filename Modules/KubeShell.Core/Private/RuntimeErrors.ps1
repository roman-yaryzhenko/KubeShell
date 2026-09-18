# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function ConvertTo-KubeRuntimeDryRunMode {
    [CmdletBinding()]
    param([ValidateSet('None','Client','Server')] [string] $DryRun = 'None')

    return [KubeShell.Runtime.KubeDryRunMode]([Enum]::Parse([KubeShell.Runtime.KubeDryRunMode], $DryRun, $true))
}

function New-KubeRuntimeErrorRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [KubeShell.Runtime.KubeException] $Exception,
        [object] $TargetObject
    )

    $category = switch ([string]$Exception.Kind) {
        'NotFound' { [Management.Automation.ErrorCategory]::ObjectNotFound; break }
        'Configuration' { [Management.Automation.ErrorCategory]::InvalidArgument; break }
        'InvalidResource' { [Management.Automation.ErrorCategory]::InvalidArgument; break }
        'Serialization' { [Management.Automation.ErrorCategory]::InvalidData; break }
        'Authentication' { [Management.Automation.ErrorCategory]::SecurityError; break }
        'Authorization' { [Management.Automation.ErrorCategory]::PermissionDenied; break }
        'Conflict' { [Management.Automation.ErrorCategory]::ResourceBusy; break }
        'Unsupported' { [Management.Automation.ErrorCategory]::NotImplemented; break }
        'Indeterminate' { [Management.Automation.ErrorCategory]::InvalidOperation; break }
        'Unavailable' { [Management.Automation.ErrorCategory]::ResourceUnavailable; break }
        'Cancelled' { [Management.Automation.ErrorCategory]::OperationStopped; break }
        default { [Management.Automation.ErrorCategory]::InvalidOperation }
    }

    $errorId = "KubeShell.Runtime.$($Exception.Kind)"
    return [Management.Automation.ErrorRecord]::new($Exception, $errorId, $category, $TargetObject)
}
