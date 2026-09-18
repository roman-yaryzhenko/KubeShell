import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(process.argv[2] ?? path.join(import.meta.dirname, '..'));
const read = relative => fs.readFileSync(path.join(root, relative), 'utf8');
const violations = [];

const objectProject = read('ObjectModel/KubeShell.ObjectModel/KubeShell.ObjectModel.csproj');
const objectText = [
  read('ObjectModel/KubeShell.ObjectModel/src/NavigationModels.cs'),
  read('ObjectModel/KubeShell.ObjectModel/src/KubeNavigationService.cs'),
  read('ObjectModel/KubeShell.ObjectModel/src/ObjectOperations.cs'),
].join('\n');
const providerProject = read('Optional/KubeShell.Provider/KubeShell.Provider.csproj');
const provider = read('Optional/KubeShell.Provider/src/KubeShellProvider.cs');
const providerBuild = read('Optional/KubeShell.Provider/build.ps1');
const hosting = read('Hosting/KubeShell.Hosting/src/KubeShellHost.cs');
const runtimeClient = read('Runtime/KubeShell.Runtime/src/Resources/KubeResourceClient.cs');
const discovery = read('Runtime/KubeShell.Runtime/src/Discovery/KubeDiscovery.cs');

if (!objectProject.includes('KubeShell.Runtime.csproj')) violations.push('ObjectModel does not depend on Runtime.');
for (const forbidden of ['System.Management.Automation','KubeShell.Hosting','KubeShell.Backends','ProcessStartInfo','kubectl']) {
  if (objectProject.includes(forbidden) || objectText.includes(forbidden)) violations.push(`ObjectModel leaks forbidden frontend/infrastructure dependency: ${forbidden}`);
}
if (!providerProject.includes('KubeShell.ObjectModel.csproj') || !providerProject.includes('KubeShell.Hosting.csproj'))
  violations.push('Provider does not compose through ObjectModel + Hosting.');
if (!/PackageReference Include="PowerShellStandard\.Library" Version="5\.1\.1"/.test(providerProject))
  violations.push('Provider SDK build is not compiled against the portable PowerShell Standard contract.');
if (/PackageReference Include="System\.Management\.Automation"/.test(providerProject))
  violations.push('Provider SDK build must not package-reference the PowerShell runtime assembly.');
if (providerProject.includes('$(PowerShellHome)') || providerBuild.includes('PowerShellRuntimeMajor') || providerBuild.includes('-p:PowerShellHome='))
  violations.push('Provider SDK artifact still depends on the PowerShell runtime of the build host.');
if (!providerBuild.includes('Provider build must not bundle System.Management.Automation'))
  violations.push('Provider build does not guard against bundling host/runtime System.Management.Automation.');
for (const forbidden of ['KubeBackendRouter','IKubeBackend','KubernetesClientBackend','KubeShell.Backends.Kubectl.','KubeShell.Backends.KubectlProcess','ProcessStartInfo','System.Diagnostics.Process','PowerShell.Create','Runspace']) {
  if (provider.includes(forbidden)) violations.push(`Provider leaks backend/process/runspace detail: ${forbidden}`);
}
if (/\bPods\b|\bDeployments\b|\bServices\b|deployments\.apps|persistentvolumes|storageclasses\.storage\.k8s\.io/.test(provider))
  violations.push('Provider contains a hardcoded Kubernetes resource catalog.');
if (!hosting.includes('new KubeBackendRouter(backends)')) violations.push('Hosting does not own backend routing composition.');
if (!runtimeClient.includes('interface IKubeResourceExecutionClient') || !runtimeClient.includes('record KubeExecutionResult<T>'))
  violations.push('Runtime rich semantic execution port/result envelope is missing.');
if (!discovery.includes('GetPreferredResourcesAsync') || !discovery.includes('ResolveResourceAsync'))
  violations.push('Runtime discovery is not async-first ready.');

for (const token of [
  'TargetRootLocator','NamespacesRootLocator','NamespaceLocator','ClusterRootLocator',
  'ResourceCollectionLocator','ResourceNamespaceBucketLocator','ResourceItemLocator',
  'IKubeNavigationService','GetChildrenAsync','ResolveChildAsync','GetItemAsync','CancellationToken',
  'GroupResource','KubeNamespaceScope.All','ResolveResourceAliasAsync','CreateRootLocatorAsync'
]) {
  if (!objectText.includes(token)) violations.push(`ObjectModel contract is missing ${token}.`);
}
if (!objectText.includes('StableId') || objectText.includes('PowerShell path')) violations.push('ObjectModel stable identity boundary is missing or path-coupled.');
if (!objectText.includes('_navigationCache') || !objectText.includes('Invalidate(')) violations.push('ObjectModel navigation cache/refresh boundary is missing.');
if (!objectText.includes('KubeTargetIdentityEncoding.Create(target)'))
  violations.push('ObjectModel target stable identity does not use canonical Runtime execution-identity encoding.');
if (!objectText.includes('return Convert.ToHexString(hash).ToLowerInvariant();') || objectText.includes('[..24]'))
  violations.push('ObjectModel target stable identity still truncates the execution-identity digest.');
if (!objectText.includes('GetPreferredResourcesAsync(Target, _executionContext, refreshDiscovery, cancellationToken)') ||
    !objectText.includes('ResolvePreferredDescriptorAsync(GroupResource resource, bool refreshDiscovery'))
  violations.push('ObjectModel -Refresh does not propagate semantic discovery freshness to the backend boundary.');
if (!objectText.includes('ResolveOperationDescriptorAsync') ||
    !objectText.includes('ResolvePreferredDescriptorAsync(resource, refreshDiscovery: true, cancellationToken)'))
  violations.push('Mutation-time preferred GVR resolution can reuse a stale backend discovery snapshot.');

if (!objectText.includes('KubeNamespaceScope.All') || !objectText.includes('ResourceNamespaceBucketLocator')) violations.push('AllNamespaces bucket semantics are missing.');
if (!objectText.includes('scope.Kind is KubeNamespaceScopeKind.Default or KubeNamespaceScopeKind.All') ||
    !objectText.includes('Navigation collection scope must be cluster, all namespaces, or an explicit namespace.'))
  violations.push('Persistent navigation locators can retain unresolved/ambiguous namespace scope.');
if (!objectText.includes('locator.Scope.Kind != KubeNamespaceScopeKind.All && descriptor.Verbs.Contains("create")') ||
    !objectText.includes('MaterializeBucket(ResourceNamespaceBucketLocator locator, KubeResourceDescriptor descriptor)'))
  violations.push('AllNamespaces create capability is attached to the wrong navigation level.');
if (!objectText.includes('if (descriptor.Verbs.Contains("patch")) capabilities |= KubeNavigationCapabilities.Editable;') ||
    objectText.includes('descriptor.Verbs.Contains("patch") || descriptor.Verbs.Contains("update")'))
  violations.push('ObjectModel edit capability does not match its Apply/patch semantic operation.');
if (!objectText.includes('parent is ResourceCollectionLocator allCollection && allCollection.Scope.Kind == KubeNamespaceScopeKind.All') ||
    !objectText.includes('KubeNamespaceScope scope = KubeNamespaceScope.Explicit(bucket.Namespace)'))
  violations.push('AllNamespaces direct bucket navigation/listing is not namespace-local.');
if (!provider.includes('NewDriveDynamicParameters') || !provider.includes('KubeNewDriveParameters') || !provider.includes('AllNamespaces'))
  violations.push('Provider New-PSDrive dynamic mount contract is missing.');
const stringArrayLoader = provider.match(/private static string\[\] GetStringArray\([\s\S]*?\n    }/);
if (!stringArrayLoader || stringArrayLoader[0].includes('IsNullOrWhiteSpace') || !stringArrayLoader[0].includes('text.Length == 0'))
  violations.push('Provider config-set loader can normalize or discard whitespace-bearing kubeconfig execution identity.');
if (!provider.includes('GetChildItemsDynamicParameters') || !provider.includes('KubeRefreshParameters'))
  violations.push('Provider -Refresh dynamic parameter is missing.');
if (!provider.includes('SplitDriveRelativePath(path)') ||
    !provider.includes('NormalizeProviderPath(Drive.Root)') ||
    !provider.includes('normalizedPath.StartsWith(prefix, StringComparison.Ordinal)'))
  violations.push('Provider does not translate provider-internal paths relative to PSDriveInfo.Root.');
const getChildNameOverride = provider.match(/protected override string GetChildName\(string path\)[\s\S]*?\n    }/);
if (!getChildNameOverride || !getChildNameOverride[0].includes('LastIndexOf') || getChildNameOverride[0].includes('ItemExists('))
  violations.push('Provider child-name path algebra is not purely lexical; engine path normalization may trigger Kubernetes reads.');
if (!provider.includes('ProviderCapabilities.ShouldProcess | ProviderCapabilities.ExpandWildcards') ||
    !provider.includes('protected override string[] ExpandPath(string path)') ||
    !provider.includes('new WildcardPattern(pattern, WildcardOptions.IgnoreCase)'))
  violations.push('Provider does not own wildcard expansion; exact destructive paths may regain engine-side ItemExists preflight.');
const hasChildrenOverride = provider.match(/protected override bool HasChildItems\(string path\)[\s\S]*?\n    }/);
if (!hasChildrenOverride || !hasChildrenOverride[0].includes('IsResourceItemParent(current)') ||
    hasChildrenOverride[0].includes('ResolveNode(path'))
  violations.push('Provider HasChildItems does not answer resource-leaf probes structurally; Remove-Item may perform a hidden read.');
if (!provider.includes('bool refreshEdge = refresh && index == segments.Length - 1') ||
    !provider.includes('ResolveChildAsync(current, segments[index], refreshEdge)'))
  violations.push('Provider consumes -Refresh before the final path-resolution edge, so stale nested topology can remain unreachable.');
if (!provider.includes('Drive.Navigation.CreateAsync') || !provider.includes('Drive.Navigation.ApplyAsync') || !provider.includes('Drive.Navigation.DeleteAsync'))
  violations.push('Provider CRUD does not flow through ObjectModel rich semantic operations.');
if (/ItemExists\([^)]*\)[\s\S]{0,300}ApplyAsync/.test(provider)) violations.push('Provider New-Item still has an Exists + Apply race.');
if (!provider.includes('ShouldProcess(')) violations.push('Provider mutation surface lost ShouldProcess.');
if (!provider.includes('KubeErrorKind.NotFound => ErrorCategory.ObjectNotFound') || !provider.includes('KubeShell.Runtime.'))
  violations.push('Provider Runtime error taxonomy projection is incomplete.');
if (!/ItemExists\(string path\)[\s\S]{0,500}catch \(KubeException exception\)[\s\S]{0,180}WriteRuntimeError\(exception, path\)/.test(provider))
  violations.push('Provider ItemExists leaks non-NotFound Runtime errors instead of mapping them to ErrorRecord.');
if (!/IsItemContainer\(string path\)[\s\S]{0,500}catch \(KubeException exception\)[\s\S]{0,180}WriteRuntimeError\(exception, path\)/.test(provider))
  violations.push('Provider IsItemContainer leaks Runtime errors instead of mapping them to ErrorRecord.');
if (/throw new PSArgumentException\(exception\.Message, exception\)/.test(provider) || !provider.includes('WriteRuntimeError(exception, drive.Root)'))
  violations.push('Provider NewDrive collapses Runtime errors instead of preserving the Runtime error taxonomy.');
if (/RemoveItem\([\s\S]*?ResolveLocator\(path, refresh: false\)/.test(provider))
  violations.push('Provider Remove-Item performs a read-resolution preflight instead of routing directly to Delete.');
if (!provider.includes('WriteWarning(') || !provider.includes('WriteVerbose(')) violations.push('Provider drops rich warnings/diagnostics.');
if (!provider.includes('recurse') || !provider.includes('NotSupported')) violations.push('Provider recursion is not explicitly bounded/rejected.');

if (violations.length) {
  for (const violation of violations) console.error(`FAIL ${violation}`);
  process.exitCode = 1;
} else {
  console.log('Provider/ObjectModel architecture audit passed.');
}
