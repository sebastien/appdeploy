#!/usr/bin/env bash
# --
# # File: daemonrun.sh
#
# `daemonrun` is a CLI tool and library to run processes with process group
# management, signal forwarding, daemonization, logging, and sandboxing.
#
# ## Usage
#
# >   daemonrun [OPTIONS] [--] COMMAND [ARGS...]
#
# ## Features
#
# - Named process groups with setsid()
# - Signal forwarding to process group
# - Graceful termination with timeout
# - Daemonization via double-fork
# - Resource limits (memory, files, processes, CPU, timeout)
# - Sandboxing (firejail, unshare)

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

DAEMONRUN_DEFAULT_KILL_TIMEOUT=${DAEMONRUN_DEFAULT_KILL_TIMEOUT:-30}
DAEMONRUN_DEFAULT_PIDFILE_DIR=${DAEMONRUN_DEFAULT_PIDFILE_DIR:-/tmp}
DAEMONRUN_DEFAULT_SANDBOX=${DAEMONRUN_DEFAULT_SANDBOX:-none}
DAEMONRUN_DEFAULT_SIGNALS=${DAEMONRUN_DEFAULT_SIGNALS:-"TERM,INT,HUP,USR1,USR2,QUIT"}

# =============================================================================
# RUNTIME STATE
# =============================================================================

# Process configuration
_DAEMONRUN_GROUP=""
_DAEMONRUN_COMMAND=()
_DAEMONRUN_SETSID=true
_DAEMONRUN_FOREGROUND=false
_DAEMONRUN_DAEMON=false
_DAEMONRUN_PIDFILE=""
_DAEMONRUN_USER=""
_DAEMONRUN_RUN_GROUP=""
_DAEMONRUN_CHDIR=""
_DAEMONRUN_UMASK=""
_DAEMONRUN_CLEAR_ENV=false

# Logging configuration
_DAEMONRUN_LOG_FILE=""
_DAEMONRUN_LOG_LEVEL=1  # 0=DEBUG, 1=INFO, 2=WARN, 3=ERROR
_DAEMONRUN_QUIET=false
_DAEMONRUN_VERBOSE=false
_DAEMONRUN_STDOUT_FILE=""
_DAEMONRUN_STDERR_FILE=""
_DAEMONRUN_SYSLOG=false

# Signal configuration
_DAEMONRUN_KILL_TIMEOUT="$DAEMONRUN_DEFAULT_KILL_TIMEOUT"
_DAEMONRUN_SIGNAL_FORWARD=true
_DAEMONRUN_FORWARD_ALL=true
_DAEMONRUN_SIGNALS_FORWARD=()
_DAEMONRUN_SIGNALS_PRESERVE=()
_DAEMONRUN_STOP_SIGNAL="TERM"
_DAEMONRUN_RELOAD_SIGNAL="HUP"

# Resource limits
_DAEMONRUN_LIMIT_MEMORY=""
_DAEMONRUN_LIMIT_CPU=""
_DAEMONRUN_LIMIT_FILES=""
_DAEMONRUN_LIMIT_PROCS=""
_DAEMONRUN_LIMIT_CORE=""
_DAEMONRUN_LIMIT_STACK=""
_DAEMONRUN_NICE=""
_DAEMONRUN_TIMEOUT=""

# Sandbox configuration
_DAEMONRUN_SANDBOX="$DAEMONRUN_DEFAULT_SANDBOX"
_DAEMONRUN_SANDBOX_PROFILE=""
_DAEMONRUN_SANDBOX_PRIVATE_TMP=false
_DAEMONRUN_SANDBOX_PRIVATE_DEV=false
_DAEMONRUN_SANDBOX_NO_NETWORK=false
_DAEMONRUN_SANDBOX_CAPS_DROP=""
_DAEMONRUN_SANDBOX_CAPS_KEEP=""
_DAEMONRUN_SANDBOX_SECCOMP=false
_DAEMONRUN_SANDBOX_SECCOMP_PROFILE=""
_DAEMONRUN_SANDBOX_READONLY_PATHS=""

# Internal state
_DAEMONRUN_CHILD_PID=""
_DAEMONRUN_PGID=""
_DAEMONRUN_TIMEOUT_PID=""
_DAEMONRUN_CPULIMIT_PID=""
_DAEMONRUN_TERMINATING=false

# -----------------------------------------------------------------------------
#
# LOGGING
#
# -----------------------------------------------------------------------------

# Function: daemonrun_log_level_parse LEVEL_STRING
# Converts log level string to numeric value.
#
# Parameters:
#   LEVEL_STRING - Level name: debug, info, warn, error (case-insensitive)
#
# Returns:
#   Outputs numeric level (0-3) to stdout.
daemonrun_log_level_parse() {
    local level="${1,,}"  # lowercase

    case "$level" in
        debug|0)   echo 0 ;;
        info|1)    echo 1 ;;
        warn|warning|2) echo 2 ;;
        error|3)   echo 3 ;;
        *)
            # Default to info if invalid
            echo 1
            ;;
    esac
}

# Function: daemonrun_log_write LEVEL MESSAGE...
# Core logging function. Writes timestamped message with level, group, and PID.
#
# Parameters:
#   LEVEL   - Numeric level (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR)
#   MESSAGE - Message parts (joined with spaces)
#
# Output format: YYYY-MM-DD HH:MM:SS [LEVEL] [GROUP:PID] MESSAGE
# Writes to _DAEMONRUN_LOG_FILE if set, syslog if enabled, otherwise stderr.
# Respects _DAEMONRUN_QUIET and _DAEMONRUN_VERBOSE settings.
daemonrun_log_write() {
    local level="$1"
    shift
    local message="$*"

    # Check if we should output this level
    if ((level < _DAEMONRUN_LOG_LEVEL)); then
        return 0
    fi

    # Quiet mode suppresses INFO and below
    if [[ "$_DAEMONRUN_QUIET" == true ]] && ((level < 2)); then
        return 0
    fi

    # Map level to name and syslog priority
    local level_name syslog_priority
    case "$level" in
        0) level_name="DEBUG"; syslog_priority="debug" ;;
        1) level_name="INFO"; syslog_priority="info" ;;
        2) level_name="WARN"; syslog_priority="warning" ;;
        3) level_name="ERROR"; syslog_priority="err" ;;
        *) level_name="UNKNOWN"; syslog_priority="notice" ;;
    esac

    # Build log line
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local group="${_DAEMONRUN_GROUP:-daemonrun}"
    local pid="${_DAEMONRUN_CHILD_PID:-$$}"
    local line="$timestamp [$level_name] [$group:$pid] $message"

    # Output to appropriate destination
    if [[ "$_DAEMONRUN_SYSLOG" == true ]]; then
        # Log to syslog using logger command
        if command -v logger &>/dev/null; then
            logger -t "daemonrun[$pid]" -p "daemon.$syslog_priority" "[$group] $message"
        fi
        # Also write to log file if specified
        if [[ -n "$_DAEMONRUN_LOG_FILE" ]]; then
            echo "$line" >> "$_DAEMONRUN_LOG_FILE"
        fi
    elif [[ -n "$_DAEMONRUN_LOG_FILE" ]]; then
        echo "$line" >> "$_DAEMONRUN_LOG_FILE"
    else
        echo "$line" >&2
    fi
}

# Function: daemonrun_log_debug MESSAGE...
# Log debug message (only shown with --verbose).
daemonrun_log_debug() {
    daemonrun_log_write 0 "$@"
}

# Function: daemonrun_log_info MESSAGE...
# Log info message (suppressed with --quiet).
daemonrun_log_info() {
    daemonrun_log_write 1 "$@"
}

# Function: daemonrun_log_warn MESSAGE...
# Log warning message.
daemonrun_log_warn() {
    daemonrun_log_write 2 "$@"
}

# Function: daemonrun_log_error MESSAGE...
# Log error message (always shown).
daemonrun_log_error() {
    daemonrun_log_write 3 "$@"
}

# -----------------------------------------------------------------------------
#
# PARSING
#
# -----------------------------------------------------------------------------

# Function: daemonrun_parse_size SIZE
# Parses human-readable size to bytes.
#
# Parameters:
#   SIZE - Size string like "512M", "1G", "1024"
#
# Returns:
#   Outputs integer bytes to stdout. Exits 1 on invalid format.
daemonrun_parse_size() {
    local input="$1"
    local number suffix multiplier

    if [[ "$input" =~ ^([0-9]+)([KkMmGg][Bb]?)?$ ]]; then
        number="${BASH_REMATCH[1]}"
        suffix="${BASH_REMATCH[2]:-}"
    else
        daemonrun_log_error "Invalid size format '$input' (use: 512M, 1G, etc.)"
        return 1
    fi

    case "${suffix,,}" in
        k|kb)   multiplier=1024 ;;
        m|mb)   multiplier=$((1024 * 1024)) ;;
        g|gb)   multiplier=$((1024 * 1024 * 1024)) ;;
        "")     multiplier=1 ;;
        *)
            daemonrun_log_error "Unknown size suffix '$suffix'"
            return 1
            ;;
    esac

    echo $((number * multiplier))
}

# Function: daemonrun_parse_list STRING DELIMITER
# Splits STRING by DELIMITER, outputs one item per line.
#
# Parameters:
#   STRING    - String to split
#   DELIMITER - Delimiter character (default: comma)
daemonrun_parse_list() {
    local string="$1"
    local delimiter="${2:-,}"

    if [[ -z "$string" ]]; then
        return 0
    fi

    local IFS="$delimiter"
    local item
    for item in $string; do
        # Trim whitespace
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] && echo "$item"
    done
}

# Function: daemonrun_parse_args ARGS...
# Parses command-line arguments into global state variables.
#
# Parameters:
#   ARGS - Command-line arguments
daemonrun_parse_args() {
    local positional=()
    local seen_separator=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            # Process management
            -g|--group)
                _DAEMONRUN_GROUP="$2"
                shift 2
                ;;
            --group=*)
                _DAEMONRUN_GROUP="${1#*=}"
                shift
                ;;
            -s|--setsid)
                _DAEMONRUN_SETSID=true
                shift
                ;;
            --no-setsid)
                _DAEMONRUN_SETSID=false
                shift
                ;;
            -f|--foreground)
                _DAEMONRUN_FOREGROUND=true
                shift
                ;;

            # Signal handling
            -k|--kill-timeout)
                _DAEMONRUN_KILL_TIMEOUT="$2"
                shift 2
                ;;
            --kill-timeout=*)
                _DAEMONRUN_KILL_TIMEOUT="${1#*=}"
                shift
                ;;
            -A|--forward-all-signals)
                _DAEMONRUN_FORWARD_ALL=true
                _DAEMONRUN_SIGNAL_FORWARD=true
                shift
                ;;
            -S|--signal)
                # Override default signals
                _DAEMONRUN_SIGNALS_FORWARD=()
                _DAEMONRUN_FORWARD_ALL=false
                while IFS= read -r sig; do
                    _DAEMONRUN_SIGNALS_FORWARD+=("$sig")
                done < <(daemonrun_parse_list "$2")
                shift 2
                ;;
            --signal=*)
                _DAEMONRUN_SIGNALS_FORWARD=()
                _DAEMONRUN_FORWARD_ALL=false
                while IFS= read -r sig; do
                    _DAEMONRUN_SIGNALS_FORWARD+=("$sig")
                done < <(daemonrun_parse_list "${1#*=}")
                shift
                ;;
            --no-signal-forward)
                _DAEMONRUN_SIGNAL_FORWARD=false
                _DAEMONRUN_FORWARD_ALL=false
                shift
                ;;
            --preserve-signals)
                while IFS= read -r sig; do
                    _DAEMONRUN_SIGNALS_PRESERVE+=("$sig")
                done < <(daemonrun_parse_list "$2")
                shift 2
                ;;
            --preserve-signals=*)
                while IFS= read -r sig; do
                    _DAEMONRUN_SIGNALS_PRESERVE+=("$sig")
                done < <(daemonrun_parse_list "${1#*=}")
                shift
                ;;
            --stop-signal)
                _DAEMONRUN_STOP_SIGNAL="$2"
                shift 2
                ;;
            --stop-signal=*)
                _DAEMONRUN_STOP_SIGNAL="${1#*=}"
                shift
                ;;
            --reload-signal)
                _DAEMONRUN_RELOAD_SIGNAL="$2"
                shift 2
                ;;
            --reload-signal=*)
                _DAEMONRUN_RELOAD_SIGNAL="${1#*=}"
                shift
                ;;

            # Daemonization
            -d|--daemon)
                _DAEMONRUN_DAEMON=true
                shift
                ;;
            -p|--pidfile)
                _DAEMONRUN_PIDFILE="$2"
                shift 2
                ;;
            --pidfile=*)
                _DAEMONRUN_PIDFILE="${1#*=}"
                shift
                ;;
            -u|--user)
                _DAEMONRUN_USER="$2"
                shift 2
                ;;
            --user=*)
                _DAEMONRUN_USER="${1#*=}"
                shift
                ;;
            -G|--run-group)
                _DAEMONRUN_RUN_GROUP="$2"
                shift 2
                ;;
            --run-group=*)
                _DAEMONRUN_RUN_GROUP="${1#*=}"
                shift
                ;;
            -C|--chdir)
                _DAEMONRUN_CHDIR="$2"
                shift 2
                ;;
            --chdir=*)
                _DAEMONRUN_CHDIR="${1#*=}"
                shift
                ;;
            --umask)
                _DAEMONRUN_UMASK="$2"
                shift 2
                ;;
            --umask=*)
                _DAEMONRUN_UMASK="${1#*=}"
                shift
                ;;

            # Logging
            -l|--log)
                _DAEMONRUN_LOG_FILE="$2"
                shift 2
                ;;
            --log=*)
                _DAEMONRUN_LOG_FILE="${1#*=}"
                shift
                ;;
            --log-level)
                _DAEMONRUN_LOG_LEVEL=$(daemonrun_log_level_parse "$2")
                shift 2
                ;;
            --log-level=*)
                _DAEMONRUN_LOG_LEVEL=$(daemonrun_log_level_parse "${1#*=}")
                shift
                ;;
            --stdout)
                _DAEMONRUN_STDOUT_FILE="$2"
                shift 2
                ;;
            --stdout=*)
                _DAEMONRUN_STDOUT_FILE="${1#*=}"
                shift
                ;;
            --stderr)
                _DAEMONRUN_STDERR_FILE="$2"
                shift 2
                ;;
            --stderr=*)
                _DAEMONRUN_STDERR_FILE="${1#*=}"
                shift
                ;;
            --syslog)
                _DAEMONRUN_SYSLOG=true
                shift
                ;;
            -q|--quiet)
                _DAEMONRUN_QUIET=true
                shift
                ;;
            -v|--verbose)
                _DAEMONRUN_VERBOSE=true
                _DAEMONRUN_LOG_LEVEL=0
                shift
                ;;
            --clear-env)
                _DAEMONRUN_CLEAR_ENV=true
                shift
                ;;

            # Resource limits
            --memory-limit)
                _DAEMONRUN_LIMIT_MEMORY="$2"
                shift 2
                ;;
            --memory-limit=*)
                _DAEMONRUN_LIMIT_MEMORY="${1#*=}"
                shift
                ;;
            --cpu-limit)
                _DAEMONRUN_LIMIT_CPU="$2"
                shift 2
                ;;
            --cpu-limit=*)
                _DAEMONRUN_LIMIT_CPU="${1#*=}"
                shift
                ;;
            --file-limit)
                _DAEMONRUN_LIMIT_FILES="$2"
                shift 2
                ;;
            --file-limit=*)
                _DAEMONRUN_LIMIT_FILES="${1#*=}"
                shift
                ;;
            --proc-limit)
                _DAEMONRUN_LIMIT_PROCS="$2"
                shift 2
                ;;
            --proc-limit=*)
                _DAEMONRUN_LIMIT_PROCS="${1#*=}"
                shift
                ;;
            --core-limit)
                _DAEMONRUN_LIMIT_CORE="$2"
                shift 2
                ;;
            --core-limit=*)
                _DAEMONRUN_LIMIT_CORE="${1#*=}"
                shift
                ;;
            --stack-limit)
                _DAEMONRUN_LIMIT_STACK="$2"
                shift 2
                ;;
            --stack-limit=*)
                _DAEMONRUN_LIMIT_STACK="${1#*=}"
                shift
                ;;
            --nice)
                _DAEMONRUN_NICE="$2"
                shift 2
                ;;
            --nice=*)
                _DAEMONRUN_NICE="${1#*=}"
                shift
                ;;
            --timeout)
                _DAEMONRUN_TIMEOUT="$2"
                shift 2
                ;;
            --timeout=*)
                _DAEMONRUN_TIMEOUT="${1#*=}"
                shift
                ;;

            # Sandboxing
            --sandbox)
                _DAEMONRUN_SANDBOX="$2"
                shift 2
                ;;
            --sandbox=*)
                _DAEMONRUN_SANDBOX="${1#*=}"
                shift
                ;;
            --sandbox-profile)
                _DAEMONRUN_SANDBOX_PROFILE="$2"
                shift 2
                ;;
            --sandbox-profile=*)
                _DAEMONRUN_SANDBOX_PROFILE="${1#*=}"
                shift
                ;;
            --private-tmp)
                _DAEMONRUN_SANDBOX_PRIVATE_TMP=true
                shift
                ;;
            --private-dev)
                _DAEMONRUN_SANDBOX_PRIVATE_DEV=true
                shift
                ;;
            --no-network)
                _DAEMONRUN_SANDBOX_NO_NETWORK=true
                shift
                ;;
            --caps-drop)
                _DAEMONRUN_SANDBOX_CAPS_DROP="$2"
                shift 2
                ;;
            --caps-drop=*)
                _DAEMONRUN_SANDBOX_CAPS_DROP="${1#*=}"
                shift
                ;;
            --caps-keep)
                _DAEMONRUN_SANDBOX_CAPS_KEEP="$2"
                shift 2
                ;;
            --caps-keep=*)
                _DAEMONRUN_SANDBOX_CAPS_KEEP="${1#*=}"
                shift
                ;;
            --seccomp)
                _DAEMONRUN_SANDBOX_SECCOMP=true
                shift
                ;;
            --seccomp-profile)
                _DAEMONRUN_SANDBOX_SECCOMP_PROFILE="$2"
                shift 2
                ;;
            --seccomp-profile=*)
                _DAEMONRUN_SANDBOX_SECCOMP_PROFILE="${1#*=}"
                shift
                ;;
            --readonly-paths)
                _DAEMONRUN_SANDBOX_READONLY_PATHS="$2"
                shift 2
                ;;
            --readonly-paths=*)
                _DAEMONRUN_SANDBOX_READONLY_PATHS="${1#*=}"
                shift
                ;;

            # Help
            -h|--help)
                daemonrun_parse_usage
                exit 0
                ;;

            # Separator
            --)
                seen_separator=true
                shift
                break
                ;;

            # Unknown option
            -*)
                daemonrun_log_error "Unknown option: $1"
                daemonrun_parse_usage >&2
                exit 1
                ;;

            # Positional (command)
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    # After --, everything is the command
    if $seen_separator; then
        _DAEMONRUN_COMMAND=("$@")
    elif [[ ${#positional[@]} -gt 0 ]]; then
        _DAEMONRUN_COMMAND=("${positional[@]}")
    fi

    # Set default group from command basename
    if [[ -z "$_DAEMONRUN_GROUP" ]] && [[ ${#_DAEMONRUN_COMMAND[@]} -gt 0 ]]; then
        _DAEMONRUN_GROUP=$(basename "${_DAEMONRUN_COMMAND[0]}")
    fi

    # Set default signals to forward if not overridden
    if [[ ${#_DAEMONRUN_SIGNALS_FORWARD[@]} -eq 0 ]] && [[ "$_DAEMONRUN_SIGNAL_FORWARD" == true ]]; then
        while IFS= read -r sig; do
            _DAEMONRUN_SIGNALS_FORWARD+=("$sig")
        done < <(daemonrun_parse_list "$DAEMONRUN_DEFAULT_SIGNALS")
    fi
}

# Function: daemonrun_parse_validate
# Validates parsed arguments for consistency and conflicts.
#
# Returns:
#   0 on success, exits with error message on failure.
daemonrun_parse_validate() {
    # Must have a command
    if [[ ${#_DAEMONRUN_COMMAND[@]} -eq 0 ]]; then
        daemonrun_log_error "No command specified"
        daemonrun_parse_usage >&2
        exit 1
    fi

    # Check daemon + foreground conflict
    if [[ "$_DAEMONRUN_DAEMON" == true ]] && [[ "$_DAEMONRUN_FOREGROUND" == true ]]; then
        daemonrun_log_error "Cannot use --daemon and --foreground together"
        exit 1
    fi

    # Validate command exists
    daemonrun_process_command_check

    # Validate user if specified
    if [[ -n "$_DAEMONRUN_USER" ]]; then
        if [[ $EUID -ne 0 ]]; then
            daemonrun_log_error "Must be root to use --user"
            exit 1
        fi
        if ! id "$_DAEMONRUN_USER" &>/dev/null; then
            daemonrun_log_error "User not found: $_DAEMONRUN_USER"
            exit 1
        fi
    fi

    # Validate run-group if specified
    if [[ -n "$_DAEMONRUN_RUN_GROUP" ]]; then
        if [[ $EUID -ne 0 ]]; then
            daemonrun_log_error "Must be root to use --run-group"
            exit 1
        fi
        if ! getent group "$_DAEMONRUN_RUN_GROUP" &>/dev/null; then
            daemonrun_log_error "Group not found: $_DAEMONRUN_RUN_GROUP"
            exit 1
        fi
    fi

    # Validate chdir if specified
    if [[ -n "$_DAEMONRUN_CHDIR" ]]; then
        if [[ ! -d "$_DAEMONRUN_CHDIR" ]]; then
            daemonrun_log_error "Directory not found: $_DAEMONRUN_CHDIR"
            exit 1
        fi
    fi

    # Validate umask if specified
    if [[ -n "$_DAEMONRUN_UMASK" ]]; then
        if ! [[ "$_DAEMONRUN_UMASK" =~ ^[0-7]{1,4}$ ]]; then
            daemonrun_log_error "Invalid umask format: $_DAEMONRUN_UMASK (use octal: 022, 077, etc.)"
            exit 1
        fi
    fi

    # Validate kill timeout
    if ! [[ "$_DAEMONRUN_KILL_TIMEOUT" =~ ^[0-9]+$ ]]; then
        daemonrun_log_error "Kill timeout must be a positive integer"
        exit 1
    fi

    # Validate CPU limit range
    if [[ -n "$_DAEMONRUN_LIMIT_CPU" ]]; then
        if ! [[ "$_DAEMONRUN_LIMIT_CPU" =~ ^[0-9]+$ ]] || \
           (( _DAEMONRUN_LIMIT_CPU < 1 || _DAEMONRUN_LIMIT_CPU > 100 )); then
            daemonrun_log_error "CPU limit must be 1-100"
            exit 1
        fi
    fi

    # Validate nice priority range
    if [[ -n "$_DAEMONRUN_NICE" ]]; then
        if ! [[ "$_DAEMONRUN_NICE" =~ ^-?[0-9]+$ ]] || \
           (( _DAEMONRUN_NICE < -20 || _DAEMONRUN_NICE > 19 )); then
            daemonrun_log_error "Nice priority must be -20 to 19"
            exit 1
        fi
    fi

    # Validate core limit if specified
    if [[ -n "$_DAEMONRUN_LIMIT_CORE" ]]; then
        if [[ "$_DAEMONRUN_LIMIT_CORE" != "unlimited" ]] && \
           ! [[ "$_DAEMONRUN_LIMIT_CORE" =~ ^[0-9]+[KkMmGg]?[Bb]?$ ]]; then
            daemonrun_log_error "Invalid core limit: $_DAEMONRUN_LIMIT_CORE (use: 0, unlimited, or size)"
            exit 1
        fi
    fi

    # Validate stack limit if specified
    if [[ -n "$_DAEMONRUN_LIMIT_STACK" ]]; then
        if [[ "$_DAEMONRUN_LIMIT_STACK" != "unlimited" ]] && \
           ! [[ "$_DAEMONRUN_LIMIT_STACK" =~ ^[0-9]+[KkMmGg]?[Bb]?$ ]]; then
            daemonrun_log_error "Invalid stack limit: $_DAEMONRUN_LIMIT_STACK (use: unlimited or size like 8M)"
            exit 1
        fi
    fi

    # Validate seccomp profile exists if specified
    if [[ -n "$_DAEMONRUN_SANDBOX_SECCOMP_PROFILE" ]] && [[ ! -f "$_DAEMONRUN_SANDBOX_SECCOMP_PROFILE" ]]; then
        daemonrun_log_error "Seccomp profile not found: $_DAEMONRUN_SANDBOX_SECCOMP_PROFILE"
        exit 1
    fi

    # Validate stdout file is writable if specified
    if [[ -n "$_DAEMONRUN_STDOUT_FILE" ]]; then
        if [[ "${_DAEMONRUN_STDOUT_FILE:0:1}" != "/" ]]; then
            _DAEMONRUN_STDOUT_FILE="$(pwd)/$_DAEMONRUN_STDOUT_FILE"
        fi
        local stdout_dir
        stdout_dir=$(dirname "$_DAEMONRUN_STDOUT_FILE")
        if [[ ! -d "$stdout_dir" ]]; then
            mkdir -p "$stdout_dir" 2>/dev/null || {
                daemonrun_log_error "Cannot create stdout directory: $stdout_dir"
                exit 1
            }
        fi
    fi

    # Validate stderr file is writable if specified
    if [[ -n "$_DAEMONRUN_STDERR_FILE" ]]; then
        if [[ "${_DAEMONRUN_STDERR_FILE:0:1}" != "/" ]]; then
            _DAEMONRUN_STDERR_FILE="$(pwd)/$_DAEMONRUN_STDERR_FILE"
        fi
        local stderr_dir
        stderr_dir=$(dirname "$_DAEMONRUN_STDERR_FILE")
        if [[ ! -d "$stderr_dir" ]]; then
            mkdir -p "$stderr_dir" 2>/dev/null || {
                daemonrun_log_error "Cannot create stderr directory: $stderr_dir"
                exit 1
            }
        fi
    fi

    # Validate sandbox
    daemonrun_sandbox_validate

    # Validate log file is writable (if specified)
    if [[ -n "$_DAEMONRUN_LOG_FILE" ]]; then
        # Convert relative path to absolute
        if [[ "${_DAEMONRUN_LOG_FILE:0:1}" != "/" ]]; then
            _DAEMONRUN_LOG_FILE="$(pwd)/$_DAEMONRUN_LOG_FILE"
        fi
        local log_dir
        log_dir=$(dirname "$_DAEMONRUN_LOG_FILE")
        if [[ ! -d "$log_dir" ]]; then
            mkdir -p "$log_dir" 2>/dev/null || {
                daemonrun_log_error "Cannot create log directory: $log_dir"
                exit 1
            }
        fi
        if ! touch "$_DAEMONRUN_LOG_FILE" 2>/dev/null; then
            daemonrun_log_error "Cannot write to log file: $_DAEMONRUN_LOG_FILE"
            exit 1
        fi
    fi

    # Convert relative pidfile to absolute
    if [[ -n "$_DAEMONRUN_PIDFILE" ]] && [[ "${_DAEMONRUN_PIDFILE:0:1}" != "/" ]]; then
        _DAEMONRUN_PIDFILE="$(pwd)/$_DAEMONRUN_PIDFILE"
    fi
}

# Function: daemonrun_parse_usage
# Prints usage information to stdout.
daemonrun_parse_usage() {
    cat <<'EOF'
Usage: daemonrun [OPTIONS] [--] COMMAND [ARGS...]

A process manager with signal forwarding, daemonization, and sandboxing.

Process Management:
  -g, --group NAME         Set process group name (default: command basename)
  -s, --setsid             Create new session with setsid() (default: true)
  -f, --foreground         Keep process in foreground (no daemonization)
  --clear-env              Clear environment variables before running command

Signal Handling:
  -A, --forward-all-signals  Forward all signals to process group (default: true)
  -S, --signal SIG         Forward specific signals (can be repeated)
  --no-signal-forward      Disable automatic signal forwarding
  --preserve-signals LIST  Don't forward these signals (comma-separated)
  -k, --kill-timeout SEC   Timeout for SIGKILL after SIGTERM (default: 30)
  --stop-signal SIG        Signal for graceful stop (default: TERM)
  --reload-signal SIG      Signal for reload (default: HUP)

Daemonization:
  -d, --daemon             Double-fork to create true daemon
  -p, --pidfile FILE       Write PID to file (default: /tmp/GROUPNAME.pid)
  -u, --user USER          Run as specific user (requires root)
  -G, --run-group GROUP    Run as specific group (requires root)
  -C, --chdir DIR          Change working directory (default: / for daemon)
  --umask OCTAL            Set file creation mask (default: 022)

Logging:
  -l, --log FILE           Log events to file (default: stderr)
  --log-level LEVEL        Log level: debug,info,warn,error (default: info)
  --stdout FILE            Redirect child stdout to file
  --stderr FILE            Redirect child stderr to file
  --syslog                 Log to syslog instead of file
  -q, --quiet              Suppress all output except errors
  -v, --verbose            Enable verbose logging (same as --log-level debug)

Resource Limits:
  --memory-limit SIZE      Set memory limit (e.g., 512M, 1G)
  --cpu-limit PERCENT      Set CPU usage limit (1-100, requires cpulimit)
  --file-limit COUNT       Set maximum open files
  --proc-limit COUNT       Set maximum processes/threads
  --core-limit SIZE        Core dump size limit (e.g., 0, unlimited)
  --stack-limit SIZE       Stack size limit (e.g., 8M)
  --timeout SECONDS        Kill process after timeout
  --nice PRIORITY          Process niceness (-20 to 19, default: 0)

Sandboxing:
  --sandbox TYPE           Enable sandboxing: none, firejail, unshare (default: none)
  --sandbox-profile FILE   Use custom sandbox profile
  --private-tmp            Use private /tmp directory
  --private-dev            Use private /dev directory
  --no-network             Disable network access
  --caps-drop LIST         Drop capabilities (comma-separated)
  --caps-keep LIST         Keep only these capabilities (comma-separated)
  --seccomp                Enable seccomp filtering
  --seccomp-profile FILE   Custom seccomp profile file
  --readonly-paths LIST    Make paths read-only (colon-separated, firejail only)

Examples:
  # Simple process group with logging
  daemonrun --group myapp --log /var/log/myapp.log ./myapp

  # Daemonize with PID file
  daemonrun --daemon --pidfile /var/run/myapp.pid --group myapp ./myapp

  # Foreground with resource limits
  daemonrun --foreground --memory-limit 512M --timeout 3600 ./batch-job

  # Sandboxed execution
  daemonrun --sandbox firejail --no-network --private-tmp ./untrusted-app

  # Run as different user/group with nice priority
  daemonrun --user nobody --run-group nogroup --nice 10 ./service
EOF
}

# -----------------------------------------------------------------------------
#
# SIGNAL HANDLING
#
# -----------------------------------------------------------------------------

# Function: daemonrun_signal_setup
# Installs signal handlers for forwarding and cleanup.
daemonrun_signal_setup() {
    # Always set up cleanup on EXIT
    trap daemonrun_signal_cleanup EXIT

    # Set up signal forwarding if enabled
    if [[ "$_DAEMONRUN_SIGNAL_FORWARD" == true ]]; then
        local sig
        for sig in "${_DAEMONRUN_SIGNALS_FORWARD[@]}"; do
            # Skip preserved signals
            local preserved=false
            local p
            for p in "${_DAEMONRUN_SIGNALS_PRESERVE[@]}"; do
                if [[ "$sig" == "$p" ]]; then
                    preserved=true
                    break
                fi
            done

            if [[ "$preserved" == false ]]; then
                # shellcheck disable=SC2064
                trap "daemonrun_signal_handler $sig" "$sig"
                daemonrun_log_debug "Installed handler for SIG$sig"
            fi
        done
    fi
}

# Function: daemonrun_signal_handler SIGNAL
# Handler for trapped signals. Forwards to process group.
#
# Parameters:
#   SIGNAL - Signal name (without SIG prefix)
daemonrun_signal_handler() {
    local sig="$1"

    daemonrun_log_info "Received SIG$sig, forwarding to process group"

    # For TERM and INT, initiate graceful termination
    if [[ "$sig" == "TERM" ]] || [[ "$sig" == "INT" ]]; then
        daemonrun_signal_terminate
    else
        # Forward other signals directly
        if [[ -n "$_DAEMONRUN_CHILD_PID" ]]; then
            kill -"$sig" "-$_DAEMONRUN_PGID" 2>/dev/null || true
        fi
    fi
}

# Function: daemonrun_signal_terminate
# Initiates graceful termination with timeout, then SIGKILL.
daemonrun_signal_terminate() {
    # Prevent re-entry
    if [[ "$_DAEMONRUN_TERMINATING" == true ]]; then
        return 0
    fi
    _DAEMONRUN_TERMINATING=true

    local timeout="$_DAEMONRUN_KILL_TIMEOUT"

    if [[ -z "$_DAEMONRUN_CHILD_PID" ]]; then
        daemonrun_log_debug "No child process to terminate"
        return 0
    fi

    # Check if process is still running
    if ! kill -0 "$_DAEMONRUN_CHILD_PID" 2>/dev/null; then
        daemonrun_log_debug "Child process already exited"
        return 0
    fi

    daemonrun_log_info "Initiating graceful termination (timeout: ${timeout}s)"

    # Send SIGTERM to process group (skip if timeout is 0)
    if ((timeout > 0)); then
        kill -TERM "-$_DAEMONRUN_PGID" 2>/dev/null || true

        # Wait for process to exit
        local elapsed=0
        while ((elapsed < timeout)); do
            if ! kill -0 "$_DAEMONRUN_CHILD_PID" 2>/dev/null; then
                daemonrun_log_info "Process terminated gracefully"
                return 0
            fi
            sleep 1
            ((elapsed++)) || true
        done

        daemonrun_log_warn "Graceful termination timeout, sending SIGKILL"
    fi

    # Force kill
    kill -KILL "-$_DAEMONRUN_PGID" 2>/dev/null || true
}

# Function: daemonrun_signal_cleanup
# EXIT trap handler. Removes PID file, cancels timeout/cpulimit.
daemonrun_signal_cleanup() {
    daemonrun_log_debug "Running cleanup"

    # Cancel timeout watchdog
    daemonrun_limit_timeout_cancel

    # Cancel cpulimit
    if [[ -n "$_DAEMONRUN_CPULIMIT_PID" ]]; then
        kill "$_DAEMONRUN_CPULIMIT_PID" 2>/dev/null || true
    fi

    # Remove PID file
    daemonrun_pidfile_remove
}

# -----------------------------------------------------------------------------
#
# PID FILE MANAGEMENT
#
# -----------------------------------------------------------------------------

# Function: daemonrun_pidfile_path
# Returns the PID file path (configured or default).
#
# Returns:
#   Outputs PID file path to stdout.
daemonrun_pidfile_path() {
    if [[ -n "$_DAEMONRUN_PIDFILE" ]]; then
        echo "$_DAEMONRUN_PIDFILE"
    else
        echo "${DAEMONRUN_DEFAULT_PIDFILE_DIR}/${_DAEMONRUN_GROUP}.pid"
    fi
}

# Function: daemonrun_pidfile_check
# Checks if PID file exists and referenced process is running.
#
# Returns:
#   0 if process is running (outputs PID), 1 if stale/missing.
daemonrun_pidfile_check() {
    local pidfile
    pidfile=$(daemonrun_pidfile_path)

    if [[ ! -f "$pidfile" ]]; then
        return 1
    fi

    local pid
    pid=$(cat "$pidfile" 2>/dev/null) || return 1

    if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
        daemonrun_log_warn "Invalid PID in pidfile: $pidfile"
        rm -f "$pidfile"
        return 1
    fi

    if kill -0 "$pid" 2>/dev/null; then
        echo "$pid"
        return 0
    else
        daemonrun_log_warn "Removing stale PID file (process $pid not running)"
        rm -f "$pidfile"
        return 1
    fi
}

# Function: daemonrun_pidfile_write PID
# Writes PID to file, creating parent directory if needed.
#
# Parameters:
#   PID - Process ID to write
daemonrun_pidfile_write() {
    local pid="$1"
    local pidfile
    pidfile=$(daemonrun_pidfile_path)

    # Create parent directory
    local piddir
    piddir=$(dirname "$pidfile")
    if [[ ! -d "$piddir" ]]; then
        mkdir -p "$piddir" 2>/dev/null || {
            daemonrun_log_error "Cannot create PID directory: $piddir"
            return 1
        }
    fi

    # Write PID
    echo "$pid" > "$pidfile" || {
        daemonrun_log_error "Cannot write PID file: $pidfile"
        return 1
    }

    daemonrun_log_debug "Wrote PID $pid to $pidfile"
}

# Function: daemonrun_pidfile_read
# Reads and outputs PID from file.
#
# Returns:
#   Outputs PID to stdout. Returns 1 if file missing or invalid.
daemonrun_pidfile_read() {
    local pidfile
    pidfile=$(daemonrun_pidfile_path)

    if [[ ! -f "$pidfile" ]]; then
        return 1
    fi

    cat "$pidfile"
}

# Function: daemonrun_pidfile_remove
# Removes PID file if it exists.
daemonrun_pidfile_remove() {
    local pidfile
    pidfile=$(daemonrun_pidfile_path)

    if [[ -f "$pidfile" ]]; then
        rm -f "$pidfile"
        daemonrun_log_debug "Removed PID file: $pidfile"
    fi
}

# -----------------------------------------------------------------------------
#
# PROCESS MANAGEMENT
#
# -----------------------------------------------------------------------------

# Function: daemonrun_process_command_check
# Validates command exists and is executable.
#
# Returns:
#   0 on success, exits with error on failure.
daemonrun_process_command_check() {
    local cmd="${_DAEMONRUN_COMMAND[0]}"

    # Check if command exists
    if ! command -v "$cmd" &>/dev/null; then
        # Maybe it's a path?
        if [[ ! -f "$cmd" ]]; then
            daemonrun_log_error "Command not found: $cmd"
            exit 127
        fi
    fi

    # Check if executable (for paths)
    if [[ -f "$cmd" ]] && [[ ! -x "$cmd" ]]; then
        daemonrun_log_error "Permission denied: $cmd"
        exit 126
    fi
}

# Function: daemonrun_process_privileges_drop
# Drops privileges to configured user.
#
# Must be called as root. Uses su to switch user.
daemonrun_process_privileges_drop() {
    if [[ -z "$_DAEMONRUN_USER" ]]; then
        return 0
    fi

    daemonrun_log_info "Dropping privileges to user: $_DAEMONRUN_USER"

    # We'll use exec su to switch user in the actual exec
    # This function just validates
    if [[ $EUID -ne 0 ]]; then
        daemonrun_log_error "Cannot drop privileges: not running as root"
        return 1
    fi
}

# Function: daemonrun_process_chdir
# Changes to configured working directory.
daemonrun_process_chdir() {
    local dir="${_DAEMONRUN_CHDIR:-}"

    # Default to / for daemon mode
    if [[ -z "$dir" ]] && [[ "$_DAEMONRUN_DAEMON" == true ]]; then
        dir="/"
    fi

    if [[ -n "$dir" ]]; then
        daemonrun_log_debug "Changing directory to: $dir"
        cd "$dir" || {
            daemonrun_log_error "Cannot change directory to: $dir"
            return 1
        }
    fi
}

# -----------------------------------------------------------------------------
#
# RESOURCE LIMITS
#
# -----------------------------------------------------------------------------

# Function: daemonrun_limit_apply
# Applies all configured resource limits via ulimit.
daemonrun_limit_apply() {
    # Memory limit
    if [[ -n "$_DAEMONRUN_LIMIT_MEMORY" ]]; then
        daemonrun_limit_memory "$_DAEMONRUN_LIMIT_MEMORY"
    fi

    # File limit
    if [[ -n "$_DAEMONRUN_LIMIT_FILES" ]]; then
        daemonrun_limit_files "$_DAEMONRUN_LIMIT_FILES"
    fi

    # Process limit
    if [[ -n "$_DAEMONRUN_LIMIT_PROCS" ]]; then
        daemonrun_limit_procs "$_DAEMONRUN_LIMIT_PROCS"
    fi

    # Core dump limit
    if [[ -n "$_DAEMONRUN_LIMIT_CORE" ]]; then
        daemonrun_limit_core "$_DAEMONRUN_LIMIT_CORE"
    fi

    # Stack size limit
    if [[ -n "$_DAEMONRUN_LIMIT_STACK" ]]; then
        daemonrun_limit_stack "$_DAEMONRUN_LIMIT_STACK"
    fi
}

# Function: daemonrun_limit_memory SIZE
# Sets memory limit via ulimit -v.
#
# Parameters:
#   SIZE - Memory size string (e.g., "512M")
daemonrun_limit_memory() {
    local size="$1"
    local bytes

    bytes=$(daemonrun_parse_size "$size") || return 1
    local kb=$((bytes / 1024))

    daemonrun_log_debug "Setting memory limit: $size ($kb KB)"

    if ! ulimit -v "$kb" 2>/dev/null; then
        daemonrun_log_warn "Failed to set memory limit (may require privileges)"
    fi
}

# Function: daemonrun_limit_files COUNT
# Sets open file limit via ulimit -n.
#
# Parameters:
#   COUNT - Maximum open files
daemonrun_limit_files() {
    local count="$1"

    daemonrun_log_debug "Setting file limit: $count"

    if ! ulimit -n "$count" 2>/dev/null; then
        daemonrun_log_warn "Failed to set file limit (may require privileges)"
    fi
}

# Function: daemonrun_limit_procs COUNT
# Sets process limit via ulimit -u.
#
# Parameters:
#   COUNT - Maximum processes
daemonrun_limit_procs() {
    local count="$1"

    daemonrun_log_debug "Setting process limit: $count"

    if ! ulimit -u "$count" 2>/dev/null; then
        daemonrun_log_warn "Failed to set process limit (may require privileges)"
    fi
}

# Function: daemonrun_limit_core SIZE
# Sets core dump limit via ulimit -c.
#
# Parameters:
#   SIZE - Core dump size (0, unlimited, or size like 10M)
daemonrun_limit_core() {
    local size="$1"
    local kb

    if [[ "$size" == "unlimited" ]]; then
        kb="unlimited"
    elif [[ "$size" == "0" ]]; then
        kb="0"
    else
        local bytes
        bytes=$(daemonrun_parse_size "$size") || return 1
        kb=$((bytes / 1024))
    fi

    daemonrun_log_debug "Setting core limit: $size ($kb)"

    if ! ulimit -c "$kb" 2>/dev/null; then
        daemonrun_log_warn "Failed to set core limit (may require privileges)"
    fi
}

# Function: daemonrun_limit_stack SIZE
# Sets stack size limit via ulimit -s.
#
# Parameters:
#   SIZE - Stack size (unlimited or size like 8M)
daemonrun_limit_stack() {
    local size="$1"
    local kb

    if [[ "$size" == "unlimited" ]]; then
        kb="unlimited"
    else
        local bytes
        bytes=$(daemonrun_parse_size "$size") || return 1
        kb=$((bytes / 1024))
    fi

    daemonrun_log_debug "Setting stack limit: $size ($kb KB)"

    if ! ulimit -s "$kb" 2>/dev/null; then
        daemonrun_log_warn "Failed to set stack limit (may require privileges)"
    fi
}

# Function: daemonrun_limit_nice PRIORITY
# Sets process priority using nice/renice.
# Note: This is applied when building the command, not via ulimit.
#
# Parameters:
#   PRIORITY - Nice value (-20 to 19)
daemonrun_limit_nice() {
    local priority="$1"

    # Validate range
    if (( priority < -20 || priority > 19 )); then
        daemonrun_log_error "Nice priority must be -20 to 19"
        return 1
    fi

    daemonrun_log_debug "Will set nice priority: $priority"
    # Actual application happens in command building
}

# Function: daemonrun_limit_cpu PID
# Applies CPU limit using cpulimit if available.
#
# Parameters:
#   PID - Process ID to limit
daemonrun_limit_cpu() {
    local pid="$1"

    if [[ -z "$_DAEMONRUN_LIMIT_CPU" ]]; then
        return 0
    fi

    if ! command -v cpulimit &>/dev/null; then
        daemonrun_log_warn "cpulimit not found, CPU limit skipped (install: apt install cpulimit)"
        return 0
    fi

    daemonrun_log_debug "Applying CPU limit: ${_DAEMONRUN_LIMIT_CPU}% to PID $pid"

    cpulimit -p "$pid" -l "$_DAEMONRUN_LIMIT_CPU" -b &>/dev/null &
    _DAEMONRUN_CPULIMIT_PID=$!
}

# Function: daemonrun_limit_timeout_setup
# Spawns background watchdog to kill process after timeout.
daemonrun_limit_timeout_setup() {
    if [[ -z "$_DAEMONRUN_TIMEOUT" ]] || [[ "$_DAEMONRUN_TIMEOUT" == "0" ]]; then
        return 0
    fi

    daemonrun_log_debug "Setting up timeout watchdog: ${_DAEMONRUN_TIMEOUT}s"

    (
        sleep "$_DAEMONRUN_TIMEOUT"
        if [[ -n "$_DAEMONRUN_CHILD_PID" ]] && kill -0 "$_DAEMONRUN_CHILD_PID" 2>/dev/null; then
            daemonrun_log_warn "Timeout reached (${_DAEMONRUN_TIMEOUT}s), terminating process"
            daemonrun_signal_terminate
        fi
    ) &
    _DAEMONRUN_TIMEOUT_PID=$!
}

# Function: daemonrun_limit_timeout_cancel
# Kills timeout watchdog if running.
daemonrun_limit_timeout_cancel() {
    if [[ -n "$_DAEMONRUN_TIMEOUT_PID" ]]; then
        kill "$_DAEMONRUN_TIMEOUT_PID" 2>/dev/null || true
        _DAEMONRUN_TIMEOUT_PID=""
    fi
}

# -----------------------------------------------------------------------------
#
# SANDBOXING
#
# -----------------------------------------------------------------------------

# Function: daemonrun_sandbox_available TYPE
# Checks if sandbox TYPE is available.
#
# Parameters:
#   TYPE - Sandbox type (firejail, unshare)
#
# Returns:
#   0 if available, 1 if not.
daemonrun_sandbox_available() {
    local type="$1"

    case "$type" in
        none)
            return 0
            ;;
        firejail)
            command -v firejail &>/dev/null
            ;;
        unshare)
            command -v unshare &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

# Function: daemonrun_sandbox_validate
# Validates sandbox configuration for unsupported combinations.
daemonrun_sandbox_validate() {
    local sandbox="$_DAEMONRUN_SANDBOX"

    # Check sandbox is valid type
    case "$sandbox" in
        none|firejail|unshare)
            ;;
        *)
            daemonrun_log_error "Unknown sandbox type: $sandbox (use: none, firejail, unshare)"
            exit 1
            ;;
    esac

    # Check sandbox tool is available
    if ! daemonrun_sandbox_available "$sandbox"; then
        case "$sandbox" in
            firejail)
                daemonrun_log_error "firejail not found (install: apt install firejail)"
                ;;
            unshare)
                daemonrun_log_error "unshare not found (usually in util-linux package)"
                ;;
        esac
        exit 1
    fi

    # Check for unsupported combinations
    if [[ "$sandbox" == "unshare" ]]; then
        if [[ -n "$_DAEMONRUN_SANDBOX_READONLY_PATHS" ]]; then
            daemonrun_log_error "--readonly-paths only supported with firejail"
            exit 1
        fi
        if [[ "$_DAEMONRUN_SANDBOX_SECCOMP" == true ]]; then
            daemonrun_log_debug "--seccomp not supported with unshare, skipped"
            _DAEMONRUN_SANDBOX_SECCOMP=false
        fi
    fi

    # Check sandbox profile exists if specified
    if [[ -n "$_DAEMONRUN_SANDBOX_PROFILE" ]] && [[ ! -f "$_DAEMONRUN_SANDBOX_PROFILE" ]]; then
        daemonrun_log_error "Sandbox profile not found: $_DAEMONRUN_SANDBOX_PROFILE"
        exit 1
    fi
}

# Function: daemonrun_sandbox_build_command
# Builds command array with sandbox wrapper.
#
# Returns:
#   Outputs command parts, one per line.
daemonrun_sandbox_build_command() {
    local sandbox="$_DAEMONRUN_SANDBOX"

    case "$sandbox" in
        none)
            printf '%s\n' "${_DAEMONRUN_COMMAND[@]}"
            ;;
        firejail)
            echo "firejail"
            daemonrun_sandbox_firejail_args
            echo "--"
            printf '%s\n' "${_DAEMONRUN_COMMAND[@]}"
            ;;
        unshare)
            echo "unshare"
            daemonrun_sandbox_unshare_args
            echo "--"
            printf '%s\n' "${_DAEMONRUN_COMMAND[@]}"
            ;;
    esac
}

# Function: daemonrun_sandbox_firejail_args
# Generates firejail-specific arguments.
#
# Returns:
#   Outputs arguments, one per line.
daemonrun_sandbox_firejail_args() {
    [[ "$_DAEMONRUN_SANDBOX_PRIVATE_TMP" == true ]] && echo "--private-tmp"
    [[ "$_DAEMONRUN_SANDBOX_PRIVATE_DEV" == true ]] && echo "--private-dev"
    [[ "$_DAEMONRUN_SANDBOX_NO_NETWORK" == true ]] && echo "--net=none"
    [[ -n "$_DAEMONRUN_SANDBOX_CAPS_DROP" ]] && echo "--caps.drop=$_DAEMONRUN_SANDBOX_CAPS_DROP"
    [[ -n "$_DAEMONRUN_SANDBOX_CAPS_KEEP" ]] && echo "--caps.keep=$_DAEMONRUN_SANDBOX_CAPS_KEEP"
    [[ -n "$_DAEMONRUN_SANDBOX_PROFILE" ]] && echo "--profile=$_DAEMONRUN_SANDBOX_PROFILE"

    # Seccomp filtering
    if [[ "$_DAEMONRUN_SANDBOX_SECCOMP" == true ]]; then
        if [[ -n "$_DAEMONRUN_SANDBOX_SECCOMP_PROFILE" ]]; then
            echo "--seccomp=$_DAEMONRUN_SANDBOX_SECCOMP_PROFILE"
        else
            echo "--seccomp"
        fi
    elif [[ -n "$_DAEMONRUN_SANDBOX_SECCOMP_PROFILE" ]]; then
        echo "--seccomp=$_DAEMONRUN_SANDBOX_SECCOMP_PROFILE"
    fi

    # Readonly paths (colon-separated)
    if [[ -n "$_DAEMONRUN_SANDBOX_READONLY_PATHS" ]]; then
        local path
        while IFS= read -r path; do
            echo "--read-only=$path"
        done < <(daemonrun_parse_list "$_DAEMONRUN_SANDBOX_READONLY_PATHS" ":")
    fi
}

# Function: daemonrun_sandbox_unshare_args
# Generates unshare-specific arguments.
#
# Returns:
#   Outputs arguments, one per line.
daemonrun_sandbox_unshare_args() {
    # Mount namespace for private-tmp/dev
    if [[ "$_DAEMONRUN_SANDBOX_PRIVATE_TMP" == true ]] || [[ "$_DAEMONRUN_SANDBOX_PRIVATE_DEV" == true ]]; then
        echo "--mount"
    fi

    # Network namespace
    [[ "$_DAEMONRUN_SANDBOX_NO_NETWORK" == true ]] && echo "--net"

    # Note: unshare doesn't directly support caps-drop, private-tmp setup, etc.
    # Those would require additional mount commands after unshare
}

# -----------------------------------------------------------------------------
#
# EXECUTION
#
# -----------------------------------------------------------------------------

# Function: daemonrun_run_foreground
# Runs command in foreground with full signal handling.
#
# Returns:
#   Child's exit code.
daemonrun_run_foreground() {
    daemonrun_log_info "Starting in foreground mode"

    # Set up signal handling
    daemonrun_signal_setup

    # Set umask if specified
    if [[ -n "$_DAEMONRUN_UMASK" ]]; then
        daemonrun_log_debug "Setting umask: $_DAEMONRUN_UMASK"
        umask "$_DAEMONRUN_UMASK"
    fi

    # Change directory
    daemonrun_process_chdir

    # Build the command with sandbox wrapper
    local cmd=()
    while IFS= read -r part; do
        cmd+=("$part")
    done < <(daemonrun_sandbox_build_command)

    # Wrap with nice if specified
    if [[ -n "$_DAEMONRUN_NICE" ]]; then
        cmd=(nice -n "$_DAEMONRUN_NICE" "${cmd[@]}")
    fi

    # Prepare user/group switch
    if [[ -n "$_DAEMONRUN_USER" ]] || [[ -n "$_DAEMONRUN_RUN_GROUP" ]]; then
        local quoted_cmd
        quoted_cmd=$(printf '%q ' "${cmd[@]}")

        if [[ -n "$_DAEMONRUN_USER" ]] && [[ -n "$_DAEMONRUN_RUN_GROUP" ]]; then
            # Switch both user and group
            cmd=(su -s /bin/sh -g "$_DAEMONRUN_RUN_GROUP" "$_DAEMONRUN_USER" -c "$quoted_cmd")
        elif [[ -n "$_DAEMONRUN_USER" ]]; then
            # Switch user only
            cmd=(su -s /bin/sh "$_DAEMONRUN_USER" -c "$quoted_cmd")
        else
            # Switch group only using sg
            cmd=(sg "$_DAEMONRUN_RUN_GROUP" -c "$quoted_cmd")
        fi
    fi

    # Wrap with env -i if clear-env is set
    if [[ "$_DAEMONRUN_CLEAR_ENV" == true ]]; then
        # Preserve essential variables
        local preserved_env=""
        [[ -n "${PATH:-}" ]] && preserved_env="PATH=$PATH "
        [[ -n "${HOME:-}" ]] && preserved_env="${preserved_env}HOME=$HOME "
        [[ -n "${USER:-}" ]] && preserved_env="${preserved_env}USER=$USER "
        [[ -n "${TERM:-}" ]] && preserved_env="${preserved_env}TERM=$TERM "
        cmd=(env -i $preserved_env "${cmd[@]}")
    fi

    # Apply limits before fork (they'll be inherited)
    daemonrun_limit_apply

    # Fork and exec
    daemonrun_log_debug "Executing: ${cmd[*]}"

    # Determine output redirection
    local stdout_target="/dev/stdout"
    local stderr_target="/dev/stderr"

    if [[ -n "$_DAEMONRUN_STDOUT_FILE" ]]; then
        stdout_target="$_DAEMONRUN_STDOUT_FILE"
    fi
    if [[ -n "$_DAEMONRUN_STDERR_FILE" ]]; then
        stderr_target="$_DAEMONRUN_STDERR_FILE"
    fi

    # For foreground mode, we run the command in a subshell that creates a new
    # process group. We use set -m (job control) to get proper PGID handling.
    if [[ "$_DAEMONRUN_SETSID" == true ]]; then
        # Run in new session - the subshell becomes session leader
        if [[ "$_DAEMONRUN_SYSLOG" == true ]] && [[ -z "$_DAEMONRUN_STDOUT_FILE" ]] && [[ -z "$_DAEMONRUN_STDERR_FILE" ]]; then
            # Pipe output to logger for syslog
            (
                if command -v setsid &>/dev/null; then
                    exec setsid "${cmd[@]}" 2>&1 | logger -t "${_DAEMONRUN_GROUP:-daemonrun}" -p daemon.info
                else
                    daemonrun_log_warn "setsid not available, running in current session"
                    exec "${cmd[@]}" 2>&1 | logger -t "${_DAEMONRUN_GROUP:-daemonrun}" -p daemon.info
                fi
            ) &
        elif [[ -n "$_DAEMONRUN_STDOUT_FILE" ]] || [[ -n "$_DAEMONRUN_STDERR_FILE" ]]; then
            # Redirect to specified files
            (
                if command -v setsid &>/dev/null; then
                    exec setsid "${cmd[@]}" >>"$stdout_target" 2>>"$stderr_target"
                else
                    daemonrun_log_warn "setsid not available, running in current session"
                    exec "${cmd[@]}" >>"$stdout_target" 2>>"$stderr_target"
                fi
            ) &
        else
            # No redirection - inherit parent's file descriptors
            (
                if command -v setsid &>/dev/null; then
                    exec setsid "${cmd[@]}"
                else
                    daemonrun_log_warn "setsid not available, running in current session"
                    exec "${cmd[@]}"
                fi
            ) &
        fi
        _DAEMONRUN_CHILD_PID=$!
        # Wait briefly for setsid to set up, then find the actual process
        sleep 0.1
        # The child of setsid will have its own PID as PGID
        _DAEMONRUN_PGID=$_DAEMONRUN_CHILD_PID
    else
        # Run without new session
        if [[ "$_DAEMONRUN_SYSLOG" == true ]] && [[ -z "$_DAEMONRUN_STDOUT_FILE" ]] && [[ -z "$_DAEMONRUN_STDERR_FILE" ]]; then
            "${cmd[@]}" 2>&1 | logger -t "${_DAEMONRUN_GROUP:-daemonrun}" -p daemon.info &
        elif [[ -n "$_DAEMONRUN_STDOUT_FILE" ]] || [[ -n "$_DAEMONRUN_STDERR_FILE" ]]; then
            "${cmd[@]}" >>"$stdout_target" 2>>"$stderr_target" &
        else
            "${cmd[@]}" &
        fi
        _DAEMONRUN_CHILD_PID=$!
        _DAEMONRUN_PGID=$_DAEMONRUN_CHILD_PID
    fi

    daemonrun_log_info "Started process (PID: $_DAEMONRUN_CHILD_PID, PGID: $_DAEMONRUN_PGID)"

    # Write PID file
    daemonrun_pidfile_write "$_DAEMONRUN_CHILD_PID"

    # Start CPU limiter if configured
    daemonrun_limit_cpu "$_DAEMONRUN_CHILD_PID"

    # Start timeout watchdog if configured
    daemonrun_limit_timeout_setup

    # Wait for child to exit
    local exit_code=0
    wait "$_DAEMONRUN_CHILD_PID" || exit_code=$?

    daemonrun_log_info "Process exited with code: $exit_code"

    return "$exit_code"
}

# Function: daemonrun_run_daemon
# Daemonizes via double-fork pattern.
#
# The parent process exits immediately after starting the daemon.
daemonrun_run_daemon() {
    daemonrun_log_info "Daemonizing process"

    # Validate we can write to pidfile before forking
    local pidfile
    pidfile=$(daemonrun_pidfile_path)
    local piddir
    piddir=$(dirname "$pidfile")
    if [[ ! -d "$piddir" ]]; then
        mkdir -p "$piddir" || {
            daemonrun_log_error "Cannot create PID directory: $piddir"
            exit 1
        }
    fi

    # Build the command
    local cmd=()
    while IFS= read -r part; do
        cmd+=("$part")
    done < <(daemonrun_sandbox_build_command)

    # Wrap with nice if specified
    if [[ -n "$_DAEMONRUN_NICE" ]]; then
        cmd=(nice -n "$_DAEMONRUN_NICE" "${cmd[@]}")
    fi

    # Prepare user/group switch
    if [[ -n "$_DAEMONRUN_USER" ]] || [[ -n "$_DAEMONRUN_RUN_GROUP" ]]; then
        local quoted_cmd
        quoted_cmd=$(printf '%q ' "${cmd[@]}")

        if [[ -n "$_DAEMONRUN_USER" ]] && [[ -n "$_DAEMONRUN_RUN_GROUP" ]]; then
            cmd=(su -s /bin/sh -g "$_DAEMONRUN_RUN_GROUP" "$_DAEMONRUN_USER" -c "$quoted_cmd")
        elif [[ -n "$_DAEMONRUN_USER" ]]; then
            cmd=(su -s /bin/sh "$_DAEMONRUN_USER" -c "$quoted_cmd")
        else
            cmd=(sg "$_DAEMONRUN_RUN_GROUP" -c "$quoted_cmd")
        fi
    fi

    # Wrap with env -i if clear-env is set
    if [[ "$_DAEMONRUN_CLEAR_ENV" == true ]]; then
        local preserved_env=""
        [[ -n "${PATH:-}" ]] && preserved_env="PATH=$PATH "
        [[ -n "${HOME:-}" ]] && preserved_env="${preserved_env}HOME=$HOME "
        cmd=(env -i $preserved_env "${cmd[@]}")
    fi

    local chdir="${_DAEMONRUN_CHDIR:-/}"
    local umask_val="${_DAEMONRUN_UMASK:-022}"
    local mem_limit_kb=""
    local core_limit_kb=""
    local stack_limit_kb=""

    if [[ -n "$_DAEMONRUN_LIMIT_MEMORY" ]]; then
        local bytes
        bytes=$(daemonrun_parse_size "$_DAEMONRUN_LIMIT_MEMORY" 2>/dev/null) || true
        [[ -n "$bytes" ]] && mem_limit_kb=$((bytes / 1024))
    fi

    if [[ -n "$_DAEMONRUN_LIMIT_CORE" ]]; then
        if [[ "$_DAEMONRUN_LIMIT_CORE" == "unlimited" ]]; then
            core_limit_kb="unlimited"
        elif [[ "$_DAEMONRUN_LIMIT_CORE" == "0" ]]; then
            core_limit_kb="0"
        else
            local bytes
            bytes=$(daemonrun_parse_size "$_DAEMONRUN_LIMIT_CORE" 2>/dev/null) || true
            [[ -n "$bytes" ]] && core_limit_kb=$((bytes / 1024))
        fi
    fi

    if [[ -n "$_DAEMONRUN_LIMIT_STACK" ]]; then
        if [[ "$_DAEMONRUN_LIMIT_STACK" == "unlimited" ]]; then
            stack_limit_kb="unlimited"
        else
            local bytes
            bytes=$(daemonrun_parse_size "$_DAEMONRUN_LIMIT_STACK" 2>/dev/null) || true
            [[ -n "$bytes" ]] && stack_limit_kb=$((bytes / 1024))
        fi
    fi

    # Determine stdout/stderr destinations
    # Default to a log file in current directory, never /dev/null
    local default_log="./${_DAEMONRUN_GROUP:-daemon}.log"

    local stdout_file="${_DAEMONRUN_STDOUT_FILE:-$default_log}"
    local stderr_file="${_DAEMONRUN_STDERR_FILE:-}"
    local use_syslog="$_DAEMONRUN_SYSLOG"

    # Quote the command for passing to bash -c
    local quoted_cmd
    quoted_cmd=$(printf '%q ' "${cmd[@]}")

    # Build ulimit commands (shared across all branches)
    local ulimit_cmds=""
    [[ -n "$mem_limit_kb" ]] && ulimit_cmds+="ulimit -v $mem_limit_kb 2>/dev/null || true"$'\n'
    [[ -n "$_DAEMONRUN_LIMIT_FILES" ]] && ulimit_cmds+="ulimit -n $_DAEMONRUN_LIMIT_FILES 2>/dev/null || true"$'\n'
    [[ -n "$_DAEMONRUN_LIMIT_PROCS" ]] && ulimit_cmds+="ulimit -u $_DAEMONRUN_LIMIT_PROCS 2>/dev/null || true"$'\n'
    [[ -n "$core_limit_kb" ]] && ulimit_cmds+="ulimit -c $core_limit_kb 2>/dev/null || true"$'\n'
    [[ -n "$stack_limit_kb" ]] && ulimit_cmds+="ulimit -s $stack_limit_kb 2>/dev/null || true"$'\n'

    # Create a temporary daemon script
    local daemon_script
    daemon_script=$(mktemp)

    if [[ "$use_syslog" == true ]] && [[ -z "$_DAEMONRUN_STDOUT_FILE" ]] && [[ -z "$_DAEMONRUN_STDERR_FILE" ]]; then
        # Use logger for syslog output, but also write to log file
        cat > "$daemon_script" <<EOF
#!/bin/bash
exec 0</dev/null
exec 1> >(tee -a "$stdout_file" | logger -t "${_DAEMONRUN_GROUP:-daemonrun}" -p daemon.info)
exec 2> >(tee -a "$stdout_file" | logger -t "${_DAEMONRUN_GROUP:-daemonrun}" -p daemon.err)

echo \$\$ > "$pidfile"

$ulimit_cmds

rm -f "$daemon_script"

# Run command and capture exit status
$quoted_cmd
exit_code=\$?

# Report signal-based crashes
if [[ \$exit_code -gt 128 ]]; then
    sig=\$((exit_code - 128))
    case \$sig in
        1) sig_name="SIGHUP" ;; 2) sig_name="SIGINT" ;; 3) sig_name="SIGQUIT" ;;
        4) sig_name="SIGILL (Illegal instruction)" ;; 6) sig_name="SIGABRT" ;;
        8) sig_name="SIGFPE" ;; 9) sig_name="SIGKILL" ;;
        11) sig_name="SIGSEGV (Segmentation fault)" ;; 13) sig_name="SIGPIPE" ;;
        15) sig_name="SIGTERM" ;; *) sig_name="signal \$sig" ;;
    esac
    echo "Process killed by \$sig_name (exit code \$exit_code)" >&2
fi

exit \$exit_code
EOF
    elif [[ -n "$stderr_file" ]]; then
        # Both stdout and stderr configured
        cat > "$daemon_script" <<EOF
#!/bin/bash
exec 0</dev/null
exec 1>>"$stdout_file"
exec 2>>"$stderr_file"

echo \$\$ > "$pidfile"

$ulimit_cmds

rm -f "$daemon_script"

# Run command and capture exit status
$quoted_cmd
exit_code=\$?

# Report signal-based crashes
if [[ \$exit_code -gt 128 ]]; then
    sig=\$((exit_code - 128))
    case \$sig in
        1) sig_name="SIGHUP" ;; 2) sig_name="SIGINT" ;; 3) sig_name="SIGQUIT" ;;
        4) sig_name="SIGILL (Illegal instruction)" ;; 6) sig_name="SIGABRT" ;;
        8) sig_name="SIGFPE" ;; 9) sig_name="SIGKILL" ;;
        11) sig_name="SIGSEGV (Segmentation fault)" ;; 13) sig_name="SIGPIPE" ;;
        15) sig_name="SIGTERM" ;; *) sig_name="signal \$sig" ;;
    esac
    echo "Process killed by \$sig_name (exit code \$exit_code)" >&2
fi

exit \$exit_code
EOF
    else
        # Only stdout configured - stderr follows stdout
        cat > "$daemon_script" <<EOF
#!/bin/bash
exec 0</dev/null
exec 1>>"$stdout_file"
exec 2>&1

echo \$\$ > "$pidfile"

$ulimit_cmds

rm -f "$daemon_script"

# Run command and capture exit status
$quoted_cmd
exit_code=\$?

# Report signal-based crashes
if [[ \$exit_code -gt 128 ]]; then
    sig=\$((exit_code - 128))
    case \$sig in
        1) sig_name="SIGHUP" ;; 2) sig_name="SIGINT" ;; 3) sig_name="SIGQUIT" ;;
        4) sig_name="SIGILL (Illegal instruction)" ;; 6) sig_name="SIGABRT" ;;
        8) sig_name="SIGFPE" ;; 9) sig_name="SIGKILL" ;;
        11) sig_name="SIGSEGV (Segmentation fault)" ;; 13) sig_name="SIGPIPE" ;;
        15) sig_name="SIGTERM" ;; *) sig_name="signal \$sig" ;;
    esac
    echo "Process killed by \$sig_name (exit code \$exit_code)" >&2
fi

exit \$exit_code
EOF
    fi
    chmod +x "$daemon_script"

    # First fork - creates intermediate process
    (
        # Change to target directory
        cd "$chdir" || exit 1
        umask "$umask_val"

        # Launch daemon with setsid
        setsid "$daemon_script" &

        # Intermediate process exits immediately
        exit 0
    ) &

    # Wait for first fork to complete
    wait $!

    # Give daemon time to start and write PID file
    sleep 0.5

    # Clean up script if still exists (in case daemon failed)
    rm -f "$daemon_script" 2>/dev/null || true

    # Helper to display startup failure logs
    _show_startup_logs() {
        # Small delay to let any final output be flushed
        sleep 0.1
        sync 2>/dev/null || true
        # Show stdout first, then stderr
        if [[ -s "$stdout_file" ]]; then
            echo "# out: $stdout_file" >&2
            cat "$stdout_file" >&2
        fi
        if [[ -n "$stderr_file" && -s "$stderr_file" ]]; then
            echo "# err: $stderr_file" >&2
            cat "$stderr_file" >&2
        fi
    }

    # Check if PID file was created
    if [[ -f "$pidfile" ]]; then
        local daemon_pid
        daemon_pid=$(cat "$pidfile")
        if kill -0 "$daemon_pid" 2>/dev/null; then
            daemonrun_log_info "Daemon started (PID: $daemon_pid, pidfile: $pidfile)"
        else
            daemonrun_log_error "Daemon process exited immediately"
            _show_startup_logs
            exit 1
        fi
    else
        daemonrun_log_error "Daemon may have failed to start (no PID file)"
        _show_startup_logs
        exit 1
    fi

    exit 0
}

# -----------------------------------------------------------------------------
#
# MAIN
#
# -----------------------------------------------------------------------------

# Function: daemonrun_main ARGS...
# Main entry point.
#
# Parameters:
#   ARGS - Command-line arguments
daemonrun_main() {
    # Parse arguments
    daemonrun_parse_args "$@"

    # Validate configuration
    daemonrun_parse_validate

    # Check if already running
    local existing_pid
    if existing_pid=$(daemonrun_pidfile_check); then
        daemonrun_log_error "Already running (PID: $existing_pid)"
        exit 1
    fi

    # Dispatch to appropriate run mode
    if [[ "$_DAEMONRUN_DAEMON" == true ]]; then
        daemonrun_run_daemon
    else
        daemonrun_run_foreground
    fi
}

# Entry point guard
if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ "$(basename "$0")" =~ ^daemonrun(\.sh)?$ ]]; then
    daemonrun_main "$@"
fi

# EOF
