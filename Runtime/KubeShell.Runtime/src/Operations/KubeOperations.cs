using System;

namespace KubeShell.Runtime;

public enum KubePreviewMode
{
    None,
    Client,
    Server
}

// Kept as a compatibility name for the current PowerShell surface.
public enum KubeDryRunMode
{
    None,
    Client,
    Server
}

public enum KubeApplyStrategy
{
    ClientSide,
    ServerSide
}

public enum KubePatchType
{
    Merge,
    Json,
    Strategic
}

public enum KubeConcurrencyMode
{
    Default,
    RequireUnchanged,
    Force
}

public sealed record KubeConcurrencyOptions(
    KubeConcurrencyMode Mode = KubeConcurrencyMode.Default,
    string? ExpectedResourceVersion = null)
{
    public static KubeConcurrencyOptions Default { get; } = new();
}

public sealed record KubeCreateOptions(
    KubePreviewMode Preview = KubePreviewMode.None,
    string? FieldManager = null);

public sealed record KubeReplaceOptions
{
    public KubeReplaceOptions(
        KubePreviewMode Preview = KubePreviewMode.None,
        string? FieldManager = null,
        KubeConcurrencyOptions? Concurrency = null)
    {
        this.Preview = Preview;
        this.FieldManager = string.IsNullOrWhiteSpace(FieldManager) ? null : FieldManager;
        // Null at the construction boundary means "use the default concurrency policy".
        // Normalize it once here so every backend sees a total, non-null Runtime contract.
        this.Concurrency = Concurrency ?? KubeConcurrencyOptions.Default;
    }

    public KubePreviewMode Preview { get; }
    public string? FieldManager { get; }
    public KubeConcurrencyOptions Concurrency { get; }
}

public sealed class KubeApplyOptions
{
    public KubeApplyOptions(
        KubeDryRunMode dryRun = KubeDryRunMode.None,
        bool serverSide = false,
        string? fieldManager = null,
        bool forceConflicts = false)
        : this(serverSide ? KubeApplyStrategy.ServerSide : KubeApplyStrategy.ClientSide,
               (KubePreviewMode)dryRun, fieldManager, forceConflicts) { }

    public KubeApplyOptions(
        KubeApplyStrategy strategy,
        KubePreviewMode preview = KubePreviewMode.None,
        string? fieldManager = null,
        bool forceConflicts = false)
    {
        if (strategy == KubeApplyStrategy.ServerSide && preview == KubePreviewMode.Client)
            throw new ArgumentException("Client preview is not valid for server-side apply.", nameof(preview));
        if (forceConflicts && strategy != KubeApplyStrategy.ServerSide)
            throw new ArgumentException("ForceConflicts requires server-side apply.", nameof(forceConflicts));
        Strategy = strategy;
        Preview = preview;
        FieldManager = string.IsNullOrWhiteSpace(fieldManager) ? "KubeShell" : fieldManager;
        ForceConflicts = forceConflicts;
    }

    public KubeApplyStrategy Strategy { get; }
    public KubePreviewMode Preview { get; }
    public string FieldManager { get; }
    public bool ForceConflicts { get; }
    public bool ServerSide => Strategy == KubeApplyStrategy.ServerSide;
    public KubeDryRunMode DryRun => (KubeDryRunMode)Preview;
}

public sealed class KubePatchOptions
{
    public KubePatchOptions(KubePatchType type = KubePatchType.Merge, KubeDryRunMode dryRun = KubeDryRunMode.None)
        : this(type, (KubePreviewMode)dryRun, null, null) { }

    public KubePatchOptions(
        KubePatchType type,
        KubePreviewMode preview,
        string? fieldManager = null,
        KubeConcurrencyOptions? concurrency = null)
    {
        Type = type;
        Preview = preview;
        FieldManager = string.IsNullOrWhiteSpace(fieldManager) ? null : fieldManager;
        Concurrency = concurrency ?? KubeConcurrencyOptions.Default;
    }

    public KubePatchType Type { get; }
    public KubePreviewMode Preview { get; }
    public string? FieldManager { get; }
    public KubeConcurrencyOptions Concurrency { get; }
    public KubeDryRunMode DryRun => (KubeDryRunMode)Preview;
}

public sealed class KubeDeleteOptions
{
    public KubeDeleteOptions(KubeDryRunMode dryRun = KubeDryRunMode.None, bool force = false, int? gracePeriodSeconds = null)
        : this((KubePreviewMode)dryRun, force, gracePeriodSeconds, null) { }

    public KubeDeleteOptions(
        KubePreviewMode preview,
        bool force = false,
        int? gracePeriodSeconds = null,
        KubeConcurrencyOptions? concurrency = null)
    {
        Preview = preview;
        Force = force;
        GracePeriodSeconds = gracePeriodSeconds;
        Concurrency = concurrency ?? KubeConcurrencyOptions.Default;
    }

    public KubePreviewMode Preview { get; }
    public bool Force { get; }
    public int? GracePeriodSeconds { get; }
    public KubeConcurrencyOptions Concurrency { get; }
    public KubeDryRunMode DryRun => (KubeDryRunMode)Preview;
}

public abstract record KubeOperation;
public sealed record KubeGetOperation(ResourceIdentity Identity) : KubeOperation;
public sealed record KubeListOperation(ResourceQuery Query) : KubeOperation;
public sealed record KubeCreateOperation(ResourceIdentity Identity, string PayloadJson, KubeCreateOptions Options) : KubeOperation;
public sealed record KubeReplaceOperation(ResourceIdentity Identity, string PayloadJson, KubeReplaceOptions Options) : KubeOperation;
public sealed record KubeApplyOperation(ResourceIdentity Identity, string PayloadJson, KubeApplyOptions Options) : KubeOperation;
public sealed record KubePatchOperation(ResourceIdentity Identity, string PayloadJson, KubePatchOptions Options) : KubeOperation;
public sealed record KubeDeleteOperation(ResourceIdentity Identity, KubeDeleteOptions Options) : KubeOperation;
public sealed record KubeWatchOperation(ResourceQuery Query, string? ResourceVersion = null, bool AllowBookmarks = true) : KubeOperation;
public sealed record KubeRolloutUndoOperation(ResourceIdentity Identity, long ToRevision = 0, KubePreviewMode Preview = KubePreviewMode.None) : KubeOperation;
public sealed record KubeRolloutRestartOperation(ResourceIdentity Identity, KubePreviewMode Preview = KubePreviewMode.None, string FieldManager = "kubeshell-rollout") : KubeOperation;
public sealed record KubeScaleOperation(ResourceIdentity Identity, int Replicas, KubePreviewMode Preview = KubePreviewMode.None) : KubeOperation;
public sealed record KubeSetImageOperation(ResourceIdentity Identity, string Container, string Image, KubePreviewMode Preview = KubePreviewMode.None, string FieldManager = "kubeshell-set-image") : KubeOperation;
public sealed record KubeRolloutStatusOperation(ResourceIdentity Identity, TimeSpan Timeout, long Revision = 0) : KubeOperation;
