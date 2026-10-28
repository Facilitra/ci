#!/usr/bin/env bash
# node-setup: decide which package manager to set up and where its files are.
# Inputs (env): INPUT_PACKAGE_MANAGER (auto|pnpm|npm|none) INPUT_WORKING_DIRECTORY
# INPUT_NODE_VERSION_FILE INPUT_INSTALL INPUT_CHECK_VERSIONS
# Outputs (GITHUB_OUTPUT), paths relative to the workspace root:
#   pm, cache (setup-node cache value, empty = no cache), lockfile,
#   package-json, version-file
set -euo pipefail

die() {
  printf '::error::node-setup: %s\n' "$1"
  exit 1
}

wd="${INPUT_WORKING_DIRECTORY:-.}"
pm="${INPUT_PACKAGE_MANAGER:-auto}"
vfile="${INPUT_NODE_VERSION_FILE:-.nvmrc}"

# The paths below are written to GITHUB_OUTPUT, one value per line.
[[ "$wd$vfile" != *[[:cntrl:]]* ]] || die "working-directory and node-version-file must not contain control characters"

for v in INSTALL CHECK_VERSIONS; do
  var="INPUT_$v"
  [[ "${!var:-true}" == true || "${!var:-true}" == false ]] || die "${v,,} must be 'true' or 'false'"
done

while [[ "$wd" == ./* ]]; do wd="${wd#./}"; done
wd="${wd%/}"
[[ -n "$wd" ]] || wd=.
[[ -d "$wd" ]] || die "working-directory '$wd' does not exist"
at() { if [[ "$wd" == . ]]; then printf '%s' "$1"; else printf '%s/%s' "$wd" "$1"; fi; }

if [[ "$pm" == auto ]]; then
  if [[ -f "$(at pnpm-lock.yaml)" ]]; then
    pm=pnpm
  elif [[ -f "$(at package-lock.json)" ]]; then
    pm=npm
  else
    pm=none
  fi
fi

cache=""
lockfile=""
case "$pm" in
  pnpm)
    field=""
    if [[ -f "$(at package.json)" ]]; then
      field="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$(at package.json)" | head -n 1 || true)"
    fi
    [[ "$field" == pnpm@* ]] || die "pnpm needs \"packageManager\": \"pnpm@<version>\" in $(at package.json); pnpm/action-setup reads the version from there"
    if [[ -f "$(at pnpm-lock.yaml)" ]]; then
      cache=pnpm
      lockfile="$(at pnpm-lock.yaml)"
    else
      echo "::warning::node-setup: no $(at pnpm-lock.yaml), the pnpm store is not cached"
    fi
    ;;
  npm)
    if [[ -f "$(at package-lock.json)" ]]; then
      cache=npm
      lockfile="$(at package-lock.json)"
    else
      echo "::warning::node-setup: no $(at package-lock.json), npm install is not cached or reproducible"
    fi
    ;;
  none) ;;
  *) die "package-manager must be auto, pnpm, npm or none, got '$pm'" ;;
esac

{
  echo "pm=$pm"
  echo "cache=$cache"
  echo "lockfile=$lockfile"
  echo "package-json=$(at package.json)"
  echo "version-file=$(at "$vfile")"
} >> "${GITHUB_OUTPUT:-/dev/null}"
echo "node-setup: package manager $pm, version file $(at "$vfile")"
