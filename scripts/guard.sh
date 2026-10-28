#!/usr/bin/env bash
# deploy-guard: refuse any run that is not a push or dispatch on an allowed
# branch, and compute the immutable image tag once.
# Inputs (env): INPUT_BRANCHES (newline or space separated bash-case globs),
# INPUT_TAG_PREFIX. Reads GITHUB_EVENT_NAME, GITHUB_REF, GITHUB_SHA.
# Writes ref, sha7 and tag to GITHUB_OUTPUT. Makes no API calls.
set -euo pipefail

# A CR or LF must not start a new log line that the runner would read as a workflow command.
die() {
  local msg="$1"
  printf '::error::deploy-guard: %s\n' "${msg//[$'\r\n']/ }"
  exit 1
}

event="${GITHUB_EVENT_NAME:-}"
ref="${GITHUB_REF:-}"
sha="${GITHUB_SHA:-}"
prefix="${INPUT_TAG_PREFIX:-}"
branches="${INPUT_BRANCHES:-}"
branches="${branches//$'\r'/ }"

case "$event" in
  push | workflow_dispatch) ;;
  *) die "event '$event' may not deploy (only push and workflow_dispatch)" ;;
esac

[[ "$ref" == refs/heads/?* ]] || die "'$ref' is not a branch ref"
branch="${ref#refs/heads/}"

[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "GITHUB_SHA '$sha' is not a full commit sha"
[[ "$prefix" =~ ^([A-Za-z0-9_][A-Za-z0-9._-]*)?$ ]] || die "tag-prefix must be empty or start with a letter, digit or '_' and contain only letters, digits, '.', '_' and '-'"

# set -f: a glob such as release/* must reach the case below unexpanded, not be
# matched against files in the checkout.
set -f
globs=($branches)
set +f
((${#globs[@]} > 0)) || die "branches is empty"

matched=""
for g in "${globs[@]}"; do
  # shellcheck disable=SC2254 # $g is a glob on purpose; * also matches '/'
  case "$branch" in
    $g)
      matched="$g"
      break
      ;;
  esac
done
[[ -n "$matched" ]] || die "branch '$branch' does not match any of: ${globs[*]}"

sha7="${sha:0:7}"
tag="${prefix}${sha7}"

{
  echo "ref=$sha"
  echo "sha7=$sha7"
  echo "tag=$tag"
} >> "${GITHUB_OUTPUT:-/dev/null}"

line="deploy-guard: ok, event=$event branch=$branch (glob '$matched') ref=$sha tag=$tag"
echo "$line"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  echo "$line" >> "$GITHUB_STEP_SUMMARY"
fi
