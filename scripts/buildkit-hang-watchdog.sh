#!/usr/bin/env bash
# Runs a command (a "docker buildx build ...") and, if it is still running after
# BUILD_WATCHDOG_DEADLINE seconds, captures BuildKit diagnostics and kills it.
#
# Why: a hung build prints nothing and idles until the job timeout, and cancelling the
# job can discard the evidence. Before failing it, capture the state of BuildKit:
#   - ps aux inside the buildkit container
#   - open TCP connections
#   - a SIGUSR1 goroutine dump (buildkitd writes its goroutine stacks to its log)
#   - the tail of the kernel log
#
# Usage: BUILD_WATCHDOG_DEADLINE=1500 bash buildkit-hang-watchdog.sh <command> [args...]
#   BUILD_WATCHDOG_DEADLINE   seconds, default 900; 0 disables (the command is exec'd as is)
#   BUILD_WATCHDOG_DUMP_WAIT  seconds to let buildkitd write its goroutine dump, default 5
# Exit status: the command's own status, or 124 when the watchdog had to kill it.
set -euo pipefail

if [[ $# -eq 0 ]]; then
  echo "usage: buildkit-hang-watchdog.sh <command> [args...]" >&2
  exit 2
fi

deadline="${BUILD_WATCHDOG_DEADLINE:-900}"
if [[ ! "$deadline" =~ ^[0-9]+$ ]]; then
  echo "::error::BUILD_WATCHDOG_DEADLINE must be a number of seconds, got '$deadline'"
  exit 2
fi
deadline=$((10#$deadline))
if [[ "$deadline" -eq 0 ]]; then
  exec "$@"
fi

# A wedged docker daemon would otherwise hang the diagnostics too. Windows ships
# a different timeout.exe, hence the probe instead of command -v.
if timeout 5 true >/dev/null 2>&1; then
  bounded() { timeout 30 "$@"; }
else
  bounded() { "$@"; }
fi

diagnose() {
  echo "::error::Build still running after ${deadline}s - capturing buildkit diagnostics before failing it"

  echo "::group::docker ps"
  bounded docker ps || true
  echo "::endgroup::"

  local bk
  bk="$(bounded docker ps --format '{{.Names}}' 2>/dev/null | grep '^buildx_buildkit' | head -1 || true)"
  if [[ -z "$bk" ]]; then
    echo "No buildx_buildkit container found"
    return 0
  fi

  echo "::group::processes inside $bk"
  bounded docker exec "$bk" ps aux || true
  echo "::endgroup::"

  echo "::group::open TCP connections inside $bk"
  bounded docker exec "$bk" netstat -tn 2>/dev/null || bounded docker exec "$bk" cat /proc/net/tcp || true
  echo "::endgroup::"

  echo "::group::kernel log tail"
  bounded docker exec "$bk" dmesg 2>/dev/null | tail -80 || true
  echo "::endgroup::"

  echo "::group::buildkitd goroutine dump (SIGUSR1, non-fatal to the daemon)"
  bounded docker kill --signal=SIGUSR1 "$bk" || true
  sleep "${BUILD_WATCHDOG_DUMP_WAIT:-5}"
  bounded docker logs --tail 6000 "$bk" 2>&1 || true
  echo "::endgroup::"
}

"$@" &
pid=$!
# Job cancellation reaches this script, not the background child.
trap 'kill "$pid" 2>/dev/null || true' TERM INT

start=$SECONDS
timed_out=0
while kill -0 "$pid" 2>/dev/null; do
  if (( SECONDS - start >= deadline )); then
    timed_out=1
    # Diagnostics are best effort: nothing in them may stop the kill below.
    diagnose || true
    echo "Killing hung build process $pid"
    kill "$pid" 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$pid" 2>/dev/null || true
    break
  fi
  sleep 1
done

rc=0
wait "$pid" || rc=$?
if [[ "$timed_out" -eq 1 ]]; then
  exit 124
fi
exit "$rc"
