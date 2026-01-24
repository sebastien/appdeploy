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

set -euo pipefail

# Configuration
APP_NAME="${APP_NAME:-myapp}"
APP_SCRIPT="${APP_SCRIPT:-./run.sh}"
APP_ENV_SCRIPT="${APP_ENV_SCRIPT:-}"  # Optional: path to env.sh to source before run
APP_LOG_SIZE="${APP_LOG_SIZE:-10M}" # 10MB default for rotatelogs
APP_LOG_COUNT="${APP_LOG_COUNT:-7}" # Keep 7 rotated logs
APP_RUN_USER="${APP_RUN_USER:-$(whoami)}"
APP_USE_SYSTEMD="${APP_USE_SYSTEMD:-auto}" # auto, true, false

# Paths (can be overridden via environment variables)
USER_SYSTEMD_DIR="$HOME/.config/systemd/user"
SYSTEM_SYSTEMD_DIR="/etc/systemd/system"
APP_LOG_DIR="${APP_LOG_DIR:-/var/log/$APP_NAME}"
APP_PID_FILE="${APP_PID_FILE:-/tmp/${APP_NAME}.pid}"

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
ROTATELOGS_INSTALLABLE=false
PACKAGE_MANAGER=""
ROTATELOGS_PACKAGE=""

# Function: appdeploy_runner_detect_package_manager
# Detects the system package manager and sets appropriate rotatelogs package name
appdeploy_runner_detect_package_manager() {
	if command -v apt-get >/dev/null 2>&1; then
		PACKAGE_MANAGER="apt"
		ROTATELOGS_PACKAGE="apache2-utils"
		return 0
	elif command -v dnf >/dev/null 2>&1; then
		PACKAGE_MANAGER="dnf"
		ROTATELOGS_PACKAGE="httpd-tools"
		return 0
	elif command -v yum >/dev/null 2>&1; then
		PACKAGE_MANAGER="yum"
		ROTATELOGS_PACKAGE="httpd-tools"
		return 0
	elif command -v pacman >/dev/null 2>&1; then
		PACKAGE_MANAGER="pacman"
		ROTATELOGS_PACKAGE="apache"
		return 0
	elif command -v zypper >/dev/null 2>&1; then
		PACKAGE_MANAGER="zypper"
		ROTATELOGS_PACKAGE="apache2-utils"
		return 0
	else
		PACKAGE_MANAGER="unknown"
		return 1
	fi
}

# Function: appdeploy_runner_check_systemd
# Checks if systemd is available and running
appdeploy_runner_check_systemd() {
	appdeploy_runner_debug "Checking systemd availability..."

	if command -v systemctl >/dev/null 2>&1; then
		# Check if systemd is actually running (not just installed)
		if systemctl --version >/dev/null 2>&1; then
			SYSTEMD_AVAILABLE=true
			appdeploy_runner_info "+ systemd is available and running"

			# Check if we can use user services
			if [ "$APP_RUN_USER" != "root" ] && [ "$(id -u)" != "0" ]; then
				if systemctl --user --version >/dev/null 2>&1; then
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
# Checks if rotatelogs is available or installable
appdeploy_runner_check_rotatelogs() {
	appdeploy_runner_debug "Checking rotatelogs availability..."

	if command -v rotatelogs >/dev/null 2>&1; then
		ROTATELOGS_AVAILABLE=true
		appdeploy_runner_info "+ rotatelogs is available"
		return 0
	else
		appdeploy_runner_warn "! rotatelogs not found"

		# Check if we can install it
		if [ "$PACKAGE_MANAGER" != "unknown" ]; then
			ROTATELOGS_INSTALLABLE=true
			appdeploy_runner_info "+ rotatelogs can be installed via: $PACKAGE_MANAGER install $ROTATELOGS_PACKAGE"
		else
			appdeploy_runner_warn "! Cannot determine how to install rotatelogs on this system"
		fi

		ROTATELOGS_AVAILABLE=false
		return 1
	fi
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
	echo
	appdeploy_runner_program "=== Dependency Check Summary"

	printf '\n%s--- Core Requirements%s\n' "$BLUE" "$RESET"
	printf '  + Basic shell tools: Available\n'
	printf '  %s systemd: %s\n' \
		"$([ "$SYSTEMD_AVAILABLE" = "true" ] && printf '+' || printf '!')" \
		"$([ "$SYSTEMD_AVAILABLE" = "true" ] && printf 'Available' || printf 'Not available')"

	printf '\n%s--- Log Rotation Options%s\n' "$BLUE" "$RESET"
	if [ "$ROTATELOGS_AVAILABLE" = "true" ]; then
		printf '  + rotatelogs: Available (pipe-based rotation)\n'
	elif [ "$ROTATELOGS_INSTALLABLE" = "true" ]; then
		printf '  ! rotatelogs: Not installed (can install with: %s install %s)\n' "$PACKAGE_MANAGER" "$ROTATELOGS_PACKAGE"
	else
		printf '  - rotatelogs: Not available\n'
	fi
	printf '  + Manual rotation: Always available (fallback)\n'

	printf '\n%s--- Recommended Setup%s\n' "$BLUE" "$RESET"
	if [ "$SYSTEMD_AVAILABLE" = "true" ] && [ "$ROTATELOGS_AVAILABLE" = "true" ]; then
		printf '  [*] Optimal: systemd + rotatelogs (best features)\n'
	elif [ "$SYSTEMD_AVAILABLE" = "true" ] && [ "$ROTATELOGS_INSTALLABLE" = "true" ]; then
		printf '  [+] Good: systemd + rotatelogs (install rotatelogs first)\n'
		printf '      Install with: sudo %s install %s\n' "$PACKAGE_MANAGER" "$ROTATELOGS_PACKAGE"
	elif [ "$SYSTEMD_AVAILABLE" = "true" ]; then
		printf '  [~] Basic: systemd + journald (system log management)\n'
	else
		printf '  [.] Manual: Custom daemon + manual log rotation\n'
	fi

	echo
}

# Function: appdeploy_runner_install_missing_dependencies
# Offers to install missing optional dependencies
appdeploy_runner_install_missing_dependencies() {
	local install_rotatelogs=false

	if [ "$ROTATELOGS_INSTALLABLE" = "true" ] && [ "$ROTATELOGS_AVAILABLE" = "false" ]; then
		echo
		read -p "Install rotatelogs ($ROTATELOGS_PACKAGE) for better log rotation? (y/N): " -n 1 -r
		echo
		if [[ $REPLY =~ ^[Yy]$ ]]; then
			install_rotatelogs=true
		fi
	fi

	if [ "$install_rotatelogs" = "true" ]; then
		appdeploy_runner_log "Installing $ROTATELOGS_PACKAGE..."

		case "$PACKAGE_MANAGER" in
		apt)
			sudo apt-get update && sudo apt-get install -y "$ROTATELOGS_PACKAGE"
			;;
		dnf)
			sudo dnf install -y "$ROTATELOGS_PACKAGE"
			;;
		yum)
			sudo yum install -y "$ROTATELOGS_PACKAGE"
			;;
		pacman)
			sudo pacman -S --noconfirm "$ROTATELOGS_PACKAGE"
			;;
		zypper)
			sudo zypper install -y "$ROTATELOGS_PACKAGE"
			;;
		esac

		# Re-check rotatelogs availability
		if command -v rotatelogs >/dev/null 2>&1; then
			ROTATELOGS_AVAILABLE=true
			appdeploy_runner_step_ok "+ rotatelogs installed successfully"
		else
			appdeploy_runner_step_fail "- Failed to install rotatelogs"
		fi
	fi
}

# Function: appdeploy_runner_comprehensive_dependency_check [install]
# Runs all dependency checks and optionally offers to install missing deps
appdeploy_runner_comprehensive_dependency_check() {
	appdeploy_runner_program "=== Checking Dependencies"
	echo

	local checks_passed=0
	local total_checks=5

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

	# Detect package manager
	appdeploy_runner_detect_package_manager
	((checks_passed++))

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
	if [ "$APP_USE_SYSTEMD" = "auto" ]; then
		APP_USE_SYSTEMD="$SYSTEMD_AVAILABLE"
	elif [ "$APP_USE_SYSTEMD" = "true" ] && [ "$SYSTEMD_AVAILABLE" = "false" ]; then
		appdeploy_runner_warn "systemd requested but not available, falling back to manual daemon"
		APP_USE_SYSTEMD=false
	fi

	appdeploy_runner_show_dependency_summary

	# Offer to install missing dependencies
	if [ "${1:-}" = "install" ]; then
		appdeploy_runner_install_missing_dependencies
	fi

	appdeploy_runner_result "Dependency check complete ($checks_passed/$total_checks optimal)"
	echo
}

# ============================================================================
# SERVICE INSTALLATION
# ============================================================================

# Function: appdeploy_runner_install_rotatelogs
# Installs rotatelogs if not present and installable
appdeploy_runner_install_rotatelogs() {
	if ! command -v rotatelogs >/dev/null 2>&1; then
		if [ "$ROTATELOGS_INSTALLABLE" = "true" ]; then
			appdeploy_runner_log "Installing rotatelogs ($ROTATELOGS_PACKAGE)..."

			case "$PACKAGE_MANAGER" in
			apt)
				sudo apt-get update && sudo apt-get install -y "$ROTATELOGS_PACKAGE"
				;;
			dnf)
				sudo dnf install -y "$ROTATELOGS_PACKAGE"
				;;
			yum)
				sudo yum install -y "$ROTATELOGS_PACKAGE"
				;;
			pacman)
				sudo pacman -S --noconfirm "$ROTATELOGS_PACKAGE"
				;;
			zypper)
				sudo zypper install -y "$ROTATELOGS_PACKAGE"
				;;
			esac

			# Verify installation
			if command -v rotatelogs >/dev/null 2>&1; then
				ROTATELOGS_AVAILABLE=true
				return 0
			else
				appdeploy_runner_error "Failed to install rotatelogs"
				return 1
			fi
		else
			appdeploy_runner_warn "Cannot install rotatelogs automatically on this system"
			return 1
		fi
	fi
	return 0
}

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

# Function: appdeploy_runner_create_manual_daemon
# Creates and starts a manual daemon when systemd is not available
appdeploy_runner_create_manual_daemon() {
	appdeploy_runner_log "Setting up manual daemon management"

	local app_script_abs
	app_script_abs=$(readlink -f "$APP_SCRIPT")
	local daemon_script="/tmp/${APP_NAME}-daemon.sh"
	
	# Resolve env script path if specified
	local env_script_abs=""
	if [ -n "$APP_ENV_SCRIPT" ]; then
		env_script_abs=$(readlink -f "$APP_ENV_SCRIPT" 2>/dev/null || echo "")
		if [ -n "$env_script_abs" ] && [ -f "$env_script_abs" ]; then
			appdeploy_runner_log "Will source env script: $env_script_abs"
		else
			appdeploy_runner_warn "Env script not found: $APP_ENV_SCRIPT (continuing without it)"
			env_script_abs=""
		fi
	fi

	# Create daemon wrapper script
	cat >"$daemon_script" <<'EOF'
#!/bin/bash
# Manual daemon wrapper

APP_SCRIPT_ABS="$1"
APP_LOG_DIR="$2"
APP_LOG_SIZE="$3"
APP_LOG_COUNT="$4"
APP_PID_FILE="$5"
APP_ENV_SCRIPT="$6"

# Create log directory
mkdir -p "$APP_LOG_DIR"

# Source env script if provided and exists
if [ -n "$APP_ENV_SCRIPT" ] && [ -f "$APP_ENV_SCRIPT" ]; then
    source "$APP_ENV_SCRIPT"
fi

# Function for manual log rotation
rotate_logs() {
    local current_log="$APP_LOG_DIR/current.log"
    local max_size_bytes=$((${APP_LOG_SIZE%M} * 1024 * 1024))

    while IFS= read -r line; do
        echo "$line" | tee -a "$current_log"

        # Check if rotation needed
        if [ -f "$current_log" ]; then
            local size=$(stat -c%s "$current_log" 2>/dev/null || echo 0)
            if [ "$size" -gt "$max_size_bytes" ]; then
                local timestamp=$(date +"%Y%m%d_%H%M%S")
                local rotated_file="$APP_LOG_DIR/app_$timestamp.log"

                mv "$current_log" "$rotated_file"
                gzip "$rotated_file" &

                # Clean up old files
                find "$APP_LOG_DIR" -name "app_*.log.gz" -mtime +$APP_LOG_COUNT -delete
                ls -t "$APP_LOG_DIR"/app_*.log.gz 2>/dev/null | tail -n +$((APP_LOG_COUNT + 1)) | xargs rm -f
            fi
        fi
    done
}

# Set process group and run with log rotation
export SERVICE_NAME="$APP_NAME"
export SERVICE_TYPE="main"

if command -v rotatelogs >/dev/null 2>&1; then
    exec "$APP_SCRIPT_ABS" 2>&1 | rotatelogs "$APP_LOG_DIR/app.%Y-%m-%d-%H_%M_%S" "$APP_LOG_SIZE"
else
    exec "$APP_SCRIPT_ABS" 2>&1 | rotate_logs
fi
EOF

	chmod +x "$daemon_script"

	# Start daemon using setsid for proper daemonization
	setsid "$daemon_script" "$app_script_abs" "$APP_LOG_DIR" "$APP_LOG_SIZE" "$APP_LOG_COUNT" "$APP_PID_FILE" "$env_script_abs" &
	echo $! >"$APP_PID_FILE"

	appdeploy_runner_log "Manual daemon started with PID $(cat "$APP_PID_FILE")"
}

# Function: appdeploy_runner_install_service
# Main entry point for installing the service
appdeploy_runner_install_service() {
	appdeploy_runner_comprehensive_dependency_check "install"

	if [ "$APP_USE_SYSTEMD" = "true" ]; then
		appdeploy_runner_create_systemd_service
		appdeploy_runner_step_ok "Service installed using systemd"
	else
		appdeploy_runner_create_manual_daemon
		appdeploy_runner_step_ok "Service installed using manual daemon management"
	fi
}

# ============================================================================
# SERVICE CONTROL
# ============================================================================

# Function: appdeploy_runner_start_service
# Starts the service (systemd or manual daemon)
appdeploy_runner_start_service() {
	appdeploy_runner_comprehensive_dependency_check

	if [ "$APP_USE_SYSTEMD" = "true" ]; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl start "${APP_NAME}.service"
		else
			systemctl --user start "${APP_NAME}.service"
		fi
		appdeploy_runner_step_ok "Service started via systemd"
	else
		if [ -f "$APP_PID_FILE" ] && kill -0 "$(cat "$APP_PID_FILE")" 2>/dev/null; then
			appdeploy_runner_warn "Service already running"
		else
			appdeploy_runner_create_manual_daemon
		fi
	fi
}

# Function: appdeploy_runner_stop_service
# Stops the service (systemd or manual daemon)
appdeploy_runner_stop_service() {
	if [ "$APP_USE_SYSTEMD" = "true" ]; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl stop "${APP_NAME}.service"
		else
			systemctl --user stop "${APP_NAME}.service"
		fi
		appdeploy_runner_step_ok "Service stopped via systemd"
	else
		if [ -f "$APP_PID_FILE" ]; then
			local pid
			pid=$(cat "$APP_PID_FILE")
			if kill -0 "$pid" 2>/dev/null; then
				kill -TERM "$pid"
				rm -f "$APP_PID_FILE"
				appdeploy_runner_step_ok "Manual daemon stopped"
			else
				appdeploy_runner_warn "Daemon not running"
				rm -f "$APP_PID_FILE"
			fi
		else
			appdeploy_runner_warn "PID file not found"
		fi
	fi
}

# Function: appdeploy_runner_enable_service
# Enables the service to start on boot (systemd only)
appdeploy_runner_enable_service() {
	if [ "$APP_USE_SYSTEMD" = "true" ]; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl enable "${APP_NAME}.service"
		else
			systemctl --user enable "${APP_NAME}.service"
		fi
		appdeploy_runner_step_ok "Service enabled (will start on boot)"
	else
		appdeploy_runner_warn "Enable/disable only supported with systemd"
		appdeploy_runner_info "Manual daemon must be started manually after reboot"
	fi
}

# Function: appdeploy_runner_disable_service
# Disables the service from starting on boot (systemd only)
appdeploy_runner_disable_service() {
	if [ "$APP_USE_SYSTEMD" = "true" ]; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl disable "${APP_NAME}.service"
		else
			systemctl --user disable "${APP_NAME}.service"
		fi
		appdeploy_runner_step_ok "Service disabled (will not start on boot)"
	else
		appdeploy_runner_warn "Enable/disable only supported with systemd"
	fi
}

# Function: appdeploy_runner_show_status
# Shows the current status of the service
appdeploy_runner_show_status() {
	if [ "$APP_USE_SYSTEMD" = "true" ]; then
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl status "${APP_NAME}.service" --no-pager
		else
			systemctl --user status "${APP_NAME}.service" --no-pager
		fi
	else
		if [ -f "$APP_PID_FILE" ] && kill -0 "$(cat "$APP_PID_FILE")" 2>/dev/null; then
			appdeploy_runner_info "Manual daemon running with PID $(cat "$APP_PID_FILE")"
			ps -p "$(cat "$APP_PID_FILE")" -o pid,ppid,pgid,user,cmd --no-headers
		else
			appdeploy_runner_info "Manual daemon not running"
		fi
	fi
}

# Function: appdeploy_runner_show_logs [OPTIONS]
# Shows logs for the service (-f for follow)
appdeploy_runner_show_logs() {
	if [ "$APP_USE_SYSTEMD" = "true" ]; then
		if [ "${1:-}" = "-f" ]; then
			if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
				journalctl -f -u "${APP_NAME}.service"
			else
				journalctl --user -f -u "${APP_NAME}.service"
			fi
		else
			if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
				journalctl -u "${APP_NAME}.service" --no-pager -n 20
			else
				journalctl --user -u "${APP_NAME}.service" --no-pager -n 20
			fi
		fi
	else
		if [ -d "$APP_LOG_DIR" ]; then
			if [ "${1:-}" = "-f" ]; then
				if [ -f "$APP_LOG_DIR/current.log" ]; then
					tail -f "$APP_LOG_DIR/current.log"
				else
					appdeploy_runner_warn "No current log file found"
				fi
			else
				if [ -f "$APP_LOG_DIR/current.log" ]; then
					tail -20 "$APP_LOG_DIR/current.log"
				else
					appdeploy_runner_warn "No current log file found"
				fi
			fi
		else
			appdeploy_runner_error "Log directory not found: $APP_LOG_DIR"
		fi
	fi
}

# Function: appdeploy_runner_uninstall_service
# Stops and removes the service completely
appdeploy_runner_uninstall_service() {
	appdeploy_runner_stop_service

	if [ "$APP_USE_SYSTEMD" = "true" ]; then
		local service_file
		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			service_file="$SYSTEM_SYSTEMD_DIR/${APP_NAME}.service"
			systemctl disable "${APP_NAME}.service" 2>/dev/null || true
		else
			service_file="$USER_SYSTEMD_DIR/${APP_NAME}.service"
			systemctl --user disable "${APP_NAME}.service" 2>/dev/null || true
		fi

		if [ -f "$service_file" ]; then
			rm "$service_file"
			appdeploy_runner_log "Service file removed"
		fi

		if [ "$APP_RUN_USER" = "root" ] || [ "$(id -u)" = "0" ]; then
			systemctl daemon-reload
		else
			systemctl --user daemon-reload
		fi
	fi

	# Clean up files
	rm -f "$APP_PID_FILE"
	rm -f "/tmp/${APP_NAME}-daemon.sh"
	rm -f "/usr/local/bin/${APP_NAME}-log-cleanup"

	# Remove from crontab
	crontab -l 2>/dev/null | grep -v "${APP_NAME}-log-cleanup" | crontab - 2>/dev/null || true

	appdeploy_runner_step_ok "Service uninstalled"
}

# Function: appdeploy_runner_check_dependencies
# Runs the dependency check (alias for comprehensive check)
appdeploy_runner_check_dependencies() {
	appdeploy_runner_comprehensive_dependency_check
}

# ============================================================================
# HELP
# ============================================================================

# Function: appdeploy_runner_show_help
# Displays usage information
appdeploy_runner_show_help() {
	cat <<EOF
AppDeploy Runner - Daemon Manager for $APP_NAME

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    check       Check all dependencies and show system capabilities
    install     Create and install the service (includes dependency check)
    uninstall   Stop and remove the service
    start       Start the service
    stop        Stop the service
    restart     Restart the service
    enable      Enable service to start on boot (systemd only)
    disable     Disable service from starting on boot (systemd only)
    status      Show service status
    logs        Show recent log entries
    logs -f     Follow logs in real-time
    help        Show this help

Environment Variables:
    APP_NAME         Service name (default: myapp)
    APP_SCRIPT       Path to script to run (default: ./run.sh)
    APP_ENV_SCRIPT   Path to env script to source before run (optional)
    APP_LOG_SIZE     Log rotation size (default: 10M)
    APP_LOG_COUNT    Number of rotated logs to keep (default: 7)
    APP_RUN_USER     User to run service as (default: current user)
    APP_USE_SYSTEMD  Use systemd: auto/true/false (default: auto)

Dependency Check:
    The script automatically checks for:
    + Basic shell tools (required)
    + systemd availability (preferred)
    + rotatelogs availability (preferred)
    + Package manager detection
    + Permission validation

Installation Commands by Distro:
    Ubuntu/Debian: sudo apt-get install apache2-utils
    Fedora/RHEL:   sudo dnf install httpd-tools
    CentOS:        sudo yum install httpd-tools
    Arch:          sudo pacman -S apache
    openSUSE:      sudo zypper install apache2-utils

Features:
    - Comprehensive dependency checking before any operation
    - Automatic fallback to compatible alternatives
    - Interactive installation of optional dependencies
    - Clear status reporting and recommendations
EOF
}

# ============================================================================
# MAIN
# ============================================================================

# Main command handling with dependency checking
case "${1:-help}" in
check)
	appdeploy_runner_check_dependencies
	;;
install)
	appdeploy_runner_install_service
	;;
uninstall)
	appdeploy_runner_uninstall_service
	;;
start)
	appdeploy_runner_start_service
	;;
stop)
	appdeploy_runner_stop_service
	;;
restart)
	appdeploy_runner_stop_service
	sleep 2
	appdeploy_runner_start_service
	;;
enable)
	appdeploy_runner_enable_service
	;;
disable)
	appdeploy_runner_disable_service
	;;
status)
	appdeploy_runner_show_status
	;;
logs)
	appdeploy_runner_show_logs "${2:-}"
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
