#!/usr/bin/env bash
# Tests for appdeploy package command (spec-002)

set -euo pipefail

BASE_PATH="$(dirname "$(dirname "$(readlink -f "$0")")")"
# shellcheck source=tests/lib-testing.sh
source "$BASE_PATH/tests/lib-testing.sh"
# shellcheck source=src/sh/appdeploy.sh
source "$BASE_PATH/src/sh/appdeploy.sh"

test-start "appdeploy-package"

EXAMPLES_DIR="$BASE_PATH/examples/hello-service"

# -----------------------------------------------------------------------------
# Package with auto-inferred version (timestamp or git)
# -----------------------------------------------------------------------------
test-step "Package with auto-inferred version"
output=$(appdeploy_package "$EXAMPLES_DIR" 2>&1)
# Find the created package
pkg_file=$(find . -maxdepth 1 -type f -name 'hello-service-*.tar.gz' -print | head -n 1)
test-noempty "$pkg_file" "Package file created with inferred version"
test-exist "$pkg_file" "Package file exists"

# -----------------------------------------------------------------------------
# Package with explicit version
# -----------------------------------------------------------------------------
test-step "Package with explicit version"
appdeploy_package "$EXAMPLES_DIR" "2.0.0" >/dev/null
test-exist "hello-service-2.0.0.tar.gz" "Package with explicit version created"

# -----------------------------------------------------------------------------
# Package with full output path
# -----------------------------------------------------------------------------
test-step "Package with full output path"
mkdir -p output
appdeploy_package "$EXAMPLES_DIR" "output/myapp-3.0.0.tar.xz" >/dev/null
test-exist "output/myapp-3.0.0.tar.xz" "Package with full output path created"

# -----------------------------------------------------------------------------
# Package with .tar.bz2 compression
# -----------------------------------------------------------------------------
test-step "Package with .tar.bz2 compression"
appdeploy_package "$EXAMPLES_DIR" "hello-service-4.0.0.tar.bz2" >/dev/null
test-exist "hello-service-4.0.0.tar.bz2" "Package with bz2 compression created"

# -----------------------------------------------------------------------------
# Force overwrite existing package
# -----------------------------------------------------------------------------
test-step "Force overwrite existing package"
# Create a package first
appdeploy_package "$EXAMPLES_DIR" "5.0.0" >/dev/null
test-exist "hello-service-5.0.0.tar.gz" "Initial package created"
# Try to overwrite with force
appdeploy_package "$EXAMPLES_DIR" "5.0.0" -f >/dev/null
test-ok "Force overwrite succeeded"

# -----------------------------------------------------------------------------
# Fail without force when file exists
# -----------------------------------------------------------------------------
test-step "Fail without force when file exists"
# Create a package first
appdeploy_package "$EXAMPLES_DIR" "6.0.0" >/dev/null
test-exist "hello-service-6.0.0.tar.gz" "Initial package created"
# Try to overwrite without force - should fail
test-expect-failure appdeploy_package "$EXAMPLES_DIR" "6.0.0"

# -----------------------------------------------------------------------------
# Verify files are readonly in archive
# -----------------------------------------------------------------------------
test-step "Verify files are readonly in archive"
appdeploy_package "$EXAMPLES_DIR" "7.0.0" >/dev/null
mkdir -p extract-readonly
# Use -p to preserve permissions from archive
tar -xpzf "hello-service-7.0.0.tar.gz" -C extract-readonly

# Check env.sh permissions (should be 555 - r-xr-xr-x)
env_perms=$(stat -c %a extract-readonly/env.sh)
if [[ "$env_perms" == "555" ]]; then
	test-ok "env.sh has readonly+executable permissions (555)"
else
	test-fail "env.sh has wrong permissions: $env_perms (expected 555)"
fi

# Check run.sh permissions (should be 555 - r-xr-xr-x)
run_perms=$(stat -c %a extract-readonly/run.sh)
if [[ "$run_perms" == "555" ]]; then
	test-ok "run.sh has readonly+executable permissions (555)"
else
	test-fail "run.sh has wrong permissions: $run_perms (expected 555)"
fi

# -----------------------------------------------------------------------------
# Verify non-executable files are readonly without +x
# -----------------------------------------------------------------------------
test-step "Verify non-executable files are readonly without +x"
# Create a test source with a non-executable file
mkdir -p source-noexec
cp "$EXAMPLES_DIR/env.sh" source-noexec/
cp "$EXAMPLES_DIR/run.sh" source-noexec/
echo "config data" > source-noexec/config.txt
chmod 644 source-noexec/config.txt

appdeploy_package source-noexec "8.0.0" >/dev/null
mkdir -p extract-noexec
# Use -p to preserve permissions from archive
tar -xpzf "source-noexec-8.0.0.tar.gz" -C extract-noexec

# Check config.txt permissions (should be 444 - r--r--r--)
config_perms=$(stat -c %a extract-noexec/config.txt)
if [[ "$config_perms" == "444" ]]; then
	test-ok "config.txt has readonly permissions (444)"
else
	test-fail "config.txt has wrong permissions: $config_perms (expected 444)"
fi

# -----------------------------------------------------------------------------
# Fail when PATH missing env.sh
# -----------------------------------------------------------------------------
test-step "Fail when PATH missing env.sh"
mkdir -p no-env
echo '#!/bin/bash' > no-env/run.sh
chmod +x no-env/run.sh
test-expect-failure appdeploy_package no-env "9.0.0"

# -----------------------------------------------------------------------------
# Fail when PATH missing run.sh
# -----------------------------------------------------------------------------
test-step "Fail when PATH missing run.sh"
mkdir -p no-run
echo '#!/bin/bash' > no-run/env.sh
chmod +x no-run/env.sh
test-expect-failure appdeploy_package no-run "10.0.0"

# -----------------------------------------------------------------------------
# Fail when PATH doesn't exist
# -----------------------------------------------------------------------------
test-step "Fail when PATH doesn't exist"
test-expect-failure appdeploy_package /nonexistent/path "11.0.0"

# -----------------------------------------------------------------------------
# Flag position: -f before version
# -----------------------------------------------------------------------------
test-step "Flag position: -f before version"
# Create initial file
touch "hello-service-12.0.0.tar.gz"
# -f before version should work
appdeploy_package "$EXAMPLES_DIR" -f "12.0.0" >/dev/null
test-ok "Force flag before version works"

# -----------------------------------------------------------------------------
# Legacy 'package create' still works
# -----------------------------------------------------------------------------
test-step "Legacy 'package create' command still works"
appdeploy_package_create "$EXAMPLES_DIR" "legacy-1.0.0.tar.gz" >/dev/null
test-exist "legacy-1.0.0.tar.gz" "Legacy package create works"

# -----------------------------------------------------------------------------
# Cleanup readonly files before test-end
# -----------------------------------------------------------------------------
chmod -R u+w extract-readonly extract-noexec 2>/dev/null || true

test-end

# EOF
