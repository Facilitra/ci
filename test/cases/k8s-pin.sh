#!/usr/bin/env bash
# scripts/pin.sh: path-keyed, host-agnostic, ':' anchored image pinning with
# positive and negative assertions. Representative manifests plus inline edge cases.
set -euo pipefail
source "$ROOT/test/lib.sh"

FX="$ROOT/test/fixtures"
OUT=''
RC=0
D=''

# fresh NAME: new work dir holding a copy of the fixtures; cd's into it.
fresh() {
  D="$TMP/$1"
  mkdir -p "$D"
  cp -r "$FX/." "$D/"
  cd "$D"
}
# run_pin FILES IMAGES FROM TO -> OUT, RC
run_pin() {
  RC=0
  OUT=$(INPUT_FILES="$1" INPUT_IMAGES="$2" INPUT_FROM="$3" INPUT_TO="$4" bash "$ROOT/scripts/pin.sh" 2>&1) || RC=$?
}
count() { grep -c -- "$2" "$1" || true; }

# ---- fixture manifests: nested init container, multi-document file, Jobs, CronJob
fresh fixture-web
cp -r web web.orig
run_pin $'web/app\nweb/jobs' $'example/web\nexample/web-migrate\nexample/web-worker' latest abc1234
assert_rc 0 "$RC" "fixture manifests: pin succeeds"
assert_eq "$(count web/app/deployment.yaml 'example/web-migrate:abc1234')" 1 "initContainer image pinned"
assert_eq "$(count web/app/deployment.yaml 'example/web:abc1234')" 1 "container image pinned"
assert_eq "$(count web/app/worker.yaml 'example/web-worker:abc1234')" 1 "worker image pinned"
assert_eq "$(count web/jobs/migrate.yaml 'example/web-migrate:abc1234')" 1 "Job image pinned"
assert_eq "$(count web/jobs/nightly.yaml 'registry.example.com/mirror/tool:2.0')" 1 "unlisted CronJob image untouched"
# nothing but the three image tags may differ from the original: comments, quoting, ordering
sed -E 's#(example/(web|web-migrate|web-worker)):latest#\1:abc1234#' web.orig/app/deployment.yaml web.orig/app/worker.yaml web.orig/jobs/migrate.yaml > expected.txt
cat web/app/deployment.yaml web/app/worker.yaml web/jobs/migrate.yaml > actual.txt
if ! diff expected.txt actual.txt > diff.txt; then fail "fixture manifests: unexpected differences: $(cat diff.txt)"; fi
pass "fixture manifests: only image tags changed"
assert_contains "$OUT" "example/web: 1 rewritten" "audit trail names each path"
assert_contains "$OUT" "web/app/deployment.yaml:" "audit trail names file and line"
assert_not_contains "$OUT" "::error::" "no errors reported"

fresh fixture-api
run_pin $'api/app\napi/jobs' $'example/api\nexample/api-tools' latest abc1234
assert_rc 0 "$RC" "second fixture set: pin succeeds"
assert_eq "$(count api/app/40-deployment.yaml 'example/api:abc1234')" 1 "single-document Deployment pinned"
assert_eq "$(count api/jobs/migrate.yaml 'example/api-tools:abc1234')" 1 "Job pinned"
assert_eq "$(count api/app/30-database.yaml 'registry.example.com/mirror/db:1.0')" 1 "third-party image in a multi-document file untouched"

fresh fixture-multi
run_pin $'multi/deployment.yaml' $'example/multi' latest abc1234
assert_rc 0 "$RC" "same path in initContainer and container"
assert_eq "$(count multi/deployment.yaml 'example/multi:abc1234')" 2 "both occurrences pinned"
assert_contains "$OUT" "example/multi: 2 rewritten" "summary counts both"

# ---- host-agnostic, quoting, trailing comments, list form, other tags kept
fresh forms
cat > forms.yaml <<'EOF'
spec:
  containers:
    - image: reg-one.example.com/example/app:latest
      name: a
    - name: b
      image: "reg-two.example.com:5000/example/app:latest"   # quoted, with comment
    - name: c
      image: 'example/app:latest'
    - name: d
      image: example/app:latest # trailing comment
  # image: example/app:latest
  # - image: example/app:latest
    - name: e
      image: reg-one.example.com/example/other:latest
    - name: f
      imagePullPolicy: Always
EOF
run_pin forms.yaml example/app latest abc1234
assert_rc 0 "$RC" "host-agnostic pin succeeds"
content=$(cat forms.yaml)
assert_contains "$content" "- image: reg-one.example.com/example/app:abc1234" "list form with host"
assert_contains "$content" '      image: "reg-two.example.com:5000/example/app:abc1234"   # quoted, with comment' "quoted value, registry port and comment kept"
assert_contains "$content" "      image: 'example/app:abc1234'" "single quotes, no host"
assert_contains "$content" "      image: example/app:abc1234 # trailing comment" "unquoted with trailing comment"
assert_contains "$content" "  # image: example/app:latest" "commented-out line untouched"
assert_contains "$content" "  # - image: example/app:latest" "commented-out list line untouched"
assert_contains "$content" "example/other:latest" "other path untouched"
assert_contains "$OUT" "example/app: 4 rewritten" "four live lines rewritten, comments not counted"

# ---- text that merely contains the image string or the word image is left alone
fresh lookalikes
cat > look.yaml <<'EOF'
metadata:
  annotations:
    example.com/image: reg.example.com/example/app:latest
    note: "see image: reg.example.com/example/app:latest"
spec:
  containers:
    - name: a
      image:	reg.example.com/example/app:latest
      env:
        - name: WORKER_IMAGE
          value: reg.example.com/example/app:latest
        - name: BASE_TAG
          value: latest
      args: ["--tag", "latest"] # image: reg.example.com/example/app:latest
EOF
cp look.yaml look.orig
run_pin look.yaml example/app latest abc1234
assert_rc 0 "$RC" "annotation keys ending in image, notes, env values and comments do not trip the pin"
assert_eq "$(diff look.orig look.yaml | grep -c '^>' || true)" 1 "exactly one line changed"
assert_contains "$(cat look.yaml)" $'image:\treg.example.com/example/app:abc1234' "tab after image: kept, tag pinned"
assert_contains "$(cat look.yaml)" "          value: reg.example.com/example/app:latest" "an env value holding the image is not an image: line"
assert_contains "$(cat look.yaml)" "          value: latest" "latest elsewhere untouched"

# a quoted key, an anchor, a stray tail or a folded value cannot be rewritten, so they fail loudly
for form in '- {"name": "b", "image": "reg.example.com/example/app:latest"}' \
  '- {name: b, image: reg.example.com/example/app:latest}' \
  "- { 'image': 'reg.example.com/example/app:latest' }" \
  '"image": reg.example.com/example/app:latest' \
  'image: &img reg.example.com/example/app:latest' \
  'image: "reg.example.com/example/app:latest" junk' \
  'image: reg.example.com/example/app:latest junk'; do
  printf '      image: reg.example.com/example/app:latest\n      %s\n' "$form" > odd.yaml
  run_pin odd.yaml example/app latest abc1234
  assert_rc 1 "$RC" "refused: $form"
  assert_contains "$OUT" "odd.yaml:2: unsupported image: syntax" "names the line: $form"
done

# ---- ':' anchoring: site vs site-tools
fresh anchor
cat > deploy.yaml <<'YAML'
spec:
  initContainers:
    - name: migrate
      image: reg.example.com/example/site-tools:latest
  containers:
    - name: site
      image: reg.example.com/example/site:latest
YAML
cp deploy.yaml deploy.orig
run_pin deploy.yaml example/site latest abc1234
assert_rc 0 "$RC" "site alone pins"
content=$(cat deploy.yaml)
assert_contains "$content" "example/site:abc1234" "site pinned"
assert_contains "$content" "example/site-tools:latest" "site-tools not matched by site"

cp deploy.orig deploy.yaml
run_pin deploy.yaml example/site-tools latest abc1234
assert_rc 0 "$RC" "tools alone pins"
content=$(cat deploy.yaml)
assert_contains "$content" "example/site-tools:abc1234" "tools pinned"
assert_contains "$content" "example/site:latest" "site not matched by site-tools"

cp deploy.orig deploy.yaml
run_pin deploy.yaml $'example/site\nexample/site-tools' latest abc1234
assert_rc 0 "$RC" "both listed"
assert_eq "$(count deploy.yaml ':abc1234')" 2 "each line rewritten exactly once"

# a shorter path must not match as a suffix inside a segment
cat > seg.yaml <<'YAML'
      image: reg.example.com/foo/myapp:latest
YAML
run_pin seg.yaml app latest abc1234
assert_rc 1 "$RC" "app does not match foo/myapp (segment boundary)"
assert_contains "$OUT" "no image line for app" "positive assertion explains"

# ---- ${GIT_SHA} placeholder is compared literally, never as a pattern
fresh gitsha
cat > webapp.yaml <<'YAML'
      containers:
        - name: app
          image: reg.example.com/example/webapp:${GIT_SHA}
        - name: runner
          image: reg.example.com/example/webapp-runner:${GIT_SHA}
YAML
run_pin webapp.yaml example/webapp '${GIT_SHA}' abc1234
assert_rc 0 "$RC" "placeholder from value"
content=$(cat webapp.yaml)
assert_contains "$content" "example/webapp:abc1234" "placeholder replaced"
assert_contains "$content" 'example/webapp-runner:${GIT_SHA}' "sibling path keeps its placeholder"

# ---- already pinned lines are left alone and still satisfy the positive assertion
fresh already
cat > pinned.yaml <<'YAML'
      image: reg.example.com/example/app:abc1234
YAML
run_pin pinned.yaml example/app latest abc1234
assert_rc 0 "$RC" "already pinned: ok"
assert_contains "$OUT" "example/app: 0 rewritten, 1 already at :abc1234" "reported as already pinned"
assert_eq "$(cat pinned.yaml)" "      image: reg.example.com/example/app:abc1234" "file unchanged"

# ---- negative assertion: a listed image on another tag
fresh negative
cat > mixed.yaml <<'YAML'
spec:
  containers:
    - image: reg.example.com/example/app:latest
    - image: reg.example.com/example/app:dev-latest
YAML
run_pin mixed.yaml example/app latest abc1234
assert_rc 1 "$RC" "other tag on a listed path fails"
assert_contains "$OUT" "mixed.yaml:4:" "names file and line of the leftover"
assert_contains "$OUT" "::error::k8s-pin:" "reported as an error annotation"

# a registry port without a tag is an implicit :latest, not something to guess about
printf '      image: reg.example.com:5000/example/app\n' > notag.yaml
run_pin notag.yaml example/app latest abc1234
assert_rc 1 "$RC" "untagged reference on a listed path fails"
assert_contains "$OUT" "notag.yaml:1:" "names the line"

# a single-character repository path is still a path
printf '      image: reg.example.com/x:latest\n' > one.yaml
run_pin one.yaml x latest abc1234
assert_rc 0 "$RC" "single-character path"
assert_contains "$(cat one.yaml)" "reg.example.com/x:abc1234" "and it is pinned"

# digest-pinned listed image cannot be pinned
cat > digest.yaml <<'YAML'
      image: reg.example.com/example/app@sha256:0000000000000000000000000000000000000000000000000000000000000000
YAML
run_pin digest.yaml example/app latest abc1234
assert_rc 1 "$RC" "digest reference on a listed path fails"

# flow style is not rewritten, so it must not pass silently
cat > flow.yaml <<'YAML'
      - {name: a, image: reg.example.com/example/app:latest}
YAML
run_pin flow.yaml example/app latest abc1234
assert_rc 1 "$RC" "flow-style image on a listed path fails"
assert_contains "$OUT" "unsupported image: syntax" "says why"

# ---- positive assertion: listed path absent everywhere
fresh positive
run_pin $'web/app' $'example/web\nexample/does-not-exist' latest abc1234
assert_rc 1 "$RC" "path with no image line fails"
assert_contains "$OUT" "no image line for example/does-not-exist" "names the missing path"

# ---- directories: sorted, one level, yaml/yml only; paths with spaces
fresh dirs
mkdir -p "with space/sub" "with space/dev"
cat > "with space/a b.yaml" <<'YAML'
      image: reg.example.com/example/app:latest
YAML
cat > "with space/c.yml" <<'YAML'
      image: reg.example.com/example/app:latest
YAML
cat > "with space/note.txt" <<'YAML'
      image: reg.example.com/example/app:latest
YAML
cat > "with space/sub/deep.yaml" <<'YAML'
      image: reg.example.com/example/app:latest
YAML
cat > "with space/x.yaml.example" <<'YAML'
      image: reg.example.com/example/app:latest
YAML
run_pin "with space/" example/app latest abc1234
assert_rc 0 "$RC" "directory with a space in its name"
assert_contains "$(cat "with space/a b.yaml")" ":abc1234" "yaml in dir pinned (name with space)"
assert_contains "$(cat "with space/c.yml")" ":abc1234" "yml in dir pinned"
assert_contains "$(cat "with space/note.txt")" ":latest" "non-yaml file untouched"
assert_contains "$(cat "with space/sub/deep.yaml")" ":latest" "sub-directory not recursed"
assert_contains "$(cat "with space/x.yaml.example")" ":latest" ".example file untouched"

# ---- byte fidelity: no trailing newline, CRLF
fresh bytes
printf 'a: 1\n      image: reg.example.com/example/app:latest' > nonl.yaml
run_pin nonl.yaml example/app latest abc1234
assert_rc 0 "$RC" "file without trailing newline"
assert_eq "$(od -An -c nonl.yaml | tr -d ' \n')" "$(printf 'a:1\n      image:reg.example.com/example/app:abc1234' | od -An -c | tr -d ' \n')" "still no trailing newline"
printf 'x: 1\r\n      image: reg.example.com/example/app:latest\r\n' > crlf.yaml
run_pin crlf.yaml example/app latest abc1234
assert_rc 0 "$RC" "CRLF file"
assert_eq "$(od -An -c crlf.yaml | tr -d ' \n')" "$(printf 'x:1\r\n      image:reg.example.com/example/app:abc1234\r\n' | od -An -c | tr -d ' \n')" "CRLF preserved"

printf '      image: "reg.example.com/example/app:latest"  # c\r\n      image: reg.example.com/example/other:latest\t# t\r\n' > crlf2.yaml
run_pin crlf2.yaml example/app latest abc1234
assert_rc 0 "$RC" "CRLF with quotes, comments and a tab"
assert_eq "$(od -An -c crlf2.yaml | tr -d ' \n')" "$(printf '      image:"reg.example.com/example/app:abc1234"#c\r\n      image:reg.example.com/example/other:latest\t#t\r\n' | od -An -c | tr -d ' \n')" "bytes preserved"

# ---- multi-document file where one document is a Secret: pin does not care, it only edits image lines
printf 'kind: Secret\nmetadata:\n  name: x\n---\nspec:\n  containers:\n    - image: reg.example.com/example/app:latest\n' > mixed-secret.yaml
run_pin mixed-secret.yaml example/app latest abc1234
assert_rc 0 "$RC" "a Secret document in the same file is left to k8s-apply"

# ---- input validation
fresh inputs
run_pin '' example/app latest abc1234
assert_rc 1 "$RC" "empty files"
run_pin pinned.yaml '' latest abc1234
assert_rc 1 "$RC" "empty images"
cat > pinned.yaml <<'YAML'
      image: reg.example.com/example/app:latest
YAML
run_pin pinned.yaml example/app latest 'bad tag'
assert_rc 1 "$RC" "invalid to tag"
run_pin pinned.yaml example/app abc1234 abc1234
assert_rc 1 "$RC" "from equal to"
run_pin missing.yaml example/app latest abc1234
assert_rc 1 "$RC" "missing file"
assert_contains "$OUT" "path not found: missing.yaml" "names the missing file"
run_pin pinned.yaml 'reg.example.com/example/app:latest' latest abc1234
assert_rc 1 "$RC" "images entry with host and tag rejected"
run_pin pinned.yaml 'Example/App' latest abc1234
assert_rc 1 "$RC" "images entry must be lowercase path"

# ---- never touches the cluster
assert_eq "$(cat "$FAKE_LOG")" "" "pin never calls kubectl"
