# Internal implementation for KubeShell.Core. Loaded into the parent module scope.

function Initialize-KubeManagedBackendResolver {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $DependencyRoot)

    $resolverTypeName = 'KubeShell.PowerShell.ManagedBackendAssemblyResolver'
    if (-not ($resolverTypeName -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Reflection;
using System.Runtime.Loader;

namespace KubeShell.PowerShell
{
    public static class ManagedBackendAssemblyResolver
    {
        private static readonly object Gate = new object();
        private static string dependencyRoot;
        private static bool installed;

        public static void Install(string root)
        {
            if (string.IsNullOrWhiteSpace(root))
                throw new ArgumentException("Dependency root is required.", nameof(root));

            lock (Gate)
            {
                dependencyRoot = Path.GetFullPath(root);
                if (!installed)
                {
                    AssemblyLoadContext.Default.Resolving += Resolve;
                    installed = true;
                }
            }
        }

        private static Assembly Resolve(AssemblyLoadContext context, AssemblyName assemblyName)
        {
            string root;
            lock (Gate) { root = dependencyRoot; }
            if (string.IsNullOrWhiteSpace(root) || string.IsNullOrWhiteSpace(assemblyName.Name)) return null;
            string candidate = Path.Combine(root, assemblyName.Name + ".dll");
            return File.Exists(candidate) ? context.LoadFromAssemblyPath(Path.GetFullPath(candidate)) : null;
        }
    }
}
'@
    }

    [KubeShell.PowerShell.ManagedBackendAssemblyResolver]::Install($DependencyRoot)
}

function Import-KubeManagedBackendAssembly {
    [CmdletBinding()]
    param(
        [switch] $Optional,
        [switch] $BuildIfMissing
    )

    if ('KubeShell.Backends.KubernetesClient.KubernetesClientBackend' -as [type]) {
        # The type may have appeared after an earlier host was composed. Recreate the host so the
        # shared Hosting policy can put Managed back in its documented first-priority position.
        if ($null -ne $script:KubeRuntimeHost -and
            (Get-Command Reset-KubeRuntimeComposition -CommandType Function -ErrorAction SilentlyContinue)) {
            Reset-KubeRuntimeComposition
        }
        return $true
    }

    $moduleRoot = Split-Path -Parent $PSScriptRoot
    $backendRoot = Join-Path $moduleRoot '../../Backends/KubeShell.KubernetesClient'
    $outputRoot = Join-Path $backendRoot 'bin/Release/net8.0'
    $backendDll = Join-Path $outputRoot 'KubeShell.KubernetesClient.dll'

    if (-not (Test-Path -LiteralPath $backendDll -PathType Leaf) -and ($BuildIfMissing -or -not $Optional)) {
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            if ($Optional) { return $false }
            throw 'The official KubernetesClient managed backend is not built and the .NET SDK is unavailable.'
        }
        $backendDll = & (Join-Path $backendRoot 'build.ps1') | Select-Object -Last 1
    }
    if (-not (Test-Path -LiteralPath $backendDll -PathType Leaf)) {
        if ($Optional) { return $false }
        throw "Managed Kubernetes backend is missing: $backendDll"
    }

    $officialClientDll = Join-Path $outputRoot 'KubernetesClient.dll'
    if (-not (Test-Path -LiteralPath $officialClientDll -PathType Leaf)) {
        if ($Optional) { return $false }
        throw "KubernetesClient.dll is missing from '$outputRoot'. Rebuild Backends/KubeShell.KubernetesClient."
    }

    Initialize-KubeManagedBackendResolver -DependencyRoot $outputRoot
    $loadContext = [System.Runtime.Loader.AssemblyLoadContext]::Default
    $backendAssembly = @($loadContext.Assemblies | Where-Object { $_.GetName().Name -eq 'KubeShell.KubernetesClient' }) | Select-Object -First 1
    if ($null -eq $backendAssembly) {
        try { $backendAssembly = $loadContext.LoadFromAssemblyPath([IO.Path]::GetFullPath($backendDll)) }
        catch {
            if ($Optional) { return $false }
            throw "Failed to load managed Kubernetes backend '$backendDll': $($_.Exception.Message)"
        }
    }

    try { $null = $backendAssembly.GetType('KubeShell.Backends.KubernetesClient.KubernetesClientBackend', $true, $false) }
    catch {
        if ($Optional) { return $false }
        throw "Managed Kubernetes backend loaded, but its public type could not be resolved: $($_.Exception.Message)"
    }

    # If semantic clients were composed before this optional assembly became available, rebuild
    # composition so the Managed adapter assumes its documented first-priority position.
    if (Get-Command Reset-KubeRuntimeComposition -CommandType Function -ErrorAction SilentlyContinue) {
        Reset-KubeRuntimeComposition
    }
    return $true
}


function New-KubeManagedExplicitBackend {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Server,
        [string] $Token,
        [Security.Cryptography.X509Certificates.X509Certificate2] $ClientCertificate,
        [Security.Cryptography.X509Certificates.X509Certificate2] $CertificateAuthority,
        [switch] $SkipCertificateCheck,
        [string] $DefaultNamespace
    )

    [void](Import-KubeManagedBackendAssembly -BuildIfMissing)
    $managedType = 'KubeShell.Backends.KubernetesClient.KubernetesClientBackend' -as [type]
    if ($null -eq $managedType) { throw 'Managed Kubernetes backend type is unavailable after loading.' }

    $method = $managedType.GetMethod('CreateExplicit')
    if ($null -eq $method) { throw 'Managed Kubernetes backend does not expose CreateExplicit.' }

    $tokenValue = if ([string]::IsNullOrWhiteSpace($Token)) { $null } else { [string]$Token }
    $arguments = [object[]]@(
        $Server,
        $tokenValue,
        $ClientCertificate,
        $CertificateAuthority,
        [bool]$SkipCertificateCheck,
        $DefaultNamespace
    )
    return [KubeShell.Runtime.IKubeBackend]$method.Invoke($null, $arguments)
}

function New-KubeManagedExplicitRuntimeClients {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [uri] $Server,
        [string] $Token,
        [Security.Cryptography.X509Certificates.X509Certificate2] $ClientCertificate,
        [Security.Cryptography.X509Certificates.X509Certificate2] $CertificateAuthority,
        [switch] $SkipCertificateCheck,
        [string] $DefaultNamespace
    )

    $backend = New-KubeManagedExplicitBackend `
        -Server $Server `
        -Token $Token `
        -ClientCertificate $ClientCertificate `
        -CertificateAuthority $CertificateAuthority `
        -SkipCertificateCheck:$SkipCertificateCheck `
        -DefaultNamespace $DefaultNamespace

    $selector = [KubeShell.Runtime.KubeBackendRouter]::new(
        [KubeShell.Runtime.IKubeBackend[]]@($backend)
    )
    $operationClient = [KubeShell.Runtime.KubeOperationClient]::new(
        [KubeShell.Runtime.IKubeBackendSelector]$selector
    )

    # Return only semantic Runtime ports. The concrete backend remains inside the selector/composition
    # boundary and is never exposed to KubeShell.Api or future frontend consumers.
    [pscustomobject]@{
        OperationClient = $operationClient
        ResourceClient  = [KubeShell.Runtime.KubeResourceClient]::new($operationClient)
        DiscoveryClient = [KubeShell.Runtime.KubeDiscoveryClient]::new([KubeShell.Runtime.IKubeBackendSelector]$selector)
    }
}
