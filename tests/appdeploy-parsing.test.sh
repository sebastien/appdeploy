#!/usr/bin/env bash
# Tests for appdeploy argument/string parsing functions

set -euo pipefail

BASE_PATH="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BASE_PATH/tests/lib-testing.sh"
source "$BASE_PATH/src/sh/appdeploy.sh"

test-start "appdeploy-parsing"

# -----------------------------------------------------------------------------
# appdeploy_target_user
# -----------------------------------------------------------------------------
test-step "appdeploy_target_user: user@host:path"
result=$(appdeploy_target_user "deploy@server:/opt/apps")
test-expect "$result" "deploy" "Extract user from user@host:path"

test-step "appdeploy_target_user: host:path (no user)"
result=$(appdeploy_target_user "server:/opt/apps" || echo "")
# When no @ is present, the regex fails to match user properly
# The function returns empty when there's a colon but no @
test-expect "$result" "" "No user when format is host:path"

test-step "appdeploy_target_user: user@host (no path)"
result=$(appdeploy_target_user "deploy@server")
test-expect "$result" "deploy" "Extract user from user@host"

# -----------------------------------------------------------------------------
# appdeploy_target_host
# -----------------------------------------------------------------------------
test-step "appdeploy_target_host: user@host:path"
result=$(appdeploy_target_host "deploy@server:/opt/apps")
test-expect "$result" "server" "Extract host from user@host:path"

test-step "appdeploy_target_host: host:path"
result=$(appdeploy_target_host "server:/opt/apps")
test-expect "$result" "server" "Extract host from host:path"

test-step "appdeploy_target_host: user@host (no path)"
result=$(appdeploy_target_host "deploy@server")
test-expect "$result" "server" "Extract host from user@host"

# -----------------------------------------------------------------------------
# appdeploy_target_path
# -----------------------------------------------------------------------------
test-step "appdeploy_target_path: user@host:path"
result=$(appdeploy_target_path "deploy@server:/opt/apps")
test-expect "$result" "/opt/apps" "Extract path from user@host:path"

test-step "appdeploy_target_path: host:path"
result=$(appdeploy_target_path "server:/opt/apps")
test-expect "$result" "/opt/apps" "Extract path from host:path"

test-step "appdeploy_target_path: no colon (no path)"
result=$(appdeploy_target_path "server" || echo "")
test-expect "$result" "" "Empty path when no colon"

test-step "appdeploy_target_path: local path only"
result=$(appdeploy_target_path ":/opt/apps")
test-expect "$result" "/opt/apps" "Extract local path (no host)"

# -----------------------------------------------------------------------------
# appdeploy_package_name
# -----------------------------------------------------------------------------
test-step "appdeploy_package_name: simple name"
result=$(appdeploy_package_name "myapp-1.0.0.tar.gz")
test-expect "$result" "myapp" "Extract name from myapp-1.0.0.tar.gz"

test-step "appdeploy_package_name: hyphenated name"
result=$(appdeploy_package_name "my-app-2.1.0.tar.xz")
test-expect "$result" "my-app" "Extract hyphenated name"

test-step "appdeploy_package_name: multi-hyphen name"
result=$(appdeploy_package_name "my-cool-app-1.0.0.tar.bz2")
test-expect "$result" "my-cool-app" "Extract multi-hyphen name"

# -----------------------------------------------------------------------------
# appdeploy_package_version
# -----------------------------------------------------------------------------
test-step "appdeploy_package_version: simple version"
result=$(appdeploy_package_version "myapp-1.0.0.tar.gz")
test-expect "$result" "1.0.0" "Extract version from myapp-1.0.0.tar.gz"

test-step "appdeploy_package_version: version with suffix"
result=$(appdeploy_package_version "app-2.1.0-rc1.tar.bz2")
test-expect "$result" "2.1.0-rc1" "Extract version with suffix"

test-step "appdeploy_package_version: version with alpha"
result=$(appdeploy_package_version "app-1.0.0-alpha.tar.xz")
test-expect "$result" "1.0.0-alpha" "Extract version with alpha suffix"

# -----------------------------------------------------------------------------
# appdeploy_package_ext
# -----------------------------------------------------------------------------
test-step "appdeploy_package_ext: .tar.gz"
result=$(appdeploy_package_ext "app-1.0.tar.gz")
test-expect "$result" "gz" "Extract gz extension"

test-step "appdeploy_package_ext: .tar.xz"
result=$(appdeploy_package_ext "app-1.0.tar.xz")
test-expect "$result" "xz" "Extract xz extension"

test-step "appdeploy_package_ext: .tar.bz2"
result=$(appdeploy_package_ext "app-1.0.tar.bz2")
test-expect "$result" "bz2" "Extract bz2 extension"

# -----------------------------------------------------------------------------
# appdeploy_package_parse
# -----------------------------------------------------------------------------
test-step "appdeploy_package_parse: name:version"
result=$(appdeploy_package_parse "myapp:1.0.0")
test-expect "$result" "myapp 1.0.0" "Parse name:version"

test-step "appdeploy_package_parse: name only"
result=$(appdeploy_package_parse "myapp")
test-expect "$result" "myapp " "Parse name only (empty version)"

test-step "appdeploy_package_parse: name with hyphen and version"
result=$(appdeploy_package_parse "my-app:2.0.0-rc1")
test-expect "$result" "my-app 2.0.0-rc1" "Parse hyphenated name with version"

# -----------------------------------------------------------------------------
# appdeploy_package_name and appdeploy_package_version: git hash versions
# -----------------------------------------------------------------------------
test-step "appdeploy_package_name: git hash version"
result=$(appdeploy_package_name "littlenotes-c1b87d2.tar.gz")
test-expect "$result" "littlenotes" "Extract name from git hash version"

test-step "appdeploy_package_version: git hash version"
result=$(appdeploy_package_version "littlenotes-c1b87d2.tar.gz")
test-expect "$result" "c1b87d2" "Extract git hash version"

test-step "appdeploy_package_name: timestamped git hash"
result=$(appdeploy_package_name "myapp-20260124-abc1234.tar.gz")
test-expect "$result" "myapp" "Extract name from timestamped git hash"

test-step "appdeploy_package_version: timestamped git hash"
result=$(appdeploy_package_version "myapp-20260124-abc1234.tar.gz")
test-expect "$result" "20260124-abc1234" "Extract timestamped git hash version"

test-step "appdeploy_package_name: v-prefixed version"
result=$(appdeploy_package_name "myapp-v1.0.0.tar.gz")
test-expect "$result" "myapp" "Extract name from v-prefixed version"

test-step "appdeploy_package_version: v-prefixed version"
result=$(appdeploy_package_version "myapp-v1.0.0.tar.gz")
test-expect "$result" "v1.0.0" "Extract v-prefixed version"

test-step "appdeploy_package_name: multi-dash name with git hash"
result=$(appdeploy_package_name "my-cool-app-abc1234.tar.xz")
test-expect "$result" "my-cool-app" "Extract multi-dash name with git hash"

test-step "appdeploy_package_version: multi-dash name with git hash"
result=$(appdeploy_package_version "my-cool-app-abc1234.tar.xz")
test-expect "$result" "abc1234" "Extract git hash from multi-dash name"

test-end

# EOF
