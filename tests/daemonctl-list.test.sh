#!/usr/bin/env bash
# --
# # File: daemonctl-list.test.sh
#
# Test that daemonctl detects applications in DAEMONCTL_PATH

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/lib-testing.sh"

DAEMONCTL="$SCRIPT_DIR/../bin/daemonctl"

test-init "daemonctl list and status detection"

# --
## Create DAEMONCTL_PATH with test apps
test-step "create DAEMONCTL_PATH structure with test apps"

export DAEMONCTL_PATH="$TEST_PATH/apps"
mkdir -p "$DAEMONCTL_PATH"

# Active app1: has run/ directory with .version file and run script
mkdir -p "$DAEMONCTL_PATH/app1/run"
echo "v1.0.0" > "$DAEMONCTL_PATH/app1/run/.version"
touch "$DAEMONCTL_PATH/app1/run/run"
chmod +x "$DAEMONCTL_PATH/app1/run/run"

# Active app2: has run/ directory with .version file and run.sh script
mkdir -p "$DAEMONCTL_PATH/app2/run"
echo "v2.0.0" > "$DAEMONCTL_PATH/app2/run/.version"
touch "$DAEMONCTL_PATH/app2/run/run.sh"
chmod +x "$DAEMONCTL_PATH/app2/run/run.sh"

# Inactive app3: has run/ directory but NO .version file
mkdir -p "$DAEMONCTL_PATH/app3/run"
touch "$DAEMONCTL_PATH/app3/run/run"
chmod +x "$DAEMONCTL_PATH/app3/run/run"
# Note: no .version file, so it's "installed" but not "active"

# Invalid app4: has directory but no run/ subdirectory and no run script
mkdir -p "$DAEMONCTL_PATH/app4"
# No run script or run/ directory

test-ok "Created test apps in DAEMONCTL_PATH"

# --
## Test 1: daemonctl list should detect all valid apps
test-step "verify daemonctl list detects all valid apps"
LIST_OUTPUT=$("$DAEMONCTL" --path "$DAEMONCTL_PATH" list 2>&1)
echo "$LIST_OUTPUT"

# Verify app1 is detected
echo "$LIST_OUTPUT" | grep -q "app1" || test-fail "app1 not found in list output"

# Verify app2 is detected
echo "$LIST_OUTPUT" | grep -q "app2" || test-fail "app2 not found in list output"

# Verify app3 is detected (has run script even without .version)
echo "$LIST_OUTPUT" | grep -q "app3" || test-fail "app3 not found in list output"

# Verify app4 is NOT detected (no run script)
if echo "$LIST_OUTPUT" | grep -q "app4"; then
    test-fail "app4 should not be detected (missing run script)"
fi

test-ok "daemonctl list detects correct apps"

# --
## Test 2: daemonctl status should show status for active apps
test-step "verify daemonctl status detects and shows active apps"
STATUS_OUTPUT=$("$DAEMONCTL" --path "$DAEMONCTL_PATH" status --all 2>&1)
echo "$STATUS_OUTPUT"

# Verify app1 status is shown
echo "$STATUS_OUTPUT" | grep -q "app1" || test-fail "app1 not found in status output"

# Verify app2 status is shown
echo "$STATUS_OUTPUT" | grep -q "app2" || test-fail "app2 not found in status output"

# Verify app3 status is shown
echo "$STATUS_OUTPUT" | grep -q "app3" || test-fail "app3 not found in status output"

# All apps should show as "stopped" (not running)
echo "$STATUS_OUTPUT" | grep "app1" | grep -q "stopped" || test-fail "app1 should show as stopped"
echo "$STATUS_OUTPUT" | grep "app2" | grep -q "stopped" || test-fail "app2 should show as stopped"
echo "$STATUS_OUTPUT" | grep "app3" | grep -q "stopped" || test-fail "app3 should show as stopped"

test-ok "daemonctl status shows correct app status"

# --
## Test 3: daemonctl status for specific app
test-step "verify daemonctl status works for specific app"
APP1_STATUS=$("$DAEMONCTL" --path "$DAEMONCTL_PATH" status app1 2>&1)
echo "$APP1_STATUS"

echo "$APP1_STATUS" | grep -q "app1" || test-fail "app1 status not found"
echo "$APP1_STATUS" | grep -q "stopped" || test-fail "app1 should be stopped"

test-ok "daemonctl status works for specific app"

# --
## Test 4: verify run/.version file detection
test-step "verify run/.version files exist for active apps"
test-exist "$DAEMONCTL_PATH/app1/run/.version" "app1 .version exists"
test-exist "$DAEMONCTL_PATH/app2/run/.version" "app2 .version exists"
test-exist "$DAEMONCTL_PATH/app3/run" "app3 run directory exists"

if [ -f "$DAEMONCTL_PATH/app3/run/.version" ]; then
    test-fail "app3 should not have .version file"
fi

# Verify the version content
APP1_VERSION=$(cat "$DAEMONCTL_PATH/app1/run/.version")
test-expect "$APP1_VERSION" "v1.0.0" "app1 version is v1.0.0"

APP2_VERSION=$(cat "$DAEMONCTL_PATH/app2/run/.version")
test-expect "$APP2_VERSION" "v2.0.0" "app2 version is v2.0.0"

test-ok "version files have correct content"

test-end
