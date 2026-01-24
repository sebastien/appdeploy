#!/usr/bin/env bash
# --
# File: teelog.sh
#
# `teelog` is a tee-like utility that supports stdout & stderr logging,
# size-based log rotation, and rotated log cleanup by count or age.
#
# ## Usage
#
# Piped mode:
# >   command | teelog [OPTIONS] OUT [ERR]
#
# Command mode:
# >   teelog [OPTIONS] OUT [ERR] -- COMMAND [ARGS...]
#
# ## Options
#
# -s, --max-size SIZE   - Max file size before rotation (e.g., 10Mb, 1G, 500K)
# -a, --max-age AGE     - Max age for rotated logs (e.g., 7d, 24h, 30m)
# -c, --max-count COUNT - Max number of rotated files to keep

set -euo pipefail

# =============================================================================
# DEFAULTS
# =============================================================================

TEELOG_MAX_SIZE=${TEELOG_MAX_SIZE:-}
TEELOG_MAX_AGE=${TEELOG_MAX_AGE:-}
TEELOG_MAX_COUNT=${TEELOG_MAX_COUNT:-}

# Internal state
_TEELOG_OUT_FILE=""
_TEELOG_ERR_FILE=""
_TEELOG_COMMAND=()
_TEELOG_MAX_SIZE_BYTES=""
_TEELOG_MAX_AGE_SECONDS=""

# -----------------------------------------------------------------------------
#
# PARSING
#
# -----------------------------------------------------------------------------

# Function: teelog_parse_size SIZE
# Parses a human-readable size string and outputs bytes.
#
# Parameters:
#   SIZE - Size string like "10Mb", "1G", "500K", "1024"
#
# Returns:
#   Outputs integer bytes to stdout. Exits 1 on invalid format.
#
# Supported suffixes (case-insensitive):
#   - K, Kb: kilobytes (1024)
#   - M, Mb: megabytes (1024^2)
#   - G, Gb: gigabytes (1024^3)
#   - (none): bytes
teelog_parse_size() {
	local input="$1"
	local number suffix multiplier

	# Extract number and suffix
	if [[ "$input" =~ ^([0-9]+)([KkMmGg][Bb]?)?$ ]]; then
		number="${BASH_REMATCH[1]}"
		suffix="${BASH_REMATCH[2]:-}"
	else
		echo "Error: Invalid size format '$input'" >&2
		return 1
	fi

	# Determine multiplier based on suffix
	case "${suffix,,}" in
	k | kb) multiplier=1024 ;;
	m | mb) multiplier=$((1024 * 1024)) ;;
	g | gb) multiplier=$((1024 * 1024 * 1024)) ;;
	"") multiplier=1 ;;
	*)
		echo "Error: Unknown size suffix '$suffix'" >&2
		return 1
		;;
	esac

	echo $((number * multiplier))
}

# Function: teelog_parse_age AGE
# Parses a human-readable age string and outputs seconds.
#
# Parameters:
#   AGE - Age string like "7d", "24h", "30m"
#
# Returns:
#   Outputs integer seconds to stdout. Exits 1 on invalid format.
#
# Supported suffixes:
#   - m: minutes (60)
#   - h: hours (3600)
#   - d: days (86400)
teelog_parse_age() {
	local input="$1"
	local number suffix multiplier

	# Extract number and suffix
	if [[ "$input" =~ ^([0-9]+)([mhd])$ ]]; then
		number="${BASH_REMATCH[1]}"
		suffix="${BASH_REMATCH[2]}"
	else
		echo "Error: Invalid age format '$input'" >&2
		return 1
	fi

	# Determine multiplier based on suffix
	case "$suffix" in
	m) multiplier=60 ;;
	h) multiplier=3600 ;;
	d) multiplier=86400 ;;
	*)
		echo "Error: Unknown age suffix '$suffix'" >&2
		return 1
		;;
	esac

	echo $((number * multiplier))
}

# Function: teelog_parse_args ARGS...
# Parses command-line arguments and sets global variables.
#
# Parameters:
#   ARGS - Command-line arguments
#
# Sets:
#   _TEELOG_OUT_FILE      - Path to stdout log file
#   _TEELOG_ERR_FILE      - Path to stderr log file (may equal OUT)
#   _TEELOG_COMMAND       - Command array (empty in pipe mode)
#   _TEELOG_MAX_SIZE_BYTES - Max size in bytes (parsed)
#   _TEELOG_MAX_AGE_SECONDS - Max age in seconds (parsed)
#   TEELOG_MAX_COUNT      - Max count (already integer)
teelog_parse_args() {
	local positional=()
	local seen_separator=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		-s | --max-size)
			TEELOG_MAX_SIZE="$2"
			shift 2
			;;
		--max-size=*)
			TEELOG_MAX_SIZE="${1#*=}"
			shift
			;;
		-a | --max-age)
			TEELOG_MAX_AGE="$2"
			shift 2
			;;
		--max-age=*)
			TEELOG_MAX_AGE="${1#*=}"
			shift
			;;
		-c | --max-count)
			TEELOG_MAX_COUNT="$2"
			shift 2
			;;
		--max-count=*)
			TEELOG_MAX_COUNT="${1#*=}"
			shift
			;;
		-h | --help)
			teelog_usage
			exit 0
			;;
		--)
			seen_separator=true
			shift
			break
			;;
		-*)
			echo "Error: Unknown option '$1'" >&2
			teelog_usage >&2
			exit 1
			;;
		*)
			positional+=("$1")
			shift
			;;
		esac
	done

	# After --, everything is the command
	if $seen_separator; then
		_TEELOG_COMMAND=("$@")
	fi

	# Validate positional arguments
	if [[ ${#positional[@]} -lt 1 ]]; then
		echo "Error: OUT file is required" >&2
		teelog_usage >&2
		exit 1
	fi

	_TEELOG_OUT_FILE="${positional[0]}"

	if [[ ${#positional[@]} -ge 2 ]]; then
		_TEELOG_ERR_FILE="${positional[1]}"
	else
		_TEELOG_ERR_FILE="$_TEELOG_OUT_FILE"
	fi

	# Parse size and age if provided
	if [[ -n "$TEELOG_MAX_SIZE" ]]; then
		_TEELOG_MAX_SIZE_BYTES=$(teelog_parse_size "$TEELOG_MAX_SIZE")
	fi

	if [[ -n "$TEELOG_MAX_AGE" ]]; then
		_TEELOG_MAX_AGE_SECONDS=$(teelog_parse_age "$TEELOG_MAX_AGE")
	fi

	# Validate command mode has a command
	if $seen_separator && [[ ${#_TEELOG_COMMAND[@]} -eq 0 ]]; then
		echo "Error: No command specified after --" >&2
		exit 1
	fi
}

# Function: teelog_usage
# Prints usage information to stdout.
teelog_usage() {
	cat <<'EOF'
Usage: teelog [OPTIONS] OUT [ERR] [-- COMMAND [ARGS...]]

A tee-like utility with log rotation support.

Options:
  -s, --max-size SIZE    Max file size before rotation (e.g., 10Mb, 1G, 500K)
  -a, --max-age AGE      Max age for rotated logs (e.g., 7d, 24h, 30m)
  -c, --max-count COUNT  Max number of rotated files to keep
  -h, --help             Show this help message

Arguments:
  OUT                    Path to stdout log file (required)
  ERR                    Path to stderr log file (defaults to OUT)
  COMMAND                Command to execute (requires -- separator)

Environment Variables:
  TEELOG_MAX_SIZE        Default for --max-size
  TEELOG_MAX_AGE         Default for --max-age
  TEELOG_MAX_COUNT       Default for --max-count

Examples:
  # Pipe mode
  ./my-service | teelog --max-size 10Mb service.log

  # Command mode with separate error log
  teelog --max-size 10Mb --max-age 7d out.log err.log -- ./my-service
EOF
}

# -----------------------------------------------------------------------------
#
# FILE OPERATIONS
#
# -----------------------------------------------------------------------------

# Function: teelog_ensure_dir FILE
# Creates parent directory for FILE if it doesn't exist.
#
# Parameters:
#   FILE - Path to file whose parent directory should exist
teelog_ensure_dir() {
	local file="$1"
	local dir
	dir=$(dirname "$file")

	if [[ ! -d "$dir" ]]; then
		mkdir -p "$dir"
	fi
}

# Function: teelog_file_size FILE
# Returns file size in bytes, or 0 if file doesn't exist.
#
# Parameters:
#   FILE - Path to file
#
# Returns:
#   Outputs file size in bytes to stdout.
teelog_file_size() {
	local file="$1"

	if [[ -f "$file" ]]; then
		stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0
	else
		echo 0
	fi
}

# Function: teelog_rotate FILE
# Rotates a log file by renaming it with a timestamp suffix.
#
# Parameters:
#   FILE - Path to log file to rotate
#
# The file is renamed to FILE.YYYY-MM-DD-HHmmSS. If that name already
# exists, a sequence number is appended (e.g., FILE.YYYY-MM-DD-HHmmSS.1).
# A new empty file is created at FILE. Cleanup is triggered after rotation.
teelog_rotate() {
	local file="$1"
	local timestamp target seq

	# Don't rotate if file doesn't exist or is empty
	if [[ ! -f "$file" ]] || [[ ! -s "$file" ]]; then
		return 0
	fi

	timestamp=$(date '+%Y-%m-%d-%H%M%S')
	target="${file}.${timestamp}"

	# Handle same-second conflicts with sequence numbers
	if [[ -e "$target" ]]; then
		seq=1
		while [[ -e "${target}.${seq}" ]]; do
			((seq++))
		done
		target="${target}.${seq}"
	fi

	mv "$file" "$target"
	touch "$file"

	teelog_cleanup "$file"
}

# Function: teelog_cleanup FILE
# Removes rotated log files exceeding count or age limits.
#
# Parameters:
#   FILE - Base path of log file (rotated files are FILE.*)
#
# Applies both max-count and max-age rules if configured.
# Files are sorted by name (which sorts by timestamp due to naming scheme).
teelog_cleanup() {
	local base_file="$1"
	local rotated_files=()
	local f

	# Find all rotated files - use nullglob to handle no matches
	shopt -s nullglob
	for f in "${base_file}".*; do
		rotated_files+=("$f")
	done
	shopt -u nullglob

	# Early return if no rotated files
	if [[ ${#rotated_files[@]} -eq 0 ]]; then
		return 0
	fi

	# Sort by name descending (newest first)
	local sorted_files
	sorted_files=$(printf '%s\n' "${rotated_files[@]}" | sort -r)
	rotated_files=()
	while IFS= read -r f; do
		rotated_files+=("$f")
	done <<<"$sorted_files"

	# Cleanup by count
	if [[ -n "$TEELOG_MAX_COUNT" ]]; then
		local i=0
		for f in "${rotated_files[@]}"; do
			((i++)) || true
			if ((i > TEELOG_MAX_COUNT)); then
				rm -f "$f"
			fi
		done
	fi

	# Cleanup by age
	if [[ -n "$_TEELOG_MAX_AGE_SECONDS" ]]; then
		local now cutoff mtime
		now=$(date +%s)
		cutoff=$((now - _TEELOG_MAX_AGE_SECONDS))

		for f in "${rotated_files[@]}"; do
			# Skip if already deleted by count rule
			[[ -f "$f" ]] || continue

			# Get file modification time
			mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
			if ((mtime < cutoff)); then
				rm -f "$f"
			fi
		done
	fi
}

# Function: teelog_write FILE LINE
# Appends a line to a file and triggers rotation if size exceeded.
#
# Parameters:
#   FILE - Path to log file
#   LINE - Line to write (newline is added automatically)
#
# After writing, checks if file exceeds max size and rotates if needed.
# Rotation happens after the complete line is written (never mid-line).
teelog_write() {
	local file="$1"
	local line="$2"

	printf '%s\n' "$line" >>"$file"

	# Check if rotation is needed
	if [[ -n "$_TEELOG_MAX_SIZE_BYTES" ]]; then
		local size
		size=$(teelog_file_size "$file")
		if ((size > _TEELOG_MAX_SIZE_BYTES)); then
			teelog_rotate "$file"
		fi
	fi
}

# -----------------------------------------------------------------------------
#
# RUN MODES
#
# -----------------------------------------------------------------------------

# Function: teelog_run_pipe
# Runs teelog in pipe mode, reading from stdin.
#
# Reads stdin line-by-line, writes each line to the output file,
# and passes it through to stdout. Uses _TEELOG_OUT_FILE as destination.
teelog_run_pipe() {
	local line

	teelog_ensure_dir "$_TEELOG_OUT_FILE"

	while IFS= read -r line || [[ -n "$line" ]]; do
		teelog_write "$_TEELOG_OUT_FILE" "$line"
		printf '%s\n' "$line"
	done
}

# Global variables for pipe cleanup (needed for trap)
_TEELOG_STDOUT_PIPE=""
_TEELOG_STDERR_PIPE=""

# Function: _teelog_cleanup_pipes
# Cleanup handler for named pipes used in command mode.
_teelog_cleanup_pipes() {
	rm -f "$_TEELOG_STDOUT_PIPE" "$_TEELOG_STDERR_PIPE"
}

# Function: teelog_run_command
# Runs teelog in command mode, executing and capturing a command.
#
# Executes the command specified in _TEELOG_COMMAND, capturing stdout
# to _TEELOG_OUT_FILE and stderr to _TEELOG_ERR_FILE. Both streams are
# also passed through to real stdout/stderr respectively.
#
# On completion, prints "EOK" if command succeeded, or "EFAIL N" where
# N is the exit code if it failed. Returns the command's exit code.
teelog_run_command() {
	local exit_code=0

	teelog_ensure_dir "$_TEELOG_OUT_FILE"
	if [[ "$_TEELOG_ERR_FILE" != "$_TEELOG_OUT_FILE" ]]; then
		teelog_ensure_dir "$_TEELOG_ERR_FILE"
	fi

	# Create named pipes for capturing output
	_TEELOG_STDOUT_PIPE=$(mktemp -u)
	_TEELOG_STDERR_PIPE=$(mktemp -u)
	mkfifo "$_TEELOG_STDOUT_PIPE"
	mkfifo "$_TEELOG_STDERR_PIPE"

	trap _teelog_cleanup_pipes EXIT

	# Start background readers for stdout and stderr
	(
		while IFS= read -r line || [[ -n "$line" ]]; do
			teelog_write "$_TEELOG_OUT_FILE" "$line"
			printf '%s\n' "$line"
		done <"$_TEELOG_STDOUT_PIPE"
	) &
	local stdout_pid=$!

	(
		while IFS= read -r line || [[ -n "$line" ]]; do
			teelog_write "$_TEELOG_ERR_FILE" "$line"
			printf '%s\n' "$line" >&2
		done <"$_TEELOG_STDERR_PIPE"
	) &
	local stderr_pid=$!

	# Execute the command with redirected output
	"${_TEELOG_COMMAND[@]}" >"$_TEELOG_STDOUT_PIPE" 2>"$_TEELOG_STDERR_PIPE" || exit_code=$?

	# Wait for readers to finish
	wait "$stdout_pid" 2>/dev/null || true
	wait "$stderr_pid" 2>/dev/null || true

	# Report result
	if ((exit_code == 0)); then
		echo "EOK"
	else
		echo "EFAIL $exit_code"
	fi

	return "$exit_code"
}

# -----------------------------------------------------------------------------
#
# MAIN
#
# -----------------------------------------------------------------------------

# Function: teelog_main ARGS...
# Main entry point for teelog.
#
# Parameters:
#   ARGS - Command-line arguments
#
# Parses arguments and dispatches to the appropriate run mode:
# - Command mode if a command was specified after --
# - Pipe mode otherwise (reads from stdin)
teelog_main() {
	teelog_parse_args "$@"

	if [[ ${#_TEELOG_COMMAND[@]} -gt 0 ]]; then
		teelog_run_command
	else
		teelog_run_pipe
	fi
}

# Can be used as a library or executable
if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ "$(basename "$0")" =~ ^teelog(\.sh)?$ ]]; then
	teelog_main "$@"
fi

# EOF
