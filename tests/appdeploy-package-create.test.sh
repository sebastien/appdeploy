#!/usr/bin/env bash
# Tests for appdeploy_package_create function

set -euo pipefail

BASE_PATH="$(dirname "$(dirname "$(readlink -f "$0")")")"
source "$BASE_PATH/tests/lib-testing.sh"
source "$BASE_PATH/src/sh/appdeploy.sh"

test-start "appdeploy-package-create"

EXAMPLES_DIR="$BASE_PATH/examples/hello-service"

# -----------------------------------------------------------------------------
# Create .tar.gz package
# -----------------------------------------------------------------------------
test-step "Create .tar.gz package from examples/hello-service"
dest="$TEST_PATH/hello-service-1.0.0.tar.gz"
appdeploy_package_create "$EXAMPLES_DIR" "$dest" >/dev/null
test-exist "$dest" "Package file created"

# Verify contents
test-step "Verify .tar.gz package contents"
mkdir -p "$TEST_PATH/extract-gz"
tar -xzf "$dest" -C "$TEST_PATH/extract-gz"
test-exist "$TEST_PATH/extract-gz/env.sh" "env.sh in package"
test-exist "$TEST_PATH/extract-gz/run.sh" "run.sh in package"

# -----------------------------------------------------------------------------
# Create .tar.bz2 package
# -----------------------------------------------------------------------------
test-step "Create .tar.bz2 package from examples/hello-service"
dest="$TEST_PATH/hello-service-1.0.0.tar.bz2"
appdeploy_package_create "$EXAMPLES_DIR" "$dest" >/dev/null
test-exist "$dest" "Package file created"

# Verify contents
test-step "Verify .tar.bz2 package contents"
mkdir -p "$TEST_PATH/extract-bz2"
tar -xjf "$dest" -C "$TEST_PATH/extract-bz2"
test-exist "$TEST_PATH/extract-bz2/env.sh" "env.sh in package"
test-exist "$TEST_PATH/extract-bz2/run.sh" "run.sh in package"

# -----------------------------------------------------------------------------
# Create .tar.xz package
# -----------------------------------------------------------------------------
test-step "Create .tar.xz package from examples/hello-service"
dest="$TEST_PATH/hello-service-1.0.0.tar.xz"
appdeploy_package_create "$EXAMPLES_DIR" "$dest" >/dev/null
test-exist "$dest" "Package file created"

# Verify contents
test-step "Verify .tar.xz package contents"
mkdir -p "$TEST_PATH/extract-xz"
tar -xJf "$dest" -C "$TEST_PATH/extract-xz"
test-exist "$TEST_PATH/extract-xz/env.sh" "env.sh in package"
test-exist "$TEST_PATH/extract-xz/run.sh" "run.sh in package"

# -----------------------------------------------------------------------------
# Fail when source directory doesn't exist
# -----------------------------------------------------------------------------
test-step "Fail when source directory doesn't exist"
test-expect-failure appdeploy_package_create "/nonexistent/dir" "$TEST_PATH/fail.tar.gz"

# -----------------------------------------------------------------------------
# Fail when destination has invalid format (no version)
# -----------------------------------------------------------------------------
test-step "Fail when destination has invalid name format"
test-expect-failure appdeploy_package_create "$EXAMPLES_DIR" "$TEST_PATH/invalid.tar.gz"

# -----------------------------------------------------------------------------
# Fail when env.sh missing
# -----------------------------------------------------------------------------
test-step "Fail when env.sh missing"
mkdir -p "$TEST_PATH/no-env"
echo '#!/bin/bash' > "$TEST_PATH/no-env/run.sh"
chmod +x "$TEST_PATH/no-env/run.sh"
test-expect-failure appdeploy_package_create "$TEST_PATH/no-env" "$TEST_PATH/no-env-1.0.0.tar.gz"

# -----------------------------------------------------------------------------
# Fail when run.sh missing
# -----------------------------------------------------------------------------
test-step "Fail when run.sh missing"
mkdir -p "$TEST_PATH/no-run"
echo '#!/bin/bash' > "$TEST_PATH/no-run/env.sh"
chmod +x "$TEST_PATH/no-run/env.sh"
test-expect-failure appdeploy_package_create "$TEST_PATH/no-run" "$TEST_PATH/no-run-1.0.0.tar.gz"

# -----------------------------------------------------------------------------
# Fail when env.sh not executable
# -----------------------------------------------------------------------------
test-step "Fail when env.sh not executable"
mkdir -p "$TEST_PATH/env-not-exec"
echo '#!/bin/bash' > "$TEST_PATH/env-not-exec/env.sh"
echo '#!/bin/bash' > "$TEST_PATH/env-not-exec/run.sh"
chmod +x "$TEST_PATH/env-not-exec/run.sh"
# env.sh is NOT executable (no chmod +x)
test-expect-failure appdeploy_package_create "$TEST_PATH/env-not-exec" "$TEST_PATH/env-not-exec-1.0.0.tar.gz"

# -----------------------------------------------------------------------------
# Fail when run.sh not executable
# -----------------------------------------------------------------------------
test-step "Fail when run.sh not executable"
mkdir -p "$TEST_PATH/run-not-exec"
echo '#!/bin/bash' > "$TEST_PATH/run-not-exec/env.sh"
echo '#!/bin/bash' > "$TEST_PATH/run-not-exec/run.sh"
chmod +x "$TEST_PATH/run-not-exec/env.sh"
# run.sh is NOT executable (no chmod +x)
test-expect-failure appdeploy_package_create "$TEST_PATH/run-not-exec" "$TEST_PATH/run-not-exec-1.0.0.tar.gz"

# -----------------------------------------------------------------------------
# Create package in nested directory
# -----------------------------------------------------------------------------
test-step "Create package in nested destination directory"
dest="$TEST_PATH/nested/dir/hello-service-2.0.0.tar.gz"
appdeploy_package_create "$EXAMPLES_DIR" "$dest" >/dev/null
test-exist "$dest" "Package created in nested directory"

# -----------------------------------------------------------------------------
# Cleanup readonly files before test-end
# -----------------------------------------------------------------------------
chmod -R u+w "$TEST_PATH/extract-gz" "$TEST_PATH/extract-bz2" "$TEST_PATH/extract-xz" 2>/dev/null || true

test-end

# EOF
