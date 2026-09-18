package main

import (
	"context"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strings"

	"github.com/kubeshell/kubeshell/native/kubeshell-kubectl/host/internal/kube"
	ipcserver "github.com/kubeshell/kubeshell/native/kubeshell-kubectl/internal/server"
	"k8s.io/cli-runtime/pkg/genericclioptions"
	"k8s.io/cli-runtime/pkg/genericiooptions"
	kubectlcmd "k8s.io/kubectl/pkg/cmd"
)

func main() {
	// The long-lived process is always entered explicitly with --transport.
	// Compatibility workers are deliberately narrow. Semantic debug mutation lives on the framed IPC
	// channel; attach and exec own a terminal while port-forward owns a local listener lifetime.
	args := os.Args[1:]
	if hasTransportArgument(args) {
		if err := runIPC(args); err != nil {
			fmt.Fprintln(os.Stderr, "kubeshell-kubectl-host:", err)
			os.Exit(1)
		}
		return
	}

	worker, workerArgs, ok, err := parseWorker(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, "kubeshell-kubectl-host:", err)
		os.Exit(2)
	}
	if !ok {
		fmt.Fprintln(os.Stderr, "kubeshell-kubectl-host: specify --transport=stdio|unix or --worker=attach|exec|port-forward")
		os.Exit(2)
	}
	if err := runWorker(worker, workerArgs); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func hasTransportArgument(args []string) bool {
	for _, arg := range args {
		if arg == "--transport" || strings.HasPrefix(arg, "--transport=") || arg == "--socket" || strings.HasPrefix(arg, "--socket=") {
			return true
		}
	}
	return false
}

func parseWorker(args []string) (string, []string, bool, error) {
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if strings.HasPrefix(arg, "--worker=") {
			worker := strings.TrimPrefix(arg, "--worker=")
			if worker == "" {
				return "", nil, false, fmt.Errorf("--worker requires a value")
			}
			remaining := append(append([]string(nil), args[:i]...), args[i+1:]...)
			return worker, remaining, true, nil
		}
		if arg == "--worker" {
			if i+1 >= len(args) || strings.TrimSpace(args[i+1]) == "" {
				return "", nil, false, fmt.Errorf("--worker requires a value")
			}
			worker := args[i+1]
			remaining := append(append([]string(nil), args[:i]...), args[i+2:]...)
			return worker, remaining, true, nil
		}
	}
	return "", nil, false, nil
}

func runWorker(worker string, args []string) error {
	switch worker {
	case "attach", "exec", "port-forward":
		return runEmbeddedKubectl(append([]string{worker}, args...))
	default:
		return fmt.Errorf("unknown compatibility worker %q", worker)
	}
}

func runEmbeddedKubectl(args []string) error {
	streams := genericiooptions.IOStreams{In: os.Stdin, Out: os.Stdout, ErrOut: os.Stderr}
	configFlags := genericclioptions.NewConfigFlags(true).
		WithDeprecatedPasswordFlag().
		WithDiscoveryBurst(300).
		WithDiscoveryQPS(50.0).
		WithWarningPrinter(streams)

	commandArgs := append([]string{"kubeshell-kubectl-host"}, args...)
	command := kubectlcmd.NewKubectlCommand(kubectlcmd.KubectlOptions{
		Arguments:   commandArgs,
		ConfigFlags: configFlags,
		IOStreams:   streams,
	})
	command.SetArgs(args)
	command.SilenceErrors = true
	command.SilenceUsage = true
	return command.ExecuteContext(context.Background())
}

func runIPC(args []string) error {
	flags := flag.NewFlagSet("kubeshell-kubectl-host", flag.ContinueOnError)
	transport := flags.String("transport", "stdio", "IPC transport: stdio or unix")
	socketPath := flags.String("socket", "", "Unix socket path when --transport=unix")
	if err := flags.Parse(args); err != nil {
		return err
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	switch *transport {
	case "stdio":
		return ipcserver.New(os.Stdin, os.Stdout, kube.NewHandler()).Serve(ctx)
	case "unix":
		return serveUnix(ctx, *socketPath)
	default:
		return fmt.Errorf("unknown transport %q", *transport)
	}
}

func serveUnix(ctx context.Context, path string) error {
	if path == "" {
		return fmt.Errorf("--socket is required for unix transport")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	_ = os.Remove(path)
	listener, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(path)
	if err := os.Chmod(path, 0o600); err != nil {
		return err
	}

	go func() { <-ctx.Done(); _ = listener.Close() }()
	conn, err := listener.Accept()
	if err != nil {
		return err
	}
	defer conn.Close()
	go func() {
		<-ctx.Done()
		_ = conn.Close()
	}()
	return ipcserver.New(conn, conn, kube.NewHandler()).Serve(ctx)
}
