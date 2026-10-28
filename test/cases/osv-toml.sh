#!/usr/bin/env bash
# osv-scan: scripts/check-osv-toml.sh and scripts/osv-lockfiles.sh.
set -euo pipefail
source "$ROOT/test/lib.sh"

n=0
newdir() {
  n=$((n + 1))
  dir="$TMP/d$n"
  mkdir -p "$dir"
}

# toml [WORKING_DIRECTORY] [LOCKFILES]: run check-osv-toml.sh in $dir; sets rc, out
toml() {
  rc=0
  out="$(cd "$dir" && INPUT_WORKING_DIRECTORY="${1-.}" INPUT_LOCKFILES="${2-}" \
    bash "$ROOT/scripts/check-osv-toml.sh" 2>&1)" || rc=$?
}

# --- check-osv-toml.sh --------------------------------------------------------
newdir
toml
assert_rc 0 "$rc" "no osv-scanner.toml is fine"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
# Accepted risks. Every entry needs a reason and an expiry.
#
# [[IgnoredVulns]]
# id = "GHSA-commented-out"
EOF
toml
assert_rc 0 "$rc" "a toml with only comments passes"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-aaaa-bbbb-cccc"
ignoreUntil = 2026-12-31
reason = "dev dependency only, fixed upstream in the next minor"

[[IgnoredVulns]]
id = 'GHSA-dddd-eeee-ffff'
ignoreUntil = 2026-11-30T00:00:00Z # revisit
reason = 'not reachable'

[[PackageOverrides]]
name = "left-pad"
ignore = true
EOF
toml
assert_rc 0 "$rc" "complete entries pass"
assert_contains "$out" "osv-scanner.toml ok" "and the file is reported"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-aaaa-bbbb-cccc"
reason = "waiting for the fix"
EOF
toml
assert_rc 1 "$rc" "an entry without ignoreUntil fails"
assert_contains "$out" "::error file=./osv-scanner.toml,line=1::[[IgnoredVulns]] GHSA-aaaa-bbbb-cccc needs ignoreUntil" "naming the file, line and id"
assert_not_contains "$out" "reason" "the reason was there"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-aaaa-bbbb-cccc"
ignoreUntil = 2026-12-31
EOF
toml
assert_rc 1 "$rc" "an entry without reason fails"
assert_contains "$out" "needs a non-empty reason" "and says so"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-aaaa-bbbb-cccc"
ignoreUntil = 2026-12-31
reason = ""
EOF
toml
assert_rc 1 "$rc" "an empty reason fails"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-aaaa-bbbb-cccc"
ignoreUntil = 2026-12-31
reason = "   "
EOF
toml
assert_rc 1 "$rc" "a blank reason fails"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-aaaa-bbbb-cccc"
ignoreUntil = never
reason = "x"
EOF
toml
assert_rc 1 "$rc" "an ignoreUntil that is not a date fails"
assert_contains "$out" "not a date" "and says so"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-good-good-good"
ignoreUntil = 2026-12-31
reason = "fine"

[[IgnoredVulns]]
id = "GHSA-bad0-bad0-bad0"
reason = "no date"

[[IgnoredVulns]]
id = "GHSA-bad1-bad1-bad1"
ignoreUntil = 2026-12-31
EOF
toml
assert_rc 1 "$rc" "one good entry does not hide bad ones"
assert_contains "$out" "line=6::[[IgnoredVulns]] GHSA-bad0-bad0-bad0 needs ignoreUntil" "the second entry is reported at its line"
assert_contains "$out" "line=10::[[IgnoredVulns]] GHSA-bad1-bad1-bad1 needs a non-empty reason" "and so is the third"
assert_not_contains "$out" "GHSA-good-good-good" "the good one is not"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-aaaa-bbbb-cccc"
ignoreUntil = 2026-12-31
reason = """
Accepted until the upstream fix ships.
[[IgnoredVulns]]
id = "not-an-entry-this-is-prose"
"""
EOF
toml
assert_rc 0 "$rc" "a multi-line reason counts as a reason and its text is not parsed"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
IgnoredVulns = [{ id = "GHSA-aaaa-bbbb-cccc" }]
EOF
toml
assert_rc 1 "$rc" "IgnoredVulns written as an inline array cannot be checked and fails"

newdir
cat > "$dir/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-aaaa-bbbb-cccc"
ignoreUntil = 2026-12-31
reason = "ok"
EOF
printf '[[IgnoredVulns]]\r\nid = "GHSA-crlf"\r\nignoreUntil = 2026-12-31\r\nreason = "ok"\r\n' > "$dir/osv-scanner.toml"
toml
assert_rc 0 "$rc" "CRLF line endings work"

newdir
printf '\xef\xbb\xbf[[IgnoredVulns]]\nid = "GHSA-bom"\nreason = "no date"\n' > "$dir/osv-scanner.toml"
toml
assert_rc 1 "$rc" "a UTF-8 BOM does not hide the first [[IgnoredVulns]] entry"
assert_contains "$out" "GHSA-bom needs ignoreUntil" "and it is checked like any other"

# the scanner loads the toml next to the lockfile
newdir
mkdir -p "$dir/sub"
touch "$dir/sub/pnpm-lock.yaml"
cat > "$dir/sub/osv-scanner.toml" <<'EOF'
[[IgnoredVulns]]
id = "GHSA-sub-sub-sub"
reason = "no date"
EOF
toml . ""
assert_rc 0 "$rc" "a toml in a subdirectory is not read when no lockfile lives there"
toml . "sub/pnpm-lock.yaml"
assert_rc 1 "$rc" "it is read once a lockfile in that subdirectory is scanned"
assert_contains "$out" "file=sub/osv-scanner.toml" "reported with its path"
toml sub "sub/pnpm-lock.yaml"
assert_rc 1 "$rc" "working-directory and lockfile in the same directory is checked (once)"
assert_eq "$(printf '%s\n' "$out" | grep -c '::error')" "1" "and reported once"

# a lockfile path with a space (working-directory "my app") is one path, not two
newdir
mkdir -p "$dir/my app/sub"
touch "$dir/my app/sub/pnpm-lock.yaml"
printf '[[IgnoredVulns]]\nid = "GHSA-space"\nreason = "no date"\n' > "$dir/my app/sub/osv-scanner.toml"
toml "my app" "my app/sub/pnpm-lock.yaml"
assert_rc 1 "$rc" "a toml next to a lockfile whose path has a space is still checked"
assert_contains "$out" "file=my app/sub/osv-scanner.toml" "reported with its path"
toml "my app" $'my app/sub/pnpm-lock.yaml\r\n'
assert_rc 1 "$rc" "a CRLF list of resolved lockfiles is read too"

# --- osv-lockfiles.sh ------------------------------------------------------------
# lockfiles [LOCKFILES] [WORKING_DIRECTORY] [FAIL]: sets rc, out, outputs
lockfiles() {
  : > "$TMP/gh-output"
  rc=0
  out="$(cd "$dir" && GITHUB_OUTPUT="$TMP/gh-output" INPUT_LOCKFILES="${1-}" INPUT_WORKING_DIRECTORY="${2-.}" \
    INPUT_FAIL="${3-true}" bash "$ROOT/scripts/osv-lockfiles.sh" 2>&1)" || rc=$?
  outputs="$(cat "$TMP/gh-output")"
}

newdir
touch "$dir/pnpm-lock.yaml" "$dir/composer.lock" "$dir/yarn.lock"
lockfiles
assert_rc 0 "$rc" "autodetect succeeds"
assert_eq "$outputs" "found=true
files<<OSV_EOF
pnpm-lock.yaml
composer.lock
OSV_EOF
scan-args<<OSV_EOF
--lockfile=pnpm-lock.yaml
--lockfile=composer.lock
OSV_EOF" "autodetect finds the known lockfile names at the root, in the scanner's one-argument-per-line format"

newdir
mkdir -p "$dir/client"
touch "$dir/Cargo.lock" "$dir/client/package-lock.json"
lockfiles "Cargo.lock
client/package-lock.json"
assert_rc 0 "$rc" "a multi-line list succeeds"
assert_contains "$outputs" "--lockfile=Cargo.lock
--lockfile=client/package-lock.json" "with one scan argument per line"

lockfiles "Cargo.lock client/package-lock.json"
assert_rc 0 "$rc" "a space separated list succeeds as well"
assert_contains "$outputs" "--lockfile=client/package-lock.json" "with the same arguments"

lockfiles "./Cargo.lock"
assert_contains "$outputs" "--lockfile=Cargo.lock" "a leading ./ is dropped"

lockfiles $'Cargo.lock\r\nclient/package-lock.json\r\n'
assert_rc 0 "$rc" "a CRLF lockfiles list works (a trailing CR must not end up in the path)"
assert_contains "$outputs" "--lockfile=client/package-lock.json
OSV_EOF" "and the paths are clean"

lockfiles "" $'client\nfound=false'
assert_rc 1 "$rc" "a working-directory with a newline cannot add lines to the outputs"
assert_eq "$outputs" "" "and writes nothing"

lockfiles "Cargo.lock nope/package-lock.json"
assert_rc 1 "$rc" "a listed lockfile that does not exist fails"
assert_contains "$out" "lockfile 'nope/package-lock.json' does not exist" "and is named"
assert_eq "$outputs" "" "without outputs"

lockfiles "Cargo.lock" client
assert_rc 1 "$rc" "paths are relative to working-directory"

touch "$dir/client/pnpm-lock.yaml"
lockfiles "" client
assert_rc 0 "$rc" "autodetect looks in working-directory"
assert_contains "$outputs" "--lockfile=client/pnpm-lock.yaml" "and prefixes the path with it"
lockfiles "package-lock.json" ./client/
assert_contains "$outputs" "--lockfile=client/package-lock.json" "./client/ is normalised"

for bad in "--format=sarif" "/etc/passwd" "../x/pnpm-lock.yaml" "a/../../b.lock"; do
  lockfiles "$bad"
  assert_rc 1 "$rc" "'$bad' is rejected"
done

# an autodetect miss is a notice, not a failure
newdir
touch "$dir/yarn.lock"
lockfiles
assert_rc 0 "$rc" "no lockfile succeeds"
assert_contains "$out" "::notice::osv-scan: no lockfile found" "with a notice"
assert_eq "$outputs" "found=false
files=
scan-args=" "and found=false"

lockfiles "" . maybe
assert_rc 1 "$rc" "fail must be true or false"
lockfiles "" . false
assert_rc 0 "$rc" "fail=false is accepted"
