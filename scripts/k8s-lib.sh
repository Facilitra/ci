#!/usr/bin/env bash
# Shared helpers for the k8s-* scripts. Sourced, never executed.
# shellcheck disable=SC2034  # PROG and the nameref targets are read by the callers
set -euo pipefail

# Sorted globs must not depend on the runner locale. LC_ALL, not LC_COLLATE: an
# exported LC_ALL would override LC_COLLATE and reorder 10-a.yaml before 1-b.yaml.
LC_ALL=C

die() { echo "::error::${PROG:-k8s}: $*"; exit 1; }
warn() { echo "::warning::${PROG:-k8s}: $*"; }
notice() { echo "::notice::${PROG:-k8s}: $*"; }

# trim STRING -> TRIMMED
trim() {
  TRIMMED=$1
  TRIMMED=${TRIMMED#"${TRIMMED%%[![:space:]]*}"}
  TRIMMED=${TRIMMED%"${TRIMMED##*[![:space:]]}"}
}

# lines_to_array NAME TEXT: trimmed, non-empty lines of TEXT (CRLF tolerated) into array NAME.
lines_to_array() {
  local -n _lta_out=$1
  local l
  _lta_out=()
  while IFS= read -r l || [[ -n $l ]]; do
    l=${l%$'\r'}
    trim "$l"
    if [[ -n $TRIMMED ]]; then _lta_out+=("$TRIMMED"); fi
  done <<< "$2"
}

# expand_targets NAME TARGET...: files stay as they are; a directory becomes its
# *.yaml and *.yml files, one level deep, sorted (the same set kubectl would apply
# for `-f dir` minus .json and minus sub-directories).
expand_targets() {
  local -n _et_out=$1
  shift
  local t f n
  _et_out=()
  for t in "$@"; do
    if [[ -d $t ]]; then
      n=0
      for f in "${t%/}"/*; do
        if [[ -f $f && ( $f == *.yaml || $f == *.yml ) ]]; then
          _et_out+=("$f")
          n=$((n + 1))
        fi
      done
      if [[ $n -eq 0 ]]; then warn "no .yaml/.yml files directly in $t"; fi
    elif [[ -f $t ]]; then
      _et_out+=("$t")
    else
      die "path not found: $t"
    fi
  done
}

# File k8s-apply appends "kind/name" lines to and k8s-rollout reads.
workloads_file() { printf '%s/k8s-workloads.txt' "${RUNNER_TEMP:-${TMPDIR:-/tmp}}"; }

# DNS-1123 style name used for namespaces, jobs and workloads.
NAME_RE='^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'
