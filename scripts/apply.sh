#!/usr/bin/env bash
# k8s-apply: refuse Secrets, server-side dry run, apply, record the workloads
# that were applied so k8s-rollout knows what to wait for.
#
# Inputs (env): INPUT_PATHS, INPUT_EXCLUDE, INPUT_DRY_RUN_FIRST
# shellcheck disable=SC2154  # arrays are filled through namerefs in k8s-lib.sh
set -euo pipefail
PROG=k8s-apply
# shellcheck source=k8s-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/k8s-lib.sh"

dry_first=${INPUT_DRY_RUN_FIRST:-true}
lines_to_array paths "${INPUT_PATHS:-}"
lines_to_array excludes "${INPUT_EXCLUDE:-}"

[[ ${#paths[@]} -gt 0 ]] || die "paths is empty"
case $dry_first in true | false) ;; *) die "dry-run-first must be 'true' or 'false', got '$dry_first'" ;; esac

expand_targets candidates "${paths[@]}"

# Exclude globs match the path as listed (leading ./ ignored) or just the file name.
files=()
used=()
for i in "${!excludes[@]}"; do used[i]=0; done
for f in "${candidates[@]}"; do
  n=${f#./}
  skip=0
  for i in "${!excludes[@]}"; do
    g=${excludes[$i]#./}
    # shellcheck disable=SC2053  # glob match is the point
    if [[ $n == $g || ${n##*/} == $g ]]; then
      used[i]=1
      skip=1
    fi
  done
  if [[ $skip -eq 1 ]]; then echo "excluded: $f"; else files+=("$f"); fi
done
# An exclude that matches nothing usually means a renamed manifest, which would
# then be applied too early (for example a Deployment before its migration Job).
for i in "${!excludes[@]}"; do
  [[ ${used[$i]} -eq 1 ]] || die "exclude '${excludes[$i]}' matched no file in paths"
done
# Deduplicate, keeping the first occurrence (and therefore the sorted order).
declare -A seen=()
unique=()
for f in "${files[@]}"; do
  if [[ -z ${seen[$f]:-} ]]; then
    seen[$f]=1
    unique+=("$f")
  fi
done
files=("${unique[@]}")
[[ ${#files[@]} -gt 0 ]] || die "nothing left to apply after exclude"

# Any document of kind Secret, at any nesting, in plain YAML, flow YAML or JSON.
# Full-line and trailing comments are skipped; a string that merely contains the
# text "kind: Secret" is refused too (fail closed).
secret_re=$'(^|[[{,[:space:]-])["\']?kind["\']?[[:space:]]*:[[:space:]]*["\']?Secret["\']?[[:space:]]*($|[],}#])'
found_secret=0
for f in "${files[@]}"; do
  n=0
  while IFS= read -r line || [[ -n $line ]]; do
    n=$((n + 1))
    # A byte order mark (Windows editors) is skipped by the YAML parser but would hide line 1 from ^.
    if [[ $n -eq 1 ]]; then line=${line#$'\xEF\xBB\xBF'}; fi
    if [[ $line =~ ^[[:space:]]*# ]]; then continue; fi
    body=${line%%[[:space:]]#*}
    if [[ $body =~ $secret_re ]]; then
      echo "::error file=$f,line=$n::$PROG: kind: Secret is not applied from CI (manage Secrets outside this pipeline)"
      found_secret=1
    fi
  done < "$f"
done
[[ $found_secret -eq 0 ]] || die "refusing to apply: a manifest contains kind: Secret"

args=()
echo "applying ${#files[@]} file(s):"
for f in "${files[@]}"; do
  echo "  $f"
  args+=(-f "$f")
done

if [[ $dry_first == true ]]; then
  echo "server-side dry run"
  kubectl apply --dry-run=server "${args[@]}" || die "server-side dry run failed, nothing was applied"
fi

wl=$(workloads_file)
mkdir -p "$(dirname "$wl")"
: >> "$wl"
out=$(mktemp "$(dirname "$wl")/k8s-apply-out.XXXXXX")
rc=0
kubectl apply "${args[@]}" 2>&1 | tee "$out" || rc=${PIPESTATUS[0]}
[[ $rc -eq 0 ]] || die "kubectl apply failed (exit $rc)"

# "deployment.apps/foo configured", "statefulset.apps/db created", "daemonset.apps/x unchanged"
wl_re='^(deployment|statefulset|daemonset)(\.[a-z0-9.-]+)?/([a-z0-9][a-z0-9.-]*)[[:space:]]+(created|configured|unchanged)([[:space:]]|$)'
recorded=0
while IFS= read -r line || [[ -n $line ]]; do
  if [[ $line =~ $wl_re ]]; then
    echo "${BASH_REMATCH[1]}/${BASH_REMATCH[3]}" >> "$wl"
    recorded=$((recorded + 1))
  fi
done < "$out"
rm -f "$out"
echo "recorded $recorded workload line(s) in $wl for k8s-rollout"
