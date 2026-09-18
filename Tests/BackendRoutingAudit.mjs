import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(process.argv[2] ?? path.join(import.meta.dirname, '..'));
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const violations = [];

const router = read('Runtime/KubeShell.Runtime/src/Backends/KubeBackendRouter.cs');
const resourceClient = read('Runtime/KubeShell.Runtime/src/Resources/KubeResourceClient.cs');
if (!router.includes('public interface IKubeBackendSelector') || !router.includes('KubeBackendRouter : IKubeBackendSelector'))
    violations.push('Runtime does not expose a backend-neutral selector port.');
if (!router.includes('KubeCapabilityRequest<TBackend>') || !/SelectCapabilityAsync<TBackend>\(\s*KubeCapabilityRequest<TBackend> request/.test(router))
    violations.push('Specialized capability request and semantic port are not linked by the type system.');
if (!router.includes('KubeSupportState.Unknown') || !router.includes('KubeSupportState.Unavailable'))
    violations.push('Shared selector does not encode explicit Unknown/Unavailable policy.');
if (!router.includes('effective.ToFailureKind()'))
    violations.push('Shared selector does not preserve Unknown through the Runtime support-state mapping.');
const unknownRank = Number(router.match(/KubeSupportState\.Unknown => (\d+)/)?.[1] ?? -1);
const unavailableRank = Number(router.match(/KubeSupportState\.Unavailable => (\d+)/)?.[1] ?? -1);
if (!(unknownRank > unavailableRank))
    violations.push('Unknown can be hidden by a definite Unavailable decision when no backend is Supported.');
const resourceModels = read('Runtime/KubeShell.Runtime/src/Resources/ResourceModels.cs');
if (!resourceModels.includes('A single Kubernetes resource identity cannot use all-namespaces scope'))
    violations.push('ResourceIdentity still permits ambiguous all-namespaces item identity.');
const errorContract = read('Runtime/KubeShell.Runtime/src/Errors/KubeException.cs');
if (!errorContract.includes('Indeterminate'))
    violations.push('Runtime error taxonomy does not expose Indeterminate.');
const operationClientStart = resourceClient.indexOf('public sealed class KubeOperationClient');
const resourceExecutionClientStart = resourceClient.indexOf('public sealed class KubeResourceExecutionClient');
const operationClient = resourceClient.slice(operationClientStart, resourceExecutionClientStart);
if (!/SelectOperationAsync[\s\S]*backend\.ExecuteAsync/.test(operationClient))
    violations.push('KubeOperationClient does not select before one-shot execution.');
if ((operationClient.match(/SelectOperationAsync/g) ?? []).length !== 1 ||
    (operationClient.match(/backend\.ExecuteAsync/g) ?? []).length !== 1)
    violations.push('KubeOperationClient does not preserve exactly one selection and one execution attempt.');
if (!/IKubeResourceClient[\s\S]*KubeExecutionContext\? executionContext/.test(resourceClient))
    violations.push('Resource facade does not expose Runtime execution context for Provider/Shell callers.');
const richStart = resourceClient.indexOf('public sealed class KubeResourceExecutionClient');
const narrowStart = resourceClient.indexOf('public sealed class KubeResourceClient');
const richFacade = resourceClient.slice(richStart, narrowStart);
const narrowFacade = resourceClient.slice(narrowStart);
if (!richFacade.includes('new KubeCreateOperation') || /CreateAsync[\s\S]{0,900}Exists(?:Async)?\s*\(/.test(richFacade))
    violations.push('Rich resource Create is not a direct atomic KubeCreateOperation projection.');
if (!richFacade.includes('new KubeReplaceOperation'))
    violations.push('Rich resource Replace is not a direct KubeReplaceOperation projection.');
if (!narrowFacade.includes('_execution.CreateAsync') || !narrowFacade.includes('_execution.ReplaceAsync'))
    violations.push('Narrow resource facade does not unwrap the shared rich execution implementation.');
if (!resourceClient.includes('CancellationToken cancellationToken = default') || !resourceClient.includes('ValueTask<IReadOnlyList<KubeResource>> GetAsync'))
    violations.push('Resource facade does not expose cancellable async CRUD for future non-PowerShell frontends.');
if (!resourceClient.includes('ValidateConcurrency(options?.Concurrency, identity, target)'))
    violations.push('Resource facade does not validate RequireUnchanged preconditions before backend routing.');
const wireSerializer = read('Runtime/KubeShell.Runtime/src/Serialization/KubeWireSerializer.cs');
if (!wireSerializer.includes('KubeNamespaceScopeKind.Default when target is not null => target.DefaultNamespace'))
    violations.push('Mutation identity validation ignores the effective target default namespace.');

for (const relative of [
    'Runtime/KubeShell.Runtime/src/Discovery/KubeDiscovery.cs',
    'Runtime/KubeShell.Runtime/src/Configuration/KubeConfigView.cs',
    'Runtime/KubeShell.Runtime/src/Schema/KubeSchema.cs',
    'Runtime/KubeShell.Runtime/src/Watch/KubeWatch.cs',
    'Runtime/KubeShell.Runtime/src/Logs/KubeLogs.cs',
    'Runtime/KubeShell.Runtime/src/Copy/KubeCopy.cs',
    'Runtime/KubeShell.Runtime/src/Debug/KubeDebug.cs',
    'Runtime/KubeShell.Runtime/src/Diagnostics/KubeDiagnostics.cs',
]) {
    const text = read(relative);
    if (!text.includes('IKubeBackendSelector') || !text.includes('SelectCapabilityAsync'))
        violations.push(`${relative}: specialized client does not depend on the selector port.`);
    if (/private readonly KubeBackendRouter|OfType<IKube|foreach\s*\(IKubeBackend\s+backend/.test(text))
        violations.push(`${relative}: contains concrete/first-interface routing policy.`);
}

const diagnostics = read('Runtime/KubeShell.Runtime/src/Diagnostics/KubeDiagnostics.cs');
if (diagnostics.includes('IKubeDiagnosticsBackend'))
    violations.push('Diagnostics remains a fat backend interface instead of segregated capability ports.');
for (const port of ['IKubeAccessReviewBackend','IKubePodMetricsBackend','IKubeNodeMetricsBackend','IKubeDnsProbeBackend']) {
    if (!diagnostics.includes(`interface ${port}`))
        violations.push(`Diagnostics is missing narrow port ${port}.`);
}

const managed = read('Backends/KubeShell.KubernetesClient/src/KubernetesClientBackend.cs');
if (!/EvaluateLocalSemantics[\s\S]*ResolveResourceAsync/.test(managed) || !managed.includes('descriptor.Verbs.Contains(verb)'))
    violations.push('Managed Supported does not prove discovered resource/verb support.');
if (!managed.includes('_sessions.Create(target)'))
    violations.push('Managed discovery capability does not prove target/session availability before Supported.');
if (!managed.includes('IKubeCapabilityEvaluator') || !managed.includes('KubeDiscoveryCapabilityRequest'))
    violations.push('Managed discovery is not capability-evaluated.');

const sessionFactory = read('Backends/KubeShell.KubernetesClient/src/KubernetesSessionFactory.cs');
if (!sessionFactory.includes('managed.target.kubeconfig') || !sessionFactory.includes('KubeExecutionContext executionContext'))
    violations.push('Managed session/cache identity does not fail closed on target config and include execution identity.');
if (!sessionFactory.includes('EffectiveGroups') || !sessionFactory.includes('EffectiveExtra'))
    violations.push('Managed discovery cache identity omits impersonation groups/extra.');

const responseMapper = read('Backends/KubeShell.KubernetesClient/src/KubernetesResponseMapper.cs');
for (const mapping of ['400 => KubeErrorKind.InvalidResource','405 => KubeErrorKind.Unsupported','409 => KubeErrorKind.Conflict','422 => KubeErrorKind.InvalidResource']) {
    if (!responseMapper.includes(mapping)) violations.push(`Managed error taxonomy is missing ${mapping}.`);
}

const kubectl = read('Backends/KubeShell.Kubectl/src/KubectlBackend.cs');
const support = read('Backends/KubeShell.Kubectl/src/Support/KubectlSupportEvaluator.cs');
if (!kubectl.includes('IKubeCapabilityEvaluator') || !support.includes('EvaluateCapabilityAsync'))
    violations.push('Go host backend does not evaluate specialized semantic capabilities.');
for (const marker of ['EvaluateScale(', 'descriptor.SubresourceDetails.TryGetValue("scale"', 'EvaluateRolloutUndo(', 'EvaluateRolloutRestart(', 'EvaluateSetImage(', 'EvaluateRolloutStatus(', 'EvaluateDebugAsync(']) {
    if (!support.includes(marker)) violations.push(`Go support evaluation is missing request-specific parity marker ${marker}.`);
}

const processBackend = read('Backends/KubeShell.KubectlProcess/src/KubectlProcessBackend.cs');
const goErrors = read('native/kubeshell-kubectl/host/internal/kube/errors.go');
if (!goErrors.includes('apierrors.IsAlreadyExists(err), apierrors.IsConflict(err)'))
    violations.push('Go host does not normalize AlreadyExists and Conflict to one Runtime conflict class.');
if (!processBackend.includes('(AlreadyExists)') || !processBackend.includes('already exists'))
    violations.push('Process fallback does not normalize kubectl AlreadyExists output to Runtime Conflict.');
if (!processBackend.includes('(Invalid)') || !processBackend.includes('(BadRequest)'))
    violations.push('Process fallback does not normalize common kubectl validation failures to Runtime InvalidResource.');
if (!processBackend.includes('(MethodNotAllowed)'))
    violations.push('Process fallback does not normalize kubectl method-not-allowed failures to Runtime Unsupported.');
if (!processBackend.includes('ParseWarnings(result.StdErr)'))
    violations.push('Process fallback drops kubectl Warning headers/messages instead of projecting Runtime warnings.');
const processTransport = read('Backends/KubeShell.KubectlProcess/src/KubectlProcessTransport.cs');
const kubectlCompatibility = read('Modules/KubeShell.Core/Private/KubectlCompatibility.ps1');
for (const semanticGuard of [
    'kubectl-process.kubeconfig-unrepresentable',
    'kubectl-process.field-validation',
    'kubectl-process.user-agent',
    'kubectl-process.impersonation-extra',
    'kubectl-process.concurrency',
    'kubectl-process.subresource',
]) {
    if (!processBackend.includes(semanticGuard))
        violations.push(`Process compatibility backend is missing fail-closed semantic guard ${semanticGuard}.`);
}
if (!/ExecuteAsync[\s\S]{0,1800}EvaluateAsync\(operation, target, executionContext/.test(processBackend))
    violations.push('Process ExecuteAsync does not self-enforce the same support contract as Managed/Go.');

if (/ExecuteRaw|CreateProcessStartInfo|BuildEffectiveArguments|ApplyEnvironment/.test(processBackend))
    violations.push('Semantic process backend still owns raw process transport responsibilities.');
for (const marker of ['class KubectlProcessTransport','ExecuteAsync(', 'CreateProcessStartInfo(', 'BuildEffectiveArguments(', 'ApplyEnvironment(']) {
    if (!processTransport.includes(marker)) violations.push(`Raw process transport is missing ${marker}.`);
}
if (!kubectlCompatibility.includes('KubectlProcessTransport') || kubectlCompatibility.includes('New-KubeRuntimeBackend'))
    violations.push('Raw Invoke-Kubectl compatibility lane still depends on the semantic process backend.');

const targetEncoding = read('Runtime/KubeShell.Runtime/src/Targets/KubeTargetIdentityEncoding.cs');
const targetModel = read('Runtime/KubeShell.Runtime/src/Targets/KubeTarget.cs');
const configModel = read('Runtime/KubeShell.Runtime/src/Configuration/KubeConfiguration.cs');
const managedSessionFactory = read('Backends/KubeShell.KubernetesClient/src/KubernetesSessionFactory.cs');
const managedDiscoveryService = read('Backends/KubeShell.KubernetesClient/src/KubernetesDiscoveryService.cs');
const goSessionPool = read('Backends/KubeShell.Kubectl/src/Sessions/KubectlSessionPool.cs');
const goSessionSource = read('native/kubeshell-kubectl/host/internal/kube/session.go');
const configSetsSource = read('Modules/KubeShell.Configuration/Private/ConfigSets.ps1');
const configSessionSource = read('Modules/KubeShell.Configuration/Private/Session.ps1');
const providerSource = read('Optional/KubeShell.Provider/src/KubeShellProvider.cs');
const shellContextSource = read('Modules/KubeShell.Shell/Private/Context.ps1');
const configurationBootstrap = read('Modules/KubeShell.Configuration/KubeShell.Configuration.psm1');
const configurationStore = read('Modules/KubeShell.Configuration/Private/Store.ps1');
if (!targetEncoding.includes('value.Length') || !targetEncoding.includes('KubeTargetIdentityEncoding'))
    violations.push('Runtime target identity encoding is not length-prefixed/canonical.');
if (/\.Select\(path => path\.Trim\(\)\)/.test(targetModel) || /\.Select\(path => path\.Trim\(\)\)/.test(configModel))
    violations.push('Runtime still trims kubeconfig paths and can change execution identity.');
if (!managedSessionFactory.includes('KubeTargetIdentityEncoding.Create(target)') || managedSessionFactory.includes('string.Join(Path.PathSeparator, target.KubeConfigPaths)'))
    violations.push('Managed discovery cache identity still uses delimiter-based kubeconfig path serialization.');
if (!goSessionPool.includes('KubeTargetIdentityEncoding.Create(target)') || goSessionPool.includes("string.Join('\u001f', target.KubeConfigPaths)"))
    violations.push('Go session pool key still uses delimiter-based kubeconfig path serialization.');
if (!processTransport.includes('CanRepresentKubeConfigPaths') || !processTransport.includes('kubectl-process.kubeconfig-unrepresentable'))
    violations.push('Process fallback does not fail closed for kubeconfig paths that KUBECONFIG cannot encode.');
if (!managedDiscoveryService.includes('if (!refresh && _cache.TryGetValue'))
    violations.push('Managed discovery backend does not enforce refresh=true as a cache bypass/refetch contract.');
if (!goSessionSource.includes('if refresh {') || !goSessionSource.includes('delete(s.discovery, key)'))
    violations.push('Go discovery backend does not invalidate its owned discovery bundle on refresh=true.');
if (configSetsSource.includes('Select-Object -Unique'))
    violations.push('Configuration adapter still rewrites ordered kubeconfig precedence by deduplicating paths.');
if (!configSessionSource.includes('cannot be represented losslessly in KUBECONFIG'))
    violations.push('Explicit KUBECONFIG export does not fail closed for an unrepresentable path list.');
if (providerSource.includes('StringSplitOptions.TrimEntries'))
    violations.push('Provider ambient KUBECONFIG parsing still trims exact path segments.');
if (!shellContextSource.includes('IsNullOrEmpty([string]$state.Context)') || !shellContextSource.includes('Where-Object Name -CEQ $Name') || !shellContextSource.includes('Current    = $name -ceq $current'))
    violations.push('PowerShell shell context selection still collapses whitespace or case-distinct Kubernetes context identity.');
if (!configurationBootstrap.includes('IsNullOrEmpty([string]$initialState.Context)') || configurationStore.includes('IsNullOrWhiteSpace([string]$_.Context)'))
    violations.push('Configuration persistence/bootstrap still collapses an explicit whitespace Kubernetes context.');
if (providerSource.includes('IsNullOrWhiteSpace(drive.Root)') || configModel.includes('IsNullOrWhiteSpace(reference)'))
    violations.push('Provider/Runtime target reference parsing still rejects an explicit whitespace Kubernetes context.');




const runtimeResult = read('Runtime/KubeShell.Runtime/src/Backends/KubeBackendContracts.cs');
if (runtimeResult.includes('BackendId') || /backendId/.test(runtimeResult))
    violations.push('Runtime semantic operation results still expose backend provenance.');
if (!runtimeResult.includes('KubeSupportState.Unknown => KubeErrorKind.Indeterminate'))
    violations.push('Runtime support-state mapping still collapses Unknown into Unsupported.');
for (const backendMapping of [managed, kubectl, processBackend]) {
    if (!backendMapping.includes('support.ToFailureKind()'))
        violations.push('A self-enforcing backend bypasses the shared support-state failure taxonomy.');
}
const runtimeExecution = read('Runtime/KubeShell.Runtime/src/Execution/KubeExecutionContext.cs');
if (!runtimeExecution.includes('best-effort observability metadata'))
    violations.push('CorrelationId semantics are not documented as best-effort transport telemetry.');

const executionContext = read('Modules/KubeShell.Core/Private/ExecutionContext.ps1');
if (!executionContext.includes('function Get-KubeSessionState') || !executionContext.includes('function Get-KubeRuntimeExecutionContext'))
    violations.push('PowerShell target/session state is not separated from Runtime execution context.');
if (!executionContext.includes('[KubeShell.Runtime.KubeExecutionContext]::Default'))
    violations.push('Runtime execution-context adapter does not construct the Runtime DTO.');

const composition = read('Modules/KubeShell.Core/Private/RuntimeComposition.ps1');
const hosting = read('Hosting/KubeShell.Hosting/src/KubeShellHost.cs');
const resourceAdapter = read('Modules/KubeShell.Core/Private/RuntimeResources.ps1');
const managedIndex = hosting.indexOf('KubeShell.Backends.KubernetesClient.KubernetesClientBackend');
const goIndex = hosting.indexOf('KubeShell.Backends.Kubectl.KubectlBackend');
const processIndex = hosting.indexOf('KubeShell.Backends.KubectlProcess.KubectlProcessBackend');
if (managedIndex < 0 || goIndex < 0 || processIndex < 0 || !(managedIndex < goIndex && goIndex < processIndex))
    violations.push('Shared Hosting composition is not Managed -> Go host -> process.');
if (!hosting.includes('new KubeBackendRouter(backends)') || !hosting.includes('public sealed class KubeShellHost'))
    violations.push('KubeShell.Hosting does not own the selector/composition root.');
if (!hosting.includes('IsOptionalAdapterLoadFailure') ||
    !hosting.includes('if (!managedAdded && resolver is not null)') ||
    !hosting.includes('AssemblyLoadContext.Default.Resolving -= resolver'))
    violations.push('Optional adapter load failure can abort or contaminate later backend fallback composition.');
if (hosting.includes('MissingMethodException => true') || hosting.includes('MissingFieldException => true') ||
    !hosting.includes('does not define expected type'))
    violations.push('Hosting can silently fall back after a resolved adapter violates its ABI/semantic contract.');
if (!composition.includes('function Get-KubeRuntimeHost') || !composition.includes('$script:KubeRuntimeHost.Dispose()'))
    violations.push('Core does not own one disposable Hosting instance for its module lifetime.');
for (const concrete of ['KubernetesClientBackend','KubeShell.Backends.Kubectl.KubectlBackend','KubeShell.Backends.KubectlProcess.KubectlProcessBackend','KubeBackendRouter']) {
    if (composition.includes(concrete)) violations.push(`Core still duplicates concrete composition detail: ${concrete}`);
}
const managedLoader = read('Modules/KubeShell.Core/Private/ManagedBackend.ps1');
if (!managedLoader.includes('Reset-KubeRuntimeComposition'))
    violations.push('Late Managed backend loading does not invalidate cached composition.');
for (const split of ['RuntimeErrors.ps1','RuntimeResources.ps1','RuntimeDiscovery.ps1','RuntimeWorkloads.ps1','RuntimeDiagnostics.ps1','RuntimeStreaming.ps1']) {
    if (!fs.existsSync(path.join(root, 'Modules/KubeShell.Core/Private', split)))
        violations.push(`Core Runtime adapter SRP split is missing ${split}.`);
}
if (fs.existsSync(path.join(root, 'Modules/KubeShell.Core/Private/RuntimeAdapter.ps1')))
    violations.push('Legacy god RuntimeAdapter.ps1 still exists after SRP decomposition.');
const coreModule = read('Modules/KubeShell.Core/KubeShell.Core.psm1');
const exportBlock = coreModule.slice(coreModule.indexOf('Export-ModuleMember'));
for (const routingInternal of ['New-KubeRuntimeBackend','Get-KubeRuntimeBackendSelector','Get-KubeRuntimeHost','Get-KubeRuntimeOperationClient']) {
    if (exportBlock.includes(`'${routingInternal}'`))
        violations.push(`Core exports routing/composition internals ${routingInternal} to frontend modules.`);
}
if (resourceAdapter.includes('(Get-KubeExecutionContext)') && /KubeShell\.Runtime/.test(resourceAdapter))
    violations.push('Runtime resource adapter still passes PowerShell session state as Runtime execution context.');
for (const call of [
    '.Get((Get-KubeRuntimeTarget), $Query, (Get-KubeRuntimeExecutionContext))',
    '.Apply((Get-KubeRuntimeTarget), $Identity, $PayloadJson, $Options, (Get-KubeRuntimeExecutionContext))',
    '.Patch((Get-KubeRuntimeTarget), $Identity, $PayloadJson, $Options, (Get-KubeRuntimeExecutionContext))',
    '.Delete((Get-KubeRuntimeTarget), $Identity, $Options, (Get-KubeRuntimeExecutionContext))'
]) {
    if (!resourceAdapter.includes(call)) violations.push(`Generic resource path does not propagate Runtime execution context: ${call}`);
}

const managedFactory = read('Modules/KubeShell.Core/Private/ManagedBackend.ps1');
if (!managedFactory.includes('function New-KubeManagedExplicitRuntimeClients') || !managedFactory.includes('ResourceClient') || !managedFactory.includes('DiscoveryClient'))
    violations.push('Explicit Managed sessions are not hidden behind semantic Runtime clients at the Core boundary.');

const api = read('Optional/KubeShell.Api/KubeShell.Api.psm1');
if (api.includes('function Initialize-KubeManagedBackendResolver') || api.includes('function Import-KubeManagedBackendAssembly'))
    violations.push('Optional/KubeShell.Api still owns a duplicate managed backend loader.');
for (const forbidden of ['Get-KubeRuntimeBackends','KubeShell.Backends.','IKubeBackend','KubeBackendRouter','Backend =']) {
    if (api.includes(forbidden)) violations.push(`Optional/KubeShell.Api leaks backend composition detail: ${forbidden}`);
}
if (!api.includes('New-KubeRuntimeResourceClient') || !api.includes('New-KubeRuntimeDiscoveryClient') || !api.includes('New-KubeManagedExplicitRuntimeClients'))
    violations.push('KubeShell.Api does not consume semantic Runtime clients from Core.');
if (!api.includes('KubeExecutionContext]::Default'))
    violations.push('KubeShell.Api session does not carry a real Runtime execution context.');

const operations = read('Runtime/KubeShell.Runtime/src/Operations/KubeOperations.cs');
if (operations.includes('"kubectl-rollout"') || operations.includes('"kubectl-set"'))
    violations.push('Runtime operation defaults still expose kubectl implementation identity to future Provider consumers.');

const provider = read('Optional/KubeShell.Provider/src/KubeShellProvider.cs');
if (/KubeBackendRouter|KubernetesClientBackend|KubeShell\.Backends\.Kubectl\.|Get-KubeRuntimeBackends/.test(provider))
    violations.push('Provider is coupled to backend composition instead of semantic ObjectModel/Runtime ports.');

const modulesRoot = path.join(root, 'Modules');
function filesUnder(dir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const full = path.join(dir, entry.name);
        return entry.isDirectory() ? filesUnder(full) : [full];
    });
}
for (const file of filesUnder(modulesRoot).filter(x => /\.(ps1|psm1)$/.test(x))) {
    const relative = path.relative(root, file).replaceAll('\\','/');
    if (relative.startsWith('Modules/KubeShell.Core/')) continue;
    if (/KubeShell\.Backends\./.test(fs.readFileSync(file, 'utf8')))
        violations.push(`${relative}: frontend module selects a concrete backend directly.`);
}

if (violations.length) {
    for (const violation of violations) console.error(`FAIL ${violation}`);
    process.exitCode = 1;
} else {
    console.log('Capability-aware backend contract audit passed.');
}
