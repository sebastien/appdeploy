#!/usr/bin/env bash
# Basic test for the deploy command
# Tests the full deployment lifecycle

set -euo pipefail

BASE_PATH="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BASE_PATH/tests/lib-testing.sh"
source "$BASE_PATH/src/sh/appdeploy.sh"

test-start "deploy-basic"

EXAMPLES_DIR="$BASE_PATH/examples/hello-service"

# -----------------------------------------------------------------------------
# Setup: Create local target directory
# -----------------------------------------------------------------------------
test-step "Setup: Create target directory structure"
TARGET_DIR="$TEST_PATH/target"
mkdir -p "$TARGET_DIR"
# Use local target format: :path (no host)
LOCAL_TARGET=":$TARGET_DIR"
test-ok "Created target directory: $TARGET_DIR"

# Clean up any existing temp files
test-step "Clean up any existing temp files"
rm -f "$TEST_PATH"/hello-service-*.tar.gz || true
test-ok "Cleaned up temp files"

# -----------------------------------------------------------------------------
# Test: Deploy a package directory
# -----------------------------------------------------------------------------
test-step "Deploy package directory"
if appdeploy_deploy "$EXAMPLES_DIR" "$LOCAL_TARGET"; then
	test-ok "Deploy command succeeded"
else
	test-fail "Deploy command failed"
fi

# -----------------------------------------------------------------------------
# Verify: Check that package was deployed correctly
# -----------------------------------------------------------------------------
test-step "Verify package was uploaded"
test-exist "$TARGET_DIR/hello-service/packages" "Package directory created"
# Find the actual package file
PACKAGE_FILE=$(find "$TARGET_DIR/hello-service/packages" -name "hello-service-*.tar.gz" | head -1)
test-exist "$PACKAGE_FILE" "Package archive uploaded"

test-step "Verify package was installed"
test-exist "$TARGET_DIR/hello-service/dist" "Package dist directory created"

test-step "Verify package was activated"
test-exist "$TARGET_DIR/hello-service/.active" "Package activated"
test-exist "$TARGET_DIR/hello-service/run" "Package run directory created"

# -----------------------------------------------------------------------------
# Test: Deploy with configuration
# -----------------------------------------------------------------------------
test-step "Setup: Create configuration archive"
CONFIG_DIR="$TEST_PATH/config"
mkdir -p "$CONFIG_DIR"
echo "TEST_CONFIG=value" > "$CONFIG_DIR/test.conf"
tar -czf "$TEST_PATH/config.tar.gz" -C "$TEST_PATH" config
test-exist "$TEST_PATH/config.tar.gz" "Configuration archive created"

test-step "Deploy package with configuration"
# First, deactivate current package
appdeploy_package_deactivate "$LOCAL_TARGET" "hello-service" >/dev/null || true

# Deploy with configuration
if appdeploy_deploy "$EXAMPLES_DIR" "$TEST_PATH/config.tar.gz" "$LOCAL_TARGET"; then
	test-ok "Deploy with configuration succeeded"
else
	test-fail "Deploy with configuration failed"
fi

test-step "Verify configuration was deployed"
test-exist "$TARGET_DIR/hello-service/var/config/test.conf" "Configuration deployed"

# -----------------------------------------------------------------------------
# Cleanup is automatic via test-end
# -----------------------------------------------------------------------------
test-end

# EOF