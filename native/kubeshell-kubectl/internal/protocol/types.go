package protocol

import "encoding/json"

type Method uint32

const (
	MethodSessionCreate      Method = 1
	MethodSessionClose       Method = 2
	MethodDiscoverAPIVersion Method = 3
	MethodResolveResource    Method = 4
	MethodDiscoverPreferred  Method = 5

	MethodGet        Method = 100
	MethodList       Method = 101
	MethodCreate     Method = 102
	MethodReplace    Method = 103
	MethodDelete     Method = 104
	MethodPatch      Method = 105
	MethodApply      Method = 106
	MethodWatchStart Method = 107
	MethodLogsStart  Method = 108

	MethodExplain        Method = 200
	MethodRolloutUndo    Method = 201
	MethodRolloutRestart Method = 202
	MethodScale          Method = 203
	MethodSetImage       Method = 204
	MethodRolloutStatus  Method = 205

	MethodConfigView Method = 300

	MethodAccessReview Method = 400
	MethodPodMetrics   Method = 401
	MethodNodeMetrics  Method = 402
	MethodDNSProbe     Method = 403

	MethodCopy  Method = 500
	MethodDebug Method = 600
)

const (
	FeatureDiscovery uint64 = 1 << iota
	FeatureCRUD
	FeatureClientPreview
	FeatureServerPreview
	FeatureClientSideApply
	FeatureServerSideApply
	FeatureWatch
	FeatureSubresources
	FeatureImpersonation
	FeatureFieldValidation
	FeatureSchema
	FeatureRolloutUndo
	FeatureWorkloads
	FeatureDiagnostics
	FeatureLogs
	FeatureCopy
	FeatureDebug
)

type Hello struct {
	MinProtocol  uint16 `json:"minProtocol"`
	MaxProtocol  uint16 `json:"maxProtocol"`
	Client       string `json:"client,omitempty"`
	ContractHash string `json:"contractHash"`
}

type HelloAck struct {
	Protocol        uint16 `json:"protocol"`
	FeatureBits     uint64 `json:"featureBits"`
	BuildVersion    string `json:"buildVersion"`
	KubectlVersion  string `json:"kubectlVersion"`
	ClientGoVersion string `json:"clientGoVersion"`
	ContractHash    string `json:"contractHash"`
}

type Request struct {
	Method    Method          `json:"method"`
	SessionID uint64          `json:"sessionId,omitempty"`
	Body      json.RawMessage `json:"body,omitempty"`
}

type Response struct {
	Body json.RawMessage `json:"body,omitempty"`
}

type Cancel struct {
	CorrelationID uint64 `json:"correlationId,omitempty"`
	OperationID   uint64 `json:"operationId,omitempty"`
}

type WireError struct {
	Class       string            `json:"class"`
	Code        string            `json:"code"`
	Message     string            `json:"message"`
	HTTPStatus  int               `json:"httpStatus,omitempty"`
	Retryable   *bool             `json:"retryable,omitempty"`
	Status      json.RawMessage   `json:"status,omitempty"`
	Diagnostics map[string]string `json:"diagnostics,omitempty"`
}

type SessionCreateRequest struct {
	KubeconfigPaths  []string `json:"kubeconfigPaths,omitempty"`
	Context          string   `json:"context,omitempty"`
	DefaultNamespace string   `json:"defaultNamespace,omitempty"`
}

type SessionCreateResponse struct {
	SessionID uint64 `json:"sessionId"`
}
type SessionCloseRequest struct {
	SessionID uint64 `json:"sessionId"`
}

type NamespaceScope struct {
	Kind string `json:"kind"`
	Name string `json:"name,omitempty"`
}

type GVR struct {
	Group    string `json:"group,omitempty"`
	Version  string `json:"version,omitempty"`
	Resource string `json:"resource"`
}

type ResourceRef struct {
	GVR         GVR            `json:"gvr"`
	Name        string         `json:"name,omitempty"`
	Namespace   NamespaceScope `json:"namespace"`
	Subresource string         `json:"subresource,omitempty"`
}

type Query struct {
	GVR           GVR            `json:"gvr"`
	Name          string         `json:"name,omitempty"`
	Namespace     NamespaceScope `json:"namespace"`
	LabelSelector string         `json:"labelSelector,omitempty"`
	FieldSelector string         `json:"fieldSelector,omitempty"`
	Subresource   string         `json:"subresource,omitempty"`
}

type Impersonation struct {
	User   string              `json:"user,omitempty"`
	UID    string              `json:"uid,omitempty"`
	Groups []string            `json:"groups,omitempty"`
	Extra  map[string][]string `json:"extra,omitempty"`
}

type ExecutionContext struct {
	TimeoutMilliseconds int64          `json:"timeoutMilliseconds,omitempty"`
	UserAgent           string         `json:"userAgent,omitempty"`
	FieldValidation     string         `json:"fieldValidation,omitempty"`
	CorrelationID       string         `json:"correlationId,omitempty"`
	Impersonation       *Impersonation `json:"impersonation,omitempty"`
}

type Concurrency struct {
	Mode                    string `json:"mode,omitempty"`
	ExpectedResourceVersion string `json:"expectedResourceVersion,omitempty"`
}

type OperationRequest struct {
	Resource                *ResourceRef     `json:"resource,omitempty"`
	Query                   *Query           `json:"query,omitempty"`
	Execution               ExecutionContext `json:"execution"`
	Payload                 json.RawMessage  `json:"payload,omitempty"`
	Preview                 string           `json:"preview,omitempty"`
	ApplyStrategy           string           `json:"applyStrategy,omitempty"`
	PatchType               string           `json:"patchType,omitempty"`
	FieldManager            string           `json:"fieldManager,omitempty"`
	ForceConflicts          bool             `json:"forceConflicts,omitempty"`
	Force                   bool             `json:"force,omitempty"`
	GracePeriodSeconds      *int64           `json:"gracePeriodSeconds,omitempty"`
	Concurrency             Concurrency      `json:"concurrency,omitempty"`
	ResourceVersion         string           `json:"resourceVersion,omitempty"`
	AllowBookmarks          bool             `json:"allowBookmarks,omitempty"`
	ToRevision              int64            `json:"toRevision,omitempty"`
	Replicas                *int32           `json:"replicas,omitempty"`
	Container               string           `json:"container,omitempty"`
	Image                   string           `json:"image,omitempty"`
	WaitTimeoutMilliseconds int64            `json:"waitTimeoutMilliseconds,omitempty"`
	Revision                int64            `json:"revision,omitempty"`
}

type ResourceResult struct {
	GVR  GVR             `json:"gvr"`
	JSON json.RawMessage `json:"json"`
}

type OperationResponse struct {
	Resources   []ResourceResult  `json:"resources,omitempty"`
	Warnings    []string          `json:"warnings,omitempty"`
	Diagnostics map[string]string `json:"diagnostics,omitempty"`
	OperationID uint64            `json:"operationId,omitempty"`
}

type DiscoverRequest struct {
	APIVersion string           `json:"apiVersion,omitempty"`
	Resource   *GVR             `json:"resource,omitempty"`
	Refresh    bool             `json:"refresh,omitempty"`
	Execution  ExecutionContext `json:"execution"`
}

type SubresourceDescriptor struct {
	Name       string   `json:"name"`
	Group      string   `json:"group,omitempty"`
	Version    string   `json:"version,omitempty"`
	Kind       string   `json:"kind,omitempty"`
	Namespaced bool     `json:"namespaced"`
	Verbs      []string `json:"verbs,omitempty"`
}

type ResourceDescriptor struct {
	GVR          GVR                     `json:"gvr"`
	Kind         string                  `json:"kind,omitempty"`
	Namespaced   bool                    `json:"namespaced"`
	Verbs        []string                `json:"verbs,omitempty"`
	SingularName string                  `json:"singularName,omitempty"`
	ShortNames   []string                `json:"shortNames,omitempty"`
	Categories   []string                `json:"categories,omitempty"`
	Subresources []SubresourceDescriptor `json:"subresources,omitempty"`
}

type DiscoverResponse struct {
	Resources []ResourceDescriptor `json:"resources,omitempty"`
}

type StreamItem struct {
	OperationID     uint64          `json:"operationId"`
	EventType       string          `json:"eventType"`
	Resource        *ResourceResult `json:"resource,omitempty"`
	Error           *WireError      `json:"error,omitempty"`
	ResourceVersion string          `json:"resourceVersion,omitempty"`
	Text            string          `json:"text,omitempty"`
}

type StreamEnd struct {
	OperationID uint64     `json:"operationId"`
	Error       *WireError `json:"error,omitempty"`
}

type SchemaRequest struct {
	Resource  GVR              `json:"resource"`
	FieldPath string           `json:"fieldPath,omitempty"`
	Recursive bool             `json:"recursive,omitempty"`
	MaxDepth  int              `json:"maxDepth,omitempty"`
	Execution ExecutionContext `json:"execution"`
}

type SchemaField struct {
	Name        string        `json:"name"`
	Path        string        `json:"path"`
	Type        string        `json:"type,omitempty"`
	Format      string        `json:"format,omitempty"`
	Description string        `json:"description,omitempty"`
	Required    bool          `json:"required,omitempty"`
	Enum        []string      `json:"enum,omitempty"`
	Children    []SchemaField `json:"children,omitempty"`
}

type SchemaResponse struct {
	GVR         GVR           `json:"gvr"`
	Kind        string        `json:"kind,omitempty"`
	FieldPath   string        `json:"fieldPath,omitempty"`
	Type        string        `json:"type,omitempty"`
	Format      string        `json:"format,omitempty"`
	Description string        `json:"description,omitempty"`
	Fields      []SchemaField `json:"fields,omitempty"`
}

type ConfigContext struct {
	Name      string `json:"name"`
	Cluster   string `json:"cluster,omitempty"`
	User      string `json:"user,omitempty"`
	Namespace string `json:"namespace,omitempty"`
}

type ConfigViewResponse struct {
	CurrentContext string          `json:"currentContext,omitempty"`
	Contexts       []ConfigContext `json:"contexts"`
}

type AccessReviewRequest struct {
	Verb        string           `json:"verb"`
	Resource    string           `json:"resource"`
	Name        string           `json:"name,omitempty"`
	Namespace   string           `json:"namespace,omitempty"`
	Group       string           `json:"group,omitempty"`
	Subresource string           `json:"subresource,omitempty"`
	Namespaced  bool             `json:"namespaced,omitempty"`
	AsUser      string           `json:"asUser,omitempty"`
	AsGroups    []string         `json:"asGroups,omitempty"`
	Execution   ExecutionContext `json:"execution"`
}

type AccessReviewResponse struct {
	Allowed         bool   `json:"allowed"`
	Denied          bool   `json:"denied"`
	Reason          string `json:"reason,omitempty"`
	EvaluationError string `json:"evaluationError,omitempty"`
}

type MetricsRequest struct {
	Namespace string           `json:"namespace,omitempty"`
	Execution ExecutionContext `json:"execution"`
}

type MetricsResponse struct {
	JSON string `json:"json"`
}

type DNSProbeRequest struct {
	Namespace           string           `json:"namespace"`
	Name                string           `json:"name"`
	Image               string           `json:"image"`
	TimeoutMilliseconds int64            `json:"timeoutMilliseconds,omitempty"`
	Execution           ExecutionContext `json:"execution"`
}

type DNSProbeResponse struct {
	Success bool   `json:"success"`
	Output  string `json:"output,omitempty"`
}

type LogRequest struct {
	Pod          string           `json:"pod"`
	Namespace    NamespaceScope   `json:"namespace"`
	Container    string           `json:"container,omitempty"`
	TailLines    int64            `json:"tailLines,omitempty"`
	SinceSeconds int64            `json:"sinceSeconds,omitempty"`
	Previous     bool             `json:"previous,omitempty"`
	Follow       bool             `json:"follow,omitempty"`
	Timestamps   bool             `json:"timestamps,omitempty"`
	Prefix       bool             `json:"prefix,omitempty"`
	Execution    ExecutionContext `json:"execution"`
}

type CopyRequest struct {
	Pod        string           `json:"pod"`
	Namespace  NamespaceScope   `json:"namespace"`
	LocalPath  string           `json:"localPath"`
	RemotePath string           `json:"remotePath"`
	ToPod      bool             `json:"toPod"`
	Container  string           `json:"container,omitempty"`
	Execution  ExecutionContext `json:"execution"`
}

type CopyResponse struct {
	Output      string `json:"output,omitempty"`
	ErrorOutput string `json:"errorOutput,omitempty"`
}

type DebugRequest struct {
	Target             ResourceRef       `json:"target"`
	Image              string            `json:"image,omitempty"`
	Command            []string          `json:"command,omitempty"`
	ArgumentsOnly      bool              `json:"argumentsOnly,omitempty"`
	Attach             *bool             `json:"attach,omitempty"`
	Container          string            `json:"container,omitempty"`
	CopyTo             string            `json:"copyTo,omitempty"`
	Replace            bool              `json:"replace,omitempty"`
	Environment        map[string]string `json:"environment,omitempty"`
	Interactive        bool              `json:"interactive,omitempty"`
	TTY                bool              `json:"tty,omitempty"`
	Quiet              bool              `json:"quiet,omitempty"`
	KeepLabels         bool              `json:"keepLabels,omitempty"`
	KeepAnnotations    bool              `json:"keepAnnotations,omitempty"`
	KeepLiveness       bool              `json:"keepLiveness,omitempty"`
	KeepReadiness      bool              `json:"keepReadiness,omitempty"`
	KeepStartup        bool              `json:"keepStartup,omitempty"`
	KeepInitContainers *bool             `json:"keepInitContainers,omitempty"`
	SameNode           bool              `json:"sameNode,omitempty"`
	SetImages          map[string]string `json:"setImages,omitempty"`
	ShareProcesses     *bool             `json:"shareProcesses,omitempty"`
	TargetContainer    string            `json:"targetContainer,omitempty"`
	Profile            string            `json:"profile,omitempty"`
	CustomProfileJSON  string            `json:"customProfileJson,omitempty"`
	ImagePullPolicy    string            `json:"imagePullPolicy,omitempty"`
	Execution          ExecutionContext  `json:"execution"`
}

type DebugAttachment struct {
	Namespace    string `json:"namespace"`
	Pod          string `json:"pod"`
	Container    string `json:"container"`
	Continuation string `json:"continuation"`
	Interactive  bool   `json:"interactive,omitempty"`
	TTY          bool   `json:"tty,omitempty"`
	Quiet        bool   `json:"quiet,omitempty"`
}

type DebugResponse struct {
	Resource   *ResourceResult  `json:"resource,omitempty"`
	Attachment *DebugAttachment `json:"attachment,omitempty"`
	Warnings   []string         `json:"warnings,omitempty"`
	Output     string           `json:"output,omitempty"`
}
