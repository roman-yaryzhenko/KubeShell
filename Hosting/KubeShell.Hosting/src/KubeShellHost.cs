using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Runtime.Loader;
using System.Threading.Tasks;
using KubeShell.Runtime;

namespace KubeShell.Hosting;

public sealed record KubeShellHostOptions(
    string? RepositoryRoot = null,
    string? KubectlPath = null,
    bool EnableManagedBackend = true,
    bool EnableNativeBackend = true,
    bool EnableProcessFallback = true);

/// <summary>
/// Outer composition root. Concrete adapter discovery and lifetime live here; callers receive only
/// Runtime-owned semantic clients and never backend collections or the router.
/// </summary>
public sealed class KubeShellHost : IDisposable, IAsyncDisposable
{
    private readonly List<object> _ownedAdapters;
    private readonly Func<AssemblyLoadContext, AssemblyName, Assembly?>? _dependencyResolver;

    private KubeShellHost(
        IReadOnlyList<IKubeBackend> backends,
        List<object> ownedAdapters,
        Func<AssemblyLoadContext, AssemblyName, Assembly?>? dependencyResolver)
    {
        if (backends.Count == 0)
            throw new KubeException(KubeErrorKind.Unavailable, "No KubeShell semantic backend is available.", code: "hosting.no-backend");

        _ownedAdapters = ownedAdapters;
        _dependencyResolver = dependencyResolver;
        IKubeBackendSelector selector = new KubeBackendRouter(backends);
        OperationClient = new KubeOperationClient(selector);
        ResourceExecutionClient = new KubeResourceExecutionClient(OperationClient);
        ResourceClient = new KubeResourceClient(OperationClient, ResourceExecutionClient);
        DiscoveryClient = new KubeDiscoveryClient(selector);
        WatchClient = new KubeWatchClient(selector);
        ConfigClient = new KubeConfigClient(selector);
        SchemaClient = new KubeSchemaClient(selector);
        DiagnosticsClient = new KubeDiagnosticsClient(selector);
        LogClient = new KubeLogClient(selector);
        CopyClient = new KubeCopyClient(selector);
        DebugClient = new KubeDebugClient(selector);
    }

    public IKubeOperationClient OperationClient { get; }
    public IKubeResourceExecutionClient ResourceExecutionClient { get; }
    public IKubeResourceClient ResourceClient { get; }
    public IKubeDiscoveryClient DiscoveryClient { get; }
    public KubeWatchClient WatchClient { get; }
    public KubeConfigClient ConfigClient { get; }
    public KubeSchemaClient SchemaClient { get; }
    public KubeDiagnosticsClient DiagnosticsClient { get; }
    public KubeLogClient LogClient { get; }
    public KubeCopyClient CopyClient { get; }
    public KubeDebugClient DebugClient { get; }

    public static KubeShellHost Create(KubeShellHostOptions? options = null)
    {
        options ??= new KubeShellHostOptions();
        string? root = options.RepositoryRoot ?? FindRepositoryRoot();
        List<IKubeBackend> backends = new();
        List<object> owned = new();
        Func<AssemblyLoadContext, AssemblyName, Assembly?>? resolver = options.EnableManagedBackend
            ? CreateLocalDependencyResolver(root, "Backends/KubeShell.KubernetesClient/bin/Release/net8.0")
            : null;
        if (resolver is not null) AssemblyLoadContext.Default.Resolving += resolver;

        try
        {
            bool managedAdded = false;
            if (options.EnableManagedBackend)
                managedAdded = TryAddBackend(backends, owned, root, "Backends/KubeShell.KubernetesClient/bin/Release/net8.0/KubeShell.KubernetesClient.dll", "KubeShell.Backends.KubernetesClient.KubernetesClientBackend", null);

            // The managed dependency resolver belongs to the managed adapter lifetime. If that
            // optional adapter could not be loaded, detach the resolver before composing later
            // backends so stale managed dependencies cannot affect native/process fallback.
            if (!managedAdded && resolver is not null)
            {
                AssemblyLoadContext.Default.Resolving -= resolver;
                resolver = null;
            }

            if (options.EnableNativeBackend)
                _ = TryAddBackend(backends, owned, root, "Backends/KubeShell.Kubectl/bin/Release/net8.0/KubeShell.Kubectl.dll", "KubeShell.Backends.Kubectl.KubectlBackend", null);

            if (options.EnableProcessFallback)
            {
                string? kubectl = options.KubectlPath ?? FindExecutable("kubectl");
                if (!string.IsNullOrWhiteSpace(kubectl))
                    _ = TryAddBackend(backends, owned, root, "Backends/KubeShell.KubectlProcess/bin/Release/net8.0/KubeShell.KubectlProcess.dll", "KubeShell.Backends.KubectlProcess.KubectlProcessBackend", new object?[] { kubectl });
            }

            return new KubeShellHost(backends, owned, resolver);
        }
        catch
        {
            if (resolver is not null) AssemblyLoadContext.Default.Resolving -= resolver;
            foreach (object adapter in owned.AsEnumerable().Reverse())
            {
                switch (adapter)
                {
                    case IAsyncDisposable asyncDisposable:
                        try { asyncDisposable.DisposeAsync().AsTask().GetAwaiter().GetResult(); } catch { }
                        break;
                    case IDisposable disposable:
                        try { disposable.Dispose(); } catch { }
                        break;
                }
            }
            throw;
        }
    }

    public void Dispose() => DisposeAsync().AsTask().GetAwaiter().GetResult();

    public async ValueTask DisposeAsync()
    {
        foreach (object adapter in _ownedAdapters.AsEnumerable().Reverse())
        {
            switch (adapter)
            {
                case IAsyncDisposable asyncDisposable:
                    try { await asyncDisposable.DisposeAsync().ConfigureAwait(false); } catch { }
                    break;
                case IDisposable disposable:
                    try { disposable.Dispose(); } catch { }
                    break;
            }
        }
        _ownedAdapters.Clear();
        if (_dependencyResolver is not null)
            AssemblyLoadContext.Default.Resolving -= _dependencyResolver;
    }

    private static Func<AssemblyLoadContext, AssemblyName, Assembly?>? CreateLocalDependencyResolver(string? root, string relativeDirectory)
    {
        if (string.IsNullOrWhiteSpace(root)) return null;
        string directory = Path.Combine(root, relativeDirectory.Replace('/', Path.DirectorySeparatorChar));
        if (!Directory.Exists(directory)) return null;

        return (context, name) =>
        {
            if (string.IsNullOrWhiteSpace(name.Name)) return null;
            string candidate = Path.Combine(directory, name.Name + ".dll");
            return File.Exists(candidate) ? context.LoadFromAssemblyPath(Path.GetFullPath(candidate)) : null;
        };
    }

    private static bool TryAddBackend(List<IKubeBackend> backends, List<object> owned, string? root, string relativeAssemblyPath, string typeName, object?[]? args)
    {
        try
        {
            Type? type = null;
            bool localAssemblyExists = false;
            if (!string.IsNullOrWhiteSpace(root))
            {
                string path = Path.Combine(root, relativeAssemblyPath.Replace('/', Path.DirectorySeparatorChar));
                localAssemblyExists = File.Exists(path);
                if (localAssemblyExists)
                {
                    Assembly assembly = Assembly.LoadFrom(path);
                    type = assembly.GetType(typeName, throwOnError: false, ignoreCase: false);
                }
            }

            // An explicit repository-local adapter is authoritative. Reusing a same-named type
            // already loaded elsewhere in the process would silently bypass a stale/incompatible
            // local package and retain the wrong dependency resolver for this Host instance.
            if (!localAssemblyExists)
                type ??= FindLoadedType(typeName);

            if (type is null)
            {
                if (localAssemblyExists)
                    throw new InvalidOperationException($"Configured backend assembly '{relativeAssemblyPath}' does not define expected type '{typeName}'.");
                return false;
            }

            object? instance = Activator.CreateInstance(type, args ?? Array.Empty<object>());
            if (instance is not IKubeBackend backend)
                throw new InvalidOperationException($"Configured backend type '{typeName}' does not implement IKubeBackend.");
            backends.Add(backend);
            owned.Add(instance);
            return true;
        }
        catch (Exception exception) when (IsOptionalAdapterLoadFailure(exception))
        {
            // Optional adapters are preference candidates, not prerequisites. Ordinary file/image/
            // dependency/type-load failures may fall through to later semantic backends. Once the
            // expected type is resolved, constructor/member/interface contract mismatches fail fast.
            return false;
        }
    }

    private static bool IsOptionalAdapterLoadFailure(Exception exception) => exception switch
    {
        FileNotFoundException => true,
        FileLoadException => true,
        BadImageFormatException => true,
        // DllNotFoundException and EntryPointNotFoundException derive from TypeLoadException,
        // so the base arm intentionally covers those native-load failures as well.
        TypeLoadException => true,
        ReflectionTypeLoadException => true,
        TargetInvocationException invocation when invocation.InnerException is not null => IsOptionalAdapterLoadFailure(invocation.InnerException),
        TypeInitializationException initialization when initialization.InnerException is not null => IsOptionalAdapterLoadFailure(initialization.InnerException),
        _ => false
    };

    private static Type? FindLoadedType(string fullName)
    {
        foreach (Assembly assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            Type? type = assembly.GetType(fullName, throwOnError: false, ignoreCase: false);
            if (type is not null) return type;
        }
        return null;
    }

    private static string? FindRepositoryRoot()
    {
        string? location = typeof(KubeShellHost).Assembly.Location;
        if (string.IsNullOrWhiteSpace(location)) return null;
        DirectoryInfo? directory = new FileInfo(location).Directory;
        for (int i = 0; i < 8 && directory is not null; i++, directory = directory.Parent)
        {
            if (Directory.Exists(Path.Combine(directory.FullName, "Runtime", "KubeShell.Runtime")))
                return directory.FullName;
        }
        return null;
    }

    private static string? FindExecutable(string name)
    {
        string? path = Environment.GetEnvironmentVariable("PATH");
        if (string.IsNullOrWhiteSpace(path)) return null;
        string[] extensions = OperatingSystem.IsWindows()
            ? new[] { ".exe", ".cmd", ".bat", string.Empty }
            : new[] { string.Empty };
        foreach (string directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        foreach (string extension in extensions)
        {
            string candidate = Path.Combine(directory, name + extension);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }
}
