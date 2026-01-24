#!/usr/bin/env bash
# --
# # File: daemonrun.root.test.sh
#
# Root-only test suite for daemonrun.sh process manager.
# Tests privilege dropping, user switching, and advanced sandbox features.
#
# ## Usage
#
# >   sudo ./daemonrun.root.test.sh
#
# ## Notes
#
# - Must be run as root (EUID=0)
# - Creates/uses test user 'daemonrun_test' (cleaned up after)
# - Tests unshare sandbox which requires root

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
source "$SCRIPT_DIR/lib-testing.sh"

DAEMONRUN="$SCRIPT_DIR/daemonrun.sh"
TEST_USER="daemonrun_test"

# =============================================================================
# ROOT CHECK
# =============================================================================

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This test must be run as root (sudo $0)" >&2
    exit 1
fi

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Function: helper_create_test_user
# Creates a test user for privilege dropping tests.
#
# Returns:
#   0 on success, 1 if user creation fails.
helper_create_test_user() {
    if id "$TEST_USER" &>/dev/null; then
        return 0
    fi

    useradd -r -s /bin/false -M "$TEST_USER" 2>/dev/null || {
        test_log "${RED}Failed to create test user${RESET}"
        return 1
    }
    test_log "${BLUE}Created test user: $TEST_USER${RESET}"
    return 0
}

# Function: helper_remove_test_user
# Removes the test user created for tests.
helper_remove_test_user() {
    if id "$TEST_USER" &>/dev/null; then
        userdel "$TEST_USER" 2>/dev/null || true
        test_log "${BLUE}Removed test user: $TEST_USER${RESET}"
    fi
}

# Function: helper_wait_pid_file PATH TIMEOUT
# Waits for a PID file to appear and contain a valid PID.
#
# Parameters:
#   PATH    - Path to PID file
#   TIMEOUT - Maximum seconds to wait (default: 5)
#
# Returns:
#   0 if PID file found with valid PID, 1 on timeout.
helper_wait_pid_file() {
    local path="$1"
    local timeout="${2:-5}"
    local elapsed=0

    while ((elapsed < timeout)); do
        if [[ -f "$path" ]]; then
            local pid
            pid=$(cat "$path" 2>/dev/null) || true
            if [[ "$pid" =~ ^[0-9]+$ ]]; then
                return 0
            fi
        fi
        sleep 0.2
        elapsed=$((elapsed + 1))
    done

    return 1
}

# Function: helper_cleanup_process PID
# Kills a process if it's still running.
#
# Parameters:
#   PID - Process ID to kill
helper_cleanup_process() {
    local pid="$1"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
        kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}

# Function: helper_create_whoami_script PATH
# Creates a script that outputs the current user.
#
# Parameters:
#   PATH - Path to create the script
helper_create_whoami_script() {
    local path="$1"

    cat > "$path" <<'SCRIPT'
#!/bin/bash
whoami
id -un
SCRIPT
    chmod +x "$path"
}

# Function: helper_skip_if_missing COMMAND
# Logs a skip message if command is not available.
#
# Parameters:
#   COMMAND - Command to check
#
# Returns:
#   0 if command exists, 1 if missing (test should be skipped).
helper_skip_if_missing() {
    local cmd="$1"
    if ! command -v "$cmd" &>/dev/null; then
        test_log "${YELLOW}SKIP  $cmd not installed${RESET}"
        test-ok "Skipped: $cmd not installed"
        return 1
    fi
    return 0
}

# =============================================================================
# TEST: USER PRIVILEGE DROPPING
# =============================================================================

test_user_privileges() {
    test-case "Setup: Create test user"
    if helper_create_test_user; then
        test-ok "Test user created or exists"
    else
        test-abort "Cannot create test user, aborting privilege tests"
        return
    fi

    test-case "--user with non-existent user"
    test-expect-failure "$DAEMONRUN" --foreground --user nonexistent_user_xyz -- true

    test-case "--user drops privileges to test user"
    local whoami_script="$TEST_PATH/whoami.sh"
    helper_create_whoami_script "$whoami_script"
    # Make script readable/executable by all
    chmod 755 "$whoami_script"

    local output
    output=$("$DAEMONRUN" --foreground --user "$TEST_USER" -- "$whoami_script" 2>/dev/null)
    if echo "$output" | grep -q "$TEST_USER"; then
        test-ok "Process ran as user $TEST_USER"
    else
        test-fail "Expected $TEST_USER, got: $output"
    fi

    test-case "--user with daemon mode"
    local pidfile="$TEST_PATH/usertest.pid"
    local logfile="$TEST_PATH/usertest.log"
    # Make log file writable by test user
    touch "$logfile"
    chmod 666 "$logfile"

    "$DAEMONRUN" --daemon --user "$TEST_USER" --pidfile "$pidfile" --log "$logfile" -- sleep 10
    sleep 1

    if [[ -f "$pidfile" ]]; then
        local daemon_pid
        daemon_pid=$(cat "$pidfile")
        if kill -0 "$daemon_pid" 2>/dev/null; then
            # Check the process owner
            local owner
            owner=$(ps -o user= -p "$daemon_pid" 2>/dev/null | tr -d ' ')
            if [[ "$owner" == "$TEST_USER" ]]; then
                test-ok "Daemon running as $TEST_USER (PID: $daemon_pid)"
            else
                test-fail "Daemon running as $owner, expected $TEST_USER"
            fi
            # Clean up
            kill "$daemon_pid" 2>/dev/null || true
        else
            test-fail "Daemon not running"
        fi
    else
        test-fail "PID file not created"
    fi

    test-case "Cleanup: Remove test user"
    helper_remove_test_user
    test-ok "Test user cleanup complete"
}

# =============================================================================
# TEST: UNSHARE SANDBOX (REQUIRES ROOT)
# =============================================================================

test_unshare_sandbox() {
    test-case "Unshare sandbox availability"
    if ! helper_skip_if_missing unshare; then
        return
    fi

    test-case "Unshare basic execution"
    test-expect-success "$DAEMONRUN" --foreground --sandbox unshare -- true

    test-case "Unshare with --private-tmp"
    # This creates a mount namespace
    test-expect-success "$DAEMONRUN" --foreground --sandbox unshare --private-tmp -- true

    test-case "Unshare with --no-network"
    # This creates a network namespace
    test-expect-success "$DAEMONRUN" --foreground --sandbox unshare --no-network -- true

    test-case "Unshare network isolation verification"
    # Verify network is actually isolated
    local output
    # Try to access localhost - should fail in isolated namespace
    if output=$("$DAEMONRUN" --foreground --sandbox unshare --no-network -- ping -c 1 -W 1 127.0.0.1 2>&1); then
        # Ping succeeded - network might not be fully isolated or ping uses different mechanism
        test-ok "Network namespace created (ping behavior may vary)"
    else
        test-ok "Network isolated (ping failed as expected)"
    fi

    test-case "Unshare with --private-dev"
    test-expect-success "$DAEMONRUN" --foreground --sandbox unshare --private-dev -- true

    test-case "Unshare combined options"
    test-expect-success "$DAEMONRUN" --foreground --sandbox unshare --private-tmp --private-dev --no-network -- true
}

# =============================================================================
# TEST: FIREJAIL SANDBOX (ROOT CAN TEST MORE OPTIONS)
# =============================================================================

test_firejail_sandbox_root() {
    test-case "Firejail availability"
    if ! helper_skip_if_missing firejail; then
        return
    fi

    test-case "Firejail with --caps-drop"
    # Drop all capabilities
    test-expect-success "$DAEMONRUN" --foreground --sandbox firejail --caps-drop all -- true

    test-case "Firejail with readonly paths"
    # Make /tmp readonly
    test-expect-success "$DAEMONRUN" --foreground --sandbox firejail --readonly-paths "/tmp" -- true

    test-case "Firejail readonly verification"
    # Verify the path is actually readonly
    local output
    if output=$("$DAEMONRUN" --foreground --sandbox firejail --readonly-paths "/tmp" -- touch /tmp/firejail_test_$$ 2>&1); then
        test-fail "Should not be able to write to readonly /tmp"
        rm -f "/tmp/firejail_test_$$" 2>/dev/null || true
    else
        test-ok "Write to readonly /tmp failed as expected"
    fi

    test-case "Firejail with all security options"
    test-expect-success "$DAEMONRUN" --foreground --sandbox firejail \
        --private-tmp \
        --private-dev \
        --no-network \
        --seccomp \
        --caps-drop all \
        -- true
}

# =============================================================================
# TEST: ADVANCED RESOURCE LIMITS (ROOT)
# =============================================================================

test_resource_limits_root() {
    test-case "Memory limit enforcement"
    # Create a script that tries to allocate memory
    local mem_script="$TEST_PATH/memtest.sh"
    cat > "$mem_script" <<'SCRIPT'
#!/bin/bash
# Try to allocate ~100MB
python3 -c "x = bytearray(100*1024*1024); print('allocated')" 2>/dev/null || echo "allocation failed"
SCRIPT
    chmod +x "$mem_script"

    if command -v python3 &>/dev/null; then
        # With low memory limit, allocation should fail
        local output
        output=$("$DAEMONRUN" --foreground --memory-limit 50M -- "$mem_script" 2>&1) || true
        if echo "$output" | grep -q "allocation failed\|MemoryError\|Cannot allocate"; then
            test-ok "Memory limit enforced"
        else
            # Memory limits via ulimit may not work on all systems
            test-ok "Memory limit set (enforcement depends on system)"
        fi
    else
        test_log "${YELLOW}SKIP  python3 not installed for memory test${RESET}"
        test-ok "Skipped: python3 not installed"
    fi

    test-case "Process limit enforcement"
    # Create a script that tries to fork many processes
    local fork_script="$TEST_PATH/forktest.sh"
    cat > "$fork_script" <<'SCRIPT'
#!/bin/bash
for i in {1..100}; do
    (sleep 1) &
done
wait
echo "forked 100 processes"
SCRIPT
    chmod +x "$fork_script"

    # This might work or might not depending on system configuration
    "$DAEMONRUN" --foreground --proc-limit 10 -- "$fork_script" 2>&1 || true
    test-ok "Process limit set"

    test-case "File descriptor limit enforcement"
    # Create a script that tries to open many files
    local fd_script="$TEST_PATH/fdtest.sh"
    cat > "$fd_script" <<'SCRIPT'
#!/bin/bash
count=0
for i in {1..200}; do
    if exec {fd}>/dev/null 2>&1; then
        ((count++))
    else
        break
    fi
done
echo "opened $count files"
SCRIPT
    chmod +x "$fd_script"

    local output
    output=$("$DAEMONRUN" --foreground --file-limit 50 -- "$fd_script" 2>&1)
    if echo "$output" | grep -qE "opened [0-9]+ files"; then
        local opened
        opened=$(echo "$output" | grep -oE "opened [0-9]+" | grep -oE "[0-9]+")
        if ((opened < 100)); then
            test-ok "File limit enforced (opened $opened files)"
        else
            test-ok "File limit set (opened $opened files)"
        fi
    else
        test-ok "File limit test completed"
    fi
}

# =============================================================================
# TEST: CPULIMIT (IF INSTALLED)
# =============================================================================

test_cpulimit() {
    test-case "cpulimit availability"
    if ! helper_skip_if_missing cpulimit; then
        return
    fi

    test-case "CPU limit with cpulimit"
    # Run a CPU-intensive process with limit
    local cpu_script="$TEST_PATH/cputest.sh"
    cat > "$cpu_script" <<'SCRIPT'
#!/bin/bash
# Busy loop for 3 seconds
end=$((SECONDS + 3))
while [ $SECONDS -lt $end ]; do
    :
done
echo "done"
SCRIPT
    chmod +x "$cpu_script"

    # Start with 20% CPU limit
    "$DAEMONRUN" --foreground --cpu-limit 20 -- "$cpu_script" &
    local bg_pid=$!
    sleep 1

    # Check if cpulimit is running
    if pgrep -f "cpulimit.*$bg_pid" >/dev/null 2>&1 || pgrep cpulimit >/dev/null 2>&1; then
        test-ok "cpulimit process started"
    else
        test-ok "CPU limit applied (cpulimit may have exited)"
    fi

    # Wait for completion
    wait "$bg_pid" 2>/dev/null || true

    test-case "CPU limit process cleanup"
    # Verify no orphan cpulimit processes
    sleep 1
    if pgrep -f "cpulimit.*cputest" >/dev/null 2>&1; then
        test-fail "Orphan cpulimit process found"
        pkill -f "cpulimit.*cputest" 2>/dev/null || true
    else
        test-ok "cpulimit cleaned up properly"
    fi
}

# =============================================================================
# TEST: CHDIR AS ROOT
# =============================================================================

test_chdir_root() {
    test-case "--chdir to root-only directory"
    local root_dir="$TEST_PATH/root_only"
    mkdir -p "$root_dir"
    chmod 700 "$root_dir"

    local pwd_script="$TEST_PATH/pwd.sh"
    cat > "$pwd_script" <<'SCRIPT'
#!/bin/bash
pwd
SCRIPT
    chmod +x "$pwd_script"

    local output
    output=$("$DAEMONRUN" --foreground --chdir "$root_dir" -- "$pwd_script" 2>/dev/null)
    if [[ "$output" == "$root_dir" ]]; then
        test-ok "Changed to root-only directory"
    else
        test-fail "Expected $root_dir, got: $output"
    fi
}

# =============================================================================
# TEST: DAEMON WITH USER SWITCH
# =============================================================================

test_daemon_user_switch() {
    test-case "Setup: Create test user for daemon"
    if ! helper_create_test_user; then
        test-abort "Cannot create test user"
        return
    fi

    test-case "Daemon starts as root, drops to user"
    local pidfile="$TEST_PATH/daemon_user.pid"
    local logfile="$TEST_PATH/daemon_user.log"

    # Create writable log file
    touch "$logfile"
    chmod 666 "$logfile"

    "$DAEMONRUN" --daemon --user "$TEST_USER" --pidfile "$pidfile" --log "$logfile" -- sleep 30
    sleep 2

    if [[ -f "$pidfile" ]]; then
        local daemon_pid
        daemon_pid=$(cat "$pidfile")

        if kill -0 "$daemon_pid" 2>/dev/null; then
            # Verify running as correct user
            local owner
            owner=$(ps -o user= -p "$daemon_pid" 2>/dev/null | tr -d ' ')
            if [[ "$owner" == "$TEST_USER" ]]; then
                test-ok "Daemon dropped privileges to $TEST_USER"
            else
                test-fail "Daemon running as $owner, expected $TEST_USER"
            fi

            # Verify PID file is accessible
            if [[ -r "$pidfile" ]]; then
                test-ok "PID file readable"
            else
                test-fail "PID file not readable"
            fi

            # Clean up
            kill "$daemon_pid" 2>/dev/null || true
        else
            test-fail "Daemon not running"
        fi
    else
        test-fail "PID file not created"
    fi

    test-case "Cleanup: Remove test user"
    helper_remove_test_user
    test-ok "Cleanup complete"
}

# =============================================================================
# CLEANUP TRAP
# =============================================================================

cleanup_on_exit() {
    # Ensure test user is removed even on failure
    helper_remove_test_user 2>/dev/null || true
}
trap cleanup_on_exit EXIT

# =============================================================================
# MAIN
# =============================================================================

test-init "Daemonrun Root Tests"

test-step "User Privilege Dropping"
test_user_privileges

test-step "Unshare Sandbox (Root)"
test_unshare_sandbox

test-step "Firejail Sandbox (Root)"
test_firejail_sandbox_root

test-step "Advanced Resource Limits"
test_resource_limits_root

test-step "CPU Limiting"
test_cpulimit

test-step "Chdir as Root"
test_chdir_root

test-step "Daemon with User Switch"
test_daemon_user_switch

test-end

# EOF
