#!/usr/bin/env bash
# Verification test for appdeploy run command - ensures env.sh is sourced and run.sh is executed

set -euo pipefail

BASE_PATH="$(dirname "$(dirname "$(readlink -f "$0")")")"
# shellcheck source=tests/lib-testing.sh
source "$BASE_PATH/tests/lib-testing.sh"
# shellcheck source=src/sh/appdeploy.sh
source "$BASE_PATH/src/sh/appdeploy.sh"

test-start "appdeploy-run-verification"

# Clean up any previous test logs
rm -f /tmp/appdeploy_test_env.log /tmp/appdeploy_test_run.log

test-step "Create test package with verification scripts"
PACKAGE_FILE="$TEST_PATH/verify-app-1.0.0.tar.gz"
EXAMPLES_DIR="$BASE_PATH/examples/hello-service"

# Create package with updated scripts
appdeploy_package_create "$EXAMPLES_DIR" "$PACKAGE_FILE" >/dev/null
test-exist "$PACKAGE_FILE" "Verification package created"

test-step "Run package and verify environment sourcing"
# Clean up any existing logs
rm -f /tmp/appdeploy_test_env.log /tmp/appdeploy_test_run.log

# Run the package with a short timeout
# The package should run for about 10 seconds (loop in run.sh)
timeout 15 "$BASE_PATH/build/appdeploy.sh" run "$PACKAGE_FILE" >/dev/null 2>&1 || true

# Check if env.sh was sourced
test-step "Verify env.sh was sourced"
if [ -f /tmp/appdeploy_test_env.log ]; then
    if grep -q "ENV_SH_SOURCED=1" /tmp/appdeploy_test_env.log; then
        test-ok "env.sh was sourced correctly"
    else
        test-fail "env.sh was not sourced - ENV_SH_SOURCED not found"
    fi
    
    if grep -q "HELLO_MESSAGE=" /tmp/appdeploy_test_env.log; then
        test-ok "Environment variables were set in env.sh"
    else
        test-fail "Environment variables were not set"
    fi
else
    test-fail "env.sh was not executed - log file not created"
fi

test-step "Verify run.sh was executed"
if [ -f /tmp/appdeploy_test_run.log ]; then
    if grep -q "RUN_SH_EXECUTED=1" /tmp/appdeploy_test_run.log; then
        test-ok "run.sh was executed correctly"
    else
        test-fail "run.sh was not executed - RUN_SH_EXECUTED not found"
    fi
    
    if grep -q "HELLO_MESSAGE=" /tmp/appdeploy_test_run.log; then
        test-ok "Environment variables were available in run.sh"
    else
        test-fail "Environment variables were not available in run.sh"
    fi
else
    test-fail "run.sh was not executed - log file not created"
fi

test-step "Verify environment variable passing"
# Check that the HELLO_MESSAGE value is the same in both files
if [ -f /tmp/appdeploy_test_env.log ] && [ -f /tmp/appdeploy_test_run.log ]; then
    env_message=$(grep "HELLO_MESSAGE=" /tmp/appdeploy_test_env.log | cut -d'=' -f2-)
    run_message=$(grep "HELLO_MESSAGE=" /tmp/appdeploy_test_run.log | cut -d'=' -f2-)
    
    if [ "$env_message" = "$run_message" ]; then
        test-ok "Environment variables correctly passed from env.sh to run.sh"
    else
        test-fail "Environment variable values don't match"
        echo "env.sh: $env_message"
        echo "run.sh: $run_message"
    fi
fi

test-step "Test with custom run path and verify execution"
CUSTOM_PATH="$TEST_PATH/verify-custom-run"
mkdir -p "$CUSTOM_PATH"

# Clean up logs again
rm -f /tmp/appdeploy_test_env.log /tmp/appdeploy_test_run.log

# Run with custom path
timeout 15 "$BASE_PATH/build/appdeploy.sh" run "$PACKAGE_FILE" -r "$CUSTOM_PATH" >/dev/null 2>&1 || true

# Verify the execution happened
if [ -f /tmp/appdeploy_test_env.log ] && [ -f /tmp/appdeploy_test_run.log ]; then
    test-ok "Package executed correctly with custom run path"
else
    test-fail "Package did not execute with custom run path"
fi

# Verify the structure was created
test-exist "$CUSTOM_PATH/verify-app/.active" "Custom path structure created correctly"

test-step "Display test logs for verification"
echo "=== env.sh log ==="
cat /tmp/appdeploy_test_env.log 2>/dev/null || echo "No env.log found"
echo ""
echo "=== run.sh log ==="
cat /tmp/appdeploy_test_run.log 2>/dev/null || echo "No run.log found"

test-end

echo "Environment sourcing and execution verification complete!"
