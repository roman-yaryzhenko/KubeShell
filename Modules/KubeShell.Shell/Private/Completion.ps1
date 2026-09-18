# Internal implementation for KubeShell.Shell. Loaded into the parent module scope.

function Get-KubeCompletionValues {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Context','Namespace','Pod','Deployment','Service','Node','Kind','Container','SchemaField','ConfigSet','Profile')]
        [string] $Type,
        [string] $Namespace,
        [string] $Pod,
        [string] $Resource,
        [string] $ApiVersion
    )
    try {
        switch ($Type) {
            'Context' { @(Get-KubeContext | ForEach-Object Name) }
            'ConfigSet' { @(Get-KubeConfigSet | ForEach-Object Name) }
            'Profile' { @(Get-KubeProfile | ForEach-Object Name) }
            'Namespace' { @(Get-KubeNamespace | ForEach-Object Name) }
            'Pod' { @(Get-KubePod -Namespace ($Namespace ?? (Get-KubeCurrentNamespace)) | ForEach-Object Name) }
            'Deployment' { @(Get-KubeDeployment -Namespace ($Namespace ?? (Get-KubeCurrentNamespace)) | ForEach-Object Name) }
            'Service' { @(Get-KubeService -Namespace ($Namespace ?? (Get-KubeCurrentNamespace)) | ForEach-Object Name) }
            'Node' { @(Get-KubeNode | ForEach-Object Name) }
            'Kind' { @(Get-KubeKind | ForEach-Object Name) }
            'SchemaField' {
                if (-not $Resource) { return @() }
                $cacheKey = "$Resource|$ApiVersion"
                $now = [DateTimeOffset]::UtcNow
                $cached = $script:SchemaCompletionCache[$cacheKey]
                if ($cached -and ($now - $cached.Timestamp).TotalSeconds -lt 60) {
                    return @($cached.Values)
                }

                $values = @(Get-KubeSchemaField -Resource $Resource -ApiVersion $ApiVersion | ForEach-Object Path)
                $script:SchemaCompletionCache[$cacheKey] = [pscustomobject]@{
                    Timestamp = $now
                    Values    = $values
                }
                return $values
            }
            'Container' {
                if (-not $Pod) { return @() }
                @(Get-KubePod -Name $Pod -Namespace ($Namespace ?? (Get-KubeCurrentNamespace)) | Get-KubeContainer | ForEach-Object Name)
            }
        }
    }
    catch { @() }
}
function Enable-KubeCompletion {
    [CmdletBinding()]
    param()
    if ($script:CompletionEnabled) { return }

    # Registered completers execute later, outside the module import call stack. Keep an
    # explicit PSModuleInfo handle so private completion helpers run in this module's scope.
    $shellModule = $ExecutionContext.SessionState.Module

    $contextCompleter = {
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $values = & $shellModule { Get-KubeCompletionValues Context }
        $values | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
            [Management.Automation.CompletionResult]::new($_,$_, 'ParameterValue', $_)
        }
    }.GetNewClosure()
    Register-ArgumentCompleter -CommandName Set-KubeContext -ParameterName Name -ScriptBlock $contextCompleter
    Register-ArgumentCompleter -CommandName Push-KubeContext -ParameterName Context -ScriptBlock $contextCompleter

    $namespaceCompleter = {
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $values = & $shellModule { Get-KubeCompletionValues Namespace }
        $values | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
            [Management.Automation.CompletionResult]::new($_,$_, 'ParameterValue', $_)
        }
    }.GetNewClosure()
    Register-ArgumentCompleter -CommandName Set-KubeNamespace,Get-KubePod,Get-KubeDeployment,Get-KubeService,Get-KubeStatefulSet,Get-KubeDaemonSet -ParameterName Namespace -ScriptBlock $namespaceCompleter

    $containerCompleter = {
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $podValue = $fakeBoundParameters['Pod']
        $podName = & $shellModule {
            param($value)
            if ($value -is [string]) { return $value }
            return Get-KubePropertyValue $value @('Name')
        } $podValue
        if (-not $podName) { return }
        $namespace = $fakeBoundParameters['Namespace']
        $values = & $shellModule {
            param($resolvedNamespace,$resolvedPod)
            Get-KubeCompletionValues Container -Namespace $resolvedNamespace -Pod $resolvedPod
        } $namespace $podName
        $values | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
            [Management.Automation.CompletionResult]::new($_,$_, 'ParameterValue', $_)
        }
    }.GetNewClosure()
    Register-ArgumentCompleter -CommandName Get-KubeLog,Enter-KubePod,Invoke-KubeExec -ParameterName Container -ScriptBlock $containerCompleter
    Register-ArgumentCompleter -CommandName Enter-KubeDebugPod -ParameterName TargetContainer -ScriptBlock $containerCompleter

    foreach ($entry in @(
        @{ Commands=@('Get-KubePod'); Parameter='Name'; Type='Pod' },
        @{ Commands=@('Get-KubeLog','Enter-KubePod','Invoke-KubeExec','Enter-KubeDebugPod'); Parameter='Pod'; Type='Pod' },
        @{ Commands=@('Get-KubeDeployment'); Parameter='Name'; Type='Deployment' },
        @{ Commands=@('Get-KubeService'); Parameter='Name'; Type='Service' },
        @{ Commands=@('Get-KubeNode'); Parameter='Name'; Type='Node' },
        @{ Commands=@('Enter-KubeNode'); Parameter='Node'; Type='Node' },
        @{ Commands=@('Get-KubeResource','Watch-KubeResource','Get-KubeSchema','Get-KubeSchemaField'); Parameter='Resource'; Type='Kind' }
    )) {
        $type = $entry.Type
        $completer = {
            param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
            $namespace = $fakeBoundParameters['Namespace']
            $values = & $shellModule {
                param($resolvedType,$resolvedNamespace)
                Get-KubeCompletionValues $resolvedType -Namespace $resolvedNamespace
            } $type $namespace
            $values | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [Management.Automation.CompletionResult]::new($_,$_, 'ParameterValue', $_)
            }
        }.GetNewClosure()
        Register-ArgumentCompleter -CommandName $entry.Commands -ParameterName $entry.Parameter -ScriptBlock $completer
    }

    $schemaFieldCompleter = {
        param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
        $resource = [string]$fakeBoundParameters['Resource']
        if ([string]::IsNullOrWhiteSpace($resource)) { return }
        $apiVersion = [string]$fakeBoundParameters['ApiVersion']
        $values = & $shellModule {
            param($resolvedResource,$resolvedApiVersion)
            Get-KubeCompletionValues SchemaField -Resource $resolvedResource -ApiVersion $resolvedApiVersion
        } $resource $apiVersion
        $values | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
            [Management.Automation.CompletionResult]::new($_,$_, 'ParameterValue', $_)
        }
    }.GetNewClosure()
    Register-ArgumentCompleter -CommandName Get-KubeSchema -ParameterName Field -ScriptBlock $schemaFieldCompleter

    foreach ($entry in @(
        @{ Commands=@('Use-KubeConfigSet','Set-KubeConfigSet','Remove-KubeConfigSet','Invoke-KubeConfigSet'); Parameter='Name'; Type='ConfigSet' },
        @{ Commands=@('Use-KubeProfile','Set-KubeProfile','Remove-KubeProfile','Invoke-KubeProfile'); Parameter='Name'; Type='Profile' },
        @{ Commands=@('New-KubeProfile'); Parameter='ConfigSet'; Type='ConfigSet' }
    )) {
        $type = $entry.Type
        $completer = {
            param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)
            $values = & $shellModule { param($resolvedType) Get-KubeCompletionValues $resolvedType } $type
            $values | Where-Object { $_ -like "$wordToComplete*" } | ForEach-Object {
                [Management.Automation.CompletionResult]::new($_,$_,'ParameterValue',$_)
            }
        }.GetNewClosure()
        Register-ArgumentCompleter -CommandName $entry.Commands -ParameterName $entry.Parameter -ScriptBlock $completer
    }

    $script:CompletionEnabled = $true
}
