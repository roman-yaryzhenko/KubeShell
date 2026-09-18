#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="$(go env GOVERSION | sed 's/^go//')"
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
if (( major < 1 || (major == 1 && minor < 26) )); then
  echo "kubeshell-kubectl-host requires Go 1.26 or newer; found go $version" >&2
  exit 2
fi
goos="$(go env GOOS)"; goarch="$(go env GOARCH)"
case "$goarch" in
  amd64) ridarch="x64" ;;
  386) ridarch="x86" ;;
  arm64) ridarch="arm64" ;;
  arm) ridarch="arm" ;;
  *) ridarch="$goarch" ;;
esac
case "$goos" in
  linux) rid="linux-$ridarch" ;;
  darwin) rid="osx-$ridarch" ;;
  windows) rid="win-$ridarch" ;;
  *) rid="$goos-$ridarch" ;;
esac
ext=""; [[ "$goos" == windows ]] && ext=".exe"
out="${1:-$root/bin/$rid/kubeshell-kubectl-host$ext}"
mkdir -p "$(dirname "$out")"
cd "$root"
go test ./internal/protocol ./internal/server
cd "$root/host"
go build -trimpath -o "$out" ./cmd/kubeshell-kubectl-host
printf '%s\n' "$out"
