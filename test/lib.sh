#!/usr/bin/env bash
# Assertion helpers, sourced by every test/cases/*.sh (which run under
# set -euo pipefail themselves). Each failure prints the evidence to stderr
# and exits the case with status 1.

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok: %s\n' "$1"
}

# assert_eq ACTUAL EXPECTED MSG
assert_eq() {
  if [[ "$1" != "$2" ]]; then
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$2" "$1" >&2
    exit 1
  fi
  pass "$3"
}

# assert_contains HAYSTACK NEEDLE MSG (NEEDLE is a literal, not a pattern)
assert_contains() {
  if [[ "$1" != *"$2"* ]]; then
    printf 'FAIL: %s\n  missing: %s\n  in:\n%s\n' "$3" "$2" "$1" >&2
    exit 1
  fi
  pass "$3"
}

# assert_not_contains HAYSTACK NEEDLE MSG (NEEDLE is a literal, not a pattern)
assert_not_contains() {
  if [[ "$1" == *"$2"* ]]; then
    printf 'FAIL: %s\n  unexpected: %s\n  in:\n%s\n' "$3" "$2" "$1" >&2
    exit 1
  fi
  pass "$3"
}

# assert_rc EXPECTED ACTUAL MSG
assert_rc() {
  if [[ "$1" != "$2" ]]; then
    printf 'FAIL: %s\n  expected exit code: %s\n  actual exit code:   %s\n' "$3" "$1" "$2" >&2
    exit 1
  fi
  pass "$3"
}
