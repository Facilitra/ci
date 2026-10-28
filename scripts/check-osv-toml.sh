#!/usr/bin/env bash
# osv-scan: every [[IgnoredVulns]] entry of an osv-scanner.toml needs a valid
# ignoreUntil date and a non-empty reason, so an accepted risk always expires.
# Checks osv-scanner.toml in the working directory and next to each lockfile
# (where the scanner auto-loads it).
# Inputs (env): INPUT_WORKING_DIRECTORY, INPUT_LOCKFILES (the RESOLVED lockfile
# paths relative to the workspace, one per line; may be empty)
set -euo pipefail

wd="${INPUT_WORKING_DIRECTORY:-.}"
while [[ "$wd" == ./* ]]; do wd="${wd#./}"; done
wd="${wd%/}"
[[ -n "$wd" ]] || wd=.
dirs="$wd"
# One path per line, never word-split: a path may hold a space.
while IFS= read -r lf || [[ -n "$lf" ]]; do
  lf="${lf%$'\r'}"
  [[ -n "$lf" ]] || continue
  dirs+=$'\n'"$(dirname -- "$lf")"
done <<< "${INPUT_LOCKFILES:-}"

bad=0
seen=$'\n'
while IFS= read -r d; do
  [[ "$seen" == *$'\n'"$d"$'\n'* ]] && continue
  seen+="$d"$'\n'
  f="$d/osv-scanner.toml"
  [[ -f "$f" ]] || continue
  # The scanner's TOML parser accepts a UTF-8 BOM, so the checker must see through it too.
  if awk -v f="$f" -v bom=$'\xef\xbb\xbf' '
    function emit(line, msg) {
      printf "::error file=%s,line=%d::%s\n", f, line, msg
      bad = 1
    }
    function flush() {
      if (!inentry) return
      if (!hasdate) emit(start, "[[IgnoredVulns]] " id " needs ignoreUntil (YYYY-MM-DD)")
      else if (!validdate) emit(start, "[[IgnoredVulns]] " id " has an ignoreUntil that is not a date")
      if (!hasreason) emit(start, "[[IgnoredVulns]] " id " needs a non-empty reason")
      inentry = 0
    }
    {
      line = $0
      sub(/\r$/, "", line)
      if (NR == 1 && index(line, bom) == 1) line = substr(line, length(bom) + 1)
      if (inml) {
        if (index(line, mlq)) inml = 0
        next
      }
      if (line ~ /^[ \t]*#/) next
      if (line ~ /^[ \t]*\[\[[ \t]*IgnoredVulns[ \t]*\]\]/) {
        flush()
        inentry = 1; start = NR; id = "(no id)"; hasdate = 0; validdate = 0; hasreason = 0
        next
      }
      if (line ~ /^[ \t]*\[/) {
        flush()
        if (line ~ /^[ \t]*\[[ \t]*IgnoredVulns/) emit(NR, "write IgnoredVulns as [[IgnoredVulns]] tables so each entry can be checked")
        next
      }
      if (line ~ /^[ \t]*IgnoredVulns[ \t]*=/) emit(NR, "write IgnoredVulns as [[IgnoredVulns]] tables so each entry can be checked")
      if (!match(line, /^[ \t]*[A-Za-z_][A-Za-z0-9_-]*[ \t]*=[ \t]*/)) next
      key = substr(line, 1, RLENGTH)
      val = substr(line, RLENGTH + 1)
      sub(/^[ \t]+/, "", key); sub(/[ \t]*=[ \t]*$/, "", key)
      q = substr(val, 1, 3)
      multi = (q == "\"\"\"" || q == "\047\047\047")
      if (multi && index(substr(val, 4), q) == 0) { inml = 1; mlq = q }
      if (!inentry) next
      if (key == "id") { id = val; gsub(/["\047]/, "", id); sub(/[ \t]*#.*$/, "", id) }
      else if (key == "ignoreUntil") {
        hasdate = 1
        if (val ~ /^["\047]?[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) validdate = 1
      }
      else if (key == "reason") {
        if (multi || val ~ /^"[ \t]*[^" \t]/ || val ~ /^\047[ \t]*[^\047 \t]/) hasreason = 1
      }
    }
    END { flush(); exit bad }
  ' "$f"; then
    echo "check-osv-toml: $f ok"
  else
    bad=1
  fi
done <<< "$dirs"

exit "$bad"
