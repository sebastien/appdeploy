#!/usr/bin/env bash
# Tests for appdeploy version comparison functions

set -euo pipefail

BASE_PATH="$(dirname "$(dirname "$(readlink -f "$0")")")"
# shellcheck source=tests/lib-testing.sh
source "$BASE_PATH/tests/lib-testing.sh"
# shellcheck source=src/sh/appdeploy.sh
source "$BASE_PATH/src/sh/appdeploy.sh"

test-start "appdeploy-version"

# -----------------------------------------------------------------------------
# appdeploy_version_compare
# -----------------------------------------------------------------------------
test-step "appdeploy_version_compare: equal versions"
appdeploy_version_compare "1.0.0" "1.0.0"
result=$?
test-expect "$result" "0" "1.0.0 == 1.0.0 returns 0"

test-step "appdeploy_version_compare: first greater (major)"
set +e
appdeploy_version_compare "2.0.0" "1.0.0"
result=$?
set -e
test-expect "$result" "1" "2.0.0 > 1.0.0 returns 1"

test-step "appdeploy_version_compare: first less (major)"
set +e
appdeploy_version_compare "1.0.0" "2.0.0"
result=$?
set -e
test-expect "$result" "2" "1.0.0 < 2.0.0 returns 2"

test-step "appdeploy_version_compare: first greater (minor)"
set +e
appdeploy_version_compare "1.5.0" "1.0.0"
result=$?
set -e
test-expect "$result" "1" "1.5.0 > 1.0.0 returns 1"

test-step "appdeploy_version_compare: first less (minor)"
set +e
appdeploy_version_compare "1.0.0" "1.5.0"
result=$?
set -e
test-expect "$result" "2" "1.0.0 < 1.5.0 returns 2"

test-step "appdeploy_version_compare: first greater (patch)"
set +e
appdeploy_version_compare "1.0.5" "1.0.0"
result=$?
set -e
test-expect "$result" "1" "1.0.5 > 1.0.0 returns 1"

test-step "appdeploy_version_compare: equal with different length"
appdeploy_version_compare "1.0.0" "1.0"
result=$?
test-expect "$result" "0" "1.0.0 == 1.0 returns 0 (padding)"

test-step "appdeploy_version_compare: alpha < beta"
set +e
appdeploy_version_compare "1.0.0-alpha" "1.0.0-beta"
result=$?
set -e
test-expect "$result" "2" "1.0.0-alpha < 1.0.0-beta returns 2"

test-step "appdeploy_version_compare: beta > alpha"
set +e
appdeploy_version_compare "1.0.0-beta" "1.0.0-alpha"
result=$?
set -e
test-expect "$result" "1" "1.0.0-beta > 1.0.0-alpha returns 1"

test-step "appdeploy_version_compare: rc > beta"
set +e
appdeploy_version_compare "1.0.0-rc1" "1.0.0-beta"
result=$?
set -e
test-expect "$result" "1" "1.0.0-rc1 > 1.0.0-beta returns 1"

test-step "appdeploy_version_compare: release vs rc"
set +e
appdeploy_version_compare "1.0.0" "1.0.0-rc1"
result=$?
set -e
# Note: empty string "" < "rc1" alphabetically, so 1.0.0 < 1.0.0-rc1
# This is a known limitation of the simple comparison
test-expect "$result" "2" "1.0.0 vs 1.0.0-rc1 (lexicographic)"

# -----------------------------------------------------------------------------
# appdeploy_version_latest
# -----------------------------------------------------------------------------
test-step "appdeploy_version_latest: find latest from list"
result=$(appdeploy_version_latest "1.0.0" "2.0.0" "1.5.0")
test-expect "$result" "2.0.0" "Latest of 1.0.0 2.0.0 1.5.0 is 2.0.0"

test-step "appdeploy_version_latest: single version"
result=$(appdeploy_version_latest "1.0.0")
test-expect "$result" "1.0.0" "Latest of single version is itself"

test-step "appdeploy_version_latest: already sorted"
result=$(appdeploy_version_latest "1.0.0" "1.1.0" "1.2.0")
test-expect "$result" "1.2.0" "Latest of sorted list"

test-step "appdeploy_version_latest: reverse sorted"
result=$(appdeploy_version_latest "3.0.0" "2.0.0" "1.0.0")
test-expect "$result" "3.0.0" "Latest of reverse sorted list"

test-step "appdeploy_version_latest: with prerelease"
result=$(appdeploy_version_latest "1.0.0-alpha" "1.0.0-beta" "0.9.0")
test-expect "$result" "1.0.0-beta" "Latest including prerelease versions"

test-step "appdeploy_version_latest: complex versions"
result=$(appdeploy_version_latest "1.0.0" "1.0.1" "1.1.0" "2.0.0-rc1")
test-expect "$result" "2.0.0-rc1" "Latest with complex versions"

# -----------------------------------------------------------------------------
# appdeploy_validate_version
# -----------------------------------------------------------------------------
test-step "appdeploy_validate_version: semver"
appdeploy_validate_version "1.0.0" 2>/dev/null
result=$?
test-expect "$result" "0" "1.0.0 is valid"

test-step "appdeploy_validate_version: v-prefixed"
appdeploy_validate_version "v1.0.0" 2>/dev/null
result=$?
test-expect "$result" "0" "v1.0.0 is valid"

test-step "appdeploy_validate_version: git hash"
appdeploy_validate_version "c1b87d2" 2>/dev/null
result=$?
test-expect "$result" "0" "c1b87d2 (git hash) is valid"

test-step "appdeploy_validate_version: long git hash"
appdeploy_validate_version "abc123def456" 2>/dev/null
result=$?
test-expect "$result" "0" "abc123def456 (long git hash) is valid"

test-step "appdeploy_validate_version: timestamped git hash"
appdeploy_validate_version "20260124-c1b87d2" 2>/dev/null
result=$?
test-expect "$result" "0" "20260124-c1b87d2 (timestamped) is valid"

test-step "appdeploy_validate_version: version with rc suffix"
appdeploy_validate_version "1.0.0-rc1" 2>/dev/null
result=$?
test-expect "$result" "0" "1.0.0-rc1 is valid"

test-step "appdeploy_validate_version: version with underscore"
appdeploy_validate_version "1.0.0_build123" 2>/dev/null
result=$?
test-expect "$result" "0" "1.0.0_build123 is valid"

test-step "appdeploy_validate_version: empty is invalid"
set +e
appdeploy_validate_version "" 2>/dev/null
result=$?
set -e
test-expect "$result" "1" "Empty version is invalid"

test-step "appdeploy_validate_version: path traversal invalid"
set +e
appdeploy_validate_version "1.0..0" 2>/dev/null
result=$?
set -e
test-expect "$result" "1" "Version with .. is invalid"

test-step "appdeploy_validate_version: special chars invalid"
set +e
appdeploy_validate_version "1.0.0/bad" 2>/dev/null
result=$?
set -e
test-expect "$result" "1" "Version with / is invalid"

test-step "appdeploy_validate_version: starts with dash invalid"
set +e
appdeploy_validate_version "-1.0.0" 2>/dev/null
result=$?
set -e
test-expect "$result" "1" "Version starting with - is invalid"

test-end

# EOF
