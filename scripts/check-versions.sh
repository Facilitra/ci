#!/usr/bin/env bash
# node-setup: the Node and pnpm versions a repo declares in several places must
# agree. Compares the version file (.nvmrc) and package.json packageManager
# with each Dockerfile:
#   - node tag from 'FROM ...node:<v>', 'ARG NODE_VERSION=<v>' or any
#     'ARG <NAME>=...node:<v>'; no match means the Dockerfile takes its Node
#     from somewhere else and is skipped
#   - a less specific tag than the version file (node:22 vs 22.11.0) is a
#     warning, a different version is an error
#   - a literal 'pnpm@x' must equal packageManager (without '+sha')
# Inputs (env): INPUT_NODE_VERSION_FILE INPUT_WORKING_DIRECTORY INPUT_DOCKERFILES
set -euo pipefail
shopt -s nocasematch

wd="${INPUT_WORKING_DIRECTORY:-.}"
while [[ "$wd" == ./* ]]; do wd="${wd#./}"; done
wd="${wd%/}"
[[ -n "$wd" ]] || wd=.
at() { if [[ "$wd" == . ]]; then printf '%s' "$1"; else printf '%s/%s' "$wd" "$1"; fi; }
vfile="${INPUT_NODE_VERSION_FILE:-.nvmrc}"
dockerfiles="${INPUT_DOCKERFILES-Dockerfile .docker/Dockerfile}"
dockerfiles="${dockerfiles//$'\r'/ }"

errors=0
err() { # file line message
  printf '::error file=%s,line=%s::%s\n' "$1" "$2" "$3"
  errors=$((errors + 1))
}
warn() { printf '::warning file=%s,line=%s::%s\n' "$1" "$2" "$3"; }

nvmrc="$(at "$vfile")"
if [[ ! -f "$nvmrc" ]]; then
  printf '::error file=%s::version file not found\n' "$nvmrc"
  exit 1
fi

want=""
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"
  line="${line//[[:space:]]/}"
  if [[ -n "$line" ]]; then
    want="${line#v}"
    break
  fi
done < "$nvmrc"
if [[ ! "$want" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  printf '::error file=%s::must hold an exact version (22.11.0) or a major (22), got "%s"\n' "$nvmrc" "$want"
  exit 1
fi
IFS=. read -r -a w <<< "$want"

pm_field=""
if [[ -f "$(at package.json)" ]]; then
  pm_field="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$(at package.json)" | head -n 1 || true)"
fi
pm_pnpm=""
if [[ "$pm_field" == pnpm@* ]]; then
  pm_pnpm="${pm_field#pnpm@}"
  pm_pnpm="${pm_pnpm%%+*}"
fi

# check_node FILE LINE TAG: TAG is the text after 'node:' or the NODE_VERSION value.
check_node() {
  local f="$1" n="$2" tag="${3%%@*}" v i m
  tag="${tag#v}"
  [[ "$tag" == *'$'* ]] && return 0 # value comes from an ARG, which is checked itself
  if [[ ! "$tag" =~ ^[0-9]+(\.[0-9]+){0,2} ]]; then
    warn "$f" "$n" "node tag '$tag' is floating, cannot be compared with $want from $nvmrc"
    return 0
  fi
  v="${BASH_REMATCH[0]}"
  local d
  IFS=. read -r -a d <<< "$v"
  m=${#d[@]}
  ((${#w[@]} < m)) && m=${#w[@]}
  for ((i = 0; i < m; i++)); do
    if ((10#${d[i]} != 10#${w[i]})); then
      err "$f" "$n" "node $v does not match $want from $nvmrc"
      return 0
    fi
  done
  if ((${#d[@]} < ${#w[@]})); then
    warn "$f" "$n" "node $v is less specific than $want from $nvmrc (floating tag)"
  fi
}

check_dockerfile() {
  local f="$1" n=0 line tok image name val rest lit
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    line="${line//$'\r'/}"
    # Docker accepts a UTF-8 BOM; without this a BOM would hide the first FROM line.
    if ((n == 1)); then line="${line#$'\xef\xbb\xbf'}"; fi
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" =~ ^FROM[[:space:]]+(.*)$ ]]; then
      image=""
      set -f
      for tok in ${BASH_REMATCH[1]}; do
        [[ "$tok" == --* ]] && continue
        image="${tok%%@*}"
        break
      done
      set +f
      if [[ "$image" =~ (^|/)node:([^[:space:]]+)$ ]]; then
        check_node "$f" "$n" "${BASH_REMATCH[2]}"
      elif [[ "$image" =~ (^|/)node$ ]]; then
        check_node "$f" "$n" latest
      fi
    elif [[ "$line" =~ ^ARG[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      name="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]//[\"\']/}"
      if [[ "$name" == NODE_VERSION ]]; then
        check_node "$f" "$n" "$val"
      elif [[ "$val" =~ (^|/)node:([^[:space:]]+)$ ]]; then
        check_node "$f" "$n" "${BASH_REMATCH[2]}"
      fi
    fi

    rest="$line"
    while [[ "$rest" =~ pnpm@([0-9A-Za-z][0-9A-Za-z.+_-]*)(.*)$ ]]; do
      lit="${BASH_REMATCH[1]%%+*}"
      lit="${lit%.}"
      rest="${BASH_REMATCH[2]}"
      if [[ "$lit" != "$pm_pnpm" ]]; then
        err "$f" "$n" "pnpm@$lit does not match packageManager '${pm_field:-unset}' in $(at package.json)"
      fi
    done
  done < "$f"
}

checked=0
set -f
for df in $dockerfiles; do
  path="$(at "$df")"
  [[ -f "$path" ]] || continue
  checked=$((checked + 1))
  check_dockerfile "$path"
done
set +f

if ((errors > 0)); then
  echo "check-versions: $errors mismatch(es) against $nvmrc ($want)"
  exit 1
fi
echo "check-versions: ok, $nvmrc=$want, packageManager=${pm_field:-unset}, $checked Dockerfile(s) checked"
