#!/usr/bin/env bash
# Basic test for appdeploy run command

set -euo pipefail

BASE_PATH="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BASE_PATH/tests/lib-testing.sh"
source "$BASE_PATH/src/sh/appdeploy.sh"

test-start "appdeploy-run-basic"

test-step "Create test package"
PACKAGE_FILE="$TEST_PATH/test-app-1.0.0.tar.gz"
EXAMPLES_DIR="$BASE_PATH/examples/hello-service"

# Create package
appdeploy_package_create "$EXAMPLES_DIR" "$PACKAGE_FILE" >/dev/null
test-exist "$PACKAGE_FILE" "Test package created"

test-step "Test basic run command"
# Test that run command executes without error (use timeout to prevent hanging)
# The command should timeout (exit 124) which indicates it's working correctly
if timeout 3 "$BASE_PATH/build/appdeploy.sh" run "$PACKAGE_FILE" >/dev/null 2>&1; then
    test-ok "Run command completed successfully"
else
    exit_code=$?
    # Check if the error was due to timeout (expected) or other issue
    if [ $exit_code -eq 124 ]; then
        test-ok "Run command executed and timed out as expected (working correctly)"
    else
        test-fail "Run command failed with unexpected error code: $exit_code"
    fi
fi

test-step "Test run command with custom path"
CUSTOM_PATH="$TEST_PATH/custom-run"
mkdir -p "$CUSTOM_PATH"

# Test with custom run path
if timeout 2 "$BASE_PATH/build/appdeploy.sh" run "$PACKAGE_FILE" -r "$CUSTOM_PATH" >/dev/null 2>&1; then
    test-ok "Run command with custom path executed successfully"
else
    if [ $? -eq 124 ]; then
        test-ok "Run command with custom path timed out as expected"
    else
        test-fail "Run command with custom path failed"
    fi
fi

# Verify custom path structure was created
test-exist "$CUSTOM_PATH/test-app" "Custom path structure created"
test-exist "$CUSTOM_PATH/test-app/.active" "Active marker created"

test-step "Test run command with overlay"
OVERLAY_FILE="$TEST_PATH/test-overlay.txt"
echo "TEST_OVERLAY=value" > "$OVERLAY_FILE"

# Test with overlay (use short timeout)
if timeout 2 "$BASE_PATH/build/appdeploy.sh" run "$PACKAGE_FILE" "$OVERLAY_FILE" >/dev/null 2>&1; then
    test-ok "Run command with overlay executed successfully"
else
    if [ $? -eq 124 ]; then
        test-ok "Run command with overlay timed out as expected"
    else
        test-fail "Run command with overlay failed"
    fi
fi

test-step "Test error handling - non-existent package"
if "$BASE_PATH/build/appdeploy.sh" run "$TEST_PATH/non-existent.tar.gz" >/dev/null 2>&1; then
    test-fail "Should have failed with non-existent package"
else
    test-ok "Correctly failed with non-existent package"
fi

test-step "Test error handling - non-executable env.sh"
# Create a package with non-executable env.sh (bypass appdeploy_package_create which now validates)
mkdir -p "$TEST_PATH/bad-env-src"
echo '#!/bin/bash' > "$TEST_PATH/bad-env-src/env.sh"
echo '#!/bin/bash' > "$TEST_PATH/bad-env-src/run.sh"
chmod +x "$TEST_PATH/bad-env-src/run.sh"
# Don't make env.sh executable
tar -czf "$TEST_PATH/bad-env-1.0.0.tar.gz" -C "$TEST_PATH/bad-env-src" .
output=$("$BASE_PATH/build/appdeploy.sh" run "$TEST_PATH/bad-env-1.0.0.tar.gz" 2>&1) || true
if echo "$output" | grep -q "not executable"; then
    test-ok "Correctly failed with non-executable env.sh"
else
    test-fail "Should have failed with non-executable env.sh"
fi

test-step "Test error handling - non-executable run.sh"
# Create a package with non-executable run.sh
mkdir -p "$TEST_PATH/bad-run-src"
echo '#!/bin/bash' > "$TEST_PATH/bad-run-src/env.sh"
echo '#!/bin/bash' > "$TEST_PATH/bad-run-src/run.sh"
chmod +x "$TEST_PATH/bad-run-src/env.sh"
# Don't make run.sh executable
tar -czf "$TEST_PATH/bad-run-1.0.0.tar.gz" -C "$TEST_PATH/bad-run-src" .
output=$("$BASE_PATH/build/appdeploy.sh" run "$TEST_PATH/bad-run-1.0.0.tar.gz" 2>&1) || true
if echo "$output" | grep -q "not executable"; then
    test-ok "Correctly failed with non-executable run.sh"
else
    test-fail "Should have failed with non-executable run.sh"
fi

test-step "Test dry run flag (-d)"
# Dry run should succeed without executing the scripts
DRY_RUN_PATH="$TEST_PATH/dry-run-test"
mkdir -p "$DRY_RUN_PATH"
output=$("$BASE_PATH/build/appdeploy.sh" run -d "$PACKAGE_FILE" -r "$DRY_RUN_PATH" 2>&1)
if echo "$output" | grep -q "Dry run mode"; then
    test-ok "Dry run mode message shown"
else
    test-fail "Dry run mode message not shown"
fi
if echo "$output" | grep -q "Skipping execution"; then
    test-ok "Skipping execution message shown"
else
    test-fail "Skipping execution message not shown"
fi
# Verify the package was set up
test-exist "$DRY_RUN_PATH/test-app/run/env.sh" "env.sh set up in dry run"
test-exist "$DRY_RUN_PATH/test-app/run/run.sh" "run.sh set up in dry run"

test-step "Test dry run flag (--dry)"
# Test long form of the flag
DRY_RUN_PATH2="$TEST_PATH/dry-run-test2"
mkdir -p "$DRY_RUN_PATH2"
output=$("$BASE_PATH/build/appdeploy.sh" run --dry "$PACKAGE_FILE" -r "$DRY_RUN_PATH2" 2>&1)
if echo "$output" | grep -q "Dry run mode"; then
    test-ok "Dry run with --dry flag works"
else
    test-fail "Dry run with --dry flag failed"
fi

test-end

echo "All basic tests passed!"