using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.IO;
using System.Linq;
using System.Management.Automation;
using System.Management.Automation.Provider;
using System.Text.Json;
using KubeShell.Hosting;
using KubeShell.ObjectModel;
using KubeShell.Runtime;

namespace KubeShell.Provider;

public sealed class KubeProviderItem
{
    public string? Name { get; init; }
    public string? Namespace { get; init; }
    public string? Kind { get; init; }
    public string? ApiVersion { get; init; }
    public string? Resource { get; init; }
    public string? Context { get; init; }
    public string? RawJson { get; init; }
    public KubeNavigationNode? Node { get; init; }
    public override string ToString() => Name ?? string.Empty;
}

public sealed class KubeProviderContainer
{
    public string? Name { get; init; }
    public string? Namespace { get; init; }
    public string? Kind { get; init; }
    public string? ApiVersion { get; init; }
    public string? Resource { get; init; }
    public string? Context { get; init; }
    public KubeNavigationNode? Node { get; init; }
    public override string ToString() => Name ?? string.Empty;
}

public sealed class KubeNewDriveParameters
{
    [Parameter]
    public string? Namespace { get; set; }

    [Parameter]
    public string? Resource { get; set; }

    [Parameter]
    public SwitchParameter AllNamespaces { get; set; }
}

public sealed class KubeRefreshParameters
{
    [Parameter]
    public SwitchParameter Refresh { get; set; }
}

internal sealed class KubeProviderDriveInfo : PSDriveInfo, IDisposable
{
    public KubeProviderDriveInfo(
        PSDriveInfo source,
        string sourceReference,
        KubeTarget target,
        KubeShellHost host,
        IKubeNavigationService navigation,
        KubeNodeLocator rootLocator)
        : base(source)
    {
        SourceReference = sourceReference;
        Target = target;
        Host = host;
        Navigation = navigation;
        RootLocator = rootLocator;
    }

    public string SourceReference { get; }
    public KubeTarget Target { get; }
    public KubeShellHost Host { get; }
    public IKubeNavigationService Navigation { get; }
    public KubeNodeLocator RootLocator { get; }

    public void Dispose() => Host.Dispose();
}

[CmdletProvider("Kube", ProviderCapabilities.ShouldProcess | ProviderCapabilities.ExpandWildcards)]
public sealed class KubeProvider : NavigationCmdletProvider
{
    protected override Collection<PSDriveInfo> InitializeDefaultDrives()
    {
        Collection<PSDriveInfo> drives = new();
        KubeShellHost? host = null;
        try
        {
            host = KubeShellHost.Create(new KubeShellHostOptions(RepositoryRoot: FindRepositoryRoot()));
            KubeTarget provisional = EnsureExplicitKubeConfigPaths(new KubeTarget(source: "Default"));
            KubeConfigView view = host.ConfigClient.GetConfigView(provisional);
            if (string.IsNullOrEmpty(view.CurrentContext))
            {
                host.Dispose();
                return drives;
            }

            KubeTarget target = EnsureExplicitKubeConfigPaths(new KubeTarget(view.CurrentContext, source: "Default"));
            IKubeNavigationService navigation = NewNavigation(host, target);
            PSDriveInfo shellDrive = new("Kube", ProviderInfo, view.CurrentContext, "Current Kubernetes context (KubeShell provider)", null);
            drives.Add(new KubeProviderDriveInfo(shellDrive, view.CurrentContext, target, host, navigation, navigation.TargetRoot));
            host = null; // ownership transferred to the drive state
        }
        catch
        {
            host?.Dispose();
            // Provider import remains valid when no semantic backend or kubeconfig is available.
        }
        return drives;
    }

    protected override object NewDriveDynamicParameters() => new KubeNewDriveParameters();

    protected override PSDriveInfo NewDrive(PSDriveInfo drive)
    {
        ArgumentNullException.ThrowIfNull(drive);
        if (string.IsNullOrEmpty(drive.Root))
            throw new PSArgumentException("The drive root must be a context, profile:<name>, or configset:<name>.");
        if (drive.Credential is not null && drive.Credential != PSCredential.Empty)
            throw new PSNotSupportedException("KubeShell Provider does not support PSCredential on PSDrive mounts.");

        KubeShellHost? host = null;
        try
        {
            KubeConfigurationDocument configuration = LoadConfigurationDocumentIfNeeded(drive.Root);
            KubeTarget target = EnsureExplicitKubeConfigPaths(new KubeTargetResolver(configuration).ResolveReference(drive.Root));
            host = KubeShellHost.Create(new KubeShellHostOptions(RepositoryRoot: FindRepositoryRoot()));
            target = FreezeCurrentContext(target, host);

            KubeNewDriveParameters parameters = DynamicParameters as KubeNewDriveParameters ?? new KubeNewDriveParameters();
            IKubeNavigationService navigation = NewNavigation(host, target);
            KubeNodeLocator root = navigation.CreateRootLocatorAsync(
                new KubeMountRequest(parameters.Namespace, parameters.Resource, parameters.AllNamespaces.IsPresent))
                .AsTask().GetAwaiter().GetResult();

            return new KubeProviderDriveInfo(drive, drive.Root, target, host, navigation, root);
        }
        catch (KubeException exception)
        {
            host?.Dispose();
            WriteRuntimeError(exception, drive.Root);
            return null!;
        }
        catch
        {
            host?.Dispose();
            throw;
        }
    }

    protected override PSDriveInfo RemoveDrive(PSDriveInfo drive)
    {
        if (drive is KubeProviderDriveInfo state) state.Dispose();
        return drive;
    }

    protected override bool IsValidPath(string path) => IsSyntacticallyValidPath(path);

    // Path decomposition is engine plumbing and must stay lexical. The base
    // NavigationCmdletProvider implementation may call ItemExists() while
    // extracting a child name, which would turn PowerShell path normalization
    // and dynamic-parameter discovery into an unexpected Kubernetes read.
    protected override string GetChildName(string path)
    {
        if (string.IsNullOrEmpty(path))
            throw new ArgumentException("Path cannot be null or empty.", nameof(path));

        string normalized = NormalizeProviderPath(path);
        int separatorIndex = normalized.LastIndexOf('/');
        return separatorIndex < 0 ? normalized : normalized[(separatorIndex + 1)..];
    }

    protected override string[] ExpandPath(string path)
    {
        try
        {
            string[] patterns = SplitDriveRelativePath(path);
            if (patterns.Length == 0)
                return new[] { BuildProviderPath(Array.Empty<string>()) };

            List<ExpansionState> states = new()
            {
                new ExpansionState(Drive.RootLocator, Array.Empty<string>())
            };

            for (int index = 0; index < patterns.Length; index++)
            {
                string pattern = patterns[index];
                bool wildcard = WildcardPattern.ContainsWildcardCharacters(pattern);
                WildcardPattern? matcher = wildcard
                    ? new WildcardPattern(pattern, WildcardOptions.IgnoreCase)
                    : null;
                bool last = index == patterns.Length - 1;
                List<ExpansionState> next = new();

                foreach (ExpansionState state in states)
                {
                    if (wildcard)
                    {
                        IReadOnlyList<string> names = Drive.Navigation.GetChildNamesAsync(state.Locator).AsTask().GetAwaiter().GetResult();
                        foreach (string name in names)
                        {
                            if (!matcher!.IsMatch(name)) continue;
                            string[] segments = AppendSegment(state.Segments, name);
                            if (last)
                            {
                                next.Add(new ExpansionState(state.Locator, segments));
                                continue;
                            }

                            KubeNavigationNode? child = Drive.Navigation.ResolveChildAsync(state.Locator, name).AsTask().GetAwaiter().GetResult();
                            if (child is not null) next.Add(new ExpansionState(child.Locator, segments));
                        }
                        continue;
                    }

                    KubeNavigationNode? exact = Drive.Navigation.ResolveChildAsync(state.Locator, pattern).AsTask().GetAwaiter().GetResult();
                    if (exact is not null)
                        next.Add(new ExpansionState(exact.Locator, AppendSegment(state.Segments, exact.Name)));
                }

                states = next;
                if (states.Count == 0) break;
            }

            return states.Select(state => BuildProviderPath(state.Segments)).ToArray();
        }
        catch (KubeException exception) when (exception.Kind == KubeErrorKind.NotFound)
        {
            return Array.Empty<string>();
        }
        catch (KubeException exception)
        {
            WriteRuntimeError(exception, path);
            return Array.Empty<string>();
        }
    }

    protected override bool ItemExists(string path)
    {
        try { return ResolveNode(path, refresh: false) is not null; }
        catch (KubeException exception) when (exception.Kind == KubeErrorKind.NotFound) { return false; }
        catch (KubeException exception)
        {
            WriteRuntimeError(exception, path);
            return false;
        }
    }

    protected override bool HasChildItems(string path)
    {
        try
        {
            KubeNodeLocator current = Drive.RootLocator;
            string[] segments = SplitDriveRelativePath(path);

            foreach (string segment in segments)
            {
                // A concrete child of these locators is always a resource item. Kubernetes
                // resources are leaves in the Provider hierarchy, so Remove-Item can answer
                // the engine's mandatory HasChildItems probe without a point GET.
                if (IsResourceItemParent(current)) return false;

                KubeNavigationNode? child = Drive.Navigation.ResolveChildAsync(current, segment).AsTask().GetAwaiter().GetResult();
                if (child is null) return false;
                current = child.Locator;
            }

            if (current is ResourceItemLocator) return false;
            return Drive.Navigation.GetChildNamesAsync(current).AsTask().GetAwaiter().GetResult().Count > 0;
        }
        catch (KubeException exception) when (exception.Kind == KubeErrorKind.NotFound)
        {
            return false;
        }
        catch (KubeException exception)
        {
            WriteRuntimeError(exception, path);
            return false;
        }
    }

    protected override bool IsItemContainer(string path)
    {
        try { return ResolveNode(path, refresh: false)?.IsContainer == true; }
        catch (KubeException exception) when (exception.Kind == KubeErrorKind.NotFound) { return false; }
        catch (KubeException exception)
        {
            WriteRuntimeError(exception, path);
            return false;
        }
    }

    protected override void GetItem(string path)
    {
        try
        {
            KubeNavigationNode? node = ResolveNode(path, refresh: false);
            if (node is null)
            {
                WriteError(new ErrorRecord(new ItemNotFoundException(path), "KubeShell.Provider.ItemNotFound", ErrorCategory.ObjectNotFound, path));
                return;
            }
            WriteProjected(node, path);
        }
        catch (KubeException exception) { WriteRuntimeError(exception, path); }
    }

    protected override object GetChildItemsDynamicParameters(string path, bool recurse) => new KubeRefreshParameters();
    protected override object GetChildNamesDynamicParameters(string path) => new KubeRefreshParameters();

    protected override void GetChildItems(string path, bool recurse)
    {
        if (recurse)
            throw new PSNotSupportedException("Recursive Kubernetes Provider traversal is intentionally unsupported in this iteration.");

        try
        {
            bool refresh = (DynamicParameters as KubeRefreshParameters)?.Refresh.IsPresent == true;
            KubeNodeLocator? locator = ResolveLocator(path, refresh);
            if (locator is null)
            {
                WriteError(new ErrorRecord(new ItemNotFoundException(path), "KubeShell.Provider.ItemNotFound", ErrorCategory.ObjectNotFound, path));
                return;
            }

            IReadOnlyList<KubeNavigationNode> children = Drive.Navigation.GetChildrenAsync(locator, refresh).AsTask().GetAwaiter().GetResult();
            foreach (KubeNavigationNode child in children)
                WriteProjected(child, MakePath(path, child.Name));
        }
        catch (KubeException exception) { WriteRuntimeError(exception, path); }
    }

    protected override void GetChildNames(string path, ReturnContainers returnContainers)
    {
        try
        {
            bool refresh = (DynamicParameters as KubeRefreshParameters)?.Refresh.IsPresent == true;
            KubeNodeLocator? locator = ResolveLocator(path, refresh);
            if (locator is null)
            {
                WriteError(new ErrorRecord(new ItemNotFoundException(path), "KubeShell.Provider.ItemNotFound", ErrorCategory.ObjectNotFound, path));
                return;
            }

            if (locator is ResourceCollectionLocator collection && collection.Scope.Kind != KubeNamespaceScopeKind.All ||
                locator is ResourceNamespaceBucketLocator)
            {
                IReadOnlyList<string> names = Drive.Navigation.GetChildNamesAsync(locator, refresh).AsTask().GetAwaiter().GetResult();
                foreach (string name in names)
                    WriteItemObject(name, MakePath(path, name), false);
                return;
            }

            IReadOnlyList<KubeNavigationNode> children = Drive.Navigation.GetChildrenAsync(locator, refresh).AsTask().GetAwaiter().GetResult();
            foreach (KubeNavigationNode child in children)
                WriteItemObject(child.Name, MakePath(path, child.Name), child.IsContainer);
        }
        catch (KubeException exception) { WriteRuntimeError(exception, path); }
    }

    protected override void NewItem(string path, string itemTypeName, object newItemValue)
    {
        try
        {
            ResourceItemLocator locator = ResolveResourceItemLocator(path);
            string payload = GetPayload(newItemValue);
            string action = Force ? "Apply Kubernetes resource" : "Create Kubernetes resource";
            if (!ShouldProcess(path, action)) return;

            KubeExecutionResult<KubeNavigationNode> result = Force
                ? Drive.Navigation.ApplyAsync(locator, payload).AsTask().GetAwaiter().GetResult()
                : Drive.Navigation.CreateAsync(locator, payload).AsTask().GetAwaiter().GetResult();
            WriteExecutionMessages(result.Warnings, result.Diagnostics);
            WriteProjected(result.Value, path);
        }
        catch (KubeException exception) { WriteRuntimeError(exception, path); }
    }

    protected override void SetItem(string path, object value)
    {
        try
        {
            ResourceItemLocator locator = ResolveResourceItemLocator(path);
            string payload = GetPayload(value);
            if (!ShouldProcess(path, "Apply Kubernetes resource")) return;

            KubeExecutionResult<KubeNavigationNode> result = Drive.Navigation.ApplyAsync(locator, payload).AsTask().GetAwaiter().GetResult();
            WriteExecutionMessages(result.Warnings, result.Diagnostics);
            WriteProjected(result.Value, path);
        }
        catch (KubeException exception) { WriteRuntimeError(exception, path); }
    }

    protected override void RemoveItem(string path, bool recurse)
    {
        if (recurse)
            throw new PSNotSupportedException("Recursive Kubernetes Provider deletion is not supported.");

        try
        {
            ResourceItemLocator locator = ResolveResourceItemLocator(path);

            if (string.Equals(locator.Resource.Group, string.Empty, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(locator.Resource.Resource, "nodes", StringComparison.OrdinalIgnoreCase) && !Force)
                throw new InvalidOperationException("Deleting a Kubernetes Node through the provider requires -Force.");

            if (!ShouldProcess(path, "Delete Kubernetes resource")) return;
            KubeExecutionResult result = Drive.Navigation.DeleteAsync(locator).AsTask().GetAwaiter().GetResult();
            WriteExecutionMessages(result.Warnings, result.Diagnostics);
        }
        catch (KubeException exception) { WriteRuntimeError(exception, path); }
    }

    private KubeProviderDriveInfo Drive => PSDriveInfo as KubeProviderDriveInfo
        ?? throw new InvalidOperationException("KubeShell drive state is unavailable. Remount the PSDrive with the current Provider version.");

    private KubeNavigationNode? ResolveNode(string path, bool refresh)
    {
        KubeNodeLocator current = Drive.RootLocator;
        string[] segments = SplitDriveRelativePath(path);
        if (segments.Length == 0)
            return Drive.Navigation.GetItemAsync(current).AsTask().GetAwaiter().GetResult();

        KubeNavigationNode? node = null;
        for (int index = 0; index < segments.Length; index++)
        {
            // Refresh the topology edge that resolves the requested node, rather than consuming
            // -Refresh on the first path segment. Otherwise a stale Namespace/Cluster cache can
            // make a newly discovered collection unreachable before its own refresh is attempted.
            bool refreshEdge = refresh && index == segments.Length - 1;
            node = Drive.Navigation.ResolveChildAsync(current, segments[index], refreshEdge).AsTask().GetAwaiter().GetResult();
            if (node is null) return null;
            current = node.Locator;
        }
        return node;
    }

    private KubeNodeLocator? ResolveLocator(string path, bool refresh) =>
        ResolveNode(path, refresh)?.Locator;

    private ResourceItemLocator ResolveResourceItemLocator(string path)
    {
        string[] segments = SplitDriveRelativePath(path);
        if (segments.Length == 0)
            throw new PSNotSupportedException("A Kubernetes resource item name is required.");

        string name = segments[^1];
        KubeNodeLocator parent = Drive.RootLocator;
        foreach (string segment in segments[..^1])
        {
            KubeNavigationNode? child = Drive.Navigation.ResolveChildAsync(parent, segment).AsTask().GetAwaiter().GetResult();
            parent = child?.Locator ?? throw new ItemNotFoundException(path);
        }

        return parent switch
        {
            ResourceCollectionLocator collection when collection.Scope.Kind != KubeNamespaceScopeKind.All =>
                new ResourceItemLocator(collection.TargetKey, collection.Resource, collection.Scope, name),
            ResourceNamespaceBucketLocator bucket =>
                new ResourceItemLocator(bucket.TargetKey, bucket.Resource, KubeNamespaceScope.Explicit(bucket.Namespace), name),
            _ => throw new PSNotSupportedException("The operation requires a Kubernetes resource item beneath a resource collection or all-namespaces namespace bucket.")
        };
    }

    private void WriteProjected(KubeNavigationNode node, string path)
    {
        if (node.IsContainer)
        {
            string? ns = node.Locator switch
            {
                NamespaceLocator locator => locator.Namespace,
                ResourceNamespaceBucketLocator locator => locator.Namespace,
                ResourceCollectionLocator locator when locator.Scope.Kind == KubeNamespaceScopeKind.Explicit => locator.Scope.Name,
                _ => null
            };
            WriteItemObject(new KubeProviderContainer
            {
                Name = node.Name,
                Namespace = ns,
                Kind = ReadMetadata(node, "Kind"),
                ApiVersion = ReadMetadata(node, "ApiVersion"),
                Resource = node.Locator switch
                {
                    ResourceCollectionLocator collection => collection.Resource.ToString(),
                    ResourceNamespaceBucketLocator bucket => bucket.Resource.ToString(),
                    _ => ReadMetadata(node, "GroupResource")
                },
                Context = Drive.Target.Context,
                Node = node
            }, path, true);
            return;
        }

        KubeResource? value = node.Value;
        WriteItemObject(new KubeProviderItem
        {
            Name = node.Name,
            Namespace = value?.Identity.Namespace,
            Kind = value?.Identity.Kind ?? ReadMetadata(node, "Kind"),
            ApiVersion = value?.Identity.ApiVersion ?? ReadMetadata(node, "ApiVersion"),
            Resource = node.Locator is ResourceItemLocator item ? item.Resource.ToString() : ReadMetadata(node, "GroupResource"),
            Context = Drive.Target.Context,
            RawJson = value?.RawJson,
            Node = node
        }, path, false);
    }

    private static string? ReadMetadata(KubeNavigationNode node, string key) =>
        node.Properties.TryGetValue(key, out object? value) ? value?.ToString() : null;

    private void WriteExecutionMessages(IReadOnlyList<KubeWarning> warnings, IReadOnlyList<KubeDiagnostic> diagnostics)
    {
        foreach (KubeWarning warning in warnings) WriteWarning(warning.Message);
        foreach (KubeDiagnostic diagnostic in diagnostics)
        {
            if (diagnostic.Level == KubeDiagnosticLevel.Warning) WriteWarning(diagnostic.Message);
            else WriteVerbose($"{diagnostic.Code}: {diagnostic.Message}");
        }
    }

    private void WriteRuntimeError(KubeException exception, object? target)
    {
        WriteExecutionMessages(exception.Warnings, exception.Diagnostics);
        WriteError(new ErrorRecord(exception, $"KubeShell.Runtime.{exception.Kind}", MapErrorCategory(exception.Kind), target));
    }

    private static ErrorCategory MapErrorCategory(KubeErrorKind kind) => kind switch
    {
        KubeErrorKind.NotFound => ErrorCategory.ObjectNotFound,
        KubeErrorKind.Configuration => ErrorCategory.InvalidArgument,
        KubeErrorKind.InvalidResource => ErrorCategory.InvalidArgument,
        KubeErrorKind.Serialization => ErrorCategory.InvalidData,
        KubeErrorKind.Authentication => ErrorCategory.SecurityError,
        KubeErrorKind.Authorization => ErrorCategory.PermissionDenied,
        KubeErrorKind.Conflict => ErrorCategory.ResourceBusy,
        KubeErrorKind.Unsupported => ErrorCategory.NotImplemented,
        KubeErrorKind.Indeterminate => ErrorCategory.InvalidOperation,
        KubeErrorKind.Unavailable => ErrorCategory.ResourceUnavailable,
        KubeErrorKind.Cancelled => ErrorCategory.OperationStopped,
        _ => ErrorCategory.InvalidOperation
    };

    private static IKubeNavigationService NewNavigation(KubeShellHost host, KubeTarget target) =>
        new KubeNavigationService(target, host.ResourceClient, host.ResourceExecutionClient, host.DiscoveryClient);

    private static KubeTarget EnsureExplicitKubeConfigPaths(KubeTarget target)
    {
        if (target.KubeConfigPaths.Length > 0) return target;

        string? configured = Environment.GetEnvironmentVariable("KUBECONFIG");
        string[] paths;
        if (!string.IsNullOrEmpty(configured))
        {
            paths = configured.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries);
        }
        else
        {
            string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (string.IsNullOrWhiteSpace(home))
                throw new KubeException(KubeErrorKind.Configuration, "Cannot resolve a kubeconfig path because the user home directory is unavailable.", target: target);
            paths = new[] { Path.Combine(home, ".kube", "config") };
        }

        return new KubeTarget(target.Context, paths, target.DefaultNamespace, target.Profile, target.ConfigSet, target.Source);
    }

    private static KubeTarget FreezeCurrentContext(KubeTarget target, KubeShellHost host)
    {
        // Explicit contexts are already frozen by KubeTargetResolver. Only ambient/current-context
        // mounts need the configuration capability during drive creation.
        if (!string.IsNullOrEmpty(target.Context)) return target;
        return KubeTargetResolution.FreezeCurrentContext(target, host.ConfigClient.GetConfigView(target));
    }

    private static KubeConfigurationDocument LoadConfigurationDocumentIfNeeded(string reference)
    {
        bool named = reference.StartsWith("profile:", StringComparison.OrdinalIgnoreCase) ||
                     reference.StartsWith("configset:", StringComparison.OrdinalIgnoreCase);
        if (!named) return new KubeConfigurationDocument(1);

        string path = GetConfigurationStorePath();
        if (!File.Exists(path))
            throw new KubeException(KubeErrorKind.Configuration, "KubeShell configuration store was not found: " + path);

        using JsonDocument document = JsonDocument.Parse(File.ReadAllText(path));
        JsonElement root = document.RootElement;
        List<KubeConfigSet> configSets = new();
        List<KubeProfile> profiles = new();

        if (root.TryGetProperty("configSets", out JsonElement setArray) && setArray.ValueKind == JsonValueKind.Array)
        foreach (JsonElement item in setArray.EnumerateArray())
        {
            string? name = GetString(item, "name");
            if (string.IsNullOrWhiteSpace(name)) continue;
            configSets.Add(new KubeConfigSet(name, GetStringArray(item, "paths")));
        }

        if (root.TryGetProperty("profiles", out JsonElement profileArray) && profileArray.ValueKind == JsonValueKind.Array)
        foreach (JsonElement item in profileArray.EnumerateArray())
        {
            string? name = GetString(item, "name");
            if (string.IsNullOrWhiteSpace(name)) continue;
            profiles.Add(new KubeProfile(name, GetString(item, "configSet"), GetString(item, "context"), GetString(item, "namespace")));
        }

        int version = root.TryGetProperty("version", out JsonElement versionValue) && versionValue.TryGetInt32(out int parsedVersion) ? parsedVersion : 1;
        return new KubeConfigurationDocument(version, configSets, profiles);
    }

    private static string GetConfigurationStorePath()
    {
        string? configured = Environment.GetEnvironmentVariable("KUBESHELL_CONFIG_HOME");
        if (!string.IsNullOrWhiteSpace(configured)) return Path.Combine(configured, "configuration.json");
        if (OperatingSystem.IsWindows())
        {
            string? appData = Environment.GetEnvironmentVariable("APPDATA");
            if (string.IsNullOrWhiteSpace(appData))
                appData = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "AppData", "Roaming");
            return Path.Combine(appData, "KubeShell", "configuration.json");
        }
        string? xdg = Environment.GetEnvironmentVariable("XDG_CONFIG_HOME");
        if (string.IsNullOrWhiteSpace(xdg))
            xdg = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config");
        return Path.Combine(xdg, "kubeshell", "configuration.json");
    }

    private static string? GetString(JsonElement element, string property) =>
        element.TryGetProperty(property, out JsonElement value) && value.ValueKind != JsonValueKind.Null ? value.GetString() : null;

    private static string[] GetStringArray(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out JsonElement value) || value.ValueKind != JsonValueKind.Array)
            return Array.Empty<string>();

        List<string> result = new();
        foreach (JsonElement item in value.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String)
                throw new KubeException(KubeErrorKind.Configuration, $"Configuration property '{property}' must contain only string values.");

            string? text = item.GetString();
            if (text is null || text.Length == 0)
                throw new KubeException(KubeErrorKind.Configuration, $"Configuration property '{property}' cannot contain an empty kubeconfig path.");

            // Kubeconfig paths are execution identity. Whitespace is legal in Unix filenames,
            // so the adapter must preserve every non-empty string byte-for-byte at this boundary.
            result.Add(text);
        }
        return result.ToArray();
    }

    private static bool IsSyntacticallyValidPath(string? path) =>
        SplitPath(path).All(segment => segment.IndexOfAny(new[] { '\0', '\r', '\n' }) < 0);

    // PowerShell provider callbacks receive provider-internal paths that include
    // PSDriveInfo.Root. Root is already represented semantically by RootLocator,
    // so remove that exact engine-supplied prefix before ObjectModel traversal.
    private string[] SplitDriveRelativePath(string? path)
    {
        string normalizedPath = NormalizeProviderPath(path);
        string normalizedRoot = NormalizeProviderPath(Drive.Root);
        if (!string.IsNullOrEmpty(normalizedRoot))
        {
            if (string.Equals(normalizedPath, normalizedRoot, StringComparison.Ordinal))
                return Array.Empty<string>();

            string prefix = normalizedRoot + "/";
            if (normalizedPath.StartsWith(prefix, StringComparison.Ordinal))
                normalizedPath = normalizedPath[prefix.Length..];
        }

        return SplitPath(normalizedPath);
    }

    private static string NormalizeProviderPath(string? path) =>
        (path ?? string.Empty).Replace('\\', '/').TrimEnd('/');

    private static bool IsResourceItemParent(KubeNodeLocator locator) =>
        (locator is ResourceCollectionLocator collection && collection.Scope.Kind != KubeNamespaceScopeKind.All) ||
        locator is ResourceNamespaceBucketLocator;

    private string BuildProviderPath(IReadOnlyList<string> relativeSegments)
    {
        string root = NormalizeProviderPath(Drive.Root);
        if (relativeSegments.Count == 0) return root;
        string relative = string.Join("/", relativeSegments);
        return string.IsNullOrEmpty(root) ? relative : $"{root}/{relative}";
    }

    private static string[] AppendSegment(IReadOnlyList<string> segments, string segment)
    {
        string[] result = new string[segments.Count + 1];
        for (int index = 0; index < segments.Count; index++) result[index] = segments[index];
        result[^1] = segment;
        return result;
    }

    private sealed record ExpansionState(KubeNodeLocator Locator, string[] Segments);

    private static string[] SplitPath(string? path) =>
        (path ?? string.Empty).Replace('\\', '/').Split('/', StringSplitOptions.RemoveEmptyEntries);

    private static string GetPayload(object? value)
    {
        if (value is null) throw new PSArgumentNullException(nameof(value));
        if (value is string text) return text;
        if (value is KubeProviderItem item && !string.IsNullOrWhiteSpace(item.RawJson)) return item.RawJson;
        if (value is KubeNavigationNode node && node.Value is not null) return node.Value.RawJson;
        if (value is PSObject wrapper)
        {
            if (wrapper.BaseObject is string wrappedText) return wrappedText;
            if (wrapper.BaseObject is KubeProviderItem wrappedItem && !string.IsNullOrWhiteSpace(wrappedItem.RawJson)) return wrappedItem.RawJson;
            if (wrapper.BaseObject is KubeNavigationNode wrappedNode && wrappedNode.Value is not null) return wrappedNode.Value.RawJson;
        }
        throw new PSArgumentException("Set-Item/New-Item expects JSON text or a KubeShell resource presentation object with RawJson.");
    }

    private static string? FindRepositoryRoot()
    {
        string? location = typeof(KubeProvider).Assembly.Location;
        if (string.IsNullOrWhiteSpace(location)) return null;
        DirectoryInfo? directory = new FileInfo(location).Directory;
        for (int i = 0; i < 8 && directory is not null; i++, directory = directory.Parent)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "Runtime", "KubeShell.Runtime"))) return directory.FullName;
        }
        return null;
    }
}
