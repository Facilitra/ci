#!/usr/bin/env bash
# release-gate: a tag may only release when
#   1. it is a plain semver tag vX.Y.Z,
#   2. every version file equals the tag without the 'v',
#   3. the tagged commit is an ancestor of the branch head (default branch
#      unless INPUT_BRANCH is set), and
#   4. a push run of the CI workflow exists for that commit and passes.
# Run it in a job with contents: read and actions: read and the tagged commit
# checked out; the version files are read from the working directory.
# Inputs (env): INPUT_TAG INPUT_VERSION_FILES (lines or words 'path[:jsonpath]',
# default jsonpath 'version') INPUT_CI_WORKFLOW INPUT_BRANCH INPUT_WAIT_SECONDS
# INPUT_TOKEN. Reads GITHUB_REPOSITORY. RELEASE_GATE_POLL_SECONDS is a test seam.
set -euo pipefail

# The tag can come from a dispatch input, so a CR or LF in it must not start a
# new line of log output that the runner would read as a workflow command.
die() {
  local msg="$1"
  printf '::error::release-gate: %s\n' "${msg//[$'\r\n']/ }"
  exit 1
}

tag="${INPUT_TAG:-}"
files="${INPUT_VERSION_FILES:-}"
files="${files//$'\r'/ }"
workflow="${INPUT_CI_WORKFLOW:-ci.yml}"
branch="${INPUT_BRANCH:-}"
wait_s="${INPUT_WAIT_SECONDS:-600}"
poll="${RELEASE_GATE_POLL_SECONDS:-10}"

[[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || die "tag '$tag' is not a plain semver tag vX.Y.Z"
version="${tag#v}"
[[ "$wait_s" =~ ^[0-9]+$ ]] || die "wait-seconds must be a number, got '$wait_s'"
wait_s=$((10#$wait_s)) # 0600 is not octal
[[ "$workflow" =~ ^[A-Za-z0-9._/-]+$ ]] || die "ci-workflow '$workflow' is not a workflow file name"
token="${INPUT_TOKEN:-}"
unset INPUT_TOKEN # only gh gets the token, not the node processes below
[[ -n "$token" ]] || die "token is empty"
repo="${GITHUB_REPOSITORY:-}"
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "GITHUB_REPOSITORY '$repo' is not owner/name"

# 2. version files
read_json='
const fs = require("fs");
let v;
try {
  v = fs.readFileSync(process.argv[1], "utf8");
  v = JSON.parse(v.charCodeAt(0) === 0xFEFF ? v.slice(1) : v);
}
catch (e) { process.exit(2); }
for (const k of process.argv[2].replace(/^\./, "").split(".")) v = v == null ? undefined : v[k];
if (typeof v !== "string") process.exit(3);
process.stdout.write(v);'
n=0
set -f
for entry in $files; do
  command -v node >/dev/null 2>&1 || die "node is not on the PATH, it is needed to read $entry"
  file="${entry%%:*}"
  path=version
  [[ "$entry" == *:* ]] && path="${entry#*:}"
  [[ -f "$file" ]] || die "version file '$file' does not exist"
  # '--' so a file name that looks like a node option is still just an argument
  got="$(node -e "$read_json" -- "$file" "$path")" || die "cannot read a string at '$path' in $file"
  [[ "$got" == "$version" ]] || die "$file ($path) is '$got', the tag says '$version'"
  n=$((n + 1))
done
set +f
if ((n == 0)); then
  echo "::warning::release-gate: no version-files given, the tag is not compared with any file"
fi

export GH_TOKEN="$token"
export GH_REPO="$repo"

# 3. the tagged commit is on the branch. refs/tags/ so a branch of the same name
# cannot be the one that gets resolved.
sha="$(gh api "repos/$repo/commits/refs/tags/$tag" --jq .sha)" || die "cannot resolve tag $tag to a commit"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "tag $tag resolved to '$sha', not a commit sha"
if checked_out="$(git rev-parse --verify -q HEAD 2>/dev/null)" && [[ "$checked_out" != "$sha" ]]; then
  die "checked-out commit $checked_out is not the tagged commit $sha, so the version files are not the tag's"
fi

if [[ -z "$branch" ]]; then
  branch="$(gh api "repos/$repo" --jq .default_branch)" || die "cannot read the default branch"
fi
[[ "$branch" =~ ^[A-Za-z0-9._/-]+$ && "$branch" != *..* ]] || die "branch '$branch' has unexpected characters"
tip="$(gh api "repos/$repo/branches/$branch" --jq .commit.sha)" || die "cannot read branch $branch"
[[ "$tip" =~ ^[0-9a-f]{40}$ ]] || die "branch $branch resolved to '$tip', not a commit sha"
status="$(gh api "repos/$repo/compare/$sha...$tip" --jq .status)" || die "cannot compare $sha with $branch"
case "$status" in
  identical | ahead) ;;
  *) die "tagged commit $sha is not an ancestor of $branch (compare status: $status)" ;;
esac

# 4. CI passed on that exact commit
deadline=$((SECONDS + wait_s))
while :; do
  run_id="$(gh run list --workflow "$workflow" --commit "$sha" --event push --limit 1 --json databaseId --jq '.[0].databaseId // empty')" ||
    die "cannot list runs of $workflow"
  [[ -z "$run_id" ]] || break
  ((SECONDS < deadline)) || die "no push run of $workflow for $sha appeared within ${wait_s}s; push the commit to $branch and let CI finish before tagging"
  echo "waiting for a push run of $workflow on $sha"
  sleep "$poll"
done
echo "watching $workflow run $run_id"
# gh's default interval is 3 seconds; poll less often.
gh run watch "$run_id" --exit-status --interval 15 || die "$workflow run $run_id did not pass for $sha"

echo "release-gate: $tag ok, $n version file(s) match, $sha is on $branch, $workflow run $run_id passed"
