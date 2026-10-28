#!/usr/bin/env bash
# scripts/guard.sh: event, branch globs, outputs.
set -euo pipefail
source "$ROOT/test/lib.sh"

SHA=0123456789abcdef0123456789abcdef01234567
work="$TMP/work"
mkdir -p "$work"
cd "$work"

# guard EVENT REF BRANCHES [PREFIX]: runs guard.sh, sets rc, out and outputs.
guard() {
  : > "$TMP/gh-output"
  rc=0
  out="$(GITHUB_EVENT_NAME="$1" GITHUB_REF="$2" GITHUB_SHA="${SHA_OVERRIDE-$SHA}" \
    GITHUB_OUTPUT="$TMP/gh-output" INPUT_BRANCHES="$3" INPUT_TAG_PREFIX="${4-}" \
    bash "$ROOT/scripts/guard.sh" 2>&1)" || rc=$?
  outputs="$(cat "$TMP/gh-output")"
}

guard push refs/heads/master master
assert_rc 0 "$rc" "push on the deploy branch passes"
assert_eq "$outputs" "ref=$SHA
sha7=0123456
tag=0123456" "outputs are the full sha, sha7 and the bare tag"

guard workflow_dispatch refs/heads/master master
assert_rc 0 "$rc" "workflow_dispatch on the deploy branch passes"

for ev in pull_request pull_request_target workflow_run schedule release; do
  guard "$ev" refs/heads/master master
  assert_rc 1 "$rc" "$ev is rejected"
  assert_contains "$out" "may not deploy" "$ev rejection says why"
  assert_eq "$outputs" "" "$ev writes no outputs"
done

guard push refs/heads/develop master
assert_rc 1 "$rc" "a non-matching branch is rejected"
assert_contains "$out" "branch 'develop' does not match" "names the branch"
guard push refs/heads/master-old master
assert_rc 1 "$rc" "a glob is anchored, master does not match master-old"
guard push refs/heads/amaster master
assert_rc 1 "$rc" "a glob is anchored, master does not match amaster"

guard push refs/tags/v1.0.0 master
assert_rc 1 "$rc" "a tag push is rejected"
guard workflow_dispatch refs/tags/v1.0.0 master
assert_rc 1 "$rc" "a dispatch from a tag is rejected"
guard push refs/pull/12/merge master
assert_rc 1 "$rc" "a pull ref is rejected"
guard push refs/heads/ master
assert_rc 1 "$rc" "an empty branch name is rejected"

guard push refs/heads/release/1.2 'release/*'
assert_rc 0 "$rc" "a branch with a slash matches release/*"
guard push refs/heads/release/1.2/hotfix 'release/*'
assert_rc 0 "$rc" "* also matches further slashes, as in bash case"
guard push refs/heads/feature/x 'release/*'
assert_rc 1 "$rc" "release/* does not match feature/x"
guard push refs/heads/release 'release/*'
assert_rc 1 "$rc" "release/* does not match the bare word release"
guard push refs/heads/feature/login/form 'feature/login/*'
assert_rc 0 "$rc" "a glob with two slashes matches"

# the glob must reach case unexpanded: a file named like the branch in the cwd
# would otherwise turn feat* into that file name
touch feature-a
guard push refs/heads/feature-b 'feat*'
assert_rc 0 "$rc" "globs are not expanded against the working directory"
rm -f feature-a

guard push refs/heads/develop 'master
develop'
assert_rc 0 "$rc" "newline separated list matches the second entry"
guard push refs/heads/develop 'master develop'
assert_rc 0 "$rc" "space separated list matches the second entry"
guard push refs/heads/main 'master develop'
assert_rc 1 "$rc" "no entry of the list matches"
guard push refs/heads/anything ''
assert_rc 1 "$rc" "an empty list is an error, not allow-all"
assert_contains "$out" "branches is empty" "says the list is empty"

guard push refs/heads/develop develop dev-
assert_rc 0 "$rc" "tag prefix run passes"
assert_contains "$outputs" "tag=dev-0123456" "the tag carries the prefix"
assert_contains "$outputs" "sha7=0123456" "sha7 has no prefix"
assert_contains "$outputs" "ref=$SHA" "ref has no prefix"

guard push refs/heads/develop develop 'dev-; rm -rf'
assert_rc 1 "$rc" "a tag prefix with shell characters is rejected"
guard push refs/heads/develop develop -dev
assert_rc 1 "$rc" "a tag prefix that cannot start a docker tag is rejected here, not at the build"
guard push refs/heads/develop develop .dev
assert_rc 1 "$rc" "a tag prefix starting with a dot is rejected"

# CRLF in the list (Windows editors): the CR must not stay glued to the last glob
guard push refs/heads/develop $'master\r\ndevelop\r\n'
assert_rc 0 "$rc" "a CRLF branches list matches"

# the event name is untrusted text in the error message: no new log line may start a workflow command
guard $'push\n::warning::INJECTED' refs/heads/master master
assert_rc 1 "$rc" "an event name with a newline is rejected"
assert_eq "$(grep -c '^::warning::' <<< "$out" || true)" "0" "and no log line starts with an injected workflow command"

SHA_OVERRIDE=abc123 guard push refs/heads/master master
assert_rc 1 "$rc" "a short GITHUB_SHA is rejected"
SHA_OVERRIDE='' guard push refs/heads/master master
assert_rc 1 "$rc" "a missing GITHUB_SHA is rejected"

guard push refs/heads/master master
assert_contains "$out" "deploy-guard: ok" "prints a summary line"
