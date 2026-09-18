package kube

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/protocol"
	authorizationv1 "k8s.io/api/authorization/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/kubernetes"
)

func reviewAccess(ctx context.Context, s *session, request protocol.AccessReviewRequest) (protocol.AccessReviewResponse, *protocol.WireError) {
	if strings.TrimSpace(request.Verb) == "" || strings.TrimSpace(request.Resource) == "" {
		return protocol.AccessReviewResponse{}, invalid("diagnostics.access.request", "verb and resource are required")
	}
	exec := request.Execution
	if request.AsUser != "" || len(request.AsGroups) != 0 {
		impersonation := &protocol.Impersonation{User: request.AsUser, Groups: append([]string(nil), request.AsGroups...)}
		if exec.Impersonation != nil {
			impersonation.UID = exec.Impersonation.UID
			impersonation.Extra = cloneExtra(exec.Impersonation.Extra)
			if impersonation.User == "" {
				impersonation.User = exec.Impersonation.User
			}
			if len(impersonation.Groups) == 0 {
				impersonation.Groups = append([]string(nil), exec.Impersonation.Groups...)
			}
		}
		exec.Impersonation = impersonation
	}
	config := s.configFor(exec)
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return protocol.AccessReviewResponse{}, wireError(err, "diagnostics.access.client")
	}
	namespace := request.Namespace
	if request.Namespaced && namespace == "" {
		namespace = s.defaultNamespace()
	}
	review := &authorizationv1.SelfSubjectAccessReview{Spec: authorizationv1.SelfSubjectAccessReviewSpec{
		ResourceAttributes: &authorizationv1.ResourceAttributes{
			Namespace:   namespace,
			Verb:        request.Verb,
			Group:       request.Group,
			Resource:    request.Resource,
			Subresource: request.Subresource,
			Name:        request.Name,
		},
	}}
	result, err := client.AuthorizationV1().SelfSubjectAccessReviews().Create(ctx, review, metav1.CreateOptions{})
	if err != nil {
		return protocol.AccessReviewResponse{}, wireError(err, "diagnostics.access.review")
	}
	return protocol.AccessReviewResponse{
		Allowed:         result.Status.Allowed,
		Denied:          result.Status.Denied,
		Reason:          result.Status.Reason,
		EvaluationError: result.Status.EvaluationError,
	}, nil
}

func metrics(ctx context.Context, s *session, request protocol.MetricsRequest, pods bool) (protocol.MetricsResponse, *protocol.WireError) {
	config := s.configFor(request.Execution)
	client, err := discovery.NewDiscoveryClientForConfig(config)
	if err != nil {
		return protocol.MetricsResponse{}, wireError(err, "diagnostics.metrics.client")
	}
	path := "/apis/metrics.k8s.io/v1beta1/nodes"
	if pods {
		if request.Namespace == "" {
			path = "/apis/metrics.k8s.io/v1beta1/pods"
		} else {
			path = "/apis/metrics.k8s.io/v1beta1/namespaces/" + request.Namespace + "/pods"
		}
	}
	data, err := client.RESTClient().Get().AbsPath(path).DoRaw(ctx)
	if err != nil {
		return protocol.MetricsResponse{}, wireError(err, "diagnostics.metrics.request")
	}
	return protocol.MetricsResponse{JSON: string(data)}, nil
}

func probeDNS(ctx context.Context, s *session, request protocol.DNSProbeRequest) (protocol.DNSProbeResponse, *protocol.WireError) {
	if request.Namespace == "" || request.Name == "" || request.Image == "" {
		return protocol.DNSProbeResponse{}, invalid("diagnostics.dns.request", "namespace, name and image are required")
	}
	config := s.configFor(request.Execution)
	client, err := kubernetes.NewForConfig(config)
	if err != nil {
		return protocol.DNSProbeResponse{}, wireError(err, "diagnostics.dns.client")
	}
	timeout := time.Duration(request.TimeoutMilliseconds) * time.Millisecond
	if timeout <= 0 {
		timeout = 60 * time.Second
	}
	activeDeadline := int64(timeout.Round(time.Second) / time.Second)
	if activeDeadline < 1 {
		activeDeadline = 1
	}
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{GenerateName: "kubeshell-dns-", Namespace: request.Namespace},
		Spec: corev1.PodSpec{
			RestartPolicy:         corev1.RestartPolicyNever,
			ActiveDeadlineSeconds: &activeDeadline,
			Containers: []corev1.Container{{
				Name:    "probe",
				Image:   request.Image,
				Command: []string{"nslookup", request.Name},
			}},
		},
	}
	created, err := client.CoreV1().Pods(request.Namespace).Create(ctx, pod, metav1.CreateOptions{})
	if err != nil {
		return protocol.DNSProbeResponse{}, wireError(err, "diagnostics.dns.create")
	}
	zero := int64(0)
	defer func() {
		cleanupCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
		defer cancel()
		_ = client.CoreV1().Pods(request.Namespace).Delete(cleanupCtx, created.Name, metav1.DeleteOptions{GracePeriodSeconds: &zero})
	}()

	probeCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	var phase corev1.PodPhase
	for {
		current, getErr := client.CoreV1().Pods(request.Namespace).Get(probeCtx, created.Name, metav1.GetOptions{})
		if getErr != nil {
			return protocol.DNSProbeResponse{}, wireError(getErr, "diagnostics.dns.wait")
		}
		phase = current.Status.Phase
		if phase == corev1.PodSucceeded || phase == corev1.PodFailed {
			break
		}
		select {
		case <-probeCtx.Done():
			return protocol.DNSProbeResponse{}, wireError(probeCtx.Err(), "diagnostics.dns.timeout")
		case <-ticker.C:
		}
	}

	logs, logErr := client.CoreV1().Pods(request.Namespace).GetLogs(created.Name, &corev1.PodLogOptions{Container: "probe"}).DoRaw(ctx)
	if logErr != nil {
		return protocol.DNSProbeResponse{}, wireError(logErr, "diagnostics.dns.logs")
	}
	output := strings.TrimSpace(string(logs))
	if output == "" && phase != corev1.PodSucceeded {
		output = fmt.Sprintf("DNS probe pod ended in phase %s", phase)
	}
	return protocol.DNSProbeResponse{Success: phase == corev1.PodSucceeded, Output: output}, nil
}
