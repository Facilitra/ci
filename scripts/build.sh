#!/usr/bin/env bash
# Builds and pushes the images of one deploy with docker buildx. Called by
# actions/harbor-build/action.yml, which passes every input as INPUT_<NAME>:
#   REGISTRY USERNAME PASSWORD TAG REVISION IMAGES BUILD_ARGS BUILD_SECRET_ID
#   BUILD_SECRET_VALUE FILE CONTEXT FLOATING_TAG CACHE_REF CACHE_FROM WATCHDOG_SECONDS
# Usage: build.sh            validate, then build and push
#        build.sh validate   validate only (runs before the registry login)
#
# The first image is the primary: built in the foreground, it owns the build
# args, the BuildKit secret and the registry cache it writes. Secondary images
# start after it succeeds (they reuse its cache) and build in parallel.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WATCHDOG="$HERE/buildkit-hang-watchdog.sh"

# Messages quote input values; a CR or LF in one must not start a new log line
# that the runner would read as a workflow command.
die() {
  local msg="$*"
  echo "::error::harbor-build: ${msg//[$'\r\n']/ }"
  exit 1
}

mode="${1:-build}"
[[ "$mode" == build || "$mode" == validate ]] || die "unknown mode '$mode'"

# Registry repository path: lowercase segments, at least project/name.
seg='[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*'
path_re="^${seg}(/${seg})+$"
ref_re="^${seg}(/${seg})+(:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})?$"
host_re='^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$'
word_re='^[A-Za-z0-9][A-Za-z0-9_.-]*$'
file_re='^[A-Za-z0-9_.][A-Za-z0-9_./-]*$'

registry="${INPUT_REGISTRY:-}"
[[ -n "$registry" ]] || die "registry is empty (is the registry variable set for this repository?)"
[[ "$registry" =~ $host_re && "$registry" != *..* ]] ||
  die "registry must be a lowercase hostname[:port], got '$registry'"

if [[ "$mode" == validate ]]; then
  [[ -n "${INPUT_USERNAME:-}" ]] || die "username is empty (is the secret set?)"
  [[ -n "${INPUT_PASSWORD:-}" ]] || die "password is empty (is the secret set?)"
fi

tag="${INPUT_TAG:-}"
[[ "$tag" =~ ^(dev-)?[0-9a-f]{7}$ ]] || die "tag must match ^(dev-)?[0-9a-f]{7}\$, got '$tag'"
revision="${INPUT_REVISION:-}"
[[ "$revision" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || die "revision must be a full commit sha, got '$revision'"
[[ "${revision:0:7}" == "${tag#dev-}" ]] || die "tag '$tag' is not the short form of revision '$revision'"

floating="${INPUT_FLOATING_TAG:-}"
case "$floating" in
  none) floating="" ;;
  "") ;;
  latest) [[ "$tag" != dev-* ]] || die "floating-tag latest on a dev- tag (use dev-latest)" ;;
  dev-latest) [[ "$tag" == dev-* ]] || die "floating-tag dev-latest needs a dev- tag" ;;
  *) die "floating-tag must be empty, none, latest or dev-latest, got '$floating'" ;;
esac

context="${INPUT_CONTEXT:-.}"
[[ "$context" =~ ^[A-Za-z0-9_./][A-Za-z0-9_./-]*$ ]] || die "invalid context '$context'"
default_file="${INPUT_FILE:-Dockerfile}"
[[ "$default_file" =~ $file_re && "$default_file" != *..* ]] || die "invalid file '$default_file'"

watchdog_default="${INPUT_WATCHDOG_SECONDS:-1500}"
[[ "$watchdog_default" =~ ^[0-9]+$ ]] || die "watchdog-seconds must be a number, got '$watchdog_default'"
watchdog_default=$((10#$watchdog_default))
# Secondaries reuse cached layers, so they get a tighter default; 0 disables both.
secondary_watchdog_default=$((watchdog_default > 900 ? 900 : watchdog_default))

img_path=()
img_target=()
img_file=()
img_cache=()
img_watchdog=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ ^[[:space:]]*$ ]]; then continue; fi
  read -r -a tok <<<"$line"
  p="${tok[0]}"
  [[ "$p" =~ $path_re ]] ||
    die "images: '$p' is not a lowercase repository path like project/name"
  [[ "$p" != "$registry"/* ]] || die "images: '$p' starts with the registry host; list the path without it"
  for seen in "${img_path[@]}"; do
    [[ "$seen" != "$p" ]] || die "images: '$p' listed twice"
  done
  t_target="" t_file="" t_cache="" t_wd=""
  for opt in "${tok[@]:1}"; do
    [[ "$opt" == *=* ]] || die "images: '$p': '$opt' is not key=value"
    k="${opt%%=*}"
    v="${opt#*=}"
    [[ -n "$v" ]] || die "images: '$p': empty value for '$k'"
    case "$k" in
      target)
        [[ -z "$t_target" ]] || die "images: '$p': target given twice"
        [[ "$v" =~ $word_re ]] || die "images: '$p': invalid target '$v'"
        t_target="$v" ;;
      file)
        [[ -z "$t_file" ]] || die "images: '$p': file given twice"
        [[ "$v" =~ $file_re && "$v" != *..* ]] || die "images: '$p': invalid file '$v'"
        t_file="$v" ;;
      cache)
        [[ -z "$t_cache" ]] || die "images: '$p': cache given twice"
        [[ "$v" == none || "$v" =~ $ref_re ]] || die "images: '$p': invalid cache ref '$v'"
        t_cache="$v" ;;
      watchdog)
        [[ -z "$t_wd" ]] || die "images: '$p': watchdog given twice"
        [[ "$v" =~ ^[0-9]+$ ]] || die "images: '$p': watchdog must be seconds, got '$v'"
        t_wd=$((10#$v)) ;;
      *) die "images: '$p': unknown option '$k' (target, file, cache, watchdog)" ;;
    esac
  done
  img_path+=("$p")
  img_target+=("$t_target")
  img_file+=("${t_file:-$default_file}")
  img_cache+=("$t_cache")
  img_watchdog+=("$t_wd")
done <<<"${INPUT_IMAGES:-}"
[[ ${#img_path[@]} -ge 1 ]] || die "images is empty"

project="${img_path[0]%%/*}"
case "${INPUT_CACHE_REF:-}" in
  "") primary_cache="$project/buildcache" ;;
  none) primary_cache="" ;;
  *)
    [[ "$INPUT_CACHE_REF" =~ $ref_re ]] || die "invalid cache-ref '$INPUT_CACHE_REF'"
    primary_cache="$INPUT_CACHE_REF" ;;
esac

extra_cache=()
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ ^[[:space:]]*$ ]]; then continue; fi
  [[ "$line" =~ $ref_re ]] || die "cache-from: '$line' is not a repository path like project/buildcache"
  extra_cache+=("$line")
done <<<"${INPUT_CACHE_FROM:-}"

# Build args stay in an array: values with spaces, quotes or '=' survive, nothing is eval'd.
build_args=()
n=0
while IFS= read -r line || [[ -n "$line" ]]; do
  n=$((n + 1))
  line="${line%$'\r'}"
  if [[ "$line" =~ ^[[:space:]]*$ ]]; then continue; fi
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || die "build-args line $n is not KEY=VALUE"
  build_args+=(--build-arg "$line")
done <<<"${INPUT_BUILD_ARGS:-}"

secret_id="${INPUT_BUILD_SECRET_ID:-}"
secret_value="${INPUT_BUILD_SECRET_VALUE-}"
if [[ -n "$secret_id" ]]; then
  [[ "$secret_id" =~ $word_re ]] || die "invalid build-secret-id '$secret_id'"
elif [[ -n "$secret_value" ]]; then
  die "build-secret-value is set without build-secret-id"
fi

if [[ "$mode" == validate ]]; then
  echo "harbor-build: inputs ok (${#img_path[@]} image(s), tag $tag)"
  exit 0
fi

# Credentials and the secret are not needed by anything the children run.
unset INPUT_BUILD_SECRET_VALUE INPUT_PASSWORD INPUT_USERNAME

# Fills CMD with the buildx command for image $1.
build_cmd() {
  local i="$1" ref rw="" reads=()
  CMD=(docker buildx build --file "${img_file[$i]}")
  if [[ -n "${img_target[$i]}" ]]; then CMD+=(--target "${img_target[$i]}"); fi
  CMD+=(--label "org.opencontainers.image.revision=$revision")

  if [[ "${img_cache[$i]}" == none ]]; then
    :
  elif [[ -n "${img_cache[$i]}" ]]; then
    rw="${img_cache[$i]}"
    reads=("$rw" "${extra_cache[@]}")
  else
    if [[ -n "$primary_cache" ]]; then reads+=("$primary_cache"); fi
    reads+=("${extra_cache[@]}")
    if [[ "$i" -eq 0 ]]; then rw="$primary_cache"; fi
  fi
  for ref in "${reads[@]}"; do
    CMD+=(--cache-from "type=registry,ref=$registry/$ref")
  done
  if [[ -n "$rw" ]]; then CMD+=(--cache-to "type=registry,ref=$registry/$rw,mode=max"); fi

  if [[ "$i" -eq 0 ]]; then
    CMD+=("${build_args[@]}")
    if [[ -n "$secret_id" ]]; then CMD+=(--secret "id=$secret_id,env=HARBOR_BUILD_SECRET"); fi
  fi
  CMD+=(--tag "$registry/${img_path[$i]}:$tag")
  if [[ -n "$floating" ]]; then CMD+=(--tag "$registry/${img_path[$i]}:$floating"); fi
  CMD+=(--push "$context")
}

# Prints and runs CMD under the watchdog; $1 is the deadline in seconds.
run_watched() {
  printf '+'
  printf ' %q' "${CMD[@]}"
  printf '\n'
  BUILD_WATCHDOG_DEADLINE="$1" bash "$WATCHDOG" "${CMD[@]}"
}

logdir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/harbor-build.XXXXXX")"
trap 'rm -rf "$logdir"' EXIT

primary_ref="$registry/${img_path[0]}:$tag"
wd="${img_watchdog[0]:-$watchdog_default}"

echo "::group::build ${img_path[0]} (primary)"
build_cmd 0
rc=0
HARBOR_BUILD_SECRET="$secret_value" run_watched "$wd" || rc=$?
echo "::endgroup::"
if [[ "$rc" -eq 124 ]]; then die "primary image ${img_path[0]} killed by the hang watchdog after ${wd}s"; fi
[[ "$rc" -eq 0 ]] || die "primary image ${img_path[0]} failed (exit $rc)"

pids=()
for ((i = 1; i < ${#img_path[@]}; i++)); do
  wd="${img_watchdog[$i]:-$secondary_watchdog_default}"
  (
    build_cmd "$i"
    run_watched "$wd"
  ) >"$logdir/$i.log" 2>&1 &
  pids[i]=$!
done

failed=()
if [[ ${#pids[@]} -gt 0 ]]; then
  for i in "${!pids[@]}"; do
    rc=0
    wait "${pids[$i]}" || rc=$?
    echo "::group::build ${img_path[$i]} (exit $rc)"
    cat "$logdir/$i.log"
    echo "::endgroup::"
    if [[ "$rc" -ne 0 ]]; then
      echo "::error::harbor-build: image ${img_path[$i]} failed (exit $rc)"
      failed+=("${img_path[$i]}")
    fi
  done
fi
[[ ${#failed[@]} -eq 0 ]] || die "failed images: ${failed[*]}"

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Images pushed"
    for p in "${img_path[@]}"; do
      echo "- \`$registry/$p:$tag\`"
    done
  } >>"$GITHUB_STEP_SUMMARY"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "primary-image=$primary_ref" >>"$GITHUB_OUTPUT"
fi
echo "pushed ${#img_path[@]} image(s), primary $primary_ref"
