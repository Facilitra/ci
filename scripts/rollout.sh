#!/usr/bin/env bash
# k8s-rollout: wait, in parallel and under one overall deadline, for the workloads
# k8s-apply recorded plus `extra`, minus `skip`. Failures print their diagnostics
# in this same step, because a bare "0 out of 1 new replicas updated" explains nothing.
#
# Inputs (env): INPUT_NAMESPACE, INPUT_TIMEOUT, INPUT_TIMEOUTS, INPUT_EXTRA,
#               INPUT_SKIP, INPUT_OPTIONAL, INPUT_DEADLINE, INPUT_DIAGNOSE
# shellcheck disable=SC2154  # arrays are filled through namerefs in k8s-lib.sh
set -euo pipefail
PROG=k8s-rollout
# shellcheck source=k8s-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/k8s-lib.sh"

ns=${INPUT_NAMESPACE:-}
deadline=${INPUT_DEADLINE:-900}
diagnose=${INPUT_DIAGNOSE:-true}
item_re='^(deployment|statefulset|daemonset)/[a-z0-9]([-a-z0-9.]*[a-z0-9])?$'

[[ $ns =~ $NAME_RE ]] || die "namespace is empty or not a valid name: '$ns'"
# 10# so a leading zero (010) is decimal, not octal.
[[ $deadline =~ ^[0-9]{1,6}$ && $((10#$deadline)) -gt 0 ]] || die "deadline must be a positive number of seconds, got '$deadline'"
deadline=$((10#$deadline))
case $diagnose in true | false) ;; *) die "diagnose must be 'true' or 'false', got '$diagnose'" ;; esac

# norm_timeout VALUE -> NORM: kubectl wants a unit; a bare number means seconds.
norm_timeout() {
  NORM=$1
  if [[ $NORM =~ ^[0-9]+$ ]]; then NORM=${NORM}s; fi
  [[ $NORM =~ ^[0-9]+[smh]$ ]] || die "not a timeout (use e.g. 300s or 5m): '$1'"
}
norm_timeout "${INPUT_TIMEOUT:-300s}"
default_timeout=$NORM

# Entries in timeouts/skip/optional may be "kind/name" or just "name".
declare -A timeouts=() skip=() optional=()
lines_to_array tmo_lines "${INPUT_TIMEOUTS:-}"
for l in "${tmo_lines[@]}"; do
  [[ $l == *=* ]] || die "timeouts line must be name=Ns, got '$l'"
  trim "${l%%=*}"; key=$TRIMMED
  [[ -n $key ]] || die "timeouts line has no name before '=': '$l'"
  trim "${l#*=}"
  norm_timeout "$TRIMMED"
  timeouts[$key]=$NORM
done
lines_to_array skip_lines "${INPUT_SKIP:-}"
for l in "${skip_lines[@]}"; do skip[$l]=1; done
lines_to_array opt_lines "${INPUT_OPTIONAL:-}"
for l in "${opt_lines[@]}"; do optional[$l]=1; done

# in_set ASSOC_NAME ITEM: ITEM is "kind/name"; the bare name matches too.
in_set() {
  local -n _set=$1
  [[ -n ${_set[$2]:-} || -n ${_set[${2#*/}]:-} ]]
}

# Wait list: recorded workloads, then extra, minus skip. Order kept, duplicates dropped.
declare -A seen=()
all=()
add() {
  if [[ -z ${seen[$1]:-} ]]; then
    seen[$1]=1
    all+=("$1")
  fi
}
wl=$(workloads_file)
if [[ -f $wl ]]; then
  while IFS= read -r l || [[ -n $l ]]; do
    trim "$l"
    if [[ -n $TRIMMED ]]; then add "$TRIMMED"; fi
  done < "$wl"
fi
lines_to_array extra_lines "${INPUT_EXTRA:-}"
for l in "${extra_lines[@]}"; do
  [[ $l == */* ]] || l=deployment/$l
  [[ $l =~ $item_re ]] || die "extra entry must be deployment|statefulset|daemonset/name, got '$l'"
  add "$l"
done

items=()
for it in "${all[@]}"; do
  if in_set skip "$it"; then
    echo "skipped: $it"
  else
    items+=("$it")
  fi
done
if [[ ${#items[@]} -eq 0 ]]; then
  if [[ ${#extra_lines[@]} -gt 0 ]]; then
    notice "nothing to wait for after skip"
    exit 0
  fi
  die "empty wait list: k8s-apply recorded no workload (did it run in this job? is everything skipped?) and extra is empty"
fi

tmo=()
for it in "${items[@]}"; do
  t=${timeouts[$it]:-${timeouts[${it#*/}]:-$default_timeout}}
  tmo+=("$t")
done
echo "waiting for ${#items[@]} workload(s) in $ns, overall deadline ${deadline}s:"
for i in "${!items[@]}"; do echo "  ${items[$i]} (timeout ${tmo[$i]})"; done

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/k8s-rollout.XXXXXX")
pids=()
for i in "${!items[@]}"; do
  # timeout(1) enforces the overall deadline per waiter; they all run in parallel.
  timeout --kill-after=10 "${deadline}s" \
    kubectl rollout status "${items[$i]}" -n "$ns" --timeout="${tmo[$i]}" > "$work/$i.log" 2>&1 &
  pids+=($!)
done

# A pod without a readinessProbe counts as ready the moment it starts, so
# "successfully rolled out" proves little about it. Checked while the waits run.
for it in "${items[@]}"; do
  [[ $it == deployment/* ]] || continue
  noprobe=$(kubectl get "$it" -n "$ns" \
    -o go-template='{{range .spec.template.spec.containers}}{{if not .readinessProbe}}{{.name}} {{end}}{{end}}' 2>/dev/null || true)
  trim "$noprobe"
  if [[ -n $TRIMMED ]]; then
    warn "$it: container(s) without a readinessProbe: $TRIMMED. Rollout status cannot tell when they can serve."
  fi
done

failed=()
warned=0
for i in "${!items[@]}"; do
  rc=0
  wait "${pids[$i]}" || rc=$?
  it=${items[$i]}
  if [[ $rc -eq 0 ]]; then
    echo "::group::ok: $it"
    cat "$work/$i.log"
    echo "::endgroup::"
    continue
  fi
  if [[ $rc -eq 124 || $rc -eq 137 ]]; then
    reason="did not finish within the overall deadline of ${deadline}s"
  else
    reason="rollout status failed (exit $rc)"
  fi
  cat "$work/$i.log"
  if in_set optional "$it"; then
    warn "optional workload $it: $reason"
    warned=$((warned + 1))
  else
    echo "::error::$PROG: $it: $reason"
    failed+=("$it")
  fi
done
rm -rf "$work"

diagnose_item() {
  local item=$1 sel pods pod cs c
  echo "::group::diagnostics: $item"
  kubectl describe "$item" -n "$ns" 2>&1 || true
  echo "::endgroup::"
  sel=$(kubectl get "$item" -n "$ns" \
    -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null || true)
  sel=${sel%,}
  if [[ -z $sel ]]; then
    echo "no selector found for $item, so no pods to inspect"
    return 0
  fi
  echo "::group::pods of $item ($sel)"
  kubectl get pods -n "$ns" -l "$sel" -o wide 2>&1 || true
  echo "::endgroup::"
  pods=$(kubectl get pods -n "$ns" -l "$sel" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
  read -ra pods <<< "$pods"
  for pod in "${pods[@]}"; do
    echo "::group::describe pod $pod"
    kubectl describe pod "$pod" -n "$ns" 2>&1 || true
    echo "::endgroup::"
    cs=$(kubectl get pod "$pod" -n "$ns" \
      -o jsonpath='{.spec.initContainers[*].name} {.spec.containers[*].name}' 2>/dev/null || true)
    read -ra cs <<< "$cs"
    for c in "${cs[@]}"; do
      echo "::group::logs $pod/$c"
      kubectl logs "$pod" -n "$ns" -c "$c" --tail=100 2>&1 || true
      echo "::endgroup::"
      echo "::group::logs $pod/$c (previous instance)"
      kubectl logs "$pod" -n "$ns" -c "$c" --previous --tail=100 2>&1 || true
      echo "::endgroup::"
    done
  done
}

if [[ ${#failed[@]} -gt 0 ]]; then
  if [[ $diagnose == true ]]; then
    for it in "${failed[@]}"; do diagnose_item "$it"; done
    echo "::group::recent events in $ns"
    kubectl get events -n "$ns" --sort-by=.lastTimestamp 2>&1 | tail -n 50 || true
    echo "::endgroup::"
  fi
  die "rollout failed: ${failed[*]}"
fi
if [[ $warned -gt 0 ]]; then
  echo "required workloads rolled out; $warned optional workload(s) did not (see warnings)"
else
  echo "all workloads rolled out"
fi
