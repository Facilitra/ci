#!/usr/bin/env bash
# node-setup: scripts/check-versions.sh and scripts/resolve-pm.sh.
set -euo pipefail
source "$ROOT/test/lib.sh"

n=0
# newrepo NVMRC [PACKAGE_MANAGER]: fresh repo dir in $repo with .nvmrc and package.json
newrepo() {
  n=$((n + 1))
  repo="$TMP/repo$n"
  mkdir -p "$repo"
  printf '%s\n' "$1" > "$repo/.nvmrc"
  if [[ -n "${2-}" ]]; then
    printf '{\n  "name": "example-app",\n  "packageManager": "%s"\n}\n' "$2" > "$repo/package.json"
  else
    printf '{\n  "name": "example-app"\n}\n' > "$repo/package.json"
  fi
}

# cv [DOCKERFILES]: run check-versions.sh in $repo; sets rc and out
cv() {
  rc=0
  out="$(cd "$repo" && INPUT_WORKING_DIRECTORY=. INPUT_NODE_VERSION_FILE=.nvmrc \
    INPUT_DOCKERFILES="${1-Dockerfile .docker/Dockerfile}" \
    bash "$ROOT/scripts/check-versions.sh" 2>&1)" || rc=$?
}

# --- node tag in FROM -------------------------------------------------------
newrepo 22.11.0
cat > "$repo/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1
FROM node:22.11.0-alpine AS deps
RUN echo deps
FROM node:22.11.0-alpine AS builder
FROM --platform=$BUILDPLATFORM registry.example.com/mirror/node:22.11.0-alpine@sha256:abc AS runner
FROM builder AS final
EOF
cv
assert_rc 0 "$rc" "multi-stage FROM lines that all match pass"
assert_not_contains "$out" "::error" "no error annotations"
assert_not_contains "$out" "::warning" "no warnings"

newrepo 22.11.0
cat > "$repo/Dockerfile" <<'EOF'
FROM node:22.11.0-alpine AS deps
FROM node:22.4.0-alpine AS runner
EOF
cv
assert_rc 1 "$rc" "one stage with another patch version fails"
assert_contains "$out" "::error file=Dockerfile,line=2::node 22.4.0 does not match 22.11.0" "the error names file, line and versions"
assert_not_contains "$out" "line=1::" "the matching stage is not reported"

newrepo 22.11.0
printf 'FROM node:24-alpine\n' > "$repo/Dockerfile"
cv
assert_rc 1 "$rc" "a different major fails"

# --- floating tags ----------------------------------------------------------
newrepo 22.11.0
printf 'FROM node:22-alpine\n' > "$repo/Dockerfile"
cv
assert_rc 0 "$rc" "a major-only Dockerfile tag with an exact version file passes"
assert_contains "$out" "::warning file=Dockerfile,line=1::node 22 is less specific than 22.11.0" "and warns that it floats"

newrepo 22.11.0
printf 'FROM node:22.11-alpine\n' > "$repo/Dockerfile"
cv
assert_rc 0 "$rc" "a major.minor tag that agrees passes"
assert_contains "$out" "::warning" "with a warning"

newrepo 22.11.0
printf 'FROM node:22.4-alpine\n' > "$repo/Dockerfile"
cv
assert_rc 1 "$rc" "a major.minor tag that disagrees fails"

newrepo 22.11.0
printf 'FROM node:lts-alpine\nFROM node\n' > "$repo/Dockerfile"
cv
assert_rc 0 "$rc" "tags without a version only warn"
assert_contains "$out" "line=1::node tag 'lts-alpine' is floating" "lts is reported as floating"
assert_contains "$out" "line=2::node tag 'latest' is floating" "a bare node image is latest"

# --- major-only version file (libraries) ------------------------------------
newrepo 22
printf 'FROM node:22.11.0-alpine\n' > "$repo/Dockerfile"
cv
assert_rc 0 "$rc" "a major-only version file accepts an exact Dockerfile tag of that major"
assert_not_contains "$out" "::warning" "without a warning"

newrepo 22
printf 'FROM node:24.1.0-alpine\n' > "$repo/Dockerfile"
cv
assert_rc 1 "$rc" "a major-only version file rejects another major"

newrepo v22.3.0
printf 'FROM node:22.3.0-slim\n' > "$repo/Dockerfile"
cv
assert_rc 0 "$rc" "a leading v in the version file is ignored"

# --- ARG forms --------------------------------------------------------------
newrepo 22.4.0
cat > "$repo/Dockerfile" <<'EOF'
ARG NODE_VERSION=22.4.0
FROM node:${NODE_VERSION}-alpine AS base
EOF
cv
assert_rc 0 "$rc" "ARG NODE_VERSION that matches passes; the FROM using it is not re-judged"

newrepo 22.4.0
cat > "$repo/Dockerfile" <<'EOF'
ARG NODE_VERSION="22.11.0"
FROM node:${NODE_VERSION}-alpine AS base
EOF
cv
assert_rc 1 "$rc" "ARG NODE_VERSION that differs fails (quotes are ignored)"
assert_contains "$out" "line=1::node 22.11.0 does not match 22.4.0" "reported on the ARG line"

newrepo 22.11.0
cat > "$repo/Dockerfile" <<'EOF'
# syntax=docker/dockerfile:1
ARG NODE_IMAGE=registry.example.com/mirror/node:22.11.0-alpine
FROM ${NODE_IMAGE} AS deps
FROM ${NODE_IMAGE} AS runner
EOF
cv
assert_rc 0 "$rc" "ARG NODE_IMAGE with a registry path that matches passes"

newrepo 22.11.0
cat > "$repo/Dockerfile" <<'EOF'
ARG NODE_IMAGE=registry.example.com/mirror/node:22.10.0-alpine
FROM ${NODE_IMAGE} AS deps
EOF
cv
assert_rc 1 "$rc" "ARG NODE_IMAGE that differs fails"
assert_contains "$out" "line=1::node 22.10.0 does not match 22.11.0" "reported on the ARG line"

newrepo 22.11.0
cat > "$repo/Dockerfile" <<'EOF'
ARG SOMETHING=else
ARG BASE_IMAGE=registry.example.com/library/node:22.11.0-alpine@sha256:def
ARG UNRELATED_NODE_FLAG=1
FROM ${BASE_IMAGE}
EOF
cv
assert_rc 0 "$rc" "any ARG whose value is a node image is read, digest included, other ARGs are ignored"

# --- missing files, comments, line endings ----------------------------------
newrepo 22.11.0
cv
assert_rc 0 "$rc" "missing Dockerfiles are ignored"
assert_contains "$out" "0 Dockerfile(s) checked" "and the summary says none were checked"

newrepo 22.11.0
mkdir -p "$repo/.docker"
printf 'FROM node:25.0.0\n' > "$repo/.docker/Dockerfile"
cv
assert_rc 1 "$rc" ".docker/Dockerfile is checked by default"

newrepo 22.11.0
printf 'FROM node:25.0.0\n' > "$repo/Dockerfile"
cv $'Dockerfile\r\n'
assert_rc 1 "$rc" "a CRLF dockerfiles list still reads the Dockerfile (a CR must not make it look missing)"

newrepo 22.11.0
printf 'FROM node:25.0.0\n' > "$repo/Dockerfile.worker"
cv
assert_rc 0 "$rc" "a Dockerfile that is not listed is not read"
cv "Dockerfile Dockerfile.worker"
assert_rc 1 "$rc" "a listed extra Dockerfile is read"

newrepo 22.11.0
cat > "$repo/Dockerfile" <<'EOF'
# FROM node:20-alpine   (old)
#ARG NODE_VERSION=20
   # pnpm@1.0.0 in a comment
FROM node:22.11.0-alpine
EOF
cv
assert_rc 0 "$rc" "comment lines are ignored"

newrepo 22.11.0
printf 'FROM node:22.11.0-alpine AS deps\r\nFROM node:22.11.0-alpine AS runner\r\n' > "$repo/Dockerfile"
cv
assert_rc 0 "$rc" "CRLF Dockerfiles work"

newrepo 22.11.0
printf 'from NODE:22.11.0-alpine as x\narg node_version=22.11.0\n' > "$repo/Dockerfile"
cv
assert_rc 0 "$rc" "instructions are case-insensitive"

newrepo 22.11.0
printf '\xef\xbb\xbfFROM node:25.0.0-alpine\n' > "$repo/Dockerfile"
cv
assert_rc 1 "$rc" "a UTF-8 BOM does not hide the first FROM line"
newrepo 22.11.0
printf '\xef\xbb\xbfFROM node:22.11.0-alpine\n' > "$repo/Dockerfile"
cv
assert_rc 0 "$rc" "and a matching Dockerfile with a BOM passes"

# --- version file -----------------------------------------------------------
newrepo 22.11.0
rm "$repo/.nvmrc"
cv
assert_rc 1 "$rc" "a missing version file fails"
assert_contains "$out" "version file not found" "and says so"

newrepo 'lts/*'
cv
assert_rc 1 "$rc" "lts/* cannot be compared and fails"

newrepo '22.11.0 # services pin the patch'
cv
assert_rc 0 "$rc" "a trailing comment in the version file is ignored"

# --- pnpm literal ------------------------------------------------------------
newrepo 22.11.0 pnpm@9.1.0+sha512.abcdef
cat > "$repo/Dockerfile" <<'EOF'
FROM node:22.11.0-alpine
RUN npm install -g pnpm@9.1.0 && pnpm --version
EOF
cv
assert_rc 0 "$rc" "a pnpm literal equal to packageManager (ignoring +sha) passes"

newrepo 22.11.0 pnpm@9.1.0
cat > "$repo/Dockerfile" <<'EOF'
FROM node:22.11.0-alpine
RUN npm install -g pnpm@8.6.0
EOF
cv
assert_rc 1 "$rc" "a different pnpm literal fails"
assert_contains "$out" "line=2::pnpm@8.6.0 does not match packageManager 'pnpm@9.1.0'" "and names both"

newrepo 22.11.0 pnpm@9.1.0
cat > "$repo/Dockerfile" <<'EOF'
FROM node:22.11.0-alpine
RUN npm install -g "$(node -p "require('./package.json').packageManager.split('+')[0]")"
EOF
cv
assert_rc 0 "$rc" "a Dockerfile that reads packageManager passes"

newrepo 22.11.0
printf 'FROM node:22.11.0-alpine\nRUN corepack prepare pnpm@8.6.0 --activate\n' > "$repo/Dockerfile"
cv
assert_rc 1 "$rc" "a pnpm literal without packageManager fails"
assert_contains "$out" "packageManager 'unset'" "and says it is unset"

newrepo 22.11.0 pnpm@9.1.0
printf 'FROM node:22.11.0-alpine\nRUN pnpm@${PNPM_VERSION}\nRUN echo pnpm@latest\n' > "$repo/Dockerfile"
cv
assert_rc 1 "$rc" "pnpm@latest is a literal that does not match"

newrepo 22.11.0 pnpm@9.1.0
printf 'FROM node:22.11.0-alpine\nRUN echo ${X}pnpm@${PNPM_VERSION}\n' > "$repo/Dockerfile"
cv
assert_rc 0 "$rc" "a pnpm reference through a variable is not a literal"

# --- working-directory ------------------------------------------------------
newrepo 22.11.0
mkdir -p "$repo/app"
printf '24.4.0\n' > "$repo/app/.nvmrc"
printf 'FROM node:24.4.0-alpine\n' > "$repo/app/Dockerfile"
rc=0
out="$(cd "$repo" && INPUT_WORKING_DIRECTORY=app INPUT_NODE_VERSION_FILE=.nvmrc \
  INPUT_DOCKERFILES="Dockerfile .docker/Dockerfile" bash "$ROOT/scripts/check-versions.sh" 2>&1)" || rc=$?
assert_rc 0 "$rc" "working-directory points at the app folder's own .nvmrc and Dockerfile"
printf 'FROM node:22.11.0-alpine\n' > "$repo/app/Dockerfile"
rc=0
out="$(cd "$repo" && INPUT_WORKING_DIRECTORY=app INPUT_NODE_VERSION_FILE=.nvmrc \
  INPUT_DOCKERFILES="Dockerfile" bash "$ROOT/scripts/check-versions.sh" 2>&1)" || rc=$?
assert_rc 1 "$rc" "and a mismatch there fails"
assert_contains "$out" "file=app/Dockerfile" "with the path under the working directory"

# --- resolve-pm.sh ----------------------------------------------------------
# rpm [PACKAGE_MANAGER] [WORKING_DIRECTORY]: sets rc, out, outputs
rpm() {
  : > "$TMP/gh-output"
  rc=0
  out="$(cd "$repo" && GITHUB_OUTPUT="$TMP/gh-output" INPUT_PACKAGE_MANAGER="${1-auto}" \
    INPUT_WORKING_DIRECTORY="${2-.}" INPUT_NODE_VERSION_FILE=.nvmrc INPUT_INSTALL=true INPUT_CHECK_VERSIONS=true \
    bash "$ROOT/scripts/resolve-pm.sh" 2>&1)" || rc=$?
  outputs="$(cat "$TMP/gh-output")"
}

newrepo 22.11.0 pnpm@9.1.0
touch "$repo/pnpm-lock.yaml" "$repo/package-lock.json"
rpm
assert_rc 0 "$rc" "auto with both lockfiles resolves"
assert_eq "$outputs" "pm=pnpm
cache=pnpm
lockfile=pnpm-lock.yaml
package-json=package.json
version-file=.nvmrc" "auto prefers pnpm-lock.yaml and caches the pnpm store"

newrepo 22.11.0
touch "$repo/package-lock.json"
rpm
assert_rc 0 "$rc" "auto with package-lock.json resolves"
assert_contains "$outputs" "pm=npm" "to npm"
assert_contains "$outputs" "cache=npm" "with an npm cache"

newrepo 22.11.0
rpm
assert_rc 0 "$rc" "auto without a lockfile resolves"
assert_contains "$outputs" "pm=none" "to none"
assert_contains "$outputs" "cache=
" "with no cache"

newrepo 22.11.0
touch "$repo/pnpm-lock.yaml"
rpm
assert_rc 1 "$rc" "pnpm without packageManager fails"
assert_contains "$out" "needs \"packageManager\"" "and says what is missing"
assert_eq "$outputs" "" "and writes nothing"

newrepo 22.11.0 npm@10.0.0
touch "$repo/pnpm-lock.yaml"
rpm
assert_rc 1 "$rc" "pnpm with packageManager set to npm fails"

newrepo 22.11.0 pnpm@9.1.0
rpm bun
assert_rc 1 "$rc" "an unknown package manager fails"

newrepo 22.11.0 pnpm@9.1.0
touch "$repo/pnpm-lock.yaml"
rpm none
assert_rc 0 "$rc" "none skips everything even when a lockfile exists"
assert_contains "$outputs" "pm=none" "and resolves to none"

newrepo 22.11.0
rpm npm
assert_rc 0 "$rc" "explicit npm without package-lock.json resolves"
assert_contains "$outputs" "cache=
" "but does not cache"
assert_contains "$out" "::warning" "and warns"

newrepo 22.11.0 pnpm@9.1.0
mkdir -p "$repo/app"
cp "$repo/package.json" "$repo/app/package.json"
touch "$repo/app/pnpm-lock.yaml"
rpm auto app
assert_eq "$outputs" "pm=pnpm
cache=pnpm
lockfile=app/pnpm-lock.yaml
package-json=app/package.json
version-file=app/.nvmrc" "working-directory prefixes every path"
rpm auto ./app/
assert_contains "$outputs" "package-json=app/package.json" "./app/ is normalised"
rpm auto missing
assert_rc 1 "$rc" "a missing working-directory fails"

newrepo 22.11.0
rc=0
out="$(cd "$repo" && INPUT_INSTALL=yes bash "$ROOT/scripts/resolve-pm.sh" 2>&1)" || rc=$?
assert_rc 1 "$rc" "install must be true or false"

newrepo 22.11.0
: > "$TMP/gh-output"
rc=0
out="$(cd "$repo" && GITHUB_OUTPUT="$TMP/gh-output" INPUT_NODE_VERSION_FILE=$'.nvmrc\ninjected=1' bash "$ROOT/scripts/resolve-pm.sh" 2>&1)" || rc=$?
assert_rc 1 "$rc" "a node-version-file with a newline cannot add lines to the outputs"
assert_eq "$(cat "$TMP/gh-output")" "" "and writes nothing"
