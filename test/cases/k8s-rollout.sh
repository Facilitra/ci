#!/usr/bin/env bash
# scripts/rollout.sh with the fake kubectl: wait list, per-name timeouts, parallelism,
# overall deadline, optional workloads, readinessProbe warning, diagnostics.
set -euo pipefail
source "$ROOT/test/lib.sh"

OUT=''
RC=0
export RUNNER_TEMP="$TMP/runner"
mkdir -p "$RUNNER_TEMP"
WL="$RUNNER_TEMP/k8s-workloads.txt"

reset() {
  : > "$FAKE_LOG"
  rm -f "$FAKE_DIR"/* "$WL"
}
# recorded NAME... : what k8s-apply would have written
recorded() { printf '%s\n' "$@" > "$WL"; }
# run_rollout [KEY=VALUE...] -> OUT, RC ; defaults: namespace example, everything else unset
run_rollout() {
  RC=0
  OUT=$(env INPUT_NAMESPACE=example "$@" bash "$ROOT/scripts/rollout.sh" 2>&1) || RC=$?
}
log() { cat "$FAKE_LOG"; }
waits() { log | grep '^kubectl rollout status' | sort || true; }

# ---- everything rolls out; default timeout
reset
recorded deployment/example-app deployment/example-worker
run_rollout
assert_rc 0 "$RC" "all rolled out"
assert_eq "$(waits)" "kubectl rollout status deployment/example-app -n example --timeout=300s
kubectl rollout status deployment/example-worker -n example --timeout=300s" "one wait per recorded workload with the default timeout"
assert_contains "$OUT" "all workloads rolled out" "says so"
assert_not_contains "$(log)" "kubectl describe" "no diagnostics when green"

# ---- per-name timeouts (name or kind/name, bare numbers are seconds), default override
reset
recorded deployment/example-app deployment/example-worker statefulset/example-db
run_rollout INPUT_TIMEOUT=10m INPUT_TIMEOUTS=$'example-worker=180s\nstatefulset/example-db = 60\n'
assert_rc 0 "$RC" "timeouts parsed"
assert_eq "$(waits)" "kubectl rollout status deployment/example-app -n example --timeout=10m
kubectl rollout status deployment/example-worker -n example --timeout=180s
kubectl rollout status statefulset/example-db -n example --timeout=60s" "overrides by bare name and by kind/name, default for the rest"

# ---- the record file as it may really look: CRLF, blank lines, padding
reset
printf 'deployment/example-app\r\n\r\n  statefulset/example-db  \r\n' > "$WL"
run_rollout
assert_rc 0 "$RC" "messy record file"
assert_eq "$(waits)" "kubectl rollout status deployment/example-app -n example --timeout=300s
kubectl rollout status statefulset/example-db -n example --timeout=300s" "entries trimmed"

# ---- extra, skip, duplicates
reset
recorded deployment/example-app deployment/example-worker deployment/example-app
run_rollout INPUT_EXTRA=$'statefulset/example-db\nexample-app\ndaemonset/example-agent' INPUT_SKIP=$'example-worker\ndaemonset/example-agent'
assert_rc 0 "$RC" "extra and skip"
assert_eq "$(waits)" "kubectl rollout status deployment/example-app -n example --timeout=300s
kubectl rollout status statefulset/example-db -n example --timeout=300s" "recorded + extra - skip, duplicates collapsed, bare extra means deployment"
assert_contains "$OUT" "skipped: deployment/example-worker" "skip is reported"

# ---- empty wait list
reset
run_rollout
assert_rc 1 "$RC" "empty list without extra fails"
assert_contains "$OUT" "empty wait list" "says why"
reset
: > "$WL"
run_rollout
assert_rc 1 "$RC" "empty workloads file fails too"
reset
run_rollout INPUT_EXTRA=deployment/example-edge
assert_rc 0 "$RC" "empty record is fine when extra is set"
assert_eq "$(waits)" "kubectl rollout status deployment/example-edge -n example --timeout=300s" "waits on extra only"
reset
recorded deployment/example-app
run_rollout INPUT_EXTRA=deployment/example-edge INPUT_SKIP=$'example-app\nexample-edge'
assert_rc 0 "$RC" "everything skipped but extra set: nothing to do"
assert_eq "$(waits)" "" "no waits"

# ---- a required failure: diagnostics in the same step, then fail
reset
recorded deployment/example-app deployment/example-worker
echo 1 > "$FAKE_DIR/rollout-rc.example-worker"
echo 'error: deployment "example-worker" exceeded its progress deadline' > "$FAKE_DIR/rollout-out.example-worker"
echo 'app=example,app.component=worker,' > "$FAKE_DIR/selector.example-worker"
echo 'example-worker-7d9f-abcde' > "$FAKE_DIR/pods"
echo 'migrate worker' > "$FAKE_DIR/containers.example-worker-7d9f-abcde"
echo 'Warning  BackOff  pod/example-worker-7d9f-abcde  Back-off restarting failed container' > "$FAKE_DIR/events"
echo 'migrate: applying 0042' > "$FAKE_DIR/logs.example-worker-7d9f-abcde.migrate"
echo 'worker: FATAL connect ECONNREFUSED' > "$FAKE_DIR/logs.example-worker-7d9f-abcde.worker"
echo 'worker: FIRST CRASH TRACE' > "$FAKE_DIR/logs.example-worker-7d9f-abcde.worker.previous"
run_rollout
assert_rc 1 "$RC" "required failure fails"
assert_contains "$OUT" "::error::k8s-rollout: deployment/example-worker: rollout status failed (exit 1)" "error annotation names the workload"
assert_contains "$OUT" 'exceeded its progress deadline' "rollout status output is shown"
assert_contains "$OUT" "::group::diagnostics: deployment/example-worker" "diagnostics in the same step"
assert_contains "$(log)" "kubectl describe deployment/example-worker -n example" "describes the workload"
assert_contains "$(log)" "kubectl get pods -n example -l app=example,app.component=worker -o wide" "pods by the workload's selector (trailing comma stripped)"
assert_contains "$(log)" "kubectl describe pod example-worker-7d9f-abcde -n example" "describes the pod"
assert_contains "$(log)" "kubectl logs example-worker-7d9f-abcde -n example -c migrate --tail=100" "init container logs"
assert_contains "$(log)" "kubectl logs example-worker-7d9f-abcde -n example -c worker --tail=100" "container logs"
assert_contains "$(log)" "kubectl logs example-worker-7d9f-abcde -n example -c worker --previous --tail=100" "previous instance logs"
assert_contains "$OUT" "FIRST CRASH TRACE" "previous logs shown"
assert_contains "$OUT" "applying 0042" "init container logs shown"
assert_contains "$OUT" "Back-off restarting failed container" "events shown"
assert_contains "$OUT" "rollout failed: deployment/example-worker" "final message"
assert_not_contains "$(log)" "describe deployment/example-app" "the healthy workload gets no diagnostics"

# a missing previous instance must not break the diagnostics
assert_contains "$OUT" "previous terminated container not found" "missing previous logs are tolerated and visible"

# diagnose=false
: > "$FAKE_LOG"
run_rollout INPUT_DIAGNOSE=false
assert_rc 1 "$RC" "still fails without diagnostics"
assert_not_contains "$(log)" "kubectl describe" "diagnose=false prints none"
assert_not_contains "$(log)" "kubectl logs" "no logs either"

# no selector: say so, do not guess
: > "$FAKE_LOG"
rm -f "$FAKE_DIR/selector.example-worker"
run_rollout
assert_rc 1 "$RC" "no selector"
assert_contains "$OUT" "no selector found for deployment/example-worker" "reported"

# ---- optional workloads: failure is only a warning, no diagnostics
reset
recorded deployment/example-app deployment/example-legacy
echo 1 > "$FAKE_DIR/rollout-rc.example-legacy"
run_rollout INPUT_OPTIONAL=example-legacy
assert_rc 0 "$RC" "optional failure does not fail"
assert_contains "$OUT" "::warning::k8s-rollout: optional workload deployment/example-legacy" "warns"
assert_not_contains "$(log)" "kubectl describe" "no diagnostics for optional"
run_rollout INPUT_OPTIONAL=deployment/example-legacy
assert_rc 0 "$RC" "optional by kind/name"
run_rollout INPUT_OPTIONAL=example-other
assert_rc 1 "$RC" "a different name in optional does not help"

# required + optional both failing: fail, diagnose only the required one
reset
recorded deployment/example-app deployment/example-legacy
echo 1 > "$FAKE_DIR/rollout-rc.example-legacy"
echo 1 > "$FAKE_DIR/rollout-rc.example-app"
run_rollout INPUT_OPTIONAL=example-legacy
assert_rc 1 "$RC" "required failure wins over optional"
assert_contains "$(log)" "kubectl describe deployment/example-app" "required diagnosed"
assert_not_contains "$(log)" "kubectl describe deployment/example-legacy" "optional not diagnosed"

# ---- overall deadline: waits run in parallel and are cut off together
reset
recorded deployment/example-app deployment/example-worker deployment/example-slow
echo 30 > "$FAKE_DIR/rollout-sleep.example-slow"
echo 'app=slow,' > "$FAKE_DIR/selector.example-slow"
start=$SECONDS
run_rollout INPUT_DEADLINE=2
elapsed=$((SECONDS - start))
assert_rc 1 "$RC" "deadline exceeded fails"
assert_contains "$OUT" "deployment/example-slow: did not finish within the overall deadline of 2s" "names the straggler and the deadline"
assert_contains "$(log)" "kubectl describe deployment/example-slow" "straggler is diagnosed"
assert_not_contains "$(log)" "kubectl describe deployment/example-app" "finished ones are not"
if [[ $elapsed -ge 12 ]]; then fail "deadline of 2s took ${elapsed}s"; fi
pass "returned after ${elapsed}s, not after the 30s the straggler wanted"

reset
recorded deployment/example-a deployment/example-b deployment/example-c
for n in a b c; do echo 2 > "$FAKE_DIR/rollout-sleep.example-$n"; done
start=$SECONDS
run_rollout INPUT_DEADLINE=60
elapsed=$((SECONDS - start))
assert_rc 0 "$RC" "three 2s waits"
if [[ $elapsed -ge 5 ]]; then fail "three 2s waits took ${elapsed}s: they ran one after another"; fi
pass "ran in parallel (${elapsed}s for three 2s waits)"

# background exit codes are aggregated per workload: a failure and a straggler are both named, a healthy one is not
reset
recorded deployment/example-ok deployment/example-bad deployment/example-slow
echo 1 > "$FAKE_DIR/rollout-rc.example-bad"
echo 30 > "$FAKE_DIR/rollout-sleep.example-slow"
run_rollout INPUT_DEADLINE=2
assert_rc 1 "$RC" "one failure plus one straggler"
assert_contains "$OUT" "::error::k8s-rollout: deployment/example-bad: rollout status failed (exit 1)" "failure named with its own exit code"
assert_contains "$OUT" "::error::k8s-rollout: deployment/example-slow: did not finish within the overall deadline of 2s" "straggler named with the deadline"
assert_not_contains "$OUT" "deployment/example-ok: " "healthy workload is not blamed"
assert_contains "$OUT" "rollout failed: deployment/example-bad deployment/example-slow" "final message lists both"

reset
recorded deployment/example-app deployment/example-slow
echo 30 > "$FAKE_DIR/rollout-sleep.example-slow"
run_rollout INPUT_DEADLINE=2 INPUT_OPTIONAL=example-slow
assert_rc 0 "$RC" "optional straggler is a warning"
assert_contains "$OUT" "::warning::k8s-rollout: optional workload deployment/example-slow: did not finish" "deadline warning"

# ---- readinessProbe warning
reset
recorded deployment/example-app deployment/example-worker statefulset/example-db
echo 'app sidecar ' > "$FAKE_DIR/noprobe.example-app"
echo 'db ' > "$FAKE_DIR/noprobe.example-db"
run_rollout
assert_rc 0 "$RC" "missing probe is only a warning"
assert_contains "$OUT" "::warning::k8s-rollout: deployment/example-app: container(s) without a readinessProbe: app sidecar." "lists the containers"
assert_not_contains "$OUT" "deployment/example-worker: container(s) without" "workload with probes: no warning"
assert_not_contains "$OUT" "statefulset/example-db: container(s) without" "only Deployments are checked"
assert_contains "$(log)" "kubectl get deployment/example-app -n example -o go-template=" "uses kubectl's own go-template, no jq"

# ---- input validation
reset
recorded deployment/example-app
run_rollout INPUT_NAMESPACE='bad ns'
assert_rc 1 "$RC" "bad namespace"
run_rollout INPUT_DEADLINE=0
assert_rc 1 "$RC" "deadline 0"
run_rollout INPUT_DEADLINE=000
assert_rc 1 "$RC" "deadline 0 with leading zeros"
run_rollout INPUT_DEADLINE=soon
assert_rc 1 "$RC" "deadline not a number"
run_rollout INPUT_DEADLINE=99999999999999999999
assert_rc 1 "$RC" "absurd deadline"
run_rollout INPUT_TIMEOUTS='=60s'
assert_rc 1 "$RC" "timeouts line without a name"
assert_contains "$OUT" "no name before '='" "says so, not a bash subscript error"
assert_eq "$(log)" "" "none of these touched kubectl"
run_rollout INPUT_DEADLINE=08
assert_rc 0 "$RC" "leading zero is decimal, not an invalid octal (08)"
assert_not_contains "$OUT" "value too great for base" "no bash arithmetic error"
reset
recorded deployment/example-app
run_rollout INPUT_SKIP='*'
assert_rc 0 "$RC" "a glob-looking skip entry is a literal name, it does not skip everything"
assert_contains "$(log)" "kubectl rollout status deployment/example-app" "still waited"
reset
recorded deployment/example-app
run_rollout INPUT_TIMEOUT=forever
assert_rc 1 "$RC" "bad default timeout"
run_rollout INPUT_TIMEOUTS=example-app
assert_rc 1 "$RC" "timeouts line without ="
run_rollout INPUT_TIMEOUTS=example-app=never
assert_rc 1 "$RC" "timeouts value without unit"
run_rollout INPUT_EXTRA=job/example-x
assert_rc 1 "$RC" "extra kind must be a rollout kind"
run_rollout INPUT_DIAGNOSE=maybe
assert_rc 1 "$RC" "diagnose must be true or false"
assert_eq "$(log)" "" "no kubectl call on bad input"
