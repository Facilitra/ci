#!/usr/bin/env bash
# Runs every test/cases/*.sh (or only those named on the command line, with or
# without the .sh suffix) as its own bash process. Each case gets:
#   ROOT       repository root
#   TMP        fresh temp dir, removed afterwards (KEEP_TMP=1 keeps it)
#   FAKEBIN    test/fakebin, already first on PATH (fake kubectl, docker, gh)
#   FAKE_DIR   canned output for the fakes ($TMP/fake)
#   FAKE_LOG   file the fakes append "<cmd> <args...>" to
#   KUBECONFIG /nonexistent, so a real kubectl can never reach a cluster
# Works on Linux and on Git Bash for Windows.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAKEBIN="$ROOT/test/fakebin"

# Hermetic: the same result on a laptop and inside a workflow run.
while IFS= read -r v; do
  unset "$v"
done < <(compgen -e | grep -E '^(GITHUB_|INPUT_|RUNNER_|FAKE_|KUBECONFIG$)' || true)

chmod +x "$FAKEBIN"/* 2>/dev/null || true
export PATH="$FAKEBIN:$PATH"
export KUBECONFIG=/nonexistent

cases=()
if [[ $# -gt 0 ]]; then
  for n in "$@"; do
    n="${n%.sh}"
    [[ -f "$ROOT/test/cases/$n.sh" ]] || { echo "no such case: $n" >&2; exit 2; }
    cases+=("$ROOT/test/cases/$n.sh")
  done
else
  for f in "$ROOT"/test/cases/*.sh; do
    [[ -e "$f" ]] && cases+=("$f")
  done
fi
if [[ ${#cases[@]} -eq 0 ]]; then
  echo "no test cases found" >&2
  exit 1
fi

passed=0
failed=0
failed_names=()
for c in "${cases[@]}"; do
  name="$(basename "$c" .sh)"
  t="$(mktemp -d)"
  mkdir -p "$t/fake"
  : > "$t/fake.log"
  printf '== %s\n' "$name"
  rc=0
  ROOT="$ROOT" TMP="$t" FAKEBIN="$FAKEBIN" FAKE_DIR="$t/fake" FAKE_LOG="$t/fake.log" \
    KUBECONFIG=/nonexistent bash "$c" > "$t/out.log" 2>&1 || rc=$?
  sed 's/^/   /' "$t/out.log"
  if [[ "$rc" -eq 0 ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    failed_names+=("$name")
    printf '   -> FAILED (exit %s)\n' "$rc"
  fi
  [[ "${KEEP_TMP:-}" == 1 ]] && echo "   tmp kept: $t" || rm -rf "$t"
done

printf '\n%s passed, %s failed\n' "$passed" "$failed"
if [[ "$failed" -gt 0 ]]; then
  printf 'failed: %s\n' "${failed_names[*]}"
  exit 1
fi
