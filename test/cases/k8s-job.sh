#!/usr/bin/env bash
# scripts/job.sh with the fake kubectl: delete + apply + poll for Complete/Failed,
# diagnostics on Failed and on timeout.
set -euo pipefail
source "$ROOT/test/lib.sh"

OUT=''
RC=0
export K8S_POLL_INTERVAL=0.1

mkdir -p "$TMP/w"
cd "$TMP/w"
cp "$ROOT/test/fixtures/web/jobs/migrate.yaml" job.yaml

reset() {
  : > "$FAKE_LOG"
  rm -f "$FAKE_DIR"/* "$FAKE_DIR"/.job-n
  echo 'job.batch/example-migrate created' > "$FAKE_DIR/apply-out"
}
# run_job [KEY=VALUE...] -> OUT, RC ; defaults: namespace example, name example-migrate, timeout 5
run_job() {
  RC=0
  OUT=$(env INPUT_NAMESPACE=example INPUT_MANIFEST=job.yaml INPUT_NAME=example-migrate INPUT_TIMEOUT=5 INPUT_DELETE_FIRST=true "$@" \
    bash "$ROOT/scripts/job.sh" 2>&1) || RC=$?
}
log() { cat "$FAKE_LOG"; }
polls() { log | grep -c '^kubectl get job/' || true; }

# ---- completes after a few polls
reset
printf '\n\nComplete=False\nComplete=True\n' > "$FAKE_DIR/job-status"
run_job
assert_rc 0 "$RC" "Job completes"
assert_contains "$OUT" "job/example-migrate completed" "says so"
assert_eq "$(polls)" 4 "polled until Complete (empty, empty, Complete=False, Complete=True)"
assert_eq "$(log | grep -v '^kubectl get job/')" "kubectl delete job example-migrate -n example --ignore-not-found
kubectl apply -n example -f job.yaml" "delete first (ignore-not-found), then apply in the same namespace, nothing else"
assert_contains "$(log | grep '^kubectl get job/' | head -n 1)" "-n example" "polls in the namespace"

# other conditions next to Complete (newer Kubernetes adds SuccessCriteriaMet)
reset
printf 'SuccessCriteriaMet=True;Complete=True\n' > "$FAKE_DIR/job-status"
run_job
assert_rc 0 "$RC" "Complete among several conditions"

# ---- delete-first=false
reset
printf 'Complete=True\n' > "$FAKE_DIR/job-status"
run_job INPUT_DELETE_FIRST=false
assert_rc 0 "$RC" "delete-first false"
assert_not_contains "$(log)" "kubectl delete" "no delete call"

# ---- a leading zero is decimal (08 is not valid octal)
reset
printf 'Complete=True\n' > "$FAKE_DIR/job-status"
run_job INPUT_TIMEOUT=08
assert_rc 0 "$RC" "timeout with a leading zero"
assert_not_contains "$OUT" "value too great for base" "no bash arithmetic error"

# ---- Failed is detected immediately and logs/describe are printed in this step
reset
printf '\nFailed=True\n' > "$FAKE_DIR/job-status"
echo 'Name: example-migrate  Reason: BackoffLimitExceeded' > "$FAKE_DIR/describe.job_example-migrate"
echo 'DESCRIBE-POD-OUTPUT' > "$FAKE_DIR/describe.pods"
echo 'pod/example-migrate-x  0/1  Error' > "$FAKE_DIR/get.pods"
echo '[pod/example-migrate-x/migrate] ERROR relation "users" does not exist' > "$FAKE_DIR/logs.sel"
echo 'LAST-EVENT backoff limit' > "$FAKE_DIR/events"
run_job INPUT_TIMEOUT=60
assert_rc 1 "$RC" "Failed Job fails the step"
assert_contains "$OUT" "::error::k8s-job: job/example-migrate failed" "error annotation"
assert_contains "$OUT" "BackoffLimitExceeded" "job describe printed"
assert_contains "$OUT" "DESCRIBE-POD-OUTPUT" "pod describe printed"
assert_contains "$OUT" "Error" "pod list printed"
assert_contains "$OUT" 'relation "users" does not exist' "container logs printed"
assert_contains "$OUT" "LAST-EVENT" "events printed"
assert_eq "$(polls)" 2 "stopped polling at the first Failed (did not wait out the 60s timeout)"
assert_contains "$(log)" "kubectl logs -n example -l job-name=example-migrate --all-containers=true --prefix --tail=100" "logs of every container of every pod"

# ---- timeout
reset
: > "$FAKE_DIR/job-status"
run_job INPUT_TIMEOUT=1
assert_rc 1 "$RC" "timeout fails the step"
assert_contains "$OUT" "did not finish within 1s" "says so"
assert_contains "$OUT" "FAKE describe job/example-migrate" "diagnostics printed on timeout too"
assert_contains "$OUT" "FAKE logs selector" "logs printed on timeout too"

# ---- a failing apply never polls
reset
echo 1 > "$FAKE_DIR/apply-rc"
echo 'error: the namespace from the provided object does not match' > "$FAKE_DIR/apply-out"
run_job
assert_rc 1 "$RC" "apply failure"
assert_contains "$OUT" "kubectl apply -f job.yaml failed" "says so"
assert_contains "$OUT" "does not match" "kubectl's own message is shown"
assert_eq "$(polls)" 0 "no polling after a failed apply"

# ---- a failing delete (for example RBAC) fails with an annotation, before any apply
reset
echo 1 > "$FAKE_DIR/delete-rc"
echo 'Error from server (Forbidden): jobs.batch "example-migrate" is forbidden' > "$FAKE_DIR/delete-out"
run_job
assert_rc 1 "$RC" "delete failure"
assert_contains "$OUT" "::error::k8s-job: could not delete job/example-migrate in example" "annotation"
assert_not_contains "$(log)" "kubectl apply" "nothing applied after a failed delete"

# ---- the manifest must create the Job that is polled
reset
echo 'job.batch/some-other-job created' > "$FAKE_DIR/apply-out"
printf 'Complete=True\n' > "$FAKE_DIR/job-status"
run_job INPUT_DELETE_FIRST=false
assert_rc 1 "$RC" "manifest applies a differently named Job: fails instead of polling a stale one"
assert_contains "$OUT" "did not apply a Job named 'example-migrate'" "says which name was expected"
assert_eq "$(polls)" 0 "never polled"
reset
echo 'job.batch/example-migrate-v2 created' > "$FAKE_DIR/apply-out"
run_job
assert_rc 1 "$RC" "a name that is only a prefix of the applied Job does not match"
reset
echo 'job.batch/example-migrate unchanged' > "$FAKE_DIR/apply-out"
printf 'Complete=True\n' > "$FAKE_DIR/job-status"
run_job
assert_rc 0 "$RC" "unchanged is fine (delete-first=false reruns, or an identical Job)"
reset
printf 'namespace/example unchanged\njob/example-migrate created\n' > "$FAKE_DIR/apply-out"
printf 'Complete=True\n' > "$FAKE_DIR/job-status"
run_job
assert_rc 0 "$RC" "job/name without the group is accepted too, among other lines"
reset
echo 'job.batch/exampleXmigrate created' > "$FAKE_DIR/apply-out"
run_job INPUT_NAME=example.migrate
assert_rc 1 "$RC" "a dot in the name is not a regex wildcard"
reset
echo 'job.batch/example.migrate created' > "$FAKE_DIR/apply-out"
printf 'Complete=True\n' > "$FAKE_DIR/job-status"
run_job INPUT_NAME=example.migrate
assert_rc 0 "$RC" "dotted Job name"

# ---- input validation
reset
run_job INPUT_NAMESPACE=
assert_rc 1 "$RC" "empty namespace"
run_job INPUT_NAME='Bad Name'
assert_rc 1 "$RC" "invalid name"
run_job INPUT_MANIFEST=missing.yaml
assert_rc 1 "$RC" "missing manifest"
run_job INPUT_TIMEOUT=soon
assert_rc 1 "$RC" "non-numeric timeout"
run_job INPUT_TIMEOUT=0
assert_rc 1 "$RC" "zero timeout"
run_job INPUT_TIMEOUT=000
assert_rc 1 "$RC" "zero with leading zeros"
run_job INPUT_TIMEOUT=-5
assert_rc 1 "$RC" "negative timeout"
run_job INPUT_TIMEOUT=99999999999999999999
assert_rc 1 "$RC" "absurdly long timeout"
run_job INPUT_DELETE_FIRST=yes
assert_rc 1 "$RC" "delete-first must be true or false"
assert_eq "$(log)" "" "no kubectl call on bad input"
