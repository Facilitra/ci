#!/usr/bin/env bash
# k8s-pin: rewrite "image:" tags in manifests of the CI checkout (never committed).
# A line is rewritten when its image reference ends in /<path>:<from> (or is
# <path>:<from>) for a listed path; everything else on the line is kept byte for
# byte. Matching is literal, never a regex, because <from> may be ${GIT_SHA}.
#
# Inputs (env): INPUT_FILES, INPUT_IMAGES, INPUT_FROM, INPUT_TO
# shellcheck disable=SC2154  # arrays are filled through namerefs in k8s-lib.sh
set -euo pipefail
PROG=k8s-pin
# shellcheck source=k8s-lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/k8s-lib.sh"

from=${INPUT_FROM:-}
to=${INPUT_TO:-}
lines_to_array targets "${INPUT_FILES:-}"
lines_to_array images "${INPUT_IMAGES:-}"

[[ ${#targets[@]} -gt 0 ]] || die "files is empty"
[[ ${#images[@]} -gt 0 ]] || die "images is empty"
[[ -n $from ]] || die "from is empty"
[[ $to =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || die "to is not a valid image tag: '$to'"
[[ $from =~ ^[^[:space:]\"\'#:/@]+$ ]] || die "from must be one literal tag, got '$from'"
[[ $from != "$to" ]] || die "from and to are both '$to'"
for p in "${images[@]}"; do
  [[ $p =~ ^[a-z0-9]([a-z0-9._/-]*[a-z0-9])?$ && $p != *//* ]] || die "images entry must be a repository path without host or tag: '$p'"
done

# parse_image_line LINE: a block-style "image: ref" / "- image: ref" line, plain or
# quoted, with an optional trailing comment. Sets IMG_HEAD (text before the
# reference, with its opening quote), IMG_REF, IMG_TAIL (closing quote onwards).
# Returns 1 for any other line, so odd syntax is never half-rewritten.
parse_image_line() {
  local rest=$1
  [[ $rest =~ ^([[:space:]]*(-[[:space:]]+)?image:[[:space:]]+)(.*)$ ]] || return 1
  IMG_HEAD=${BASH_REMATCH[1]}
  rest=${BASH_REMATCH[3]}
  case $rest in
    \"*)
      rest=${rest#\"}
      [[ $rest == *\"* ]] || return 1
      IMG_HEAD+='"'
      IMG_REF=${rest%%\"*}
      IMG_TAIL=\"${rest#*\"}
      ;;
    \'*)
      rest=${rest#\'}
      [[ $rest == *\'* ]] || return 1
      IMG_HEAD+="'"
      IMG_REF=${rest%%\'*}
      IMG_TAIL=\'${rest#*\'}
      ;;
    *)
      IMG_REF=${rest%%[[:space:]]*}
      IMG_TAIL=${rest#"$IMG_REF"}
      ;;
  esac
  [[ -n $IMG_REF ]] || return 1
  [[ ${IMG_TAIL#[\"\']} =~ ^[[:space:]]*(#.*)?$ ]] || return 1
}

# split_ref REF -> REF_NAME (repository incl. host, no tag), REF_TAG ("" when
# none, "@sha256:..." for a digest). A ':' before the last '/' is a registry port.
split_ref() {
  local ref=$1
  REF_TAG=''
  if [[ $ref == *@* ]]; then
    REF_TAG="@${ref#*@}"
    ref=${ref%%@*}
  fi
  if [[ ${ref##*/} == *:* ]]; then
    if [[ -z $REF_TAG ]]; then REF_TAG=${ref##*:}; fi
    ref=${ref%:*}
  fi
  REF_NAME=$ref
}

# An "image" key position: line start (after indentation and "- "), or after { , [ in flow style.
image_key_re=$'(^[[:space:]]*(-[[:space:]]+)?|[{,[][[:space:]]*)["\']?image["\']?[[:space:]]*:'
rewritten=()
already=()
for i in "${!images[@]}"; do
  rewritten[i]=0
  already[i]=0
done
problems=()

pin_file() {
  local file=$1 line nl buf='' lineno=0 changed=0 i hit newtag body
  while :; do
    if IFS= read -r line; then
      nl=$'\n'
    elif [[ -n $line ]]; then
      nl=''
    else
      break
    fi
    lineno=$((lineno + 1))
    if parse_image_line "$line"; then
      split_ref "$IMG_REF"
      hit=0
      newtag=''
      for i in "${!images[@]}"; do
        if [[ $REF_NAME == "${images[$i]}" || $REF_NAME == */"${images[$i]}" ]]; then
          hit=1
          if [[ $REF_TAG == "$from" ]]; then
            rewritten[i]=$((rewritten[i] + 1))
            newtag=$to
          elif [[ $REF_TAG == "$to" ]]; then
            already[i]=$((already[i] + 1))
          else
            problems+=("$file:$lineno: ${images[$i]} is '${IMG_REF}' (expected :$from, or :$to when already pinned)")
          fi
        fi
      done
      if [[ -n $newtag ]]; then
        printf '  %s:%d: %s -> %s:%s\n' "$file" "$lineno" "$IMG_REF" "$REF_NAME" "$newtag"
        line="${IMG_HEAD}${REF_NAME}:${newtag}${IMG_TAIL}"
        changed=1
      elif [[ $hit -eq 1 ]]; then
        printf '  %s:%d: kept %s\n' "$file" "$lineno" "$IMG_REF"
      fi
    elif [[ ! $line =~ ^[[:space:]]*# ]]; then
      # Flow style ({image: x}), a quoted key, an anchor, a stray tail: refuse rather
      # than leave a listed image floating. Only an "image" key counts, so an
      # annotation like example.com/image:, prose in a string or a trailing comment
      # does not trip it.
      body=${line%%[[:space:]]#*}
      if [[ $body =~ $image_key_re ]]; then
        for i in "${!images[@]}"; do
          if [[ $body == *"${images[$i]}":* ]]; then
            problems+=("$file:$lineno: unsupported image: syntax mentions ${images[$i]}: $line")
          fi
        done
      fi
    fi
    buf+="$line$nl"
  done < "$file"
  if [[ $changed -eq 1 ]]; then printf '%s' "$buf" > "$file"; fi
}

expand_targets files "${targets[@]}"
[[ ${#files[@]} -gt 0 ]] || die "files expanded to nothing"
echo "pinning :$from -> :$to in ${#files[@]} file(s)"
for f in "${files[@]}"; do
  pin_file "$f"
done

echo "summary:"
for i in "${!images[@]}"; do
  printf '  %s: %d rewritten, %d already at :%s\n' "${images[$i]}" "${rewritten[$i]}" "${already[$i]}" "$to"
  # Positive assertion: a renamed manifest or image must fail here, not ship a floating tag.
  if [[ $((rewritten[i] + already[i])) -eq 0 ]]; then
    problems+=("no image line for ${images[$i]} found in the listed files")
  fi
done

if [[ ${#problems[@]} -gt 0 ]]; then
  for m in "${problems[@]}"; do
    echo "::error::$PROG: $m"
  done
  exit 1
fi
echo "k8s-pin: ok"
