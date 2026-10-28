#!/usr/bin/env bash
# scripts/apply.sh with the fake kubectl: Secret refusal, exclude globs, directory
# expansion, dry-run ordering, workload recording.
set -euo pipefail
source "$ROOT/test/lib.sh"

FX="$ROOT/test/fixtures"
OUT=''
RC=0
export RUNNER_TEMP="$TMP/runner"
mkdir -p "$RUNNER_TEMP"
WL="$RUNNER_TEMP/k8s-workloads.txt"

fresh() {
  mkdir -p "$TMP/$1"
  cp -r "$FX/." "$TMP/$1/"
  cd "$TMP/$1"
  : > "$FAKE_LOG"
  rm -f "$FAKE_DIR"/* "$WL"
}
# run_apply PATHS EXCLUDE [DRY_RUN_FIRST] -> OUT, RC
run_apply() {
  RC=0
  OUT=$(INPUT_PATHS="$1" INPUT_EXCLUDE="${2:-}" INPUT_DRY_RUN_FIRST="${3:-true}" bash "$ROOT/scripts/apply.sh" 2>&1) || RC=$?
}
log() { cat "$FAKE_LOG"; }

# ---- fixture manifests: directory expansion, exclude by path and by name, dry run first
fresh real
run_apply "web/app" $'web/app/deployment.yaml\nworker.yaml'
assert_rc 0 "$RC" "directory apply succeeds"
assert_contains "$OUT" "excluded: web/app/deployment.yaml" "exclude by listed path"
assert_contains "$OUT" "excluded: web/app/worker.yaml" "exclude by file name"
assert_eq "$(log)" "kubectl apply --dry-run=server -f web/app/config.yaml
kubectl apply -f web/app/config.yaml" "dry run first, then the real apply, only the surviving file"
assert_not_contains "$OUT" "::error" "a comment that mentions kind: Secret is not a Secret"

fresh real-two
run_apply $'api/app\napi/jobs/migrate.yaml' ''
assert_rc 0 "$RC" "directory plus explicit file"
assert_eq "$(log)" "kubectl apply --dry-run=server -f api/app/01-namespace.yaml -f api/app/30-database.yaml -f api/app/40-deployment.yaml -f api/jobs/migrate.yaml
kubectl apply -f api/app/01-namespace.yaml -f api/app/30-database.yaml -f api/app/40-deployment.yaml -f api/jobs/migrate.yaml" "sorted files, one call per phase"

fresh real-three
run_apply "multi/deployment.yaml" ''
assert_rc 0 "$RC" "multi-document file with PVC applies"
run_apply "multi/db" ''
assert_rc 0 "$RC" "second call"

# ---- Secret refusal, multi-document aware, everywhere in the document
fresh secrets
mkdir -p s
cat > s/two-docs.yaml <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ok
---
apiVersion: v1
kind: Secret
metadata:
  name: leaked
type: Opaque
YAML
run_apply s/two-docs.yaml ''
assert_rc 1 "$RC" "Secret in the second document is refused"
assert_contains "$OUT" "s/two-docs.yaml,line=7" "annotation names the file and the line"
assert_eq "$(log)" "" "kubectl never called when a Secret is found"

for form in 'kind: "Secret"' "kind: 'Secret'" 'kind: Secret   # why' '  kind: Secret' '- kind: Secret' '{"apiVersion": "v1", "kind": "Secret"}' '{apiVersion: v1, kind: Secret, metadata: {name: x}}' '"kind": "Secret",'; do
  printf 'items:\n%s\n' "$form" > s/form.yaml
  run_apply s/form.yaml ''
  assert_rc 1 "$RC" "refused: $form"
done
printf 'apiVersion: v1\r\nkind: Secret\r\n' > s/crlf.yaml
run_apply s/crlf.yaml ''
assert_rc 1 "$RC" "refused with CRLF line endings"
printf '\xef\xbb\xbfkind: Secret\nmetadata:\n  name: x\n' > s/bom.yaml
run_apply s/bom.yaml ''
assert_rc 1 "$RC" "refused when a UTF-8 byte order mark precedes kind: Secret on line 1"
printf '\xef\xbb\xbf{"kind": "Secret"}\n' > s/bom-json.yaml
run_apply s/bom-json.yaml ''
assert_rc 1 "$RC" "refused: BOM before a JSON document"
printf 'items: [kind: Secret]\n' > s/seq.yaml
run_apply s/seq.yaml ''
assert_rc 1 "$RC" "refused: single-pair flow sequence"
printf 'kind: ConfigMap\ndata:\n  doc: |\n    kind: Secret\n' > s/embedded.yaml
run_apply s/embedded.yaml ''
assert_rc 1 "$RC" "refused: a Secret quoted inside another document fails closed"

for form in 'kind: SecretExample' 'kind: SecretsStore' 'kind: Secrets' '# kind: Secret' '   # kind: Secret' 'name: x # kind: Secret' 'description: a secret thing' 'kind: ConfigMap # not a Secret'; do
  printf 'a: 1\n%s\n' "$form" > s/form.yaml
  run_apply s/form.yaml ''
  assert_rc 0 "$RC" "allowed: $form"
done

# a Secret in a directory is found even when it is not the first file, but not when excluded
mkdir -p s/dir
cp s/two-docs.yaml s/dir/b-secret.yaml
printf 'kind: ConfigMap\n' > s/dir/a-config.yaml
run_apply s/dir ''
assert_rc 1 "$RC" "Secret inside a directory is refused"
run_apply s/dir 'b-secret.yaml'
assert_rc 0 "$RC" "the same Secret file can be excluded explicitly"
# files kubectl would not be given are not scanned either: a notes file that mentions kind: Secret is not a Secret
mkdir -p s/notes
printf 'kind: ConfigMap\n' > s/notes/a.yaml
printf 'kind: Secret\n' > s/notes/README.md
printf 'kind: Secret\n' > s/notes/old.yaml.bak
run_apply s/notes ''
assert_rc 0 "$RC" "non-yaml files in a directory are neither applied nor scanned"
assert_eq "$(log | tail -n 1)" "kubectl apply -f s/notes/a.yaml" "only the yaml file is applied"

# ---- exclude globs
fresh globs
mkdir -p g
for f in 10-a.yaml 40-app-deployment.yaml 41-worker-deployment.yaml 50-svc.yaml; do printf 'kind: ConfigMap\n' > "g/$f"; done
run_apply ./g $'*-deployment.yaml\n./g/10-a.yaml'
assert_rc 0 "$RC" "globs and ./ prefix"
assert_eq "$(log | sed -n 2p)" "kubectl apply -f ./g/50-svc.yaml" "only the unexcluded file remains (./ prefix kept as listed)"
run_apply g 'g/4?-*'
assert_rc 0 "$RC" "glob across the directory part"
assert_contains "$(log | tail -n 1)" "-f g/10-a.yaml -f g/50-svc.yaml" "? and * work like shell globs"
run_apply g 'renamed-deployment.yaml'
assert_rc 1 "$RC" "an exclude that matches nothing fails (a renamed manifest would be applied too early)"
assert_contains "$OUT" "matched no file" "says so"
run_apply g '*'
assert_rc 1 "$RC" "excluding everything fails"
assert_contains "$OUT" "nothing left to apply" "says so"

# ---- the order is bytewise whatever the runner locale says (kubectl's own order)
fresh locale
mkdir -p loc
for f in 10-a.yaml 1-b.yaml a-b.yaml ab.yaml a.yaml B.yaml; do printf 'kind: ConfigMap\n' > "loc/$f"; done
want="kubectl apply -f loc/1-b.yaml -f loc/10-a.yaml -f loc/B.yaml -f loc/a-b.yaml -f loc/a.yaml -f loc/ab.yaml"
RC=0
OUT=$(LC_ALL=en_US.utf8 LANG=en_US.utf8 INPUT_PATHS=loc bash "$ROOT/scripts/apply.sh" 2>&1) || RC=$?
assert_rc 0 "$RC" "exported LC_ALL"
assert_eq "$(log | sed -n 2p)" "$want" "sorted bytewise even with LC_ALL=en_US.utf8 exported (1-b before 10-a, B before a; en_US reverses both)"

# ---- paths with spaces, order, duplicates, extension filter, no recursion
fresh dirs
mkdir -p "my manifests/nested" "other dir"
printf 'kind: ConfigMap\n' > "my manifests/b one.yaml"
printf 'kind: ConfigMap\n' > "my manifests/a.yml"
printf 'kind: ConfigMap\n' > "my manifests/skip.json"
printf 'kind: ConfigMap\n' > "my manifests/skip.yaml.example"
printf 'kind: ConfigMap\n' > "my manifests/nested/deep.yaml"
printf 'kind: ConfigMap\n' > "other dir/z.yaml"
run_apply $'my manifests\nmy manifests/a.yml\nother dir/' ''
assert_rc 0 "$RC" "paths with spaces"
assert_eq "$(log | sed -n 2p)" "kubectl apply -f my manifests/a.yml -f my manifests/b one.yaml -f other dir/z.yaml" "sorted, deduplicated, yaml/yml only, not recursive"
run_apply 'my manifests/nested/deep.yaml' ''
assert_rc 0 "$RC" "an explicit file below a skipped sub-directory still applies"

# ---- workload recording
fresh record
cat > apply-out.txt <<'TXT'
namespace/example unchanged
deployment.apps/example-app configured
deployment.apps/example-worker created
statefulset.apps/example-db unchanged
daemonset.apps/example-agent configured
service/example-app unchanged
cronjob.batch/example-cron configured
deployment.apps/example-other deleted
horizontalpodautoscaler.autoscaling/example-app configured
deployment.apps/example-app unchanged
TXT
cp apply-out.txt "$FAKE_DIR/apply-out"
run_apply 'api/jobs/migrate.yaml' ''
assert_rc 0 "$RC" "apply with scripted output"
assert_eq "$(cat "$WL")" "deployment/example-app
deployment/example-worker
statefulset/example-db
daemonset/example-agent
deployment/example-app" "deployment|statefulset|daemonset with created|configured|unchanged recorded, others ignored"
assert_contains "$OUT" "deployment.apps/example-app configured" "apply output is shown (tee)"
echo 'deployment.apps/second configured' > "$FAKE_DIR/apply-out"
run_apply 'api/jobs/migrate.yaml' ''
assert_contains "$(cat "$WL")" "deployment/second" "a second call appends"
assert_contains "$(cat "$WL")" "statefulset/example-db" "and keeps the first call's entries"

# Real kubectl noise around the result lines: warnings on stderr, CRLF, dotted names, other verbs.
fresh realfmt
printf 'Warning: spec.template.spec.containers[0].resources: unknown field\r\ndeployment.apps/example.api configured\r\ndeployment.apps/example-gone deleted\nstatefulset.apps/example-db created\ndeployment.apps/example-a serverside-applied\n error: deployment.apps/example-b configured\nconfigmap/deployment.apps unchanged\n  deployment.apps/example-c configured\n' > "$FAKE_DIR/apply-out"
run_apply 'api/jobs/migrate.yaml' ''
assert_rc 0 "$RC" "noisy output"
assert_eq "$(cat "$WL")" "deployment/example.api
statefulset/example-db" "only result lines of the three kinds with a known verb: not warnings, deleted, serverside-applied, indented or prefixed lines"

# the dry-run output is never recorded
fresh dryrec
echo 'deployment.apps/only-dry configured (server dry run)' > "$FAKE_DIR/dryrun-out"
run_apply 'api/jobs/migrate.yaml' ''
assert_rc 0 "$RC" "dry-run output present"
assert_eq "$(cat "$WL")" "" "dry-run lines are not recorded"

# fallback directory when RUNNER_TEMP is unset
fresh fallback
mkdir -p "$TMP/tmpdir"
echo 'deployment.apps/fb configured' > "$FAKE_DIR/apply-out"
RC=0
OUT=$(unset RUNNER_TEMP; TMPDIR="$TMP/tmpdir" INPUT_PATHS='api/jobs/migrate.yaml' bash "$ROOT/scripts/apply.sh" 2>&1) || RC=$?
assert_rc 0 "$RC" "RUNNER_TEMP unset"
assert_eq "$(cat "$TMP/tmpdir/k8s-workloads.txt")" "deployment/fb" "falls back to TMPDIR"

# ---- failures
fresh failures
echo 'error: dry run says no' > "$FAKE_DIR/dryrun-out"
echo 1 > "$FAKE_DIR/dryrun-rc"
run_apply 'api/jobs/migrate.yaml' ''
assert_rc 1 "$RC" "failed dry run fails the step"
assert_contains "$OUT" "dry run says no" "dry-run output visible"
assert_not_contains "$(log)" "kubectl apply -f" "real apply never ran after a failed dry run"

fresh nodry
echo 1 > "$FAKE_DIR/dryrun-rc"
run_apply 'api/jobs/migrate.yaml' '' false
assert_rc 0 "$RC" "dry-run-first=false skips the dry run"
assert_not_contains "$(log)" "--dry-run" "no dry-run call was made"

fresh applyfail
printf 'deployment.apps/half configured\nerror: boom\n' > "$FAKE_DIR/apply-out"
echo 1 > "$FAKE_DIR/apply-rc"
run_apply 'api/jobs/migrate.yaml' ''
assert_rc 1 "$RC" "failed apply fails the step even though tee succeeded"
assert_contains "$OUT" "kubectl apply failed (exit 1)" "says so"
assert_eq "$(cat "$WL" 2>/dev/null || true)" "" "nothing recorded for a failed apply"

# ---- input validation
fresh inputs
run_apply '' ''
assert_rc 1 "$RC" "empty paths"
run_apply 'does/not/exist' ''
assert_rc 1 "$RC" "missing path"
assert_contains "$OUT" "path not found: does/not/exist" "names it"
run_apply 'api/jobs' '' maybe
assert_rc 1 "$RC" "dry-run-first must be true or false"
assert_eq "$(log)" "" "no kubectl call on bad input"
