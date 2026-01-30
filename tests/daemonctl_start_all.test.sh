#!/usr/bin/env bash
# --
# # File: daemonctl_start_all.test.sh
#
# Test detection of run/.version in start-all --only-active

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/lib-testing.sh"

DAEMONCTL="$SCRIPT_DIR/../bin/daemonctl"

test-init "daemonctl start-all version detection"

test-step "prepare apps: plain run/.version and symlinked run"
# app1: plain run directory with version and run script
mkdir -p app1/run
echo "v1" > app1/run/.version
touch app1/run/run

# app2: symlinked run directory pointing to version folder with version and run script
mkdir -p version2
echo "v2" > version2/.version
touch version2/run
mkdir -p app2
ln -s "$PWD/version2" app2/run

test-step "invoke start-all with --only-active and dry-run"
TEST_OUTPUT=$("$DAEMONCTL" --dry-run start-all --only-active --verbose)
echo "$TEST_OUTPUT"

test-step "verify expected apps in output"
echo "$TEST_OUTPUT" | grep -q "Would start 2 apps: app1, app2"
test-ok

test-step "prepare app with run/run directory (not file) and run/run.sh script"
# app3: run/run is a directory (like SQLite data), run/run.sh is the script
mkdir -p app3/run/run/data  # run/run is a directory
echo "v3" > app3/run/.version
touch app3/run/run.sh       # run.sh is the actual script
chmod +x app3/run/run.sh

test-step "verify app3 is detected with list command"
LIST_OUTPUT=$("$DAEMONCTL" list 2>&1)
echo "$LIST_OUTPUT"
echo "$LIST_OUTPUT" | grep -q "app3"
test-ok

test-step "invoke start-all including app3"
TEST_OUTPUT2=$("$DAEMONCTL" --dry-run start-all --only-active --verbose)
echo "$TEST_OUTPUT2"
echo "$TEST_OUTPUT2" | grep -q "Would start 3 apps: app1, app2, app3"
test-ok

test-end
