#!/usr/bin/env bash
# scripts/kubectl-install.sh with a fake curl (the "download" is a copy of the fake
# kubectl): RECORD-FIRST refusal, checksum verification, PATH wiring, skew warnings,
# the ~/.kube/config directory quirk.
set -euo pipefail
source "$ROOT/test/lib.sh"

OUT=''
RC=0
export RUNNER_TEMP="$TMP/runner"
export GITHUB_PATH="$TMP/github_path"
export HOME="$TMP/home"
mkdir -p "$RUNNER_TEMP" "$HOME" "$TMP/bin"

# Fake curl, local to this case: writes the payload to the --output file.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl' >> "$FAKE_LOG"; printf ' %s' "$@" >> "$FAKE_LOG"; printf '\n' >> "$FAKE_LOG"
[[ -f $FAKE_DIR/curl-rc ]] && exit "$(cat "$FAKE_DIR/curl-rc")"
out=''
while [[ $# -gt 0 ]]; do
  if [[ $1 == --output ]]; then out=$2; shift; fi
  shift
done
cp "$FAKE_PAYLOAD" "$out"
EOF
chmod +x "$TMP/bin/curl"
export PATH="$TMP/bin:$PATH"
export FAKE_PAYLOAD="$FAKEBIN/kubectl"
GOOD_SHA=$(sha256sum "$FAKEBIN/kubectl" | cut -d' ' -f1)
BIN="$RUNNER_TEMP/kubectl-bin"

reset() {
  : > "$FAKE_LOG"
  : > "$GITHUB_PATH"
  rm -rf "$FAKE_DIR"/* "$BIN" "$HOME/.kube"
}
# run_setup VERSION SHA -> OUT, RC
run_setup() {
  RC=0
  OUT=$(INPUT_KUBECTL_VERSION="$1" INPUT_KUBECTL_SHA256="$2" bash "$ROOT/scripts/kubectl-install.sh" 2>&1) || RC=$?
}
log() { cat "$FAKE_LOG"; }

# ---- RECORD-FIRST fails with instructions, before touching the network
reset
run_setup RECORD-FIRST RECORD-FIRST
assert_rc 1 "$RC" "both RECORD-FIRST"
assert_contains "$OUT" "RECORD-FIRST" "names the placeholder"
assert_contains "$OUT" "dl.k8s.io/release/<version>/bin/linux/amd64/kubectl.sha256" "says where to get the digest"
run_setup v1.31.4 RECORD-FIRST
assert_rc 1 "$RC" "digest still RECORD-FIRST"
run_setup RECORD-FIRST "$GOOD_SHA"
assert_rc 1 "$RC" "version still RECORD-FIRST"
assert_eq "$(log)" "" "nothing downloaded"
RC=0
OUT=$(bash "$ROOT/scripts/kubectl-install.sh" 2>&1) || RC=$?
assert_rc 1 "$RC" "unset inputs behave like RECORD-FIRST"

# ---- malformed pins are rejected before they reach a URL
run_setup 'v1.31.4/../../x' "$GOOD_SHA"
assert_rc 1 "$RC" "version with path characters"
run_setup latest "$GOOD_SHA"
assert_rc 1 "$RC" "version latest"
run_setup v1.31.4 "${GOOD_SHA:0:63}"
assert_rc 1 "$RC" "short digest"
run_setup v1.31.4 "$(echo "$GOOD_SHA" | tr a-f A-F)"
assert_rc 1 "$RC" "uppercase digest"
assert_eq "$(log)" "" "still nothing downloaded"

# ---- success
reset
echo 'Client Version: v1.31.4' > "$FAKE_DIR/version-out"
echo 'v1.31.2' > "$FAKE_DIR/version-server"
run_setup v1.31.4 "$GOOD_SHA"
assert_rc 0 "$RC" "install succeeds"
assert_contains "$(log)" "https://dl.k8s.io/release/v1.31.4/bin/linux/amd64/kubectl" "downloads from dl.k8s.io for linux/amd64"
assert_contains "$(log)" "--proto =https --proto-redir =https" "https only, also across redirects"
assert_contains "$(log)" "--fail" "http errors fail"
if [[ ! -x $BIN/kubectl ]]; then fail "kubectl not installed executable at $BIN/kubectl"; fi
pass "installed executable into the temp dir"
assert_eq "$(cat "$GITHUB_PATH")" "$BIN" "temp dir added to GITHUB_PATH"
if [[ -e $BIN/kubectl.part ]]; then fail "download remnant left behind"; fi
pass "no download remnant"
assert_contains "$OUT" "Client Version: v1.31.4" "client version printed"
assert_contains "$OUT" "skew 0" "server within one minor: no warning"
assert_not_contains "$OUT" "::warning" "no warnings"

# ---- skew
reset
echo 'v1.33.0' > "$FAKE_DIR/version-server"
run_setup v1.31.4 "$GOOD_SHA"
assert_rc 0 "$RC" "two minor versions apart still installs"
assert_contains "$OUT" "::warning::k8s-setup: kubectl v1.31.4 is 2 minor versions away from the cluster (v1.33.0)" "skew warning"
reset
echo 'v1.30.9+k3s1' > "$FAKE_DIR/version-server"
run_setup v1.31.4 "$GOOD_SHA"
assert_not_contains "$OUT" "::warning" "one minor apart, vendor suffix tolerated"
reset
run_setup v1.31.4 "$GOOD_SHA"
assert_rc 0 "$RC" "no cluster reachable"
assert_contains "$OUT" "skew not checked" "noted, not fatal"
reset
echo 'v1.31.2' > "$FAKE_DIR/version-server"
echo 'Client Version: v1.29.0' > "$FAKE_DIR/version-out"
run_setup v1.31.4 "$GOOD_SHA"
assert_contains "$OUT" "::warning::k8s-setup: installed kubectl reports v1.29.0 but kubectl-version is v1.31.4" "client differs from the input"

# ---- checksum mismatch: nothing is installed or put on PATH
reset
run_setup v1.31.4 "$(printf '0%.0s' {1..64})"
assert_rc 1 "$RC" "wrong digest fails"
assert_contains "$OUT" "sha256 mismatch" "says so"
if [[ -e $BIN/kubectl ]]; then fail "unverified kubectl was installed"; fi
pass "unverified binary not installed"
if [[ -e $BIN/kubectl.part ]]; then fail "unverified download left behind"; fi
pass "unverified download removed"
assert_eq "$(cat "$GITHUB_PATH")" "" "PATH untouched"

# ---- a verified binary that does not run here (wrong architecture) is not installed or put on PATH
reset
echo 126 > "$FAKE_DIR/version-rc"
run_setup v1.31.4 "$GOOD_SHA"
assert_rc 1 "$RC" "binary that does not execute"
assert_contains "$OUT" "does not run on this machine" "says so"
if [[ -e $BIN/kubectl ]]; then fail "unusable kubectl left installed"; fi
pass "unusable binary removed"
assert_eq "$(cat "$GITHUB_PATH")" "" "PATH untouched"

# ---- download failure
reset
echo 22 > "$FAKE_DIR/curl-rc"
run_setup v1.31.4 "$GOOD_SHA"
assert_rc 1 "$RC" "download failure"
assert_contains "$OUT" "download failed" "says so"
assert_eq "$(cat "$GITHUB_PATH")" "" "PATH untouched"

# ---- ~/.kube/config as a directory is removed; as a file it is left alone
reset
mkdir -p "$HOME/.kube/config/stale"
run_setup v1.31.4 "$GOOD_SHA"
assert_rc 0 "$RC" "directory at kubeconfig path"
if [[ -e $HOME/.kube/config ]]; then fail "directory still there"; fi
pass "directory at ~/.kube/config removed"
reset
mkdir -p "$HOME/.kube"
echo 'apiVersion: v1' > "$HOME/.kube/config"
run_setup v1.31.4 "$GOOD_SHA"
assert_rc 0 "$RC" "file at kubeconfig path"
assert_eq "$(cat "$HOME/.kube/config")" "apiVersion: v1" "real kubeconfig file untouched"
