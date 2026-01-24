#!/usr/bin/env bash
# Tests for appdeploy logging functions

set -euo pipefail

BASE_PATH="$(dirname "$(dirname "$(readlink -f "$0")")")"
# shellcheck source=tests/lib-testing.sh
source "$BASE_PATH/tests/lib-testing.sh"
# shellcheck source=src/sh/appdeploy.sh
source "$BASE_PATH/src/sh/appdeploy.sh"

test-start "appdeploy-logging"

# -----------------------------------------------------------------------------
# appdeploy_log
# -----------------------------------------------------------------------------
test-step "appdeploy_log: outputs with _._ prefix"
result=$(appdeploy_log "test message")
test-substring "$result" "_._" "test message"
test-ok "appdeploy_log produces correct format"

test-step "appdeploy_log: handles multiple arguments"
result=$(appdeploy_log "hello" "world")
test-substring "$result" "_._" "hello world"
test-ok "appdeploy_log handles multiple arguments"

# -----------------------------------------------------------------------------
# appdeploy_warn
# -----------------------------------------------------------------------------
test-step "appdeploy_warn: outputs with -!- prefix"
result=$(appdeploy_warn "warning message")
test-substring "$result" "-!-" "warning message"
test-ok "appdeploy_warn produces correct format"

# -----------------------------------------------------------------------------
# appdeploy_error
# -----------------------------------------------------------------------------
test-step "appdeploy_error: outputs with ~!~ prefix"
result=$(appdeploy_error "error message")
test-substring "$result" "~!~" "error message"
test-ok "appdeploy_error produces correct format"

# -----------------------------------------------------------------------------
# Verify distinct prefixes
# -----------------------------------------------------------------------------
test-step "Logging prefixes are distinct"
log_out=$(appdeploy_log "x")
warn_out=$(appdeploy_warn "x")
error_out=$(appdeploy_error "x")
test-expect-different "$log_out" "$warn_out" "log != warn"
test-expect-different "$warn_out" "$error_out" "warn != error"
test-expect-different "$log_out" "$error_out" "log != error"

test-end

# EOF
