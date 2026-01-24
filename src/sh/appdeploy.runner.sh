#!/usr/bin/env bash
#
# AppDeploy Runner - Daemon management for deployed applications
#
# This script manages the lifecycle of deployed applications as system daemons,
# supporting both systemd and manual daemon management with log rotation.
#
# Features:
# - Comprehensive dependency checking before any operation
# - Automatic fallback to compatible alternatives
# - Interactive installation of optional dependencies
# - Support for systemd (preferred) or manual daemon management
# - Log rotation via rotatelogs or manual rotation fallback
#
# Environment Variables:
#   APP_NAME     Service name (default: myapp)
#   APP_SCRIPT   Path to script to run (default: ./run.sh)
#   APP_LOG_SIZE     Log rotation size (default: 10M)
#   APP_LOG_COUNT    Number of rotated logs to keep (default: 7)
#   APP_RUN_USER     User to run service as (default: current user)
#   APP_USE_SYSTEMD  Use systemd: auto/true/false (default: auto)
#   APP_ENV_SCRIPT   Path to env script to source before run.sh (optional)

set -uo pipefail

# Configuration
APP_NAME="${APP_NAME:-myapp}"
APP_SCRIPT="${APP_SCRIPT:-./run.sh}"
APP_ENV_SCRIPT="${APP_ENV_SCRIPT:-}"  # Optional: path to env.sh to source before run
APP_LOG_SIZE="${APP_LOG_SIZE:-10M}" # 10MB default for rotatelogs
APP_LOG_COUNT="${APP_LOG_COUNT:-7}" # Keep 7 rotated logs
APP_RUN_USER="${APP_RUN_USER:-$(whoami)}"
APP_USE_SYSTEMD="${APP_USE_SYSTEMD:-false}" # auto, true, false

# Runner version - used for compatibility checking
APPDEPLOY_RUNNER_VERSION="${APPDEPLOY_RUNNER_VERSION:-1.0.0}"

# Paths (can be overridden via environment variables)
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
SYSTEM_SYSTEMD_DIR="/etc/systemd/system"
APP_LOG_DIR="${APP_LOG_DIR:-/var/log/$APP_NAME}"
APP_PID_FILE="${APP_PID_FILE:-/tmp/${APP_NAME}.pid}"
APP_DAEMON_SCRIPT="${APP_DAEMON_SCRIPT:-/tmp/${APP_NAME}.daemon.sh}"

# --
# ## Color library
# Colored output support with terminal detection and fallback
if [ -z "${NOCOLOR:-}" ] && [ -n "${TERM:-}" ] && tput setaf 1 &>/dev/null; then
	BLUE="$(tput setaf 33)"
	GREEN="$(tput setaf 34)"
	YELLOW="$(tput setaf 220)"
	RED="$(tput setaf 124)"
	GRAY="$(tput setaf 153)"
	BOLD="$(tput bold)"
	RESET="$(tput sgr0)"
else
	BLUE=""
	GREEN=""
	YELLOW=""
	RED=""
	GRAY=""
	BOLD=""
	RESET=""
fi

# ============================================================================
# LOGGING (rap-2025 format)
# ============================================================================

# Function: appdeploy_runner_log MESSAGE
# Outputs a log message: _._ MESSAGE
appdeploy_runner_log() {
	local prefix="_._"
	printf '%s%s %s%s\n' "$BLUE" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_warn MESSAGE
# Outputs a warning message: -!- MESSAGE
appdeploy_runner_warn() {
	local prefix="-!-"
	printf '%s%s %s%s\n' "$YELLOW" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_error MESSAGE
# Outputs an error message: ~!~ MESSAGE
appdeploy_runner_error() {
	local prefix="~!~"
	printf '%s%s %s%s\n' "$RED" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_info MESSAGE
# Outputs an informational event message: <|> MESSAGE
appdeploy_runner_info() {
	local prefix="<|>"
	printf '%s%s %s%s\n' "$GREEN" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_debug MESSAGE
# Outputs a debug message (only shown when DEBUG=1)
appdeploy_runner_debug() {
	if [ -n "${DEBUG:-}" ]; then
		local prefix="[debug] _._"
		printf '%s%s %s%s\n' "$GRAY" "$prefix" "$*" "$RESET"
	fi
}

# Function: appdeploy_runner_get_version
# Extracts the version from the current runner script
# Returns the version string
appdeploy_runner_get_version() {
	# Since the version is set as a variable, we can just echo the variable value
	# The variable is already set at the top of the script
	echo "${APPDEPLOY_RUNNER_VERSION:-1.0.0}"
}

# Function: appdeploy_runner_compare_versions VERSION1 VERSION2
# Compares two semantic version strings
# Returns 0 if versions match, 1 if they don't
appdeploy_runner_compare_versions() {
	local version1="$1"
	local version2="$2"
	
	# If versions are identical, return success
	if [ "$version1" = "$version2" ]; then
		return 0
	fi
	
	# If either version is empty, consider them different
	if [ -z "$version1" ] || [ -z "$version2" ]; then
		return 1
	fi
	
	# For semantic versioning, we could add more sophisticated comparison
	# But for now, simple string comparison is sufficient for our needs
	return 1
}

# Function: appdeploy_runner_check_version EXPECTED_VERSION
# Checks if the current runner version matches the expected version
# If not, outputs warning and exits
# Returns 0 if version is acceptable, exits with error if not
appdeploy_runner_check_version() {
	local expected_version="$1"
	
	# If no expected version is specified, skip the check (backward compatibility)
	if [ -z "$expected_version" ]; then
		appdeploy_runner_debug "No expected version specified, skipping version check"
		return 0
	fi
	
	local current_version
	current_version=$(appdeploy_runner_get_version)
	
	appdeploy_runner_debug "Checking runner version: current=$current_version, expected=$expected_version"
	
	if appdeploy_runner_compare_versions "$current_version" "$expected_version"; then
		appdeploy_runner_debug "Version check passed: runner version $current_version matches expected $expected_version"
		return 0
	else
		appdeploy_runner_error "Version mismatch: runner is version $current_version but expected $expected_version"
		appdeploy_runner_error "Please update the runner script before proceeding"
		return 1
	fi
}

# Function: appdeploy_runner_validate_and_setup_application APPLICATION
# Validates APPLICATION path, derives unique APP_NAME, cd to run/ dir, sets APP_SCRIPT
appdeploy_runner_validate_and_setup_application() {
	local application="$1"

	if [ -z "$application" ]; then
		appdeploy_runner_error "APPLICATION path is required"
		exit 1
	fi

	if [ ! -d "$application" ]; then
		appdeploy_runner_error "APPLICATION '$application' is not a directory"
		exit 1
	fi

	local run_dir="$application/run"
	if [ ! -d "$run_dir" ]; then
		appdeploy_runner_error "APPLICATION '$application' must contain a 'run/' subdirectory"
		exit 1
	fi

	# Derive APP_NAME (lowercase, replace non-alnum with -)
	APP_NAME=$(basename "$application" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')

	# Uniqueness check (up to 5 attempts)
	local suffix=""
	local counter=0
	while [ $counter -lt 5 ]; do
		local test_name="${APP_NAME}${suffix}"
		if ! (systemctl list-units --all --quiet 2>/dev/null || true) | grep -q "^${test_name}\.service" && \
		   [ ! -f "/tmp/${test_name}.pid" ] && \
		   [ ! -d "/var/log/${test_name}" ]; then
			APP_NAME="$test_name"
			break
		fi
		counter=$((counter + 1))
		suffix="-$counter"
	done

	if [ $counter -ge 5 ]; then
		appdeploy_runner_error "Unable to generate unique APP_NAME for '$application'. Try different directory name or manual override."
		exit 1
	fi

	# cd and set script
	cd "$run_dir" || { appdeploy_runner_error "Failed to change to '$run_dir'"; exit 1; }
	APP_SCRIPT="./run.sh"
	APP_LOG_DIR="$application/var/log"
	APP_PID_FILE="$application/var/run/${APP_NAME}.pid"

	appdeploy_runner_log "Set up for APPLICATION '$application': APP_NAME='$APP_NAME', cd to '$run_dir', APP_SCRIPT='$APP_SCRIPT'"
}

# Function: appdeploy_runner_list_available_applications
# Lists directories in current working directory that contain a 'run/' subdirectory
appdeploy_runner_list_available_applications() {
	local available=()
	for dir in */; do
		if [ -d "$dir" ] && [ -d "${dir}run" ]; then
			available+=("${dir%/}")
		fi
	done
	if [ ${#available[@]} -eq 0 ]; then
		echo "No applications found in current directory."
	else
		echo "Available applications in current directory:"
		for app in "${available[@]}"; do
			echo "  - $app"
		done
	fi
}


# ============================================================================
# PROCESS LOGGING (rap-2025 format)
# ============================================================================

# Function: appdeploy_runner_program NAME
# Outputs a program start marker: >-- NAME
appdeploy_runner_program() {
	local prefix=">--"
	printf '%s%s %s%s\n' "$BOLD" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_step MESSAGE
# Outputs a step marker: --> MESSAGE
appdeploy_runner_step() {
	local prefix="-->"
	printf '%s%s %s%s\n' "$BLUE" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_step_ok MESSAGE
# Outputs a step success marker: <OK MESSAGE
appdeploy_runner_step_ok() {
	local prefix="<OK"
	printf '%s%s %s%s\n' "$GREEN" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_step_fail MESSAGE
# Outputs a step failure marker: <!! MESSAGE
appdeploy_runner_step_fail() {
	local prefix="<!!"
	printf '%s%s %s%s\n' "$RED" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_result MESSAGE
# Outputs a result marker: <-- MESSAGE
appdeploy_runner_result() {
	local prefix="<--"
	printf '%s%s %s%s\n' "$GRAY" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_program_ok MESSAGE
# Outputs a program success marker: EOK MESSAGE
appdeploy_runner_program_ok() {
	local prefix="EOK"
	printf '%s%s %s%s\n' "$GREEN" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_runner_program_fail MESSAGE
# Outputs a program failure marker: E!! MESSAGE
appdeploy_runner_program_fail() {
	local prefix="E!!"
	printf '%s%s %s%s\n' "$RED" "$prefix" "$*" "$RESET"
}

# ============================================================================
# DEPENDENCY DETECTION
# ============================================================================

# Dependency status tracking
SYSTEMD_AVAILABLE=false
ROTATELOGS_AVAILABLE=false



# Function: appdeploy_runner_check_systemd
# Checks if systemd is available and running
appdeploy_runner_check_systemd() {
	appdeploy_runner_debug "Checking systemd availability..."

	if command -v systemctl >/dev/null 2>&1; then
		# Check if systemd is actually running (not just installed)
		if systemctl --version >/dev/null 2>/dev/null; then
			SYSTEMD_AVAILABLE=true
			appdeploy_runner_info "+ systemd is available and running"

			# Check if we can use user services
			if [ "$APP_RUN_USER" != "root" ] && [ "$(id -u)" != "0" ]; then
				if systemctl --user --version >/dev/null 2>/dev/null; then
					appdeploy_runner_info "+ systemd user services available"
				else
					appdeploy_runner_warn "! systemd available but user services may not work"
				fi
			fi
			return 0
		else
			appdeploy_runner_warn "! systemctl found but systemd not running"
		fi
	else
		appdeploy_runner_warn "! systemd not available"
	fi

	SYSTEMD_AVAILABLE=false
	return 1
}

# Function: appdeploy_runner_check_rotatelogs
# Checks if rotatelogs is available
appdeploy_runner_check_rotatelogs() {
	appdeploy_runner_debug "Checking rotatelogs availability..."

	if command -v rotatelogs >/dev/null 2>&1; then
		ROTATELOGS_AVAILABLE=true
		appdeploy_runner_info "+ rotatelogs is available"
		return 0
	else
		appdeploy_runner_warn "! rotatelogs not found"
		ROTATELOGS_AVAILABLE=false
		return 1
	fi
}

# Function: appdeploy_runner_available
# Returns a space-separated list of available tools/features
appdeploy_runner_available() {
	appdeploy_runner_check_systemd
	appdeploy_runner_check_rotatelogs

	local available=""
	if [ "$SYSTEMD_AVAILABLE" = "true" ]; then
		available="${available}systemd "
	fi
	if [ "$ROTATELOGS_AVAILABLE" = "true" ]; then
		available="${available}rotatelogs "
	fi
	if [ -z "$available" ]; then
		available="manual"
	fi
	echo "${available% }"
}

# Function: appdeploy_runner_check_basic_tools
# Checks for basic required shell tools
appdeploy_runner_check_basic_tools() {
	appdeploy_runner_debug "Checking basic required tools..."

	local missing_tools=()
	local required_tools=("bash" "ps" "kill" "pgrep" "pkill" "tail" "tee" "stat" "find" "mkdir" "chmod" "ln")

	for tool in "${required_tools[@]}"; do
		if ! command -v "$tool" >/dev/null 2>&1; then
			missing_tools+=("$tool")
		fi
	done

	if [ ${#missing_tools[@]} -eq 0 ]; then
		appdeploy_runner_info "+ All basic tools available"
		return 0
	else
		appdeploy_runner_step_fail "- Missing required tools: ${missing_tools[*]}"
		return 1
	fi
}

# Function: appdeploy_runner_check_app_script
# Checks if the application script exists and is executable
appdeploy_runner_check_app_script() {
	appdeploy_runner_debug "Checking application script..."

	if [ ! -f "$APP_SCRIPT" ]; then
		appdeploy_runner_step_fail "- Application script '$APP_SCRIPT' not found"
		return 1
	fi

	if [ ! -r "$APP_SCRIPT" ]; then
		appdeploy_runner_step_fail "- Application script '$APP_SCRIPT' is not readable"
		return 1
	fi

	if [ ! -x "$APP_SCRIPT" ]; then
		appdeploy_runner_warn "! Application script '$APP_SCRIPT' is not executable"
		appdeploy_runner_log "  Run: chmod +x '$APP_SCRIPT' to fix this"
		return 1
	fi

	appdeploy_runner_info "+ Application script '$APP_SCRIPT' is ready"
	return 0
}

# Function: appdeploy_runner_check_permissions
# Checks for necessary directory and file permissions
appdeploy_runner_check_permissions() {
	appdeploy_runner_debug "Checking permissions..."

	local issues=()

	# Check log directory permissions
	if [ -d "$APP_LOG_DIR" ]; then
		if [ ! -w "$APP_LOG_DIR" ]; then
			issues+=("Cannot write to log directory: $APP_LOG_DIR")
		fi
	else
		# Check if we can create the log directory
		local parent_dir
		parent_dir=$(dirname "$APP_LOG_DIR")
		if [ ! -w "$parent_dir" ]; then
			issues+=("Cannot create log directory: $APP_LOG_DIR (parent not writable)")
		fi
	fi

	# Check PID file directory
	local pid_dir
	pid_dir=$(dirname "$APP_PID_FILE")
	if [ ! -w "$pid_dir" ]; then
		issues+=("Cannot write PID file: $APP_PID_FILE (directory not writable)")
	fi

	# Check systemd service directory permissions
	if [ "$SYSTEMD_AVAILABLE" = "true" ]; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			if [ ! -w "$SYSTEM_SYSTEMD_DIR" ]; then
				issues+=("Cannot write to system systemd directory: $SYSTEM_SYSTEMD_DIR")
			fi
		else
			local user_dir
			user_dir=$(dirname "$USER_SYSTEMD_DIR")
			if [ ! -d "$user_dir" ] && [ ! -w "$(dirname "$user_dir")" ]; then
				issues+=("Cannot create user systemd directory: $USER_SYSTEMD_DIR")
			fi
		fi
	fi

	if [ ${#issues[@]} -eq 0 ]; then
		appdeploy_runner_info "+ Permissions look good"
		return 0
	else
		appdeploy_runner_warn "! Permission issues found:"
		for issue in "${issues[@]}"; do
			appdeploy_runner_warn "  - $issue"
		done
		return 1
	fi
}

# Function: appdeploy_runner_show_dependency_summary
# Displays a summary of all dependency checks
appdeploy_runner_show_dependency_summary() {
	local available_tools
	available_tools=$(appdeploy_runner_available)

	echo
	appdeploy_runner_program "=== Dependency Check Summary"

	printf '\n%s--- Core Requirements%s\n' "$BLUE" "$RESET"
	printf '  + Basic shell tools: Available\n'
	printf '  %s systemd: %s\n' \
		"$([ "$SYSTEMD_AVAILABLE" = "true" ] && printf '+' || printf '!')" \
		"$([ "$SYSTEMD_AVAILABLE" = "true" ] && printf 'Available' || printf 'Not available')"

	printf '\n%s--- Log Rotation Options%s\n' "$BLUE" "$RESET"
	printf '  %s rotatelogs: %s\n' \
		"$([ "$ROTATELOGS_AVAILABLE" = "true" ] && printf '+' || printf '-')" \
		"$([ "$ROTATELOGS_AVAILABLE" = "true" ] && printf 'Available' || printf 'Not available')"
	printf '  + Manual rotation: Always available (fallback)\n'

	printf '\n%s--- Available Tools%s\n' "$BLUE" "$RESET"
	printf '  Available tools: %s\n' "$available_tools"

	printf '\n%s--- Default Setup%s\n' "$BLUE" "$RESET"
	printf '  [.] Manual: Custom daemon + manual log rotation (default)\n'

	echo
}



# Function: appdeploy_runner_comprehensive_dependency_check
# Runs all dependency checks
appdeploy_runner_comprehensive_dependency_check() {
	appdeploy_runner_program "=== Checking Dependencies"
	echo

	local checks_passed=0
	local total_checks=4

	# Check basic tools (critical)
	if appdeploy_runner_check_basic_tools; then
		((checks_passed++))
	else
		appdeploy_runner_error "Critical dependency check failed. Cannot continue."
		exit 1
	fi

	# Check application script (critical)

	if appdeploy_runner_check_app_script; then
		((checks_passed++))
	else
		appdeploy_runner_error "Application script check failed. Cannot continue."
		exit 1
	fi

	# Check systemd (optional but preferred)
	if appdeploy_runner_check_systemd; then
		((checks_passed++))
	fi

	# Check rotatelogs (optional but preferred)
	if appdeploy_runner_check_rotatelogs; then
		((checks_passed++))
	fi

	# Check permissions (important)
	appdeploy_runner_check_permissions # Don't fail on permission issues, just warn

	# Determine final configuration
	if [ "$APP_USE_SYSTEMD" = "true" ] && [ "$SYSTEMD_AVAILABLE" = "false" ]; then
		appdeploy_runner_warn "systemd requested but not available, falling back to manual daemon"
		APP_USE_SYSTEMD=false
	fi

	appdeploy_runner_show_dependency_summary

	appdeploy_runner_result "Dependency check complete ($checks_passed/$total_checks optimal)"
	echo
}

# ============================================================================
# SERVICE INSTALLATION
# ============================================================================



# Function: appdeploy_runner_setup_log_cleanup
# Sets up a cron job for log cleanup when using rotatelogs
appdeploy_runner_setup_log_cleanup() {
	# Create cleanup script for rotatelogs (since it doesn't auto-delete old files)
	local cleanup_script="/usr/local/bin/${APP_NAME}-log-cleanup"

	sudo tee "$cleanup_script" >/dev/null <<EOF
#!/bin/bash
# Auto-generated log cleanup script for $APP_NAME
find "$APP_LOG_DIR" -name "app.*" -mtime +$APP_LOG_COUNT -delete
EOF

	sudo chmod +x "$cleanup_script"

	# Add to user's crontab or systemd timer
	if [ "$APP_RUN_USER" != "root" ]; then
		(
			crontab -l 2>/dev/null
			echo "0 2 * * * $cleanup_script"
		) | crontab -
		appdeploy_runner_log "Added daily log cleanup to crontab"
	else
		(
			crontab -l 2>/dev/null
			echo "0 2 * * * $cleanup_script"
		) | sudo crontab -
		appdeploy_runner_log "Added daily log cleanup to root crontab"
	fi
}

# Function: appdeploy_runner_create_systemd_service
# Creates and enables a systemd service for the application
appdeploy_runner_create_systemd_service() {
	local service_dir
	local service_file
	local app_script_abs

	app_script_abs=$(readlink -f "$APP_SCRIPT")

	if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
		service_dir="$SYSTEM_SYSTEMD_DIR"
		service_file="$service_dir/${APP_NAME}.service"
		appdeploy_runner_log "Creating system service"
	else
		service_dir="$USER_SYSTEMD_DIR"
		service_file="$service_dir/${APP_NAME}.service"
		mkdir -p "$service_dir"
		appdeploy_runner_log "Creating user service"
	fi

	# Create log directory
	sudo mkdir -p "$APP_LOG_DIR"
	if [ "$APP_RUN_USER" != "root" ]; then
		sudo chown -R "$APP_RUN_USER:$APP_RUN_USER" "$APP_LOG_DIR"
	fi

	# Determine log rotation method and build exec_start command
	local exec_start
	local env_source=""
	
	# Add env script sourcing if specified and exists
	if [ -n "$APP_ENV_SCRIPT" ]; then
		local env_script_abs
		env_script_abs=$(readlink -f "$APP_ENV_SCRIPT" 2>/dev/null || echo "")
		if [ -n "$env_script_abs" ] && [ -f "$env_script_abs" ]; then
			env_source="source '$env_script_abs' && "
			appdeploy_runner_log "Will source env script: $env_script_abs"
		else
			appdeploy_runner_warn "Env script not found: $APP_ENV_SCRIPT (continuing without it)"
		fi
	fi
	
	if [ "$ROTATELOGS_AVAILABLE" = "true" ]; then
		# Use rotatelogs for pipe-based rotation
		exec_start="${env_source}$app_script_abs 2>&1 | rotatelogs '$APP_LOG_DIR/app.%Y-%m-%d-%H_%M_%S' $APP_LOG_SIZE"
		appdeploy_runner_log "Using rotatelogs for log rotation"
	else
		# Fallback to simple logging with journald handling rotation
		exec_start="${env_source}$app_script_abs"
		appdeploy_runner_log "Using journald for log management"
	fi

	# Create systemd service file
	cat >"$service_file" <<EOF
[Unit]
Description=$APP_NAME daemon service
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
Restart=always
RestartSec=5
User=$APP_RUN_USER
Group=$APP_RUN_USER
WorkingDirectory=$(dirname "$app_script_abs")
ExecStart=/bin/bash -c '$exec_start'
StandardOutput=journal
StandardError=journal
Environment=SERVICE_NAME=$APP_NAME
Environment=SERVICE_TYPE=main

# Process management
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=30

[Install]
WantedBy=default.target
EOF

	appdeploy_runner_log "Service file created: $service_file"

	# Reload systemd and enable service
	if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
		systemctl daemon-reload
		systemctl enable "${APP_NAME}.service"
	else
		systemctl --user daemon-reload
		systemctl --user enable "${APP_NAME}.service"
	fi

	# Set up log cleanup if using rotatelogs
	if [ "$ROTATELOGS_AVAILABLE" = "true" ]; then
		appdeploy_runner_setup_log_cleanup
	fi
}

# Function: appdeploy_runner_kill_existing_daemon
# Kills existing daemon gracefully if running
appdeploy_runner_kill_existing_daemon() {
	if [ -f "$APP_PID_FILE" ]; then
		local pid
		pid=$(cat "$APP_PID_FILE")
		if kill -0 "$pid" 2>/dev/null; then
			appdeploy_runner_log "Stopping existing daemon (PID $pid)"
			kill -TERM "$pid"
			local count=0
			while kill -0 "$pid" 2>/dev/null && [ $count -lt 50 ]; do
				sleep 0.1
				count=$((count + 1))
			done
			if kill -0 "$pid" 2>/dev/null; then
				appdeploy_runner_warn "Daemon didn't stop gracefully, force killing"
				kill -KILL "$pid" 2>/dev/null || true
			fi
		fi
		rm -f "$APP_PID_FILE"
	fi
}

# Function: appdeploy_runner_create_manual_daemon
# Creates a manual daemon using setsid and wrapper script
appdeploy_runner_create_manual_daemon() {
	local app_script_abs
	local env_script_abs=""
	local daemon_script="$APP_DAEMON_SCRIPT"

	app_script_abs=$(readlink -f "$APP_SCRIPT")

	# Add env script sourcing if specified and exists
	if [ -n "$APP_ENV_SCRIPT" ]; then
		env_script_abs=$(readlink -f "$APP_ENV_SCRIPT" 2>/dev/null || echo "")
		if [ -z "$env_script_abs" ] || [ ! -f "$env_script_abs" ]; then
			env_script_abs=""
		fi
	fi

	# Create log directory
	mkdir -p "$APP_LOG_DIR"

	# Create daemon script
	cat >"$daemon_script" <<EOF
#!/bin/bash
# Auto-generated daemon script for $APP_NAME

# Set process group and run with log rotation
export SERVICE_NAME="$APP_NAME"
export SERVICE_TYPE="main"

# Update status: running
echo "status=running" > "$APP_LOG_DIR/status"
echo "pid=\$\$" >> "$APP_LOG_DIR/status"
echo "start_time=\$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$APP_LOG_DIR/status"

# Log start
echo "[START] \$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >&2

start_time=\$(date +%s)

# Source env script if provided
if [ -n "$env_script_abs" ] && [ -f "$env_script_abs" ]; then
	source "$env_script_abs"
fi

# Run the application
if command -v rotatelogs >/dev/null 2>&1; then
    "$app_script_abs" 2>&1 | rotatelogs "$APP_LOG_DIR/app.%Y-%m-%d-%H_%M_%S" "$APP_LOG_SIZE"
    exit_code=\$?
else
    "$app_script_abs" 2>&1 | rotate_logs
    exit_code=\$?
fi

end_time=\$(date +%s)
runtime=\$((end_time - start_time))

# Update status: not running with exit info
echo "status=not_running" > "$APP_LOG_DIR/status"
echo "last_exit_code=\$exit_code" >> "$APP_LOG_DIR/status"
echo "last_exit_time=\$(date -u +"%Y-%m-%dT%H:%M:%SZ")" >> "$APP_LOG_DIR/status"
echo "runtime_seconds=\$runtime" >> "$APP_LOG_DIR/status"

# Log exit with EOK/EFAIL based on startup time
if [ \$runtime -lt 5 ]; then
    echo "[EXIT] code=\$exit_code runtime=\${runtime}s (startup failure)" >&2
    echo "EFAIL $APP_NAME exited early (code \$exit_code, runtime \${runtime}s)" >&2
else
    echo "[EXIT] code=\$exit_code runtime=\${runtime}s" >&2
    echo "EOK $APP_NAME completed (code \$exit_code, runtime \${runtime}s)" >&2
fi

exit \$exit_code
EOF

	chmod +x "$daemon_script"

	# Create PID file directory
	mkdir -p "$(dirname "$APP_PID_FILE")"

	# Start daemon using setsid for proper daemonization
	setsid "$daemon_script" &
	echo $! >"$APP_PID_FILE"

	appdeploy_runner_log "Manual daemon started with PID $(cat "$APP_PID_FILE")"
}

# Function: appdeploy_runner_install_service
# Installs the service using systemd or manual daemon
appdeploy_runner_install_service() {
	if [ "$APP_USE_SYSTEMD" = "true" ] && appdeploy_runner_check_systemd; then
		appdeploy_runner_create_systemd_service
	else
		appdeploy_runner_create_manual_daemon
	fi
}

# Function: appdeploy_runner_uninstall_service
# Uninstalls the service
appdeploy_runner_uninstall_service() {
	if [ "$APP_USE_SYSTEMD" = "true" ] && appdeploy_runner_check_systemd; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl stop "${APP_NAME}.service" 2>/dev/null || true
			systemctl disable "${APP_NAME}.service" 2>/dev/null || true
			rm -f "/etc/systemd/system/${APP_NAME}.service"
			systemctl daemon-reload
		else
			systemctl --user stop "${APP_NAME}.service" 2>/dev/null || true
			systemctl --user disable "${APP_NAME}.service" 2>/dev/null || true
			rm -f "$HOME/.config/systemd/user/${APP_NAME}.service"
			systemctl --user daemon-reload
		fi
	else
		appdeploy_runner_kill_existing_daemon
		if [ -f "$APP_DAEMON_SCRIPT" ]; then
			rm -f "$APP_DAEMON_SCRIPT"
		fi
	fi
}

# Function: appdeploy_runner_start_service
# Starts the service
appdeploy_runner_start_service() {
	appdeploy_runner_step "Starting $APP_NAME service"

	if [ "$APP_USE_SYSTEMD" = "true" ] && appdeploy_runner_check_systemd; then
		appdeploy_runner_step "Using systemd service"
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl start "${APP_NAME}.service"
		else
			systemctl --user start "${APP_NAME}.service"
		fi
	else
		appdeploy_runner_step "Using manual daemon"
		appdeploy_runner_create_manual_daemon
	fi

	appdeploy_runner_step_ok "$APP_NAME service started"
}

# Function: appdeploy_runner_stop_service
# Stops the service
appdeploy_runner_stop_service() {
	if [ "$APP_USE_SYSTEMD" = "true" ] && appdeploy_runner_check_systemd; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl stop "${APP_NAME}.service"
		else
			systemctl --user stop "${APP_NAME}.service"
		fi
	else
		appdeploy_runner_kill_existing_daemon
	fi
}

# Function: appdeploy_runner_enable_service
# Enables the service
appdeploy_runner_enable_service() {
	if [ "$APP_USE_SYSTEMD" = "true" ] && appdeploy_runner_check_systemd; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl enable "${APP_NAME}.service"
		else
			systemctl --user enable "${APP_NAME}.service"
		fi
	fi
}

# Function: appdeploy_runner_disable_service
# Disables the service
appdeploy_runner_disable_service() {
	if [ "$APP_USE_SYSTEMD" = "true" ] && appdeploy_runner_check_systemd; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl disable "${APP_NAME}.service"
		else
			systemctl --user disable "${APP_NAME}.service"
		fi
	fi
}

# Function: appdeploy_runner_show_status
# Shows the current status of the application
appdeploy_runner_show_status() {
	if [ -f "$APP_LOG_DIR/status" ]; then
		cat "$APP_LOG_DIR/status"
	else
		echo "status=not_installed"
	fi
}

# Function: appdeploy_runner_show_logs
# Shows the application logs
appdeploy_runner_show_logs() {
	local lines="${1:-50}"
	if [ -d "$APP_LOG_DIR" ]; then
		find "$APP_LOG_DIR" -name "app.*" -type f -printf '%T@ %p\n' | sort -n | tail -10 | cut -d' ' -f2- | xargs tail -n "$lines" 2>/dev/null || echo "No recent logs found"
	else
		echo "No logs directory found"
	fi
}

# Function: appdeploy_runner_tail_logs_briefly
# Shows application logs for 10 seconds after start
appdeploy_runner_tail_logs_briefly() {
	local log_file
	log_file=$(find "$APP_LOG_DIR" -name "app.*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)

	if [ -n "$log_file" ] && [ -f "$log_file" ]; then
		appdeploy_runner_info "Showing application output for 10 seconds (Ctrl+C to skip)..."
		timeout 10 tail -f "$log_file" 2>/dev/null || true
		appdeploy_runner_info "Log display complete"
	else
		appdeploy_runner_debug "No log file found yet, waiting briefly..."
		sleep 2
		log_file=$(find "$APP_LOG_DIR" -name "app.*" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
		if [ -n "$log_file" ] && [ -f "$log_file" ]; then
			appdeploy_runner_info "Showing application output for 10 seconds (Ctrl+C to skip)..."
			timeout 10 tail -f "$log_file" 2>/dev/null || true
			appdeploy_runner_info "Log display complete"
		else
			appdeploy_runner_warn "No logs available to display"
		fi
	fi
}

# ============================================================================
# MAIN
# ============================================================================

# Main command handling with dependency checking
case "${1:-help}" in
check)
	APPLICATION="${2:-}"
	appdeploy_runner_comprehensive_dependency_check
	;;
install)
	APPLICATION="${2:-}"
	if [ -z "$APPLICATION" ]; then
		appdeploy_runner_error "APPLICATION required for 'install'"
		appdeploy_runner_list_available_applications
		exit 1
	fi
	appdeploy_runner_validate_and_setup_application "$APPLICATION"
	appdeploy_runner_install_service
	;;
uninstall)
	APPLICATION="${2:-}"
	if [ -z "$APPLICATION" ]; then
		appdeploy_runner_error "APPLICATION required for 'uninstall'"
		appdeploy_runner_list_available_applications
		exit 1
	fi
	appdeploy_runner_validate_and_setup_application "$APPLICATION"
	appdeploy_runner_uninstall_service
	;;
start)
	APPLICATION="${2:-}"
	if [ -z "$APPLICATION" ]; then
		appdeploy_runner_error "APPLICATION required for 'start'"
		appdeploy_runner_list_available_applications
		exit 1
	fi
	appdeploy_runner_validate_and_setup_application "$APPLICATION"
	appdeploy_runner_start_service
	appdeploy_runner_tail_logs_briefly
	;;
stop)
	APPLICATION="${2:-}"
	if [ -z "$APPLICATION" ]; then
		appdeploy_runner_error "APPLICATION required for 'stop'"
		appdeploy_runner_list_available_applications
		exit 1
	fi
	appdeploy_runner_validate_and_setup_application "$APPLICATION"
	appdeploy_runner_stop_service
	;;
restart)
	APPLICATION="${2:-}"
	if [ -z "$APPLICATION" ]; then
		appdeploy_runner_error "APPLICATION required for 'restart'"
		appdeploy_runner_list_available_applications
		exit 1
	fi
	appdeploy_runner_validate_and_setup_application "$APPLICATION"
	# Check version compatibility before proceeding
	if ! appdeploy_runner_check_version "${APPDEPLOY_RUNNER_EXPECTED_VERSION:-}"; then
		appdeploy_runner_error "Cannot proceed with restart due to version mismatch"
		return 1
	fi
	appdeploy_runner_stop_service
	sleep 2
	appdeploy_runner_start_service
	;;
enable)
	APPLICATION="${2:-}"
	if [ -z "$APPLICATION" ]; then
		appdeploy_runner_error "APPLICATION required for 'enable'"
		appdeploy_runner_list_available_applications
		exit 1
	fi
	appdeploy_runner_validate_and_setup_application "$APPLICATION"
	appdeploy_runner_enable_service
	;;
disable)
	APPLICATION="${2:-}"
	if [ -z "$APPLICATION" ]; then
		appdeploy_runner_error "APPLICATION required for 'disable'"
		appdeploy_runner_list_available_applications
		exit 1
	fi
	appdeploy_runner_validate_and_setup_application "$APPLICATION"
	appdeploy_runner_disable_service
	;;
status)
	APPLICATION="${2:-}"
	if [ -z "$APPLICATION" ]; then
		appdeploy_runner_error "APPLICATION required for 'status'"
		appdeploy_runner_list_available_applications
		exit 1
	fi
	appdeploy_runner_validate_and_setup_application "$APPLICATION"
	appdeploy_runner_show_status
	;;
logs)
	APPLICATION="${2:-}"
	if [ -z "$APPLICATION" ]; then
		appdeploy_runner_error "APPLICATION required for 'logs'"
		appdeploy_runner_list_available_applications
		exit 1
	fi
	appdeploy_runner_validate_and_setup_application "$APPLICATION"
	appdeploy_runner_show_logs "${3:-}"
	;;
help | --help | -h)
	appdeploy_runner_show_help
	;;
*)
	appdeploy_runner_error "Unknown command: $1"
	printf "Run '%s help' for usage information\n" "$0"
	printf "Run '%s check' to verify system dependencies\n" "$0"
	exit 1
	;;
esac
