#!/usr/bin/env bash
# scripts/buildkit-hang-watchdog.sh on its own and through scripts/build.sh,
# with a fake docker whose builds hang on demand.
set -euo pipefail
source "$ROOT/test/lib.sh"

WD="$ROOT/scripts/buildkit-hang-watchdog.sh"
SHA=0123456789abcdef0123456789abcdef01234567
export GITHUB_OUTPUT="$TMP/github-output" RUNNER_TEMP="$TMP"
export BUILD_WATCHDOG_DUMP_WAIT=0

reset() {
  rm -rf "$FAKE_DIR"
  mkdir -p "$FAKE_DIR"
  : >"$FAKE_LOG"
  : >"$GITHUB_OUTPUT"
}
wd() { # wd ARGS...: run the watchdog -> RC, OUT
  RC=0
  OUT="$(bash "$WD" "$@" 2>&1)" || RC=$?
}
gone() { # gone PIDFILE: the process recorded there no longer exists
  ! kill -0 "$(cat "$1")" 2>/dev/null
}

# ---- transparent when the command finishes in time
reset
BUILD_WATCHDOG_DEADLINE=30 wd bash -c 'echo built; exit 0'
assert_rc 0 "$RC" "success is passed through"
assert_contains "$OUT" "built" "command output is passed through"
BUILD_WATCHDOG_DEADLINE=30 wd bash -c 'echo nope >&2; exit 7'
assert_rc 7 "$RC" "the command's own exit code is passed through"
assert_eq "$(cat "$FAKE_LOG")" "" "no diagnostics for a build that finishes"

BUILD_WATCHDOG_DEADLINE=0 wd bash -c 'echo plain; exit 3'
assert_rc 3 "$RC" "deadline 0 runs the command as is"
assert_contains "$OUT" "plain" "deadline 0 passes output through"

BUILD_WATCHDOG_DEADLINE=abc wd true
assert_rc 2 "$RC" "non-numeric deadline is refused"
assert_contains "$OUT" "BUILD_WATCHDOG_DEADLINE must be a number" "non-numeric deadline message"
wd
assert_rc 2 "$RC" "no command is refused"

# ---- a hung build: diagnostics, then kill, exit 124
reset
printf 'some_other_container\nbuildx_buildkit_builder0\n' >"$FAKE_DIR/docker-ps.out"
printf 'example-app/hang\n' >"$FAKE_DIR/hang-on"
BUILD_WATCHDOG_DEADLINE=2 wd docker buildx build --tag registry.example.com/example-app/hang:0123456 --push .
assert_rc 124 "$RC" "hung build: exit 124"
assert_contains "$OUT" "Build still running after 2s" "hung build: error annotation"
assert_contains "$OUT" "Killing hung build process" "hung build: kill message"
LOG="$(cat "$FAKE_LOG")"
assert_contains "$LOG" "docker ps" "hung build: docker ps"
assert_contains "$LOG" "docker exec buildx_buildkit_builder0 ps aux" "hung build: processes inside buildkit"
assert_contains "$LOG" "docker exec buildx_buildkit_builder0 netstat -tn" "hung build: tcp connections"
assert_contains "$LOG" "docker exec buildx_buildkit_builder0 dmesg" "hung build: kernel log"
assert_contains "$LOG" "docker kill --signal=SIGUSR1 buildx_buildkit_builder0" "hung build: goroutine dump"
assert_contains "$LOG" "docker logs --tail 6000 buildx_buildkit_builder0" "hung build: buildkit log"
gone "$FAKE_DIR/hung.pid" || fail "the hung build is still running"
pass "hung build: the process is gone"

reset
printf 'example-app/hang\n' >"$FAKE_DIR/hang-on"
BUILD_WATCHDOG_DEADLINE=1 wd docker buildx build --tag registry.example.com/example-app/hang:0123456 --push .
assert_rc 124 "$RC" "no buildkit container: still exit 124"
assert_contains "$OUT" "No buildx_buildkit container found" "no buildkit container: message"
assert_not_contains "$(cat "$FAKE_LOG")" "docker exec" "no buildkit container: nothing to exec into"

# a failing diagnostics step must not stop the kill (a non-numeric dump wait makes sleep fail)
reset
printf 'buildx_buildkit_builder0\n' >"$FAKE_DIR/docker-ps.out"
printf 'example-app/hang\n' >"$FAKE_DIR/hang-on"
BUILD_WATCHDOG_DUMP_WAIT=abc BUILD_WATCHDOG_DEADLINE=1 wd docker buildx build --tag registry.example.com/example-app/hang:0123456 --push .
assert_rc 124 "$RC" "failing diagnostics: still exit 124"
assert_contains "$OUT" "Killing hung build process" "failing diagnostics: still killed"
gone "$FAKE_DIR/hung.pid" || fail "the hung build survived failing diagnostics"
pass "failing diagnostics: the process is gone"

# ---- through build.sh
bs() { # bs: run build.sh with the current INPUT_* -> RC, OUT
  RC=0
  OUT="$(bash "$ROOT/scripts/build.sh" 2>&1)" || RC=$?
}
inputs() {
  export INPUT_REGISTRY=registry.example.com INPUT_TAG=0123456 INPUT_REVISION=$SHA
}

reset
inputs
export INPUT_IMAGES=$'example-app/app\nexample-app/migrate watchdog=2\nexample-app/worker'
printf 'example-app/migrate:\n' >"$FAKE_DIR/hang-on"
printf 'buildx_buildkit_builder0\n' >"$FAKE_DIR/docker-ps.out"
bs
assert_rc 1 "$RC" "hung secondary: build.sh fails"
assert_contains "$OUT" "Build still running after 2s" "hung secondary: diagnostics reach the job log"
assert_contains "$OUT" "failed images: example-app/migrate" "hung secondary: names the image"
assert_not_contains "$OUT" "failed images: example-app/migrate example-app/worker" "hung secondary: the healthy one is fine"
assert_eq "$(grep -c '^docker buildx build' "$FAKE_LOG")" "3" "hung secondary: all builds were started"
gone "$FAKE_DIR/hung.pid" || fail "the hung secondary is still running"
pass "hung secondary: the process is gone"
assert_eq "$(cat "$GITHUB_OUTPUT")" "" "hung secondary: no primary-image output"

reset
inputs
export INPUT_IMAGES=$'example-app/app\nexample-app/migrate' INPUT_WATCHDOG_SECONDS=2
printf 'example-app/app:\n' >"$FAKE_DIR/hang-on"
bs
assert_rc 1 "$RC" "hung primary: build.sh fails"
assert_contains "$OUT" "killed by the hang watchdog after 2s" "hung primary: message"
assert_eq "$(grep -c '^docker buildx build' "$FAKE_LOG")" "1" "hung primary: secondaries are not started"
gone "$FAKE_DIR/hung.pid" || fail "the hung primary is still running"
pass "hung primary: the process is gone"
