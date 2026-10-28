#!/usr/bin/env bash
# osv-scan: resolve which lockfiles to scan.
# Inputs (env): INPUT_LOCKFILES (newline or space separated, relative to
# INPUT_WORKING_DIRECTORY; empty = autodetect at its root) INPUT_WORKING_DIRECTORY
# INPUT_FAIL
# Outputs (GITHUB_OUTPUT): found (true|false), files (one workspace-relative
# path per line), scan-args (one --lockfile=<path> per line, the scanner
# action's format). No lockfile is a notice, a listed lockfile that does not
# exist is an error.
set -euo pipefail

die() {
  printf '::error::osv-scan: %s\n' "$1"
  exit 1
}

wd="${INPUT_WORKING_DIRECTORY:-.}"
list="${INPUT_LOCKFILES:-}"
list="${list//$'\r'/ }"
out="${GITHUB_OUTPUT:-/dev/null}"

[[ "${INPUT_FAIL:-true}" == true || "${INPUT_FAIL:-true}" == false ]] || die "fail must be 'true' or 'false'"

relative() { # reject absolute paths, '..' segments, control characters and anything that could pass for a flag
  [[ "$1" != -* && "$1" != /* && "/$1/" != */../* && "$1" != *[[:cntrl:]]* ]] || die "'${1//[[:cntrl:]]/ }' must be a relative path inside the checkout"
}

relative "$wd"
while [[ "$wd" == ./* ]]; do wd="${wd#./}"; done
wd="${wd%/}"
[[ -n "$wd" ]] || wd=.
at() { if [[ "$wd" == . ]]; then printf '%s' "$1"; else printf '%s/%s' "$wd" "$1"; fi; }

found=()
if [[ -z "${list//[[:space:]]/}" ]]; then
  for f in pnpm-lock.yaml package-lock.json composer.lock Cargo.lock pubspec.lock; do
    [[ -f "$(at "$f")" ]] && found+=("$(at "$f")")
  done
else
  set -f
  for f in $list; do
    relative "$f"
    while [[ "$f" == ./* ]]; do f="${f#./}"; done
    [[ -f "$(at "$f")" ]] || die "lockfile '$(at "$f")' does not exist"
    found+=("$(at "$f")")
  done
  set +f
fi

if ((${#found[@]} == 0)); then
  echo "::notice::osv-scan: no lockfile found in $wd, nothing to scan"
  {
    echo "found=false"
    echo "files="
    echo "scan-args="
  } >> "$out"
  exit 0
fi

{
  echo "found=true"
  echo "files<<OSV_EOF"
  printf '%s\n' "${found[@]}"
  echo "OSV_EOF"
  echo "scan-args<<OSV_EOF"
  printf -- '--lockfile=%s\n' "${found[@]}"
  echo "OSV_EOF"
} >> "$out"
echo "osv-scan: scanning ${found[*]}"
