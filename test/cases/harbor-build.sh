#!/usr/bin/env bash
# scripts/build.sh against the fake docker: argument handling, cache and tag
# logic, validation, ordering and failure aggregation.
set -euo pipefail
source "$ROOT/test/lib.sh"

SHA=0123456789abcdef0123456789abcdef01234567
REG=registry.example.com
export GITHUB_OUTPUT="$TMP/github-output" GITHUB_STEP_SUMMARY="$TMP/summary" RUNNER_TEMP="$TMP"

defaults() {
  local v
  for v in $(compgen -e | grep '^INPUT_' || true); do unset "$v"; done
  rm -rf "$FAKE_DIR"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_LOG"
  : >"$GITHUB_OUTPUT"
  : >"$GITHUB_STEP_SUMMARY"
  export INPUT_REGISTRY=$REG INPUT_USERNAME=robot INPUT_PASSWORD=pw
  export INPUT_TAG=0123456 INPUT_REVISION=$SHA
  export INPUT_IMAGES=$'example-app/app target=final\nexample-app/migrate target=tools'
}

run_build() { # run_build [ARGS...] -> RC, OUT
  RC=0
  OUT="$(bash "$ROOT/scripts/build.sh" "$@" 2>&1)" || RC=$?
}

# load_argv IMAGE: ARGV = arguments of the buildx build that pushes IMAGE:<tag>
load_argv() {
  local f s
  for f in "$FAKE_DIR"/argv/*; do
    s="$(tr '\0' ' ' <"$f")"
    if [[ "$s" == "buildx build "* && "$s" == *"--tag $REG/$1:"* ]]; then
      mapfile -d '' -t ARGV <"$f"
      return 0
    fi
  done
  fail "no buildx build call for $1"
}

has_pair() { # has_pair KEY VALUE: the arguments contain KEY immediately followed by VALUE
  local i
  for ((i = 0; i < ${#ARGV[@]} - 1; i++)); do
    if [[ "${ARGV[i]}" == "$1" && "${ARGV[i + 1]}" == "$2" ]]; then return 0; fi
  done
  return 1
}
has_arg() {
  local a
  for a in "${ARGV[@]}"; do
    if [[ "$a" == "$1" ]]; then return 0; fi
  done
  return 1
}
count_arg() { # count_arg KEY
  local a n=0
  for a in "${ARGV[@]}"; do
    if [[ "$a" == "$1" ]]; then n=$((n + 1)); fi
  done
  echo "$n"
}
assert_pair() { # assert_pair KEY VALUE MSG
  if has_pair "$1" "$2"; then pass "$3"; else fail "$3 (missing: $1 $2; got: ${ARGV[*]})"; fi
}
assert_no_arg() { # assert_no_arg KEY MSG
  if has_arg "$1"; then fail "$2 (unexpected $1)"; else pass "$2"; fi
}
build_calls() { grep -c '^docker buildx build' "$FAKE_LOG" || true; }

# expect_invalid MSG NEEDLE VAR VALUE [VAR VALUE]...: bad input fails before any docker call
expect_invalid() {
  local msg="$1" needle="$2"
  shift 2
  defaults
  while [[ $# -ge 2 ]]; do
    export "$1=$2"
    shift 2
  done
  run_build
  assert_rc 1 "$RC" "$msg: exit code"
  assert_contains "$OUT" "$needle" "$msg: message"
  assert_eq "$(cat "$FAKE_LOG")" "" "$msg: no docker call"
}

# ---- happy path: three images, args with spaces/quotes, secret, floating tag
defaults
export INPUT_IMAGES=$'example-app/app target=final\nexample-app/migrate target=tools\nexample-app/worker file=Dockerfile.worker cache=example-app/worker-buildcache watchdog=77'
export INPUT_BUILD_ARGS=$'BUILD_VERSION=0123456\nGREETING=hello "big" world\nEMPTY=\n\nURL=https://app.example.com/a?b=c&d=e\nEQ=a=b c\nINJECT=$(touch "'"$TMP"'/pwned") `touch '"$TMP"'/pwned2`'
export INPUT_BUILD_SECRET_ID=example_key INPUT_BUILD_SECRET_VALUE='s3cr3t value'
export INPUT_FLOATING_TAG=latest
run_build
assert_rc 0 "$RC" "happy path exits 0"
assert_eq "$(build_calls)" "3" "one buildx build per image"
assert_eq "$(grep '^docker buildx build' "$FAKE_LOG" | head -1 | grep -c "$REG/example-app/app:0123456")" "1" "primary image is built first"
assert_contains "$(cat "$GITHUB_OUTPUT")" "primary-image=$REG/example-app/app:0123456" "primary-image output"
assert_contains "$(cat "$GITHUB_STEP_SUMMARY")" "$REG/example-app/worker:0123456" "step summary lists images"

load_argv example-app/app
assert_eq "${ARGV[0]} ${ARGV[1]}" "buildx build" "uses docker buildx build"
assert_pair --file Dockerfile "primary --file"
assert_pair --target final "primary --target"
assert_pair --build-arg 'GREETING=hello "big" world' "build-arg with spaces and quotes survives as one argument"
assert_pair --build-arg 'EMPTY=' "empty build-arg value survives"
assert_pair --build-arg 'URL=https://app.example.com/a?b=c&d=e' "build-arg with ? & = survives"
assert_pair --build-arg 'EQ=a=b c' "build-arg with = in the value survives"
assert_pair --build-arg 'INJECT=$(touch "'"$TMP"'/pwned") `touch '"$TMP"'/pwned2`' "shell metacharacters stay literal"
assert_eq "$(count_arg --build-arg)" "6" "blank build-args lines are skipped"
[[ ! -e "$TMP/pwned" && ! -e "$TMP/pwned2" ]] || fail "build-args were evaluated by the shell"
pass "build-args are never evaluated"
assert_pair --secret id=example_key,env=HARBOR_BUILD_SECRET "secret passed as --secret id=,env="
assert_pair --label "org.opencontainers.image.revision=$SHA" "revision label"
assert_pair --cache-from "type=registry,ref=$REG/example-app/buildcache" "primary reads the default cache"
assert_pair --cache-to "type=registry,ref=$REG/example-app/buildcache,mode=max" "primary writes the default cache"
assert_pair --tag "$REG/example-app/app:0123456" "immutable tag"
assert_pair --tag "$REG/example-app/app:latest" "floating tag"
assert_eq "$(count_arg --push)" "1" "--push"
assert_eq "${ARGV[${#ARGV[@]} - 1]}" "." "context is the last argument"

load_argv example-app/migrate
assert_pair --target tools "secondary --target"
assert_no_arg --build-arg "secondary gets no build args"
assert_no_arg --secret "secondary gets no secret"
assert_no_arg --cache-to "secondary does not write the shared cache"
assert_pair --cache-from "type=registry,ref=$REG/example-app/buildcache" "secondary reads the shared cache"
assert_pair --label "org.opencontainers.image.revision=$SHA" "secondary revision label"
assert_pair --tag "$REG/example-app/migrate:latest" "secondary floating tag"

load_argv example-app/worker
assert_pair --file Dockerfile.worker "per-image file"
assert_no_arg --target "no target when none is given"
assert_pair --cache-from "type=registry,ref=$REG/example-app/worker-buildcache" "own cache is read"
assert_pair --cache-to "type=registry,ref=$REG/example-app/worker-buildcache,mode=max" "own cache is written"
assert_eq "$(count_arg --cache-from)" "1" "own cache replaces the shared one"

BUILD_ENV="$(cat "$FAKE_DIR/build-env")"
assert_eq "$(grep -c 'HARBOR_BUILD_SECRET=s3cr3t value ' <<<"$BUILD_ENV")" "1" "secret reaches only the primary build, through the environment"
assert_contains "$BUILD_ENV" "HARBOR_BUILD_SECRET=s3cr3t value BUILD_WATCHDOG_DEADLINE=1500" "primary watchdog = watchdog-seconds"
assert_contains "$BUILD_ENV" "HARBOR_BUILD_SECRET=UNSET BUILD_WATCHDOG_DEADLINE=900" "secondary watchdog defaults to 900"
assert_contains "$BUILD_ENV" "BUILD_WATCHDOG_DEADLINE=77" "per-image watchdog="
assert_not_contains "$(cat "$FAKE_LOG")" "s3cr3t" "secret value never on a command line"
assert_not_contains "$OUT" "s3cr3t" "secret value never in the log"

# ---- CRLF input (Windows editors) is tolerated
defaults
export INPUT_IMAGES=$'example-app/app target=final\r\nexample-app/migrate\r\n'
export INPUT_BUILD_ARGS=$'A=1\r\nB=two words\r\n'
run_build
assert_rc 0 "$RC" "CRLF inputs: exit 0"
load_argv example-app/app
assert_pair --build-arg 'B=two words' "CRLF inputs: build-arg without CR"
assert_pair --target final "CRLF inputs: target without CR"

# ---- single image, no build args, no secret, no floating tag
defaults
export INPUT_IMAGES='example-app/app'
run_build
assert_rc 0 "$RC" "single image: exit 0"
load_argv example-app/app
assert_no_arg --build-arg "single image: no build args"
assert_no_arg --secret "single image: no secret"
assert_eq "$(count_arg --tag)" "1" "no floating tag unless asked"
assert_pair --file Dockerfile "default Dockerfile"
assert_eq "${ARGV[${#ARGV[@]} - 1]}" "." "default context"

# ---- file / context inputs
defaults
export INPUT_IMAGES=$'example-app/app\nexample-app/migrate file=Dockerfile.other' INPUT_FILE=.docker/Dockerfile INPUT_CONTEXT=services/api
run_build
assert_rc 0 "$RC" "file and context: exit 0"
load_argv example-app/app
assert_pair --file .docker/Dockerfile "file input is the default"
assert_eq "${ARGV[${#ARGV[@]} - 1]}" "services/api" "context input"
load_argv example-app/migrate
assert_pair --file Dockerfile.other "file= overrides the default"

# ---- floating tags
defaults
export INPUT_FLOATING_TAG=none
run_build
assert_rc 0 "$RC" "floating-tag none: exit 0"
load_argv example-app/app
assert_eq "$(count_arg --tag)" "1" "floating-tag none pushes the immutable tag only"
defaults
export INPUT_TAG=dev-0123456 INPUT_FLOATING_TAG=dev-latest
run_build
assert_rc 0 "$RC" "dev tag: exit 0"
load_argv example-app/app
assert_pair --tag "$REG/example-app/app:dev-0123456" "dev tag"
assert_pair --tag "$REG/example-app/app:dev-latest" "dev floating tag"
assert_contains "$(cat "$GITHUB_OUTPUT")" "primary-image=$REG/example-app/app:dev-0123456" "dev primary-image output"

# ---- cache refs
defaults
export INPUT_TAG=dev-0123456 INPUT_FLOATING_TAG=dev-latest INPUT_CACHE_REF=example-app/buildcache-dev INPUT_CACHE_FROM=example-app/buildcache
run_build
assert_rc 0 "$RC" "dev cache: exit 0"
load_argv example-app/app
assert_pair --cache-from "type=registry,ref=$REG/example-app/buildcache-dev" "dev primary reads buildcache-dev"
assert_pair --cache-from "type=registry,ref=$REG/example-app/buildcache" "dev primary reads buildcache"
assert_pair --cache-to "type=registry,ref=$REG/example-app/buildcache-dev,mode=max" "dev primary writes buildcache-dev only"
assert_eq "$(count_arg --cache-to)" "1" "dev primary has one cache-to"
load_argv example-app/migrate
assert_pair --cache-from "type=registry,ref=$REG/example-app/buildcache-dev" "dev secondary reads buildcache-dev"
assert_pair --cache-from "type=registry,ref=$REG/example-app/buildcache" "dev secondary reads buildcache"
assert_no_arg --cache-to "dev secondary writes nothing"

defaults
export INPUT_CACHE_REF=none
run_build
assert_rc 0 "$RC" "cache-ref none: exit 0"
load_argv example-app/app
assert_no_arg --cache-from "cache-ref none: no cache-from"
assert_no_arg --cache-to "cache-ref none: no cache-to"

defaults
export INPUT_CACHE_REF=none INPUT_CACHE_FROM=$'example-app/buildcache\r\n'
run_build
load_argv example-app/app
assert_pair --cache-from "type=registry,ref=$REG/example-app/buildcache" "cache-ref none keeps explicit cache-from"
assert_no_arg --cache-to "cache-ref none with cache-from: still no cache-to"

defaults
export INPUT_IMAGES=$'example-app/app cache=none\nexample-app/migrate cache=none'
run_build
load_argv example-app/app
assert_no_arg --cache-from "cache=none on the primary: no cache-from"
assert_no_arg --cache-to "cache=none on the primary: no cache-to"
load_argv example-app/migrate
assert_no_arg --cache-from "cache=none on a secondary: no cache-from"

defaults
export INPUT_IMAGES=$'other-proj/app cache=other-proj/special-cache:v2'
run_build
load_argv other-proj/app
assert_pair --cache-to "type=registry,ref=$REG/other-proj/special-cache:v2,mode=max" "primary cache= overrides cache-ref (with tag)"

defaults
export INPUT_IMAGES=$'other-proj/app\nother-proj/migrate'
run_build
load_argv other-proj/migrate
assert_pair --cache-from "type=registry,ref=$REG/other-proj/buildcache" "project is the first path segment of the primary"

# ---- watchdog defaults
defaults
export INPUT_WATCHDOG_SECONDS=300 INPUT_IMAGES=$'example-app/app\nexample-app/migrate\nexample-app/tools watchdog=0'
run_build
assert_rc 0 "$RC" "watchdog-seconds: exit 0"
BUILD_ENV="$(cat "$FAKE_DIR/build-env")"
assert_eq "$(grep -c 'BUILD_WATCHDOG_DEADLINE=300$' <<<"$BUILD_ENV")" "2" "secondary default is capped by watchdog-seconds"
assert_contains "$BUILD_ENV" "BUILD_WATCHDOG_DEADLINE=0" "watchdog=0 disables for one image"

# ---- ordering and failure aggregation
defaults
export INPUT_IMAGES=$'example-app/app\nexample-app/migrate\nexample-app/worker'
printf 'example-app/app:0123456\n' >"$FAKE_DIR/fail-on"
run_build
assert_rc 1 "$RC" "primary failure: exit 1"
assert_eq "$(build_calls)" "1" "primary failure: secondaries are not started"
assert_contains "$OUT" "primary image example-app/app failed" "primary failure: message"
assert_eq "$(cat "$GITHUB_OUTPUT")" "" "primary failure: no output"

defaults
export INPUT_IMAGES=$'example-app/app\nexample-app/migrate\nexample-app/worker'
printf 'example-app/migrate:0123456\n' >"$FAKE_DIR/fail-on"
run_build
assert_rc 1 "$RC" "secondary failure: exit 1"
assert_eq "$(build_calls)" "3" "secondary failure: the other secondary still builds"
assert_contains "$OUT" "failed images: example-app/migrate" "secondary failure: message names the image"
assert_not_contains "$OUT" "failed images: example-app/migrate example-app/worker" "secondary failure: healthy image not blamed"
assert_eq "$(cat "$GITHUB_OUTPUT")" "" "secondary failure: no output"

defaults
export INPUT_IMAGES=$'example-app/app\nexample-app/m1\nexample-app/m2'
printf 'example-app/m1:\nexample-app/m2:\n' >"$FAKE_DIR/fail-on"
run_build
assert_rc 1 "$RC" "both secondaries fail: exit 1"
assert_contains "$OUT" "failed images: example-app/m1 example-app/m2" "both secondaries fail: both named"

# ---- secondaries run in parallel
defaults
export INPUT_IMAGES=$'example-app/app\nexample-app/m1\nexample-app/m2'
printf '2 example-app/m\n' >"$FAKE_DIR/rendezvous"
run_build
assert_rc 0 "$RC" "parallel secondaries: both were running at once"

# ---- validation: fails before any docker call
expect_invalid "empty registry" "registry is empty" INPUT_REGISTRY ""
expect_invalid "registry with a path" "lowercase hostname" INPUT_REGISTRY "registry.example.com/evil"
expect_invalid "registry with uppercase" "lowercase hostname" INPUT_REGISTRY "Registry.example.com"
expect_invalid "registry with a space" "lowercase hostname" INPUT_REGISTRY "registry.example.com --x"
expect_invalid "registry starting with a dash" "lowercase hostname" INPUT_REGISTRY "-registry.example.com"
expect_invalid "registry with a long port" "lowercase hostname" INPUT_REGISTRY "registry.example.com:123456"
expect_invalid "registry with empty label" "lowercase hostname" INPUT_REGISTRY "registry..example.com"
expect_invalid "tag latest" "tag must match" INPUT_TAG "latest"
expect_invalid "short tag" "tag must match" INPUT_TAG "abc12"
expect_invalid "uppercase tag" "tag must match" INPUT_TAG "ABCDEF0"
expect_invalid "long tag" "tag must match" INPUT_TAG "0123456789"
expect_invalid "short dev tag" "tag must match" INPUT_TAG "dev-abc12"
expect_invalid "empty tag" "tag must match" INPUT_TAG ""
expect_invalid "tag with a trailing CR" "tag must match" INPUT_TAG $'0123456\r'
expect_invalid "short revision" "full commit sha" INPUT_REVISION "0123456"
expect_invalid "uppercase revision" "full commit sha" INPUT_REVISION "0123456789ABCDEF0123456789ABCDEF01234567"
expect_invalid "empty revision" "full commit sha" INPUT_REVISION ""
expect_invalid "tag unrelated to revision" "not the short form" INPUT_TAG "abcdef0"
expect_invalid "unknown floating tag" "floating-tag must be" INPUT_FLOATING_TAG "stable"
expect_invalid "latest on a dev tag" "dev-latest" INPUT_FLOATING_TAG "latest" INPUT_TAG dev-0123456
expect_invalid "dev-latest on a plain tag" "needs a dev- tag" INPUT_FLOATING_TAG "dev-latest"
expect_invalid "empty images" "images is empty" INPUT_IMAGES ""
expect_invalid "blank images" "images is empty" INPUT_IMAGES $'  \n\n'
expect_invalid "uppercase image path" "lowercase repository path" INPUT_IMAGES "Example-App/app"
expect_invalid "image path without project" "lowercase repository path" INPUT_IMAGES "app"
expect_invalid "image path traversal" "lowercase repository path" INPUT_IMAGES "example-app/../app"
expect_invalid "image path with the registry host" "starts with the registry host" INPUT_IMAGES "registry.example.com/example-app/app"
expect_invalid "image listed twice" "listed twice" INPUT_IMAGES $'example-app/app\nexample-app/app target=x'
expect_invalid "unknown image option" "unknown option 'foo'" INPUT_IMAGES "example-app/app foo=bar"
expect_invalid "image option without value sign" "not key=value" INPUT_IMAGES "example-app/app target"
expect_invalid "image option with empty value" "empty value" INPUT_IMAGES "example-app/app target="
expect_invalid "target given twice" "target given twice" INPUT_IMAGES "example-app/app target=a target=b"
expect_invalid "bad target" "invalid target" INPUT_IMAGES "example-app/app target=a;b"
expect_invalid "file traversal" "invalid file" INPUT_IMAGES "example-app/app file=../Dockerfile"
expect_invalid "absolute file" "invalid file" INPUT_IMAGES "example-app/app file=/etc/passwd"
expect_invalid "bad default file" "invalid file" INPUT_FILE "-f"
expect_invalid "bad per-image cache" "invalid cache ref" INPUT_IMAGES "example-app/app cache=Bad/Ref"
expect_invalid "bad per-image watchdog" "watchdog must be seconds" INPUT_IMAGES "example-app/app watchdog=abc"
expect_invalid "bad watchdog-seconds" "watchdog-seconds must be a number" INPUT_WATCHDOG_SECONDS "soon"
expect_invalid "build-arg without equals" "build-args line 1 is not KEY=VALUE" INPUT_BUILD_ARGS "not a pair"
expect_invalid "build-arg with a bad key" "build-args line 2 is not KEY=VALUE" INPUT_BUILD_ARGS $'OK=1\n1BAD=x'
expect_invalid "build-arg with leading space" "build-args line 1 is not KEY=VALUE" INPUT_BUILD_ARGS " KEY=value"
expect_invalid "bad secret id" "invalid build-secret-id" INPUT_BUILD_SECRET_ID "a b"
expect_invalid "secret value without id" "without build-secret-id" INPUT_BUILD_SECRET_VALUE "x"
expect_invalid "uppercase cache-ref" "invalid cache-ref" INPUT_CACHE_REF "Example/BuildCache"
expect_invalid "cache-ref with a space" "invalid cache-ref" INPUT_CACHE_REF "example-app/build cache"
expect_invalid "bad cache-from" "cache-from" INPUT_CACHE_FROM $'example-app/buildcache\nnot a ref'
expect_invalid "context starting with a dash" "invalid context" INPUT_CONTEXT "--evil"
expect_invalid "context with a space" "invalid context" INPUT_CONTEXT "a b"

# ---- an input value with a newline cannot start a workflow command in the log
defaults
export INPUT_REGISTRY=$'registry.example.com\n::warning::INJECTED'
run_build
assert_rc 1 "$RC" "registry with a newline: exit 1"
assert_eq "$(grep -c '^::warning::' <<<"$OUT" || true)" "0" "registry with a newline: no log line starts with an injected workflow command"
assert_contains "$OUT" "lowercase hostname" "registry with a newline: still reported"

# ---- validate mode: no docker, no outputs
defaults
run_build validate
assert_rc 0 "$RC" "validate mode accepts good inputs"
assert_eq "$(cat "$FAKE_LOG")" "" "validate mode makes no docker call"
assert_eq "$(cat "$GITHUB_OUTPUT")" "" "validate mode writes no outputs"
defaults
export INPUT_PASSWORD=""
run_build validate
assert_rc 1 "$RC" "validate mode: empty password fails"
assert_contains "$OUT" "password is empty" "validate mode: empty password message"
defaults
export INPUT_USERNAME=""
run_build validate
assert_rc 1 "$RC" "validate mode: empty username fails"
defaults
export INPUT_REGISTRY=""
run_build validate
assert_rc 1 "$RC" "validate mode: empty registry fails"
defaults
run_build nonsense
assert_rc 1 "$RC" "unknown mode fails"
assert_contains "$OUT" "unknown mode 'nonsense'" "unknown mode message"
