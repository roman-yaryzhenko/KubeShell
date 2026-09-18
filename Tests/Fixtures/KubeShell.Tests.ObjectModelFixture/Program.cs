using KubeShell.Backends.KubernetesClient;
using System.Text.Json;
using System.Text;
using System.Reflection;
using System.Net.Sockets;
using System.Net;
using System.Collections;
using System.Text.Json.Nodes;
using KubeShell.ObjectModel;
using KubeShell.Hosting;
using KubeShell.Runtime;

static class Assert
{
    public static void True(bool value, string message)
    {
        if (!value) throw new InvalidOperationException(message);
    }

    public static void Equal<T>(T expected, T actual, string message) where T : notnull
    {
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"{message}: expected={expected}, actual={actual}");
    }

    public static async Task ThrowsAsync<T>(Func<Task> action, string message) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new InvalidOperationException(message);
    }
}

sealed class FakeDiscoveryClient : IKubeDiscoveryClient
{
    private readonly List<KubeResourceDescriptor> _descriptors;
    private readonly Func<GroupVersionResource, KubeResourceDescriptor?>? _resolver;
    public int PreferredCalls { get; private set; }
    public int RefreshRequests { get; private set; }

    public FakeDiscoveryClient(
        IReadOnlyList<KubeResourceDescriptor> descriptors,
        Func<GroupVersionResource, KubeResourceDescriptor?>? resolver = null)
    {
        _descriptors = descriptors.ToList();
        _resolver = resolver;
    }

    public IReadOnlyList<KubeResourceDescriptor> GetPreferredResources(KubeTarget target, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default) =>
        GetPreferredResourcesAsync(target, executionContext, refresh, cancellationToken).AsTask().GetAwaiter().GetResult();

    public IReadOnlyList<KubeResourceDescriptor> GetApiVersionResources(KubeTarget target, string apiVersion, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default) =>
        GetApiVersionResourcesAsync(target, apiVersion, executionContext, refresh, cancellationToken).AsTask().GetAwaiter().GetResult();

    public KubeResourceDescriptor? ResolveResource(KubeTarget target, GroupVersionResource resource, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default) =>
        ResolveResourceAsync(target, resource, executionContext, refresh, cancellationToken).AsTask().GetAwaiter().GetResult();

    public void AddDescriptor(KubeResourceDescriptor descriptor) => _descriptors.Add(descriptor);
    public void RemoveDescriptor(GroupResource resource) => _descriptors.RemoveAll(x => GroupResource.From(x.Gvr) == resource);

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(KubeTarget target, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        PreferredCalls++;
        if (refresh) RefreshRequests++;
        return ValueTask.FromResult<IReadOnlyList<KubeResourceDescriptor>>(_descriptors.ToArray());
    }

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(KubeTarget target, string apiVersion, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (refresh) RefreshRequests++;
        IReadOnlyList<KubeResourceDescriptor> result = _descriptors.Where(x => string.Equals(x.Gvr.ApiVersion, apiVersion, StringComparison.OrdinalIgnoreCase)).ToArray();
        return ValueTask.FromResult(result);
    }

    public ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(KubeTarget target, GroupVersionResource resource, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (refresh) RefreshRequests++;
        KubeResourceDescriptor? result = _resolver is not null
            ? _resolver(resource)
            : KubeDiscoveryResolution.Resolve(resource, _descriptors, _descriptors, target, "fixture.discovery.ambiguous-resource");
        return ValueTask.FromResult(result);
    }
}


sealed class CachingDiscoveryClient : IKubeDiscoveryClient
{
    private readonly List<KubeResourceDescriptor> _source;
    private IReadOnlyList<KubeResourceDescriptor>? _cached;

    public CachingDiscoveryClient(IReadOnlyList<KubeResourceDescriptor> descriptors) => _source = descriptors.ToList();

    public int PreferredCalls { get; private set; }
    public int RefreshRequests { get; private set; }
    public int DirectInvalidations { get; private set; }

    public void AddDescriptor(KubeResourceDescriptor descriptor) => _source.Add(descriptor);
    public void RemoveDescriptor(GroupResource resource) => _source.RemoveAll(x => GroupResource.From(x.Gvr) == resource);

    // Deliberately outside IKubeDiscoveryClient. F8 asserts ObjectModel never reaches into backend
    // cache ownership directly; freshness is requested only through the semantic refresh flag.
    public void InvalidateBackendCache()
    {
        DirectInvalidations++;
        _cached = null;
    }

    public IReadOnlyList<KubeResourceDescriptor> GetPreferredResources(KubeTarget target, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default) =>
        GetPreferredResourcesAsync(target, executionContext, refresh, cancellationToken).AsTask().GetAwaiter().GetResult();

    public IReadOnlyList<KubeResourceDescriptor> GetApiVersionResources(KubeTarget target, string apiVersion, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default) =>
        GetApiVersionResourcesAsync(target, apiVersion, executionContext, refresh, cancellationToken).AsTask().GetAwaiter().GetResult();

    public KubeResourceDescriptor? ResolveResource(KubeTarget target, GroupVersionResource resource, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default) =>
        ResolveResourceAsync(target, resource, executionContext, refresh, cancellationToken).AsTask().GetAwaiter().GetResult();

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(KubeTarget target, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        PreferredCalls++;
        return ValueTask.FromResult(Snapshot(refresh));
    }

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(KubeTarget target, string apiVersion, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        IReadOnlyList<KubeResourceDescriptor> result = Snapshot(refresh)
            .Where(x => string.Equals(x.Gvr.ApiVersion, apiVersion, StringComparison.OrdinalIgnoreCase))
            .ToArray();
        return ValueTask.FromResult(result);
    }

    public ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(KubeTarget target, GroupVersionResource resource, KubeExecutionContext? executionContext = null, bool refresh = false, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        IReadOnlyList<KubeResourceDescriptor> snapshot = Snapshot(refresh);
        return ValueTask.FromResult(KubeDiscoveryResolution.Resolve(resource, snapshot, snapshot, target, "fixture.discovery.ambiguous-resource"));
    }

    private IReadOnlyList<KubeResourceDescriptor> Snapshot(bool refresh)
    {
        if (refresh)
        {
            RefreshRequests++;
            _cached = null;
        }
        return _cached ??= _source.ToArray();
    }
}

sealed class FakeResourceClient : IKubeResourceClient
{
    private readonly List<KubeResource> _resources;
    public int GetCalls { get; private set; }
    public int CollectionGetCalls { get; private set; }
    public int AllNamespacesCollectionGetCalls { get; private set; }
    public int TryGetCalls { get; private set; }
    public int ListNamesCalls { get; private set; }
    public int ExistsCalls { get; private set; }

    public FakeResourceClient(IEnumerable<KubeResource> resources) => _resources = resources.ToList();

    public IReadOnlyList<KubeResource> Get(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null) => GetAsync(target, query, executionContext).AsTask().GetAwaiter().GetResult();
    public bool Exists(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null) => ExistsAsync(target, query, executionContext).AsTask().GetAwaiter().GetResult();
    public KubeResource? TryGet(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null) => TryGetAsync(target, query, executionContext).AsTask().GetAwaiter().GetResult();
    public IReadOnlyList<string> ListNames(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null) => ListNamesAsync(target, query, executionContext).AsTask().GetAwaiter().GetResult();
    public KubeResource Create(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeCreateOptions? options = null, KubeExecutionContext? executionContext = null) => throw new NotSupportedException();
    public KubeResource Replace(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeReplaceOptions? options = null, KubeExecutionContext? executionContext = null) => throw new NotSupportedException();
    public KubeResource Apply(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeApplyOptions? options = null, KubeExecutionContext? executionContext = null) => throw new NotSupportedException();
    public KubeResource Patch(KubeTarget target, ResourceIdentity identity, string payloadJson, KubePatchOptions? options = null, KubeExecutionContext? executionContext = null) => throw new NotSupportedException();
    public void Delete(KubeTarget target, ResourceIdentity identity, KubeDeleteOptions? options = null, KubeExecutionContext? executionContext = null) => throw new NotSupportedException();

    public ValueTask<IReadOnlyList<KubeResource>> GetAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        GetCalls++;
        if (string.IsNullOrWhiteSpace(query.Name))
        {
            CollectionGetCalls++;
            if (query.NamespaceScope.Kind == KubeNamespaceScopeKind.All) AllNamespacesCollectionGetCalls++;
        }
        IEnumerable<KubeResource> values = _resources.Where(x => SameGvr(x.Identity.Gvr, query.Gvr));
        values = query.NamespaceScope.Kind switch
        {
            KubeNamespaceScopeKind.All => values,
            KubeNamespaceScopeKind.Cluster => values.Where(x => x.Identity.Namespace is null),
            KubeNamespaceScopeKind.Explicit => values.Where(x => string.Equals(x.Identity.Namespace, query.NamespaceScope.Name, StringComparison.Ordinal)),
            _ => values.Where(x => string.Equals(x.Identity.Namespace, target.DefaultNamespace, StringComparison.Ordinal))
        };
        if (!string.IsNullOrWhiteSpace(query.Name)) values = values.Where(x => x.Identity.Name == query.Name);
        return ValueTask.FromResult<IReadOnlyList<KubeResource>>(values.ToArray());
    }

    public async ValueTask<bool> ExistsAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        ExistsCalls++;
        return await TryGetAsync(target, query, executionContext, cancellationToken) is not null;
    }

    public async ValueTask<KubeResource?> TryGetAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        TryGetCalls++;
        return (await GetAsync(target, query, executionContext, cancellationToken)).FirstOrDefault();
    }

    public async ValueTask<IReadOnlyList<string>> ListNamesAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        ListNamesCalls++;
        return (await GetAsync(target, query, executionContext, cancellationToken)).Select(x => x.Identity.Name).ToArray();
    }

    public ValueTask<KubeResource> CreateAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeCreateOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeResource> ReplaceAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeReplaceOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeResource> ApplyAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeApplyOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask<KubeResource> PatchAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubePatchOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();
    public ValueTask DeleteAsync(KubeTarget target, ResourceIdentity identity, KubeDeleteOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();

    private static bool SameGvr(GroupVersionResource left, GroupVersionResource right) =>
        string.Equals(left.Group, right.Group, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(left.Version, right.Version, StringComparison.OrdinalIgnoreCase) &&
        string.Equals(left.Resource, right.Resource, StringComparison.OrdinalIgnoreCase);
}

sealed class FakeExecutionClient : IKubeResourceExecutionClient
{
    public int CreateCalls { get; private set; }
    public int ReplaceCalls { get; private set; }
    public int ApplyCalls { get; private set; }
    public int PatchCalls { get; private set; }
    public int DeleteCalls { get; private set; }
    public ResourceIdentity? LastIdentity { get; private set; }

    public ValueTask<KubeExecutionResult<IReadOnlyList<KubeResource>>> GetAsync(KubeTarget target, ResourceQuery query, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default) => throw new NotSupportedException();

    public ValueTask<KubeExecutionResult<KubeResource>> CreateAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeCreateOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested(); CreateCalls++; LastIdentity = identity;
        return ValueTask.FromResult(Result(identity));
    }

    public ValueTask<KubeExecutionResult<KubeResource>> ReplaceAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeReplaceOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested(); ReplaceCalls++; LastIdentity = identity;
        return ValueTask.FromResult(Result(identity));
    }

    public ValueTask<KubeExecutionResult<KubeResource>> ApplyAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubeApplyOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested(); ApplyCalls++; LastIdentity = identity;
        return ValueTask.FromResult(Result(identity));
    }

    public ValueTask<KubeExecutionResult<KubeResource>> PatchAsync(KubeTarget target, ResourceIdentity identity, string payloadJson, KubePatchOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested(); PatchCalls++; LastIdentity = identity;
        return ValueTask.FromResult(Result(identity));
    }

    public ValueTask<KubeExecutionResult> DeleteAsync(KubeTarget target, ResourceIdentity identity, KubeDeleteOptions? options = null, KubeExecutionContext? executionContext = null, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested(); DeleteCalls++; LastIdentity = identity;
        return ValueTask.FromResult(new KubeExecutionResult(
            new[] { new KubeWarning("deleted", "fixture.warning") },
            new[] { new KubeDiagnostic("fixture.delete", "deleted") }));
    }

    private static KubeExecutionResult<KubeResource> Result(ResourceIdentity identity)
    {
        JsonObject document = new()
        {
            ["apiVersion"] = identity.Gvr.ApiVersion,
            ["kind"] = identity.Kind ?? "Fixture",
            ["metadata"] = new JsonObject
            {
                ["name"] = identity.Name,
                ["namespace"] = identity.Namespace
            }
        };
        return new KubeExecutionResult<KubeResource>(
            new KubeResource(identity, document),
            new[] { new KubeWarning("fixture warning", "fixture.warning") },
            new[] { new KubeDiagnostic("fixture.diagnostic", "fixture diagnostic") });
    }
}

sealed class CancellationBackend : IKubeBackend, IKubeDiscoveryBackend, IKubeCapabilityEvaluator
{
    public string Id => "fixture-cancellation";

    public ValueTask<KubeOperationSupport> EvaluateAsync(
        KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        ValueTask.FromResult(KubeOperationSupport.Supported());

    public ValueTask<KubeOperationResult> ExecuteAsync(
        KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        ValueTask.FromException<KubeOperationResult>(new OperationCanceledException(cancellationToken));

    public ValueTask<KubeOperationSupport> EvaluateCapabilityAsync(
        KubeCapabilityRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        ValueTask.FromResult(KubeOperationSupport.Supported());

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetPreferredResourcesAsync(
        KubeTarget target, KubeExecutionContext executionContext, bool refresh = false, CancellationToken cancellationToken = default) =>
        ValueTask.FromException<IReadOnlyList<KubeResourceDescriptor>>(new OperationCanceledException(cancellationToken));

    public ValueTask<IReadOnlyList<KubeResourceDescriptor>> GetApiVersionResourcesAsync(
        string apiVersion, KubeTarget target, KubeExecutionContext executionContext, bool refresh = false, CancellationToken cancellationToken = default) =>
        ValueTask.FromException<IReadOnlyList<KubeResourceDescriptor>>(new OperationCanceledException(cancellationToken));

    public ValueTask<KubeResourceDescriptor?> ResolveResourceAsync(
        GroupVersionResource resource, KubeTarget target, KubeExecutionContext executionContext, bool refresh = false, CancellationToken cancellationToken = default) =>
        ValueTask.FromException<KubeResourceDescriptor?>(new OperationCanceledException(cancellationToken));
}



sealed class FakeKubeDiscoveryServer : IAsyncDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private Task? _loop;

    public Uri BaseUri { get; private set; } = null!;

    public void Start()
    {
        _listener.Start();
        int port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        BaseUri = new Uri($"http://127.0.0.1:{port}/");
        _loop = Task.Run(LoopAsync);
    }

    private async Task LoopAsync()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_stop.Token); }
            catch (OperationCanceledException) { break; }
            _ = Task.Run(() => HandleAsync(client));
        }
    }

    private static async Task HandleAsync(TcpClient client)
    {
        using (client)
        using (NetworkStream stream = client.GetStream())
        using (var reader = new StreamReader(stream, Encoding.ASCII, false, 4096, leaveOpen: true))
        {
            string? requestLine = await reader.ReadLineAsync();
            if (string.IsNullOrWhiteSpace(requestLine)) return;
            string path = requestLine.Split(' ')[1];
            while (!string.IsNullOrEmpty(await reader.ReadLineAsync())) { }
            (int status, string body) = Response(path);
            byte[] bytes = Encoding.UTF8.GetBytes(body);
            string reason = status == 200 ? "OK" : "Service Unavailable";
            byte[] header = Encoding.ASCII.GetBytes($"HTTP/1.1 {status} {reason}\r\nContent-Type: application/json\r\nContent-Length: {bytes.Length}\r\nConnection: close\r\n\r\n");
            await stream.WriteAsync(header);
            await stream.WriteAsync(bytes);
        }
    }

    private static (int, string) Response(string path)
    {
        // The generated KubernetesClient 19.0.2 discovery surfaces are not uniform about a
        // terminal slash: the root discovery APIs use one, while generic group/version
        // discovery may omit it. Treat one terminal slash as URI-equivalent in this fixture,
        // but keep malformed/double-slash paths visible as failures.
        string route = path.Length > 1
            && path.EndsWith("/", StringComparison.Ordinal)
            && !path.EndsWith("//", StringComparison.Ordinal)
                ? path[..^1]
                : path;

        return route switch
        {
            "/api" => (200, "{\"kind\":\"APIVersions\",\"apiVersion\":\"v1\",\"versions\":[\"v1\"],\"serverAddressByClientCIDRs\":[]}"),
            "/apis" => (200, "{\"kind\":\"APIGroupList\",\"apiVersion\":\"v1\",\"groups\":[" +
                "{\"name\":\"good.example.com\",\"versions\":[{\"groupVersion\":\"good.example.com/v1\",\"version\":\"v1\"}],\"preferredVersion\":{\"groupVersion\":\"good.example.com/v1\",\"version\":\"v1\"}}," +
                "{\"name\":\"bad.example.com\",\"versions\":[{\"groupVersion\":\"bad.example.com/v1\",\"version\":\"v1\"}],\"preferredVersion\":{\"groupVersion\":\"bad.example.com/v1\",\"version\":\"v1\"}}," +
                "{\"name\":\"versions.example.com\",\"versions\":[{\"groupVersion\":\"versions.example.com/v1\",\"version\":\"v1\"},{\"groupVersion\":\"versions.example.com/v1alpha1\",\"version\":\"v1alpha1\"}],\"preferredVersion\":{\"groupVersion\":\"versions.example.com/v1\",\"version\":\"v1\"}}]}"),
            "/api/v1" => (200, ResourceList("v1", "{\"name\":\"pods\",\"singularName\":\"pod\",\"namespaced\":true,\"kind\":\"Pod\",\"verbs\":[\"get\",\"list\",\"patch\"],\"shortNames\":[\"po\"]}")),
            "/apis/good.example.com/v1" => (200, ResourceList("good.example.com/v1", "{\"name\":\"widgets\",\"singularName\":\"widget\",\"namespaced\":true,\"kind\":\"Widget\",\"verbs\":[\"get\",\"list\"]}")),
            "/apis/bad.example.com/v1" => (503, "{\"kind\":\"Status\",\"apiVersion\":\"v1\",\"status\":\"Failure\",\"message\":\"aggregated api unavailable\",\"reason\":\"ServiceUnavailable\",\"code\":503}"),
            "/apis/versions.example.com/v1" => (200, ResourceList("versions.example.com/v1", "{\"name\":\"versionedwidgets\",\"singularName\":\"versionedwidget\",\"namespaced\":true,\"kind\":\"VersionedWidget\",\"verbs\":[\"get\",\"list\"],\"shortNames\":[\"vw\"]}")),
            "/apis/versions.example.com/v1alpha1" => (200, ResourceList("versions.example.com/v1alpha1", "{\"name\":\"versionedwidgets\",\"singularName\":\"versionedwidget\",\"namespaced\":true,\"kind\":\"VersionedWidget\",\"verbs\":[\"get\",\"list\"],\"shortNames\":[\"vw\"]},{\"name\":\"legacywidgets\",\"singularName\":\"legacywidget\",\"namespaced\":true,\"kind\":\"LegacyWidget\",\"verbs\":[\"get\",\"list\"],\"shortNames\":[\"lw\"]}")),
            _ => (503, JsonSerializer.Serialize(new
            {
                kind = "Status",
                apiVersion = "v1",
                status = "Failure",
                message = $"unexpected path: {path}",
                reason = "ServiceUnavailable",
                code = 503
            }))
        };
    }

    private static string ResourceList(string groupVersion, string resources) =>
        $"{{\"kind\":\"APIResourceList\",\"apiVersion\":\"v1\",\"groupVersion\":\"{groupVersion}\",\"resources\":[{resources}]}}";

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        _listener.Stop();
        if (_loop is not null) { try { await _loop; } catch (OperationCanceledException) { } }
        _stop.Dispose();
    }
}

sealed class MatrixBackend : IKubeBackend, IKubeCapabilityEvaluator
{
    public MatrixBackend(string id, KubeSupportState state, Exception? executionException = null)
    {
        Id = id;
        State = state;
        ExecutionException = executionException;
    }

    public string Id { get; }
    public KubeSupportState State { get; set; }
    public Exception? ExecutionException { get; set; }
    public int EvaluateCalls { get; private set; }
    public int ExecuteCalls { get; private set; }

    public ValueTask<KubeOperationSupport> EvaluateAsync(KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default)
    {
        EvaluateCalls++;
        return ValueTask.FromResult(Support(State));
    }

    public ValueTask<KubeOperationSupport> EvaluateCapabilityAsync(KubeCapabilityRequest request, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        ValueTask.FromResult(Support(State));

    public ValueTask<KubeOperationResult> ExecuteAsync(KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default)
    {
        ExecuteCalls++;
        if (ExecutionException is not null) return ValueTask.FromException<KubeOperationResult>(ExecutionException);
        KubeResource? resource = operation switch
        {
            KubeGetOperation get => new KubeResource(get.Identity, new JsonObject
            {
                ["apiVersion"] = get.Identity.Gvr.ApiVersion,
                ["kind"] = get.Identity.Kind ?? "Fixture",
                ["metadata"] = new JsonObject { ["name"] = get.Identity.Name, ["namespace"] = get.Identity.Namespace }
            }),
            _ => null
        };
        return ValueTask.FromResult(new KubeOperationResult(resource is null ? null : new[] { resource }));
    }

    private static KubeOperationSupport Support(KubeSupportState state) => state switch
    {
        KubeSupportState.Supported => KubeOperationSupport.Supported("fixture.supported"),
        KubeSupportState.Unsupported => KubeOperationSupport.Unsupported("fixture.unsupported", "unsupported"),
        KubeSupportState.Unavailable => KubeOperationSupport.Unavailable("fixture.unavailable", "unavailable"),
        KubeSupportState.Unknown => KubeOperationSupport.Unknown("fixture.unknown", "unknown"),
        _ => throw new ArgumentOutOfRangeException(nameof(state))
    };
}

sealed class WrongAdapter { }

sealed class WrongConstructorAdapter : IKubeBackend
{
    public WrongConstructorAdapter(string requiredArgument) => Id = requiredArgument;
    public string Id { get; }
    public ValueTask<KubeOperationSupport> EvaluateAsync(KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        ValueTask.FromResult(KubeOperationSupport.Unsupported("fixture.wrong-constructor", "fixture"));
    public ValueTask<KubeOperationResult> ExecuteAsync(KubeOperation operation, KubeTarget target, KubeExecutionContext executionContext, CancellationToken cancellationToken = default) =>
        ValueTask.FromException<KubeOperationResult>(new NotSupportedException());
}

public static class Program
{
static KubeResourceDescriptor Descriptor(string group, string version, string resource, string kind, bool namespaced, string singular, params string[] shortNames) =>
    KubeResourceDescriptor.Create(
        new GroupVersionResource(group, version, resource),
        kind,
        namespaced,
        new[] { "get", "list", "create", "patch", "update", "delete" },
        singularName: singular,
        shortNames: shortNames);

static KubeResource Resource(KubeResourceDescriptor descriptor, string name, string? ns = null) =>
    new(
        new ResourceIdentity(descriptor.Gvr, name, ns is null ? KubeNamespaceScope.Cluster : KubeNamespaceScope.Explicit(ns), kind: descriptor.Kind),
        new JsonObject
        {
            ["apiVersion"] = descriptor.Gvr.ApiVersion,
            ["kind"] = descriptor.Kind,
            ["metadata"] = new JsonObject
            {
                ["name"] = name,
                ["namespace"] = ns,
                ["uid"] = $"uid-{ns}-{name}",
                ["resourceVersion"] = "1"
            }
        });

public static async Task Main()
{
var namespaces = Descriptor("", "v1", "namespaces", "Namespace", false, "namespace", "ns");
var pods = Descriptor("", "v1", "pods", "Pod", true, "pod", "po");
var deployments = Descriptor("apps", "v1", "deployments", "Deployment", true, "deployment", "deploy");
var nodes = Descriptor("", "v1", "nodes", "Node", false, "node", "no");
var widgets = Descriptor("example.com", "v1", "widgets", "Widget", true, "widget", "wdg");
var coreThings = Descriptor("", "v1", "things", "CoreThing", true, "thing");
var groupedThings = Descriptor("example.com", "v1", "things", "GroupedThing", true, "thing");
var updateOnly = KubeResourceDescriptor.Create(
    new GroupVersionResource("legacy.example.com", "v1", "updateonlys"),
    "UpdateOnly",
    true,
    new[] { "get", "list", "update" },
    singularName: "updateonly",
    shortNames: new[] { "uo" });
var descriptors = new[] { namespaces, pods, deployments, nodes, widgets, coreThings, groupedThings, updateOnly };

var resources = new[]
{
    Resource(namespaces, "default"), Resource(namespaces, "monitoring"),
    Resource(pods, "shared", "default"), Resource(pods, "api", "default"),
    Resource(pods, "shared", "monitoring"), Resource(pods, "prometheus", "monitoring"),
    Resource(deployments, "web", "default"), Resource(widgets, "sample", "default"),
    Resource(updateOnly, "legacy", "default"),
    Resource(nodes, "node-a")
};

// [D2/D9] Backend-neutral discovery resolution treats versions of one GroupResource as one
// logical candidate, prefers the server-preferred descriptor, and keeps aliases across different
// GroupResources explicitly ambiguous.
var alphaWidget = Descriptor("versions.example.com", "v1alpha1", "versionedwidgets", "VersionedWidget", true, "versionedwidget", "vw");
var stableWidget = Descriptor("versions.example.com", "v1", "versionedwidgets", "VersionedWidget", true, "versionedwidget", "vw");
var legacyOnly = Descriptor("versions.example.com", "v1alpha1", "legacywidgets", "LegacyWidget", true, "legacywidget", "lw");
var selectedPreferred = KubeDiscoveryResolution.Resolve(
    new GroupVersionResource("versions.example.com", string.Empty, "versionedwidgets"),
    new[] { alphaWidget, stableWidget },
    new[] { stableWidget });
Assert.Equal("v1", selectedPreferred!.Gvr.Version, "Version-neutral discovery did not select the preferred served version.");
var selectedLegacy = KubeDiscoveryResolution.Resolve(
    new GroupVersionResource("versions.example.com", string.Empty, "legacywidgets"),
    new[] { legacyOnly, stableWidget },
    new[] { stableWidget });
Assert.Equal("v1alpha1", selectedLegacy!.Gvr.Version, "Resource existing only in a non-preferred served version was lost.");
try
{
    _ = KubeDiscoveryResolution.Resolve(
        new GroupVersionResource(string.Empty, string.Empty, "same"),
        new[]
        {
            Descriptor("one.example.com", "v1", "ones", "One", true, "one", "same"),
            Descriptor("two.example.com", "v1", "twos", "Two", true, "two", "same")
        });
    throw new InvalidOperationException("Ambiguous cross-GroupResource alias was accepted.");
}
catch (KubeException exception) when (exception.Kind == KubeErrorKind.InvalidResource) { }

// [D2/D8/D9] Exercise the real managed adapter without a cluster. Partial aggregated discovery
// keeps useful groups, and unresolved resources see non-preferred served versions.
await using (var discoveryServer = new FakeKubeDiscoveryServer())
{
    discoveryServer.Start();
    var managedBackend = KubernetesClientBackend.CreateExplicit(discoveryServer.BaseUri);
    var managedTarget = new KubeTarget("fixture-managed");
    IReadOnlyList<KubeResourceDescriptor> managedPreferred = await managedBackend.GetPreferredResourcesAsync(
        managedTarget, KubeExecutionContext.Default, refresh: true);
    Assert.True(managedPreferred.Any(x => x.Gvr.Resource == "pods"), "Partial aggregated discovery lost core resources.");
    Assert.True(managedPreferred.Any(x => x.Gvr.Resource == "widgets" && x.Gvr.Group == "good.example.com"), "Partial aggregated discovery lost successful API group.");
    KubeResourceDescriptor? managedLegacy = await managedBackend.ResolveResourceAsync(
        new GroupVersionResource("versions.example.com", string.Empty, "legacywidgets"),
        managedTarget, KubeExecutionContext.Default, refresh: true);
    Assert.Equal("v1alpha1", managedLegacy!.Gvr.Version, "Managed discovery lost resource served only in a non-preferred version.");
}

// The managed APIResourceList mapper and Runtime token resolver consume the same frozen corpus
// as the native Go unit tests (Tests/Fixtures/discovery-parity.json). This catches orphan-subresource
// and alias/version parity drift without requiring a live Kubernetes server.
string parityPath = Path.Combine(AppContext.BaseDirectory, "discovery-parity.json");
JsonObject parity = JsonNode.Parse(await File.ReadAllTextAsync(parityPath))!.AsObject();
KubeResourceDescriptor ParseDescriptor(JsonObject item) => KubeResourceDescriptor.Create(
    new GroupVersionResource(item["group"]?.GetValue<string>() ?? string.Empty, item["version"]!.GetValue<string>(), item["resource"]!.GetValue<string>()),
    item["kind"]?.GetValue<string>(), item["namespaced"]?.GetValue<bool>() ?? false,
    item["verbs"]?.AsArray().Select(x => x!.GetValue<string>()) ?? Array.Empty<string>(),
    singularName: item["singular"]?.GetValue<string>(),
    shortNames: item["shortNames"]?.AsArray().Select(x => x!.GetValue<string>()) ?? Array.Empty<string>());
var parityAll = parity["all"]!.AsArray().Select(x => ParseDescriptor(x!.AsObject())).ToArray();
var parityPreferred = parity["preferred"]!.AsArray().Select(x => ParseDescriptor(x!.AsObject())).ToArray();
Assert.Equal("v1", KubeDiscoveryResolution.Resolve(new GroupVersionResource("apps.example.com", "", "widgets"), parityAll, parityPreferred)!.Gvr.Version, "Parity corpus did not prefer stable version.");
Assert.Equal("v1alpha1", KubeDiscoveryResolution.Resolve(new GroupVersionResource("apps.example.com", "", "legacywidgets"), parityAll, parityPreferred)!.Gvr.Version, "Parity corpus lost non-preferred-only resource.");
try
{
    _ = KubeDiscoveryResolution.Resolve(new GroupVersionResource("", "", "same"), parityAll, parityPreferred);
    throw new InvalidOperationException("Parity corpus ambiguous alias was accepted.");
}
catch (KubeException exception) when (exception.Kind == KubeErrorKind.InvalidResource) { }

Type resourceListType = Type.GetType("k8s.Models.V1APIResourceList, KubernetesClient", throwOnError: true)!;
Type apiResourceType = Type.GetType("k8s.Models.V1APIResource, KubernetesClient", throwOnError: true)!;
object apiList = Activator.CreateInstance(resourceListType)!;
JsonObject apiCorpus = parity["apiResourceList"]!.AsObject();
resourceListType.GetProperty("GroupVersion")!.SetValue(apiList, apiCorpus["groupVersion"]!.GetValue<string>());
IList apiResources = (IList)Activator.CreateInstance(typeof(List<>).MakeGenericType(apiResourceType))!;
foreach (JsonNode? entryNode in apiCorpus["resources"]!.AsArray())
{
    JsonObject entry = entryNode!.AsObject();
    object apiResource = Activator.CreateInstance(apiResourceType)!;
    apiResourceType.GetProperty("Name")!.SetValue(apiResource, entry["name"]!.GetValue<string>());
    apiResourceType.GetProperty("Kind")!.SetValue(apiResource, entry["kind"]!.GetValue<string>());
    apiResourceType.GetProperty("Namespaced")!.SetValue(apiResource, entry["namespaced"]!.GetValue<bool>());
    apiResourceType.GetProperty("SingularName")!.SetValue(apiResource, entry["singularName"]?.GetValue<string>());
    apiResourceType.GetProperty("Verbs")!.SetValue(apiResource, entry["verbs"]!.AsArray().Select(x => x!.GetValue<string>()).ToList());
    apiResourceType.GetProperty("ShortNames")!.SetValue(apiResource, entry["shortNames"]?.AsArray().Select(x => x!.GetValue<string>()).ToList() ?? new List<string>());
    apiResources.Add(apiResource);
}
resourceListType.GetProperty("Resources")!.SetValue(apiList, apiResources);
Type discoveryServiceType = typeof(KubernetesClientBackend).Assembly.GetType("KubeShell.Backends.KubernetesClient.KubernetesDiscoveryService", throwOnError: true)!;
MethodInfo mapMethod = discoveryServiceType.GetMethod("Map", BindingFlags.Static | BindingFlags.NonPublic)!;
var mappedParity = (IReadOnlyList<KubeResourceDescriptor>)mapMethod.Invoke(null, new[] { apiList })!;
Assert.True(mappedParity.Count == 1 && mappedParity[0].Gvr.Resource == "deployments", "Managed mapper did not drop orphan subresource from parity corpus.");
Assert.True(mappedParity[0].SubresourceDetails["status"].Group == "apps" && mappedParity[0].SubresourceDetails["status"].Version == "v1", "Managed subresource did not inherit parent group/version.");

var target = new KubeTarget("fixture-context", new[] { "/tmp/fixture-kubeconfig" }, "default", source: "fixture");
var discovery = new FakeDiscoveryClient(descriptors);
var resourceClient = new FakeResourceClient(resources);
var execution = new FakeExecutionClient();
var nav = new KubeNavigationService(target, resourceClient, execution, discovery);

// [A4/C1/E1/K4] Creating the default semantic root is pure navigation state and performs no resource I/O.
var rootMount = await nav.CreateRootLocatorAsync(new KubeMountRequest());
Assert.True(rootMount is TargetRootLocator, "Default mount did not produce TargetRoot.");
Assert.Equal(0, resourceClient.GetCalls, "Creating TargetRoot performed resource I/O.");
Assert.True(typeof(KubeShellHost).GetProperties(BindingFlags.Instance | BindingFlags.Public).All(p => !p.PropertyType.Name.Contains("Router", StringComparison.OrdinalIgnoreCase) && !p.PropertyType.Name.Contains("Backend", StringComparison.OrdinalIgnoreCase)), "Hosting leaked router/backend collection through public application API.");

// [C11] Runtime owns the pure current-context freeze policy while outer adapters decide when to invoke it.
var ambientTarget = new KubeTarget(null, new[] { "/tmp/fixture-kubeconfig" }, "default", profile: "prod", configSet: "fixture", source: "profile:prod");
var frozenTarget = KubeTargetResolution.FreezeCurrentContext(ambientTarget, new KubeConfigView("fixture-context", new[] { new KubeConfigContextInfo("fixture-context", "cluster", "user", "default") }));
Assert.Equal("fixture-context", frozenTarget.Context!, "Current-context target was not frozen.");
Assert.Equal("fixture-context", KubeTargetResolution.FreezeCurrentContext(frozenTarget, new KubeConfigView("other-context", new[] { new KubeConfigContextInfo("other-context", "cluster", "user", "default") })).Context!, "Already frozen target was retargeted by later ambient context.");

// Target identity follows execution identity, not profile/config/source/default-namespace aliases.
var sameTargetThroughProfile = new KubeTarget(
    "fixture-context",
    new[] { "/tmp/fixture-kubeconfig" },
    "monitoring",
    profile: "prod",
    configSet: "shared",
    source: "profile:prod");
Assert.Equal(nav.TargetRoot.TargetKey, KubeTargetIdentity.Create(sameTargetThroughProfile), "Presentation aliases changed semantic target identity.");
Assert.True(
    nav.TargetRoot.TargetKey != KubeTargetIdentity.Create(new KubeTarget("other-context", new[] { "/tmp/fixture-kubeconfig" })),
    "Different Kubernetes contexts collided in target identity.");


// [B1/B3] Kubeconfig paths are exact execution identity. Whitespace, separators, list cardinality,
// and order must survive construction and must never collapse before hashing/session-cache selection.
var trailingSpaceTarget = new KubeTarget("fixture-context", new[] { "/tmp/fixture-kubeconfig " });
Assert.Equal("/tmp/fixture-kubeconfig ", trailingSpaceTarget.KubeConfigPaths[0], "KubeTarget trimmed an exact kubeconfig path.");
Assert.True(
    KubeTargetIdentity.Create(trailingSpaceTarget) != KubeTargetIdentity.Create(new KubeTarget("fixture-context", new[] { "/tmp/fixture-kubeconfig" })),
    "Trailing-space kubeconfig path collided with the trimmed filename.");
var embeddedUnitSeparator = new KubeTarget("fixture-context", new[] { "/tmp/a\u001f/tmp/b" });
var twoUnitSeparatedPaths = new KubeTarget("fixture-context", new[] { "/tmp/a", "/tmp/b" });
Assert.True(
    KubeTargetIdentity.Create(embeddedUnitSeparator) != KubeTargetIdentity.Create(twoUnitSeparatedPaths),
    "One kubeconfig path containing U+001F collided with two ordered kubeconfig paths.");
string pathSeparator = Path.PathSeparator.ToString();
var embeddedPathSeparator = new KubeTarget("fixture-context", new[] { "/tmp/a" + pathSeparator + "/tmp/b" });
var twoPathSeparatorPaths = new KubeTarget("fixture-context", new[] { "/tmp/a", "/tmp/b" });
Assert.True(
    KubeTargetIdentity.Create(embeddedPathSeparator) != KubeTargetIdentity.Create(twoPathSeparatorPaths),
    "One kubeconfig path containing the platform path separator collided with two paths.");
Assert.True(
    KubeTargetIdentity.Create(new KubeTarget("fixture-context", new[] { "/tmp/a", "/tmp/b" })) !=
    KubeTargetIdentity.Create(new KubeTarget("fixture-context", new[] { "/tmp/b", "/tmp/a" })),
    "Ordered kubeconfig precedence was lost from target identity.");
Assert.True(
    KubeTargetIdentity.Create(new KubeTarget("fixture-context", new[] { "/tmp/a" })) !=
    KubeTargetIdentity.Create(new KubeTarget("fixture-context", new[] { "/tmp/a", "/tmp/a" })),
    "Duplicate kubeconfig entries were collapsed out of target identity.");
Assert.True(
    KubeTargetIdentity.Create(new KubeTarget("fixture-context", new[] { "/tmp/a" })) !=
    KubeTargetIdentity.Create(new KubeTarget("Fixture-Context", new[] { "/tmp/a" })),
    "Case-distinct Kubernetes context names collided in target identity.");

var whitespaceContext = new KubeTarget(" ", new[] { "/tmp/fixture-kubeconfig" });
Assert.Equal(" ", whitespaceContext.Context!, "KubeTarget collapsed an explicit whitespace context name.");
Assert.True(
    KubeTargetIdentity.Create(whitespaceContext) != KubeTargetIdentity.Create(new KubeTarget(null, new[] { "/tmp/fixture-kubeconfig" })),
    "Explicit whitespace context collided with an unresolved/current-context target.");

// Persistent navigation locators must already contain concrete scope. A Default scope would make
// the same stable ID depend on KubeTarget.DefaultNamespace, while All cannot identify one item.
try
{
    _ = new ResourceCollectionLocator(nav.TargetRoot.TargetKey, new GroupResource("", "pods"), KubeNamespaceScope.Default);
    throw new InvalidOperationException("Resource collection locator accepted unresolved default namespace scope.");
}
catch (ArgumentException) { }
try
{
    _ = new ResourceItemLocator(nav.TargetRoot.TargetKey, new GroupResource("", "pods"), KubeNamespaceScope.Default, "shared");
    throw new InvalidOperationException("Resource item locator accepted unresolved default namespace scope.");
}
catch (ArgumentException) { }
try
{
    _ = new ResourceItemLocator(nav.TargetRoot.TargetKey, new GroupResource("", "pods"), KubeNamespaceScope.All, "shared");
    throw new InvalidOperationException("Resource item locator accepted all-namespaces scope.");
}
catch (ArgumentException) { }

// Navigation node metadata is an owned immutable snapshot.
var metadataSource = new Dictionary<string, object?> { ["Kind"] = "Pod" };
var metadataLocator = new NamespaceLocator(nav.TargetRoot.TargetKey, "metadata-test");
var immutableNode = new KubeNavigationNode(
    metadataLocator,
    "metadata-test",
    "metadata-test",
    metadataLocator.Kind,
    KubeNavigationCapabilities.Container,
    metadata: metadataSource);
metadataSource["Kind"] = "Mutated";
Assert.Equal("Pod", immutableNode.Properties["Kind"]?.ToString() ?? string.Empty, "Navigation node metadata changed after source dictionary mutation.");
try
{
    ((IDictionary<string, object?>)immutableNode.Properties)["Kind"] = "MutatedAgain";
    throw new InvalidOperationException("Navigation node Properties accepted mutation.");
}
catch (NotSupportedException) { }

// Canonical topology and discovery-driven CRD visibility.
var rootChildren = await nav.GetChildrenAsync(nav.TargetRoot);
Assert.True(rootChildren.Any(x => x.Locator is NamespacesRootLocator), "Target root lacks Namespaces.");
Assert.True(rootChildren.Any(x => x.Locator is ClusterRootLocator), "Target root lacks Cluster.");

// Resolving a known namespace is a virtual edge and must not require cluster-wide namespace list RBAC.
var namespacesRoot = new NamespacesRootLocator(nav.TargetRoot.TargetKey);
var beforeNamespaceLists = resourceClient.ListNamesCalls;
var directNamespace = await nav.ResolveChildAsync(namespacesRoot, "default");
Assert.True(directNamespace?.Locator is NamespaceLocator { Namespace: "default" }, "Known namespace did not resolve as a virtual namespace node.");
Assert.Equal(beforeNamespaceLists, resourceClient.ListNamesCalls, "Direct namespace navigation required cluster-wide namespace listing.");
var listedNamespaces = await nav.GetChildrenAsync(namespacesRoot);
Assert.True(listedNamespaces.Any(x => x.Name == "default"), "Namespace enumeration lost live namespace listing.");
Assert.Equal(beforeNamespaceLists + 1, resourceClient.ListNamesCalls, "Namespace enumeration did not use exactly one namespace list operation.");

var ns = new NamespaceLocator(nav.TargetRoot.TargetKey, "default");
int beforeNamespaceTopologyLists = resourceClient.CollectionGetCalls;
var nsChildren = await nav.GetChildrenAsync(ns);
Assert.Equal(beforeNamespaceTopologyLists, resourceClient.CollectionGetCalls, "Enumerating namespace topology listed resource collections.");
Assert.True(nsChildren.Any(x => x.Name == "pods"), "Core namespaced resource missing.");
Assert.True(nsChildren.Any(x => x.Name == "deployments.apps"), "Grouped resource missing.");
Assert.True(nsChildren.Any(x => x.Name == "widgets.example.com"), "CRD-like resource missing.");
Assert.True(nsChildren.All(x => x.Name != "nodes"), "Cluster resource leaked into namespace topology.");

// [G1] The ObjectModel edit operation is ApplyAsync, which requires patch support. An update-only
// resource must therefore not advertise Editable merely because Kubernetes supports PUT/update.
var updateOnlyCollection = new ResourceCollectionLocator(
    nav.TargetRoot.TargetKey,
    new GroupResource("legacy.example.com", "updateonlys"),
    KubeNamespaceScope.Explicit("default"));
var updateOnlyItems = await nav.GetChildrenAsync(updateOnlyCollection);
var updateOnlyNode = updateOnlyItems.Single(x => x.Name == "legacy");
Assert.True((updateOnlyNode.Capabilities & KubeNavigationCapabilities.Editable) == 0, "Update-only resource advertised Apply/Edit capability without patch support.");
Assert.True(!nav.GetOperations(updateOnlyNode).Any(operation => operation.Id == "edit"), "Update-only resource exposed an executable edit operation.");

var clusterChildren = await nav.GetChildrenAsync(new ClusterRootLocator(nav.TargetRoot.TargetKey));
Assert.True(clusterChildren.Any(x => x.Name == "nodes"), "Cluster resource missing.");

// Alias canonicalization and ambiguity.
Assert.Equal("pods", GroupResource.From((await nav.ResolveResourceAliasAsync("po")).Gvr).ToString(), "Short-name alias did not canonicalize.");
Assert.Equal("pods", GroupResource.From((await nav.ResolveResourceAliasAsync("pod")).Gvr).ToString(), "Singular alias did not canonicalize.");
Assert.Equal("pods", GroupResource.From((await nav.ResolveResourceAliasAsync("pods")).Gvr).ToString(), "Plural alias did not canonicalize.");
Assert.Equal("deployments.apps", GroupResource.From((await nav.ResolveResourceAliasAsync("deployments.apps")).Gvr).ToString(), "Canonical resource.group token did not canonicalize.");
Assert.Equal("deployments.apps", GroupResource.From((await nav.ResolveResourceAliasAsync("Deployment")).Gvr).ToString(), "Kind alias did not canonicalize.");
await Assert.ThrowsAsync<KubeException>(() => nav.ResolveResourceAliasAsync("thing").AsTask(), "Ambiguous alias was accepted.");

// Canonical core identity must never fall through an unresolved alias wildcard to another API group.
var wildcardFallbackDiscovery = new FakeDiscoveryClient(
    new[] { groupedThings },
    _ => groupedThings);
var wildcardFallbackNav = new KubeNavigationService(target, resourceClient, execution, wildcardFallbackDiscovery);
var missingCoreCollection = new ResourceCollectionLocator(
    wildcardFallbackNav.TargetRoot.TargetKey,
    new GroupResource(string.Empty, "things"),
    KubeNamespaceScope.Explicit("default"));
await Assert.ThrowsAsync<KubeException>(
    () => wildcardFallbackNav.GetItemAsync(missingCoreCollection).AsTask(),
    "Canonical core resource identity was reinterpreted as a grouped alias during discovery fallback.");

// Explicit grouped canonical identity may use unresolved discovery because its group is unambiguous.
var groupedFallbackCollection = new ResourceCollectionLocator(
    wildcardFallbackNav.TargetRoot.TargetKey,
    new GroupResource("example.com", "things"),
    KubeNamespaceScope.Explicit("default"));
var groupedFallbackNode = await wildcardFallbackNav.GetItemAsync(groupedFallbackCollection);
Assert.True(groupedFallbackNode?.Locator is ResourceCollectionLocator { Resource: { Group: "example.com", Resource: "things" } }, "Explicit grouped resource did not use safe discovery fallback.");

// [C1-C10/K4/K5] Mount validation and arbitrary roots.
Assert.True(await nav.CreateRootLocatorAsync(new KubeMountRequest()) is TargetRootLocator, "Target root mount failed.");
var directNamespaceRoot = await nav.CreateRootLocatorAsync(new KubeMountRequest(Namespace: "default"));
Assert.True(directNamespaceRoot is NamespaceLocator, "Namespace subtree root was not created.");
var directCollectionRoot = await nav.CreateRootLocatorAsync(new KubeMountRequest("default", "deploy"));
Assert.True(directCollectionRoot is ResourceCollectionLocator { Resource: { Group: "apps", Resource: "deployments" }, Scope.Kind: KubeNamespaceScopeKind.Explicit }, "Namespace collection subtree root was not canonicalized.");
var directClusterRoot = await nav.CreateRootLocatorAsync(new KubeMountRequest(Resource: "nodes"));
Assert.True(directClusterRoot is ResourceCollectionLocator { Resource: { Group: "", Resource: "nodes" }, Scope.Kind: KubeNamespaceScopeKind.Cluster }, "Cluster collection root was not created.");
await Assert.ThrowsAsync<KubeException>(() => nav.CreateRootLocatorAsync(new KubeMountRequest(Resource: "pods")).AsTask(), "Namespaced resource without scope was accepted.");
await Assert.ThrowsAsync<KubeException>(() => nav.CreateRootLocatorAsync(new KubeMountRequest("default", "nodes")).AsTask(), "Cluster resource accepted namespace scope.");
await Assert.ThrowsAsync<KubeException>(() => nav.CreateRootLocatorAsync(new KubeMountRequest(Resource: "nodes", AllNamespaces: true)).AsTask(), "Cluster resource accepted AllNamespaces.");
await Assert.ThrowsAsync<KubeException>(() => nav.CreateRootLocatorAsync(new KubeMountRequest(AllNamespaces: true)).AsTask(), "AllNamespaces without resource was accepted.");
await Assert.ThrowsAsync<KubeException>(() => nav.CreateRootLocatorAsync(new KubeMountRequest("default", "pods", true)).AsTask(), "Namespace + AllNamespaces was accepted.");
Assert.True(typeof(KubeMountRequest).GetProperties().All(property => !string.Equals(property.Name, "Name", StringComparison.OrdinalIgnoreCase) && !string.Equals(property.Name, "Item", StringComparison.OrdinalIgnoreCase)), "Leaf-root mount unexpectedly became expressible in r11.");

// AllNamespaces returns namespace buckets and preserves same-name object identity by namespace.
var allPods = (ResourceCollectionLocator)await nav.CreateRootLocatorAsync(new KubeMountRequest(Resource: "pods", AllNamespaces: true));
var buckets = await nav.GetChildrenAsync(allPods);
Assert.Equal(2, buckets.Count, "AllNamespaces did not group by namespace.");
Assert.True(buckets.All(x => x.Locator is ResourceNamespaceBucketLocator), "AllNamespaces emitted non-bucket first-level nodes.");
var defaultBucketNode = buckets.Single(x => x.Name == "default");
var monitoringBucketNode = buckets.Single(x => x.Name == "monitoring");
var defaultBucket = (ResourceNamespaceBucketLocator)defaultBucketNode.Locator;
var monitoringBucket = (ResourceNamespaceBucketLocator)monitoringBucketNode.Locator;
var allPodsNode = await nav.GetItemAsync(allPods) ?? throw new InvalidOperationException("AllNamespaces collection did not materialize.");
Assert.True((allPodsNode.Capabilities & KubeNavigationCapabilities.Creatable) == 0, "AllNamespaces collection advertised create without a concrete namespace.");
Assert.True(!nav.GetOperations(allPodsNode).Any(operation => operation.Id == "create"), "AllNamespaces collection exposed an executable create operation.");
Assert.True((defaultBucketNode.Capabilities & KubeNavigationCapabilities.Creatable) != 0, "Explicit namespace bucket did not advertise create.");
Assert.True(nav.GetOperations(defaultBucketNode).Any(operation => operation.Id == "create"), "Explicit namespace bucket omitted its create operation.");

// Direct navigation into a known AllNamespaces bucket must not require a cluster-wide list.
// Enumeration of the AllNamespaces collection above is the one operation that intentionally does.
var allNamespaceListsAfterEnumeration = resourceClient.AllNamespacesCollectionGetCalls;
var directlyResolvedBucket = await nav.ResolveChildAsync(allPods, "default");
Assert.True(directlyResolvedBucket?.Locator is ResourceNamespaceBucketLocator { Namespace: "default" }, "Known AllNamespaces bucket did not resolve as a virtual edge.");
Assert.Equal(allNamespaceListsAfterEnumeration, resourceClient.AllNamespacesCollectionGetCalls, "Direct AllNamespaces bucket navigation repeated a cluster-wide resource list.");

var defaultItems = await nav.GetChildrenAsync(defaultBucket);
Assert.Equal(allNamespaceListsAfterEnumeration, resourceClient.AllNamespacesCollectionGetCalls, "Bucket contents were fetched through an all-namespaces list instead of an explicit namespace query.");
var defaultNames = await nav.GetChildNamesAsync(defaultBucket);
Assert.True(defaultNames.Contains("shared"), "Bucket child-name query lost the namespace-scoped object list.");
Assert.Equal(allNamespaceListsAfterEnumeration, resourceClient.AllNamespacesCollectionGetCalls, "Bucket child-name query used an all-namespaces list.");
var monitoringItems = await nav.GetChildrenAsync(monitoringBucket);
Assert.Equal(allNamespaceListsAfterEnumeration, resourceClient.AllNamespacesCollectionGetCalls, "Second bucket contents used an all-namespaces list.");
var defaultShared = defaultItems.Single(x => x.Name == "shared");
var monitoringShared = monitoringItems.Single(x => x.Name == "shared");
Assert.True(defaultShared.Id != monitoringShared.Id, "Same resource name in two namespaces collided.");
Assert.Equal("default", ((ResourceItemLocator)defaultShared.Locator).Scope.Name!, "Bucket item did not receive explicit namespace identity.");
var coreThingId = new ResourceItemLocator(nav.TargetRoot.TargetKey, new GroupResource("", "things"), KubeNamespaceScope.Explicit("default"), "same").StableId;
var groupedThingId = new ResourceItemLocator(nav.TargetRoot.TargetKey, new GroupResource("example.com", "things"), KubeNamespaceScope.Explicit("default"), "same").StableId;
Assert.True(coreThingId != groupedThingId, "Core/grouped resources with the same name collided in semantic identity.");

// Same semantic object through a canonical namespace tree and collection-root mount has one stable ID.
var directPodsCollection = new ResourceCollectionLocator(nav.TargetRoot.TargetKey, new GroupResource("", "pods"), KubeNamespaceScope.Explicit("default"));
var directPods = await nav.GetChildrenAsync(directPodsCollection);
Assert.Equal(defaultShared.Id, directPods.Single(x => x.Name == "shared").Id, "Drive-root projection changed semantic stable ID.");
var directPodsNode = await nav.GetItemAsync(directPodsCollection) ?? throw new InvalidOperationException("Explicit pods collection did not materialize.");
Assert.True((directPodsNode.Capabilities & KubeNavigationCapabilities.Creatable) != 0, "Explicit collection with create verb did not advertise Create.");
Assert.True(nav.GetOperations(directPodsNode).Any(operation => operation.Id == "create"), "Explicit collection omitted create operation.");

// [F2/K2] A second target has distinct locator/cache identity even for the same resource path.
var otherTarget = new KubeTarget("other-context", new[] { "/tmp/fixture-kubeconfig" }, "default", source: "fixture-other");
var otherNav = new KubeNavigationService(otherTarget, resourceClient, execution, discovery);
var otherPodsCollection = new ResourceCollectionLocator(otherNav.TargetRoot.TargetKey, new GroupResource("", "pods"), KubeNamespaceScope.Explicit("default"));
Assert.True(otherPodsCollection != directPodsCollection && otherPodsCollection.TargetKey != directPodsCollection.TargetKey, "Navigation cache identity was not isolated by TargetKey.");

// Resolving a known item is a point read and must not list the whole collection first.
var beforePointCollectionLists = resourceClient.CollectionGetCalls;
var beforePointGets = resourceClient.TryGetCalls;
var resolvedShared = await nav.ResolveChildAsync(directPodsCollection, "shared");
Assert.True(resolvedShared?.Locator is ResourceItemLocator, "Point item resolution did not return a resource item.");
Assert.Equal(beforePointCollectionLists, resourceClient.CollectionGetCalls, "Point item resolution listed the entire resource collection.");
Assert.Equal(beforePointGets + 1, resourceClient.TryGetCalls, "Point item resolution did not use exactly one TryGet.");

// Public concrete locators are still validated against discovery scope before any resource I/O.
var beforeInvalidScopeGets = resourceClient.TryGetCalls;
var clusterScopedPod = new ResourceItemLocator(nav.TargetRoot.TargetKey, new GroupResource("", "pods"), KubeNamespaceScope.Cluster, "shared");
await Assert.ThrowsAsync<KubeException>(() => nav.GetItemAsync(clusterScopedPod).AsTask(), "Namespaced item accepted cluster scope at the ObjectModel boundary.");
var namespacedNodeBucket = new ResourceNamespaceBucketLocator(nav.TargetRoot.TargetKey, new GroupResource("", "nodes"), "default");
await Assert.ThrowsAsync<KubeException>(() => nav.ResolveChildAsync(namespacedNodeBucket, "node-a").AsTask(), "Cluster resource accepted an explicit namespace bucket.");
Assert.Equal(beforeInvalidScopeGets, resourceClient.TryGetCalls, "Invalid locator scope reached the Runtime resource client.");

// Topology is cached, resource lists stay live, and refresh invalidates only navigation topology.
var beforeDiscovery = discovery.PreferredCalls;
_ = await nav.GetChildrenAsync(ns);
Assert.Equal(beforeDiscovery, discovery.PreferredCalls, "Topology cache was not reused.");
_ = await nav.GetChildrenAsync(ns, refresh: true);
Assert.True(discovery.PreferredCalls > beforeDiscovery, "Refresh did not rematerialize topology.");
var beforeLists = resourceClient.GetCalls;
_ = await nav.GetChildrenAsync(directPodsCollection);
_ = await nav.GetChildrenAsync(directPodsCollection);
Assert.True(resourceClient.GetCalls >= beforeLists + 2, "Resource collection data was incorrectly navigation-cached.");

// [F5/F7/F8] Backend discovery caching is modeled explicitly. Ordinary navigation may remain stale;
// semantic -Refresh must request a fresh discovery snapshot, while ObjectModel never owns or calls a
// backend-specific cache invalidation API directly.
var lateCrd = Descriptor("late.example.com", "v1", "latewidgets", "LateWidget", true, "latewidget", "lwdg");
var cachedDiscovery = new CachingDiscoveryClient(descriptors);
var cachedNav = new KubeNavigationService(target, resourceClient, execution, cachedDiscovery);
var cachedNs = new NamespaceLocator(cachedNav.TargetRoot.TargetKey, "default");
var cachedBefore = await cachedNav.GetChildrenAsync(cachedNs);
Assert.True(cachedBefore.All(child => child.Name != "latewidgets.late.example.com"), "Unexpected late CRD existed before discovery changed.");
cachedDiscovery.AddDescriptor(lateCrd);
var stillCached = await cachedNav.GetChildrenAsync(cachedNs);
Assert.True(stillCached.All(child => child.Name != "latewidgets.late.example.com"), "Topology changed without refresh while navigation/discovery caches were warm.");
int refreshRequestsBefore = cachedDiscovery.RefreshRequests;
var lateNode = await cachedNav.ResolveChildAsync(cachedNs, "latewidgets.late.example.com", refresh: true);
Assert.True(lateNode?.Locator is ResourceCollectionLocator { Resource: { Group: "late.example.com", Resource: "latewidgets" } }, "Deep refresh did not reconcile newly discovered CRD collection.");
Assert.True(cachedDiscovery.RefreshRequests > refreshRequestsBefore, "ObjectModel refresh did not request a fresh backend discovery snapshot.");
Assert.Equal(0, cachedDiscovery.DirectInvalidations, "ObjectModel reached into backend discovery-cache ownership directly.");
cachedDiscovery.RemoveDescriptor(new GroupResource("late.example.com", "latewidgets"));
var refreshedChildren = await cachedNav.GetChildrenAsync(cachedNs, refresh: true);
Assert.True(refreshedChildren.All(child => child.Name != "latewidgets.late.example.com"), "Topology refresh did not remove deleted CRD collection.");
Assert.Equal(0, cachedDiscovery.DirectInvalidations, "ObjectModel directly invalidated backend discovery cache while removing a CRD.");

// [F6] Resource data remains live when the resolved target container is refreshed.
int beforeTargetRefreshLists = resourceClient.GetCalls;
_ = await nav.GetChildrenAsync(directPodsCollection, refresh: true);
Assert.True(resourceClient.GetCalls > beforeTargetRefreshLists, "Refresh did not rematerialize target collection children.");

// [D7] Preferred API version may change between operations without changing locator identity.
// Use a production-like discovery cache: changing the source does not affect ordinary reads until
// the ObjectModel explicitly requests fresh operation-time discovery.
var rolloutV1 = Descriptor("roll.example.com", "v1", "rollouts", "Rollout", true, "rollout");
var rolloutV2 = Descriptor("roll.example.com", "v2", "rollouts", "Rollout", true, "rollout");
var rolloutV3 = Descriptor("roll.example.com", "v3", "rollouts", "Rollout", true, "rollout");
var rolloutV4 = Descriptor("roll.example.com", "v4", "rollouts", "Rollout", true, "rollout");
var changingDiscovery = new CachingDiscoveryClient(new[] { rolloutV1 });
var changingExecution = new FakeExecutionClient();
var changingNav = new KubeNavigationService(target, resourceClient, changingExecution, changingDiscovery);
var rolloutLocator = new ResourceItemLocator(changingNav.TargetRoot.TargetKey, new GroupResource("roll.example.com", "rollouts"), KubeNamespaceScope.Explicit("default"), "demo");
string rolloutId = rolloutLocator.StableId;
// Prime an old preferred snapshot before the underlying server preference changes.
_ = await changingDiscovery.GetPreferredResourcesAsync(target, refresh: false);
changingDiscovery.RemoveDescriptor(new GroupResource("roll.example.com", "rollouts"));
changingDiscovery.AddDescriptor(rolloutV2);
int d7RefreshBefore = changingDiscovery.RefreshRequests;
_ = await changingNav.ApplyAsync(rolloutLocator, """{"apiVersion":"roll.example.com/v2","kind":"Rollout","metadata":{"name":"demo","namespace":"default"}}""");
Assert.Equal("v2", changingExecution.LastIdentity!.Gvr.Version, "Apply used a stale preferred API version from backend discovery cache.");
Assert.True(changingDiscovery.RefreshRequests > d7RefreshBefore, "Apply did not request fresh operation-time preferred discovery.");
changingDiscovery.RemoveDescriptor(new GroupResource("roll.example.com", "rollouts"));
changingDiscovery.AddDescriptor(rolloutV3);
_ = await changingNav.CreateAsync(rolloutLocator, """{"apiVersion":"roll.example.com/v3","kind":"Rollout","metadata":{"name":"demo","namespace":"default"}}""");
Assert.Equal("v3", changingExecution.LastIdentity!.Gvr.Version, "Create used a stale preferred API version.");
changingDiscovery.RemoveDescriptor(new GroupResource("roll.example.com", "rollouts"));
changingDiscovery.AddDescriptor(rolloutV4);
_ = await changingNav.DeleteAsync(rolloutLocator);
Assert.Equal("v4", changingExecution.LastIdentity!.Gvr.Version, "Delete used a stale preferred API version.");
Assert.Equal(rolloutId, rolloutLocator.StableId, "Preferred version changes altered long-lived locator identity.");

// CRUD uses rich execution directly: no Exists preflight, and warnings/diagnostics survive projection.
var newLocator = new ResourceItemLocator(nav.TargetRoot.TargetKey, new GroupResource("", "pods"), KubeNamespaceScope.Explicit("default"), "created");
var created = await nav.CreateAsync(newLocator, "{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{\"name\":\"created\",\"namespace\":\"default\"}}");
Assert.Equal(1, execution.CreateCalls, "Create did not use rich Create exactly once.");
Assert.Equal(0, resourceClient.ExistsCalls, "Create performed an Exists preflight.");
Assert.Equal(1, created.Warnings.Count, "Create warning was lost.");
Assert.Equal(1, created.Diagnostics.Count, "Create diagnostic was lost.");
_ = await nav.ApplyAsync(newLocator, "{\"apiVersion\":\"v1\",\"kind\":\"Pod\",\"metadata\":{\"name\":\"created\",\"namespace\":\"default\"}}");
Assert.Equal(1, execution.ApplyCalls, "Apply was not delegated exactly once.");
int readsBeforeDelete = resourceClient.GetCalls + resourceClient.TryGetCalls + resourceClient.ListNamesCalls;
_ = await nav.DeleteAsync(newLocator);
Assert.Equal(1, execution.DeleteCalls, "Delete was not delegated exactly once.");
Assert.Equal(readsBeforeDelete, resourceClient.GetCalls + resourceClient.TryGetCalls + resourceClient.ListNamesCalls, "Delete performed a read/list preflight.");

// [H6/I1-I5] Routing distinguishes all support states, selects the first explicit Supported backend,
// and never replays a selected mutation after execution failure.
Assert.True(Enum.GetValues<KubeSupportState>().Distinct().Count() == 4, "Runtime support states collapsed.");
var unsupportedBackend = new MatrixBackend("unsupported", KubeSupportState.Unsupported);
var unavailableBackend = new MatrixBackend("unavailable", KubeSupportState.Unavailable);
var unknownBackend = new MatrixBackend("unknown", KubeSupportState.Unknown);
var supportedBackend = new MatrixBackend("supported", KubeSupportState.Supported);
var routingIdentity = new ResourceIdentity(pods.Gvr, "shared", KubeNamespaceScope.Explicit("default"), kind: "Pod");
var routingOp = new KubeGetOperation(routingIdentity);
var routingRouter = new KubeBackendRouter(new IKubeBackend[] { unsupportedBackend, unavailableBackend, unknownBackend, supportedBackend });
Assert.True(ReferenceEquals(supportedBackend, await routingRouter.SelectOperationAsync(routingOp, target, KubeExecutionContext.Default)), "Router did not select first Supported backend after declined candidates.");
var finalUnknownRouter = new KubeBackendRouter(new IKubeBackend[] { unsupportedBackend, unknownBackend });
try { _ = await finalUnknownRouter.SelectOperationAsync(routingOp, target, KubeExecutionContext.Default); throw new InvalidOperationException("Final Unknown routing decision executed."); }
catch (KubeException exception) { Assert.Equal(KubeErrorKind.Indeterminate, exception.Kind, "Final Unknown did not become Indeterminate."); }

async Task AssertFinalRoutingKind(KubeErrorKind expected, params KubeSupportState[] states)
{
    var candidates = states.Select((state, index) => (IKubeBackend)new MatrixBackend($"route-{index}-{state}", state)).ToArray();
    var candidateRouter = new KubeBackendRouter(candidates);
    try
    {
        _ = await candidateRouter.SelectOperationAsync(routingOp, target, KubeExecutionContext.Default);
        throw new InvalidOperationException($"Routing states [{string.Join(",", states)}] unexpectedly selected a backend.");
    }
    catch (KubeException exception)
    {
        Assert.Equal(expected, exception.Kind, $"Routing states [{string.Join(",", states)}] produced the wrong final taxonomy.");
    }
}

// [I4] Any unresolved Unknown must survive aggregation as Indeterminate when no backend is Supported,
// regardless of its position relative to definite Unsupported/Unavailable decisions.
await AssertFinalRoutingKind(KubeErrorKind.Indeterminate, KubeSupportState.Unknown, KubeSupportState.Unavailable);
await AssertFinalRoutingKind(KubeErrorKind.Indeterminate, KubeSupportState.Unavailable, KubeSupportState.Unknown);
await AssertFinalRoutingKind(KubeErrorKind.Indeterminate, KubeSupportState.Unsupported, KubeSupportState.Unavailable, KubeSupportState.Unknown);
await AssertFinalRoutingKind(KubeErrorKind.Indeterminate, KubeSupportState.Unknown, KubeSupportState.Unavailable, KubeSupportState.Unsupported);
await AssertFinalRoutingKind(KubeErrorKind.Unavailable, KubeSupportState.Unsupported, KubeSupportState.Unavailable);
await AssertFinalRoutingKind(KubeErrorKind.Unsupported, KubeSupportState.Unsupported);
var selectedFailure = new MatrixBackend("selected-failure", KubeSupportState.Supported, new KubeException(KubeErrorKind.Conflict, "selected execution failed"));
var replayCandidate = new MatrixBackend("replay-candidate", KubeSupportState.Supported);
var noReplayClient = new KubeOperationClient(new KubeBackendRouter(new IKubeBackend[] { selectedFailure, replayCandidate }));
try { _ = await noReplayClient.ExecuteAsync(target, new KubeDeleteOperation(routingIdentity, new KubeDeleteOptions())); throw new InvalidOperationException("Selected mutation failure was swallowed."); }
catch (KubeException exception) { Assert.Equal(KubeErrorKind.Conflict, exception.Kind, "Selected mutation failure changed taxonomy."); }
Assert.Equal(1, selectedFailure.ExecuteCalls, "Selected mutation was not executed exactly once.");
Assert.Equal(0, replayCandidate.ExecuteCalls, "Selected mutation failure was replayed on fallback backend.");

// [H7-H10] Invalid mutation identity/scope/concurrency fail before backend selection.
var validationBackend = new MatrixBackend("validation", KubeSupportState.Supported);
var validationClient = new KubeResourceExecutionClient(new KubeBackendRouter(new IKubeBackend[] { validationBackend }));
async Task ExpectPreRoutingFailure(Func<Task> action, string message)
{
    int before = validationBackend.EvaluateCalls;
    try { await action(); throw new InvalidOperationException(message); }
    catch (KubeException) { }
    catch (ArgumentException) { }
    Assert.Equal(before, validationBackend.EvaluateCalls, message + " reached backend selection.");
}
await ExpectPreRoutingFailure(
    () => validationClient.CreateAsync(target, new ResourceIdentity(pods.Gvr, "expected", KubeNamespaceScope.Explicit("default"), kind: "Pod"), """{"apiVersion":"v1","kind":"Pod","metadata":{"name":"other","namespace":"default"}}""").AsTask(),
    "Payload name mismatch");
await ExpectPreRoutingFailure(
    () => validationClient.CreateAsync(target, new ResourceIdentity(pods.Gvr, "expected", KubeNamespaceScope.Explicit("default"), kind: "Pod"), """{"apiVersion":"v1","kind":"Service","metadata":{"name":"expected","namespace":"default"}}""").AsTask(),
    "Payload kind mismatch");
var versionNeutralDeployment = new ResourceIdentity(
    new GroupVersionResource("apps", string.Empty, "deployments"),
    "expected",
    KubeNamespaceScope.Explicit("default"),
    kind: "Deployment");
const string wrongGroupDeployment = """{"apiVersion":"batch/v1","kind":"Deployment","metadata":{"name":"expected","namespace":"default"}}""";
await ExpectPreRoutingFailure(
    () => validationClient.CreateAsync(target, versionNeutralDeployment, wrongGroupDeployment).AsTask(),
    "Version-neutral Create payload group mismatch");
await ExpectPreRoutingFailure(
    () => validationClient.ReplaceAsync(target, versionNeutralDeployment, wrongGroupDeployment).AsTask(),
    "Version-neutral Replace payload group mismatch");
await ExpectPreRoutingFailure(
    () => validationClient.ApplyAsync(target, versionNeutralDeployment, wrongGroupDeployment).AsTask(),
    "Version-neutral Apply payload group mismatch");
await ExpectPreRoutingFailure(
    () => validationClient.CreateAsync(target, new ResourceIdentity(pods.Gvr, "expected", KubeNamespaceScope.Explicit("default"), kind: "Pod"), """{"apiVersion":"v1","kind":"Pod","metadata":{"name":"expected","namespace":"other"}}""").AsTask(),
    "Payload namespace mismatch");
await ExpectPreRoutingFailure(
    () => validationClient.CreateAsync(target, new ResourceIdentity(nodes.Gvr, "node-a", KubeNamespaceScope.Cluster, kind: "Node"), """{"apiVersion":"v1","kind":"Node","metadata":{"name":"node-a","namespace":"default"}}""").AsTask(),
    "Cluster payload namespace");
await ExpectPreRoutingFailure(
    () => validationClient.ReplaceAsync(target, routingIdentity, """{"apiVersion":"v1","kind":"Pod","metadata":{"name":"shared","namespace":"default"}}""", new KubeReplaceOptions(Concurrency: new KubeConcurrencyOptions(KubeConcurrencyMode.RequireUnchanged))).AsTask(),
    "Incomplete optimistic concurrency");

// [J1/J7] Semantic error kinds survive backend execution and contain no transport-specific status class.
foreach (KubeErrorKind kind in Enum.GetValues<KubeErrorKind>())
{
    var errorBackend = new MatrixBackend("error-" + kind, KubeSupportState.Supported, new KubeException(kind, kind.ToString()));
    var errorClient = new KubeOperationClient(errorBackend);
    try { _ = await errorClient.ExecuteAsync(target, routingOp); throw new InvalidOperationException("Error backend unexpectedly succeeded: " + kind); }
    catch (KubeException exception) { Assert.Equal(kind, exception.Kind, "Runtime error kind changed across semantic boundary."); }
}
Assert.True(Enum.GetNames<KubeErrorKind>().All(name => !name.Contains("Http", StringComparison.OrdinalIgnoreCase) && !name.Contains("Exit", StringComparison.OrdinalIgnoreCase) && !name.Contains("StatusCode", StringComparison.OrdinalIgnoreCase)), "Transport-specific status leaked into Runtime error taxonomy.");

// Cancellation reaches the semantic Runtime ports.
using var cancelled = new CancellationTokenSource();
cancelled.Cancel();
await Assert.ThrowsAsync<OperationCanceledException>(() => nav.ResolveResourceAliasAsync("pods", cancelled.Token).AsTask(), "Cancellation did not propagate to discovery.");

// Runtime semantic clients normalize adapter/selector cancellation to the backend-neutral Cancelled taxonomy.
var cancellationBackend = new CancellationBackend();
var runtimeDiscovery = new KubeDiscoveryClient(new IKubeBackend[] { cancellationBackend });
try
{
    _ = await runtimeDiscovery.GetPreferredResourcesAsync(target, cancellationToken: cancelled.Token);
    throw new InvalidOperationException("Runtime discovery accepted a cancelled backend operation.");
}
catch (KubeException exception)
{
    Assert.Equal(KubeErrorKind.Cancelled, exception.Kind, "Runtime discovery leaked backend-specific cancellation shape.");
}

var runtimeOperations = new KubeOperationClient(cancellationBackend);
var cancelledIdentity = new ResourceIdentity(pods.Gvr, "shared", KubeNamespaceScope.Explicit("default"), kind: "Pod");
try
{
    _ = await runtimeOperations.ExecuteAsync(target, new KubeGetOperation(cancelledIdentity), cancellationToken: cancelled.Token);
    throw new InvalidOperationException("Runtime operation client accepted a cancelled backend operation.");
}
catch (KubeException exception)
{
    Assert.Equal(KubeErrorKind.Cancelled, exception.Kind, "Runtime operation client leaked backend-specific cancellation shape.");
}

// Optional adapter load failure must not abort composition when a later semantic backend is
// available. An invalid managed DLL simulates a stale/incompatible optional package; the fixture
// process itself exposes a minimal process-backend type that Hosting can compose as fallback.
string compositionRoot = Path.Combine(Path.GetTempPath(), "kubeshell-hosting-fixture-" + Guid.NewGuid().ToString("N"));
try
{
    string managedDirectory = Path.Combine(compositionRoot, "Backends", "KubeShell.KubernetesClient", "bin", "Release", "net8.0");
    Directory.CreateDirectory(managedDirectory);
    await File.WriteAllBytesAsync(Path.Combine(managedDirectory, "KubeShell.KubernetesClient.dll"), new byte[] { 0x00, 0x01, 0x02, 0x03 });
    using KubeShellHost fallbackHost = KubeShellHost.Create(new KubeShellHostOptions(
        RepositoryRoot: compositionRoot,
        KubectlPath: "fixture-kubectl",
        EnableManagedBackend: true,
        EnableNativeBackend: false,
        EnableProcessFallback: true));
    Assert.True(fallbackHost.ResourceClient is not null, "Optional managed adapter load failure aborted fallback composition.");
    FieldInfo resolverField = typeof(KubeShellHost).GetField("_dependencyResolver", BindingFlags.Instance | BindingFlags.NonPublic)!;
    Assert.True(resolverField.GetValue(fallbackHost) is null, "Failed optional managed adapter left its dependency resolver attached to host lifetime.");
}
finally
{
    if (Directory.Exists(compositionRoot)) Directory.Delete(compositionRoot, recursive: true);
}

// [I6] Optional load-failure classification covers the declared load/ABI failure families.
MethodInfo optionalFailure = typeof(KubeShellHost).GetMethod("IsOptionalAdapterLoadFailure", BindingFlags.Static | BindingFlags.NonPublic)!;
bool Classified(Exception ex) => (bool)optionalFailure.Invoke(null, new object[] { ex })!;
Assert.True(Classified(new FileNotFoundException("missing dependency")), "Missing dependency was not optional-load failure.");
Assert.True(Classified(new BadImageFormatException("bad image")), "Bad image was not optional-load failure.");
Assert.True(Classified(new TypeLoadException("type load")), "Type-load failure was not optional-load failure.");
Assert.True(Classified(new TargetInvocationException(new FileLoadException("activation dependency"))), "Wrapped adapter activation load failure was not optional-load failure.");
Assert.True(!Classified(new MissingMethodException("contract method")), "Missing method contract mismatch was treated as optional unavailability.");
Assert.True(!Classified(new MissingFieldException("contract field")), "Missing field contract mismatch was treated as optional unavailability.");

// [I7] A configured type/assembly that loads successfully but violates the semantic/ABI contract fails fast.
MethodInfo tryAddBackend = typeof(KubeShellHost).GetMethod("TryAddBackend", BindingFlags.Static | BindingFlags.NonPublic)!;
try
{
    _ = tryAddBackend.Invoke(null, new object?[] { new List<IKubeBackend>(), new List<object>(), null, string.Empty, typeof(WrongAdapter).FullName!, null });
    throw new InvalidOperationException("Wrong adapter interface contract was silently treated as optional unavailability.");
}
catch (TargetInvocationException ex) when (ex.InnerException is InvalidOperationException) { }

try
{
    _ = tryAddBackend.Invoke(null, new object?[] { new List<IKubeBackend>(), new List<object>(), null, string.Empty, typeof(WrongConstructorAdapter).FullName!, null });
    throw new InvalidOperationException("Wrong adapter constructor contract was silently treated as optional unavailability.");
}
catch (TargetInvocationException ex) when (ex.InnerException is MissingMethodException) { }

string wrongTypeRoot = Path.Combine(Path.GetTempPath(), "kubeshell-hosting-wrong-type-" + Guid.NewGuid().ToString("N"));
try
{
    Directory.CreateDirectory(wrongTypeRoot);
    const string wrongTypeRelative = "adapter.dll";
    File.Copy(typeof(KubeTarget).Assembly.Location, Path.Combine(wrongTypeRoot, wrongTypeRelative));
    try
    {
        _ = tryAddBackend.Invoke(null, new object?[] { new List<IKubeBackend>(), new List<object>(), wrongTypeRoot, wrongTypeRelative, "KubeShell.Backends.MissingExpectedBackend", null });
        throw new InvalidOperationException("Repository-local adapter missing its expected type was silently treated as optional unavailability.");
    }
    catch (TargetInvocationException ex) when (ex.InnerException is InvalidOperationException) { }
}
finally
{
    if (Directory.Exists(wrongTypeRoot)) Directory.Delete(wrongTypeRoot, recursive: true);
}

// [I9] Each Host owns/disposes its adapter independently and exactly once.
// Use an explicit empty repository root so the lifetime fixture exercises the already-loaded
// process-backend test double. A real repository-local KubectlProcess assembly is intentionally
// excluded here; repository-local adapter precedence is covered separately by the optional-load
// composition fixture above.
string lifetimeRoot = Path.Combine(Path.GetTempPath(), "kubeshell-hosting-lifetime-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(lifetimeRoot);
KubeShellHost? lifetimeHost1 = null;
KubeShellHost? lifetimeHost2 = null;
try
{
    KubeShell.Backends.KubectlProcess.KubectlProcessBackend.ResetCounters();
    lifetimeHost1 = KubeShellHost.Create(new KubeShellHostOptions(RepositoryRoot: lifetimeRoot, KubectlPath: "fixture-kubectl-1", EnableManagedBackend: false, EnableNativeBackend: false, EnableProcessFallback: true));
    lifetimeHost2 = KubeShellHost.Create(new KubeShellHostOptions(RepositoryRoot: lifetimeRoot, KubectlPath: "fixture-kubectl-2", EnableManagedBackend: false, EnableNativeBackend: false, EnableProcessFallback: true));
    Assert.Equal(2, KubeShell.Backends.KubectlProcess.KubectlProcessBackend.Instances, "Independent hosts did not own independent adapters.");
    lifetimeHost1.Dispose();
    Assert.Equal(1, KubeShell.Backends.KubectlProcess.KubectlProcessBackend.DisposeCalls, "First host did not dispose exactly one owned adapter.");
    Assert.True(lifetimeHost2.ResourceClient is not null, "Disposing one host invalidated another host.");
    lifetimeHost2.Dispose();
    Assert.Equal(2, KubeShell.Backends.KubectlProcess.KubectlProcessBackend.DisposeCalls, "Second host adapter lifetime was not independent.");
}
finally
{
    lifetimeHost1?.Dispose();
    lifetimeHost2?.Dispose();
    if (Directory.Exists(lifetimeRoot)) Directory.Delete(lifetimeRoot, recursive: true);
}

Console.WriteLine("MATRIX_IDS:F=A4,B1,B2,B3,B4,B5,B6,C1,C2,C3,C4,C5,C6,C7,C8,C9,C10,C11,D1,D2,D3,D4,D5,D6,D7,D8,D9,E1,E2,E3,E4,E5,E6,E7,E8,E9,E10,E11,F1,F2,F3,F4,F5,F6,F7,F8,G1,G2,G3,G4,G6,H1,H3,H4,H6,H7,H8,H9,H10,H12,I1,I2,I3,I4,I5,I6,I7,I8,I9,J1,J2,J7,K2,K3,K4,K5");
Console.WriteLine("ObjectModel cluster-free fixture passed.");
}
}
