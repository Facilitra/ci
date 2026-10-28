#!/usr/bin/env bash
# k8s-job: run a one-off Job to completion. A Job spec is immutable, so the old
# one is deleted first; `kubectl wait --for=condition=complete` never notices a
# Failed Job and would sit out the whole timeout, so both conditions are polled.
#
# Inputs (env): INPUT_NAMESPACE, INPUT_MANIFEST, INPUT_NAME, INPUT_TIMEOUT, INPUT_DELETE_FIRST
# K8S_POLL_INTERVAL (seconds, default 5) exists for the tests only.
set -euo pipefail
PROG=k8s-job
# shellcheck source=k8s-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/k8s-lib.sh"

ns=${INPUT_NAMESPACE:-}
manifest=${INPUT_MANIFEST:-}
name=${INPUT_NAME:-}
timeout_s=${INPUT_TIMEOUT:-300}
delete_first=${INPUT_DELETE_FIRST:-true}
interval=${K8S_POLL_INTERVAL:-5}

[[ $ns =~ $NAME_RE ]] || die "namespace is empty or not a valid name: '$ns'"
[[ $name =~ $NAME_RE ]] || die "name is empty or not a valid name: '$name'"
[[ -f $manifest ]] || die "manifest not found: '$manifest'"
# 10# so a leading zero (010) is decimal, not octal.
[[ $timeout_s =~ ^[0-9]{1,6}$ && $((10#$timeout_s)) -gt 0 ]] || die "timeout must be a positive number of seconds, got '$timeout_s'"
timeout_s=$((10#$timeout_s))
case $delete_first in true | false) ;; *) die "delete-first must be 'true' or 'false', got '$delete_first'" ;; esac

diagnose() {
  echo "::group::job/$name: describe"
  kubectl describe "job/$name" -n "$ns" 2>&1 || true
  echo "::endgroup::"
  echo "::group::job/$name: pods"
  kubectl get pods -n "$ns" -l "job-name=$name" -o wide 2>&1 || true
  echo "::endgroup::"
  echo "::group::job/$name: pod describe"
  kubectl describe pods -n "$ns" -l "job-name=$name" 2>&1 || true
  echo "::endgroup::"
  echo "::group::job/$name: logs (last 100 lines per container, init containers included)"
  kubectl logs -n "$ns" -l "job-name=$name" --all-containers=true --prefix --tail=100 2>&1 || true
  echo "::endgroup::"
  echo "::group::events in $ns"
  kubectl get events -n "$ns" --sort-by=.lastTimestamp 2>&1 | tail -n 30 || true
  echo "::endgroup::"
}

if [[ $delete_first == true ]]; then
  kubectl delete job "$name" -n "$ns" --ignore-not-found || die "could not delete job/$name in $ns"
fi
# -n makes a manifest without a namespace land where delete and the polling look,
# and makes a manifest with another namespace fail instead of running unwatched.
apply_out=$(kubectl apply -n "$ns" -f "$manifest" 2>&1) || {
  echo "$apply_out"
  die "kubectl apply -f $manifest failed"
}
echo "$apply_out"
# Polling job/$name after applying a differently named Job would time out at best,
# and report an old Complete Job as success at worst (delete-first=false).
grep -Eq "^job(\.batch)?/${name//./\\.}[[:space:]]" <<< "$apply_out" \
  || die "$manifest did not apply a Job named '$name' (kubectl reported the output above)"

end=$((SECONDS + timeout_s))
while :; do
  conds=$(kubectl get "job/$name" -n "$ns" \
    -o jsonpath='{range .status.conditions[*]}{.type}={.status}{"\n"}{end}' 2>/dev/null || true)
  case $'\n'$conds$'\n' in
    *$'\nComplete=True\n'*)
      echo "job/$name completed"
      exit 0
      ;;
    *$'\nFailed=True\n'*)
      echo "::error::$PROG: job/$name failed"
      diagnose
      exit 1
      ;;
  esac
  [[ $SECONDS -lt $end ]] || break
  sleep "$interval"
done
echo "::error::$PROG: job/$name did not finish within ${timeout_s}s"
diagnose
exit 1
