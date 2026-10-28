#!/usr/bin/env bash
# k8s-setup: install a pinned, checksum-verified kubectl for linux/amd64 and put
# it first on PATH for the following steps. The pins are inputs on purpose: they
# are recorded once by a human (see the error below) and bumped through review.
#
# Inputs (env): INPUT_KUBECTL_VERSION, INPUT_KUBECTL_SHA256
set -euo pipefail
PROG=k8s-setup
# shellcheck source=k8s-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/k8s-lib.sh"

version=${INPUT_KUBECTL_VERSION:-RECORD-FIRST}
sha=${INPUT_KUBECTL_SHA256:-RECORD-FIRST}

if [[ $version == RECORD-FIRST || $sha == RECORD-FIRST ]]; then
  die "kubectl-version and kubectl-sha256 are still RECORD-FIRST. Pick a kubectl within one minor version of the cluster (kubectl version), then record the version (for example v1.31.4) and the digest from https://dl.k8s.io/release/<version>/bin/linux/amd64/kubectl.sha256 as the action inputs."
fi
[[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "kubectl-version must look like v1.31.4, got '$version'"
[[ $sha =~ ^[0-9a-f]{64}$ ]] || die "kubectl-sha256 must be 64 lowercase hex characters, got '$sha'"

# kubectl fails with "is a directory" when ~/.kube/config is a directory, so clear it.
kubeconfig="${HOME:-/nonexistent}/.kube/config"
if [[ -d $kubeconfig ]]; then
  rm -rf "$kubeconfig"
  notice "removed the directory at $kubeconfig"
fi

dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/kubectl-bin"
mkdir -p "$dir"
part="$dir/kubectl.part"
url="https://dl.k8s.io/release/${version}/bin/linux/amd64/kubectl"
echo "downloading $url"
curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --retry 3 --retry-delay 2 --output "$part" "$url" || die "download failed: $url"
if ! printf '%s  %s\n' "$sha" "$part" | sha256sum -c -; then
  rm -f "$part"
  die "sha256 mismatch for $url: the file is not the one recorded in kubectl-sha256"
fi
install -m 0755 "$part" "$dir/kubectl"
rm -f "$part"
# The sha256 only proves the file is the recorded one, not that it runs here (an
# arm64 runner would get an unusable binary and a green step).
if ! version_out=$("$dir/kubectl" version --client 2>&1); then
  echo "$version_out"
  rm -f "$dir/kubectl"
  die "the downloaded kubectl does not run on this machine; this action installs linux/amd64 only"
fi
echo "$dir" >> "${GITHUB_PATH:?GITHUB_PATH is not set}"
echo "$version_out"
client=$(sed -n 's/^Client Version: *//p' <<< "$version_out" | head -n 1)
if [[ -n $client && $client != "$version" ]]; then
  warn "installed kubectl reports $client but kubectl-version is $version"
fi

# kubectl supports a server one minor version either side of itself.
server=$("$dir/kubectl" version --request-timeout=10s 2>/dev/null | sed -n 's/^Server Version: *//p' | head -n 1 || true)
ver_re='^v([0-9]+)\.([0-9]+)\.'
if [[ -n $server && $server =~ $ver_re ]]; then
  smin=${BASH_REMATCH[2]}
  if [[ $version =~ $ver_re ]]; then
    cmin=${BASH_REMATCH[2]}
    skew=$((cmin > smin ? cmin - smin : smin - cmin))
    if [[ $skew -gt 1 ]]; then
      warn "kubectl $version is $skew minor versions away from the cluster ($server); supported skew is 1. Bump kubectl-version and kubectl-sha256."
    else
      echo "cluster $server, kubectl $version: skew $skew"
    fi
  fi
else
  notice "cluster version not readable from this step, skew not checked"
fi
