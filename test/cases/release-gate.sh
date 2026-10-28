#!/usr/bin/env bash
# scripts/release-gate.sh against the fake gh (test/fakebin/gh).
set -euo pipefail
source "$ROOT/test/lib.sh"

SHA=1111111111111111111111111111111111111111
TIP=2222222222222222222222222222222222222222
work="$TMP/work"

# fresh: new working directory and a fake gh whose answers describe a healthy release
fresh() {
  rm -rf "$work" "$FAKE_DIR"
  mkdir -p "$work" "$FAKE_DIR"
  : > "$FAKE_LOG"
  printf '{ "name": "example-app", "version": "1.2.3" }\n' > "$work/package.json"
  echo "$SHA" > "$FAKE_DIR/api-commit"
  echo main > "$FAKE_DIR/api-default-branch"
  echo "$TIP" > "$FAKE_DIR/api-branch"
  echo ahead > "$FAKE_DIR/api-compare"
  echo 4242 > "$FAKE_DIR/run-list"
  echo 0 > "$FAKE_DIR/run-watch-rc"
}

# gate [VAR=value ...]: run release-gate.sh in $work with the defaults below, overridable; sets rc, out, log
gate() {
  rc=0
  out="$(cd "$work" && env INPUT_TAG=v1.2.3 INPUT_VERSION_FILES=package.json:version INPUT_CI_WORKFLOW=ci.yml \
    INPUT_BRANCH= INPUT_WAIT_SECONDS=0 INPUT_TOKEN=test-token GITHUB_REPOSITORY=example-org/example-app \
    RELEASE_GATE_POLL_SECONDS=0 "$@" bash "$ROOT/scripts/release-gate.sh" 2>&1)" || rc=$?
  log="$(cat "$FAKE_LOG")"
}

fresh
gate
assert_rc 0 "$rc" "healthy release passes"
assert_contains "$out" "release-gate: v1.2.3 ok" "and prints a summary"
assert_contains "$log" "gh api repos/example-org/example-app/commits/refs/tags/v1.2.3" "resolves the tag to a commit as refs/tags/, so a branch of the same name cannot be meant"
assert_contains "$log" "gh api repos/example-org/example-app/branches/main" "compares with the default branch head"
assert_contains "$log" "gh api repos/example-org/example-app/compare/$SHA...$TIP" "using sha against sha"
assert_contains "$log" "gh run list --workflow ci.yml --commit $SHA --event push" "looks for a push run of the CI workflow on that commit"
assert_contains "$log" "gh run watch 4242 --exit-status" "watches it with --exit-status"
assert_contains "$(cat "$FAKE_DIR/gh-env")" "GH_TOKEN=test-token GH_REPO=example-org/example-app" "gh gets the token and the repository"

# 1. tag format (nothing may touch the API)
for bad in 1.2.3 v1.2 v1.2.3.4 v1.2.3-rc.1 v01.2.3 latest v1 "" 'v1.2.3; echo' 'v1.2.3 v1.2.4'; do
  fresh
  gate INPUT_TAG="$bad"
  assert_rc 1 "$rc" "tag '$bad' is rejected"
  assert_eq "$log" "" "tag '$bad' made no gh call"
done
fresh
gate INPUT_TAG=v10.0.0 INPUT_VERSION_FILES=
assert_contains "$out" "no version-files given" "an empty version-files list only warns"

# a tag that carries a CR/LF (a dispatch input) must not smuggle a workflow command into the log
fresh
gate INPUT_TAG=$'v1.2.3\n::warning::INJECTED'
assert_rc 1 "$rc" "a tag with a newline is rejected"
assert_eq "$(grep -c '^::warning::' <<< "$out" || true)" "0" "and no log line starts with an injected workflow command"
assert_eq "$log" "" "without a gh call"

# 2. version files
fresh
printf '{ "version": "1.2.4" }\n' > "$work/package.json"
gate
assert_rc 1 "$rc" "a version file that differs from the tag fails"
assert_contains "$out" "package.json (version) is '1.2.4', the tag says '1.2.3'" "naming file, value and tag"
assert_eq "$log" "" "before any gh call"

fresh
gate INPUT_VERSION_FILES=package.json
assert_rc 0 "$rc" "a path without :jsonpath reads .version"

fresh
printf '{ "manifest_version": 3, "version": "1.2.3" }\n' > "$work/manifest.json"
printf '{ "name": "x", "metadata": { "release": { "id": "1.2.3" } } }\n' > "$work/meta.json"
gate INPUT_VERSION_FILES="package.json:version
manifest.json:version
meta.json:metadata.release.id"
assert_rc 0 "$rc" "several files, one per line, with a nested JSON path"
gate INPUT_VERSION_FILES="package.json manifest.json:.version"
assert_rc 0 "$rc" "space separated and a leading dot in the path also work"

printf '{ "version": "1.2.2" }\n' > "$work/manifest.json"
gate INPUT_VERSION_FILES="package.json:version
manifest.json:version"
assert_rc 1 "$rc" "the second file disagreeing fails"
assert_contains "$out" "manifest.json (version) is '1.2.2'" "naming it"

gate INPUT_VERSION_FILES="nope.json:version"
assert_rc 1 "$rc" "a missing version file fails"
assert_contains "$out" "version file 'nope.json' does not exist" "and says so"
gate INPUT_VERSION_FILES="package.json:missing.key"
assert_rc 1 "$rc" "a path that is absent fails"
printf '\xef\xbb\xbf{ "version": "1.2.3" }\n' > "$work/bom.json"
gate INPUT_VERSION_FILES="bom.json:version"
assert_rc 0 "$rc" "a JSON file with a byte order mark is read"
printf 'not json' > "$work/broken.json"
gate INPUT_VERSION_FILES="broken.json:version"
assert_rc 1 "$rc" "a file that is not JSON fails"
printf '{ "version": 123 }\n' > "$work/num.json"
gate INPUT_VERSION_FILES="num.json:version"
assert_rc 1 "$rc" "a version that is not a string fails"

# a file name that looks like a node option is only an argument
printf '{ "version": "1.2.3" }\n' > "$work/--version"
gate INPUT_VERSION_FILES="--version:version"
assert_rc 0 "$rc" "a version file called --version is read as a file, not taken as a node option"
printf '{ "version": "1.2.3" }\n' > "$work/manifest.json"
gate INPUT_VERSION_FILES=$'package.json:version\r\nmanifest.json:version\r\n'
assert_rc 0 "$rc" "a CRLF version-files list works (a trailing CR must not end up in the path)"

# the token is for gh only: node must not inherit it
mkdir -p "$work/bin"
real_node="$(command -v node)"
printf '#!/usr/bin/env bash\necho "GH_TOKEN=${GH_TOKEN-UNSET} INPUT_TOKEN=${INPUT_TOKEN-UNSET}" >> "%s/node-env"\nexec "%s" "$@"\n' "$FAKE_DIR" "$real_node" > "$work/bin/node"
chmod +x "$work/bin/node"
rm -f "$FAKE_DIR/node-env"
gate PATH="$work/bin:$PATH"
assert_rc 0 "$rc" "release passes with a node shim on the PATH"
assert_eq "$(cat "$FAKE_DIR/node-env")" "GH_TOKEN=UNSET INPUT_TOKEN=UNSET" "node runs without the token in its environment"
assert_contains "$(cat "$FAKE_DIR/gh-env")" "GH_TOKEN=test-token" "while gh still gets it"

# 3. ancestry
for st in behind diverged; do
  fresh
  echo "$st" > "$FAKE_DIR/api-compare"
  gate
  assert_rc 1 "$rc" "compare status '$st' fails"
  assert_contains "$out" "is not an ancestor of main (compare status: $st)" "explains why"
  assert_not_contains "$log" "gh run" "and never reaches the CI check"
done
fresh
echo identical > "$FAKE_DIR/api-compare"
gate
assert_rc 0 "$rc" "a tag on the branch head (identical) passes"

fresh
gate INPUT_BRANCH=release/1.x
assert_rc 0 "$rc" "an explicit branch with a slash passes"
assert_contains "$log" "gh api repos/example-org/example-app/branches/release/1.x" "that branch is used"
assert_not_contains "$log" "gh api repos/example-org/example-app --jq" "without asking for the default branch"
fresh
gate INPUT_BRANCH='main;evil'
assert_rc 1 "$rc" "a branch with odd characters is rejected"

fresh
echo 1 > "$FAKE_DIR/api-commit-rc"
gate
assert_rc 1 "$rc" "a tag gh cannot resolve fails"
assert_contains "$out" "cannot resolve tag v1.2.3" "and says so"
fresh
echo abc > "$FAKE_DIR/api-commit"
gate
assert_rc 1 "$rc" "an answer that is not a sha fails"

# the checked-out commit must be the tagged one
if command -v git > /dev/null 2>&1; then
  fresh
  git -C "$work" init -q
  git -C "$work" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m init
  head="$(git -C "$work" rev-parse HEAD)"
  echo "$head" > "$FAKE_DIR/api-commit"
  gate
  assert_rc 0 "$rc" "a checkout of the tagged commit passes"
  echo "$SHA" > "$FAKE_DIR/api-commit"
  gate
  assert_rc 1 "$rc" "a checkout of another commit fails"
  assert_contains "$out" "is not the tagged commit" "and says so"
fi

# 4. CI
fresh
: > "$FAKE_DIR/run-list"
gate
assert_rc 1 "$rc" "no CI run for the commit fails"
assert_contains "$out" "no push run of ci.yml for $SHA" "naming workflow and commit"
assert_not_contains "$log" "gh run watch" "without watching anything"

fresh
: > "$FAKE_DIR/run-list.1"
: > "$FAKE_DIR/run-list.2"
echo 777 > "$FAKE_DIR/run-list.3"
gate INPUT_WAIT_SECONDS=60
assert_rc 0 "$rc" "a run that appears while waiting is picked up"
assert_eq "$(grep -c 'gh run list' <<< "$log")" "3" "after three polls"
assert_contains "$log" "gh run watch 777 --exit-status" "and watched"

fresh
echo 1 > "$FAKE_DIR/run-watch-rc"
gate
assert_rc 1 "$rc" "a CI run that fails fails the gate"
assert_contains "$out" "ci.yml run 4242 did not pass" "and says which run"

fresh
echo 1 > "$FAKE_DIR/run-list-rc"
gate
assert_rc 1 "$rc" "gh run list failing fails closed"

fresh
gate INPUT_CI_WORKFLOW=build.yaml
assert_contains "$log" "--workflow build.yaml" "ci-workflow is passed through"
gate INPUT_CI_WORKFLOW='ci.yml; echo'
assert_rc 1 "$rc" "a ci-workflow with shell characters is rejected"

# inputs
fresh
gate INPUT_WAIT_SECONDS=soon
assert_rc 1 "$rc" "wait-seconds must be a number"
fresh
: > "$FAKE_DIR/run-list.1"
echo 777 > "$FAKE_DIR/run-list.2"
gate INPUT_WAIT_SECONDS=08
assert_rc 0 "$rc" "wait-seconds 08 is decimal: the wait still happens (bash would read it as a bad octal number)"
assert_not_contains "$out" "value too great for base" "without an arithmetic error"
gate INPUT_BRANCH=release/../main
assert_rc 1 "$rc" "a branch with .. is rejected"
gate INPUT_TOKEN=
assert_rc 1 "$rc" "an empty token fails"
gate GITHUB_REPOSITORY=nonsense
assert_rc 1 "$rc" "a malformed GITHUB_REPOSITORY fails"
