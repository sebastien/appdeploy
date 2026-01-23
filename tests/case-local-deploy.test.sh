#!/usr/bin/env bash
# Scenario test: Full local deployment lifecycle
# Tests upload, install, activate, deactivate, uninstall, and remove

set -euo pipefail

BASE_PATH="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BASE_PATH/tests/lib-testing.sh"
source "$BASE_PATH/src/sh/appdeploy.sh"

test-start "case-local-deploy"

EXAMPLES_DIR="$BASE_PATH/examples/hello-service"

# -----------------------------------------------------------------------------
# Setup: Create local target directory and package
# -----------------------------------------------------------------------------
test-step "Setup: Create target directory structure"
TARGET_DIR="$TEST_PATH/target"
mkdir -p "$TARGET_DIR"
# Use local target format: :path (no host)
LOCAL_TARGET=":$TARGET_DIR"
test-ok "Created target directory: $TARGET_DIR"

test-step "Setup: Create test package"
PACKAGE_FILE="$TEST_PATH/hello-service-1.0.0.tar.gz"
appdeploy_package_create "$EXAMPLES_DIR" "$PACKAGE_FILE" >/dev/null
test-exist "$PACKAGE_FILE" "Package created"

# -----------------------------------------------------------------------------
# Test: Upload package to local target
# -----------------------------------------------------------------------------
test-step "Upload package to local target"
appdeploy_package_upload "$LOCAL_TARGET" "$PACKAGE_FILE" >/dev/null
test-exist "$TARGET_DIR/hello-service/packages/hello-service-1.0.0.tar.gz" "Package uploaded to target"

# -----------------------------------------------------------------------------
# Test: Install package
# -----------------------------------------------------------------------------
test-step "Install package (hello-service:1.0.0)"
appdeploy_package_install "$LOCAL_TARGET" "hello-service:1.0.0" >/dev/null
test-exist "$TARGET_DIR/hello-service/dist/1.0.0" "dist/1.0.0 directory created"
test-exist "$TARGET_DIR/hello-service/dist/1.0.0/env.sh" "env.sh extracted"
test-exist "$TARGET_DIR/hello-service/dist/1.0.0/run.sh" "run.sh extracted"

# -----------------------------------------------------------------------------
# Test: Install is idempotent
# -----------------------------------------------------------------------------
test-step "Install is idempotent (re-installing same version)"
output=$(appdeploy_package_install "$LOCAL_TARGET" "hello-service:1.0.0" 2>&1)
test-substring "$output" "already installed"
test-ok "Re-install reports already installed"

# -----------------------------------------------------------------------------
# Test: Activate package
# -----------------------------------------------------------------------------
test-step "Activate package (hello-service:1.0.0)"
appdeploy_package_activate "$LOCAL_TARGET" "hello-service:1.0.0" >/dev/null
test-exist "$TARGET_DIR/hello-service/run" "run directory created"
test-exist "$TARGET_DIR/hello-service/var" "var directory created"
test-exist "$TARGET_DIR/hello-service/.active" ".active marker created"

test-step "Verify .active contains correct version"
active_version=$(cat "$TARGET_DIR/hello-service/.active")
test-expect "$active_version" "1.0.0" ".active contains 1.0.0"

test-step "Verify run directory has symlinks"
if [ -L "$TARGET_DIR/hello-service/run/env.sh" ]; then
	test-ok "run/env.sh is a symlink"
else
	test-fail "run/env.sh should be a symlink"
fi
if [ -L "$TARGET_DIR/hello-service/run/run.sh" ]; then
	test-ok "run/run.sh is a symlink"
else
	test-fail "run/run.sh should be a symlink"
fi

# -----------------------------------------------------------------------------
# Test: Deactivate package
# -----------------------------------------------------------------------------
test-step "Deactivate package (hello-service:1.0.0)"
appdeploy_package_deactivate "$LOCAL_TARGET" "hello-service:1.0.0" >/dev/null

test-step "Verify symlinks removed after deactivate"
if [ -L "$TARGET_DIR/hello-service/run/env.sh" ]; then
	test-fail "run/env.sh symlink should be removed"
else
	test-ok "run/env.sh symlink removed"
fi

test-step "Verify .active removed after deactivate"
if [ -e "$TARGET_DIR/hello-service/.active" ]; then
	test-fail ".active should be removed"
else
	test-ok ".active removed"
fi

# -----------------------------------------------------------------------------
# Test: Re-activate for further tests
# -----------------------------------------------------------------------------
test-step "Re-activate package for uninstall test"
appdeploy_package_activate "$LOCAL_TARGET" "hello-service:1.0.0" >/dev/null
test-exist "$TARGET_DIR/hello-service/.active" "Package re-activated"

# -----------------------------------------------------------------------------
# Test: Uninstall package (should deactivate first)
# -----------------------------------------------------------------------------
test-step "Uninstall package (hello-service:1.0.0)"
appdeploy_package_uninstall "$LOCAL_TARGET" "hello-service:1.0.0" >/dev/null

test-step "Verify dist directory removed after uninstall"
if [ -d "$TARGET_DIR/hello-service/dist/1.0.0" ]; then
	test-fail "dist/1.0.0 should be removed"
else
	test-ok "dist/1.0.0 removed"
fi

test-step "Verify package archive still exists after uninstall"
test-exist "$TARGET_DIR/hello-service/packages/hello-service-1.0.0.tar.gz" "Package archive kept"

test-step "Verify deactivated during uninstall"
if [ -e "$TARGET_DIR/hello-service/.active" ]; then
	test-fail ".active should be removed (deactivated during uninstall)"
else
	test-ok "Deactivated during uninstall"
fi

# -----------------------------------------------------------------------------
# Test: Re-install and remove (full cleanup)
# -----------------------------------------------------------------------------
test-step "Re-install for remove test"
appdeploy_package_install "$LOCAL_TARGET" "hello-service:1.0.0" >/dev/null
test-exist "$TARGET_DIR/hello-service/dist/1.0.0" "Re-installed"

test-step "Remove package (hello-service:1.0.0)"
appdeploy_package_remove "$LOCAL_TARGET" "hello-service:1.0.0" >/dev/null

test-step "Verify dist directory removed after remove"
if [ -d "$TARGET_DIR/hello-service/dist/1.0.0" ]; then
	test-fail "dist/1.0.0 should be removed"
else
	test-ok "dist/1.0.0 removed"
fi

test-step "Verify package archive removed"
if [ -e "$TARGET_DIR/hello-service/packages/hello-service-1.0.0.tar.gz" ]; then
	test-fail "Package archive should be removed"
else
	test-ok "Package archive removed"
fi

# -----------------------------------------------------------------------------
# Test: Multiple versions
# -----------------------------------------------------------------------------
test-step "Setup: Create and upload multiple versions"
PACKAGE_V2="$TEST_PATH/hello-service-2.0.0.tar.gz"
appdeploy_package_create "$EXAMPLES_DIR" "$PACKAGE_V2" >/dev/null
appdeploy_package_upload "$LOCAL_TARGET" "$PACKAGE_FILE" >/dev/null
appdeploy_package_upload "$LOCAL_TARGET" "$PACKAGE_V2" >/dev/null
test-exist "$TARGET_DIR/hello-service/packages/hello-service-1.0.0.tar.gz" "v1.0.0 uploaded"
test-exist "$TARGET_DIR/hello-service/packages/hello-service-2.0.0.tar.gz" "v2.0.0 uploaded"

test-step "Install latest version (should be 2.0.0)"
appdeploy_package_install "$LOCAL_TARGET" "hello-service" >/dev/null
test-exist "$TARGET_DIR/hello-service/dist/2.0.0" "Latest version (2.0.0) installed"

test-step "Activate latest version"
appdeploy_package_activate "$LOCAL_TARGET" "hello-service" >/dev/null
active_version=$(cat "$TARGET_DIR/hello-service/.active")
test-expect "$active_version" "2.0.0" "Latest version (2.0.0) activated"

test-step "Install specific older version"
appdeploy_package_install "$LOCAL_TARGET" "hello-service:1.0.0" >/dev/null
test-exist "$TARGET_DIR/hello-service/dist/1.0.0" "Older version (1.0.0) installed"

test-step "Activate specific older version"
appdeploy_package_activate "$LOCAL_TARGET" "hello-service:1.0.0" >/dev/null
active_version=$(cat "$TARGET_DIR/hello-service/.active")
test-expect "$active_version" "1.0.0" "Older version (1.0.0) now active"

# -----------------------------------------------------------------------------
# Cleanup is automatic via test-end
# -----------------------------------------------------------------------------
test-end

# EOF
