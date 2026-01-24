#!/usr/bin/env bash
#
# AppDeploy manages the deployment of applications package to local and remote
# servers. Application packages are packaged in a tarball like
# `${NAME}-${VERSION}.tar.[gz|bz2|xz]`, with the following scripts expected inside:
# 
# - `env.sh`: sets up environment variables for the application
# - `run.sh`: script to run the application
#
# Application packages are first uploaded, unpacked, and then activated on the target
# server, with the following structure:
#
# ```
# /opt/apps (or other target)
#    ${NAME}/
#		packages/           # Where packages are uplaoded
#			${NAME}-${VERSION}.tar.[gz|bz2|xz]
#		dist/               # Where packages are unpacked
#			${VERSION}/
#		var/                # Directory of files/directories to overlay on top of dist
#			logs/           # The contents of var is discretionary, there are examples
#			data/
#			etc/
#		run/                # Combination of symlinks to var and dist where the app runs from
#```

set -euo pipefail

APPDEPLOY_VERSION="0.1.0"
APPDEPLOY_TARGET=${APPDEPLOY_TARGET:-/opt/apps}
APPDEPLOY_DEFAULT_TARGET=${APPDEPLOY_DEFAULT_TARGET:-/opt/appdeploy}
APPDEPLOY_DEFAULT_PATH=${APPDEPLOY_DEFAULT_PATH:-/opt/apps}

# --
# ## Color library
# Add colored output support similar to lib-testing.sh
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
export BLUE GREEN YELLOW RED GRAY BOLD RESET

# ============================================================================
# ERROR HANDLING
# ============================================================================

# Global error handler for CLI - ensures errors are logged before exit
# This catches unexpected failures from 'set -e' and provides context
function appdeploy_trap_error() {
	local exit_code=$?
	local line_no=$1
	# Only log if we have a real error (not normal exit)
	if [[ $exit_code -ne 0 ]]; then
		echo "~!~ Command failed (exit code $exit_code) at line $line_no" >&2
	fi
}

# Set trap when running as CLI (not when sourced as library)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	trap 'appdeploy_trap_error $LINENO' ERR
fi

# ============================================================================
# SECURITY HELPERS
# ============================================================================

# Function: appdeploy_validate_name NAME
# Validates that NAME contains only safe characters (alphanumeric, dash, underscore)
# Returns 0 if valid, 1 if invalid
function appdeploy_validate_name() {
	local name="$1"
	if [[ -z "$name" ]]; then
		return 1
	fi
	# Only allow alphanumeric, dash, underscore, and dot
	if [[ ! "$name" =~ ^[a-zA-Z0-9._-]+$ ]]; then
		appdeploy_error "Invalid name: '$name' (only alphanumeric, dash, underscore, dot allowed)"
		return 1
	fi
	# Prevent path traversal attempts
	if [[ "$name" == *".."* || "$name" == "."* ]]; then
		appdeploy_error "Invalid name: '$name' (path traversal not allowed)"
		return 1
	fi
	# Limit length
	if [[ ${#name} -gt 128 ]]; then
		appdeploy_error "Invalid name: '$name' (exceeds 128 characters)"
		return 1
	fi
	return 0
}

# Function: appdeploy_validate_version VERSION
# Validates that VERSION is a valid version string.
# Accepts: semver (1.0.0), prefixed (v1.0.0), git hashes (c1b87d2), 
#          timestamped (20260124-c1b87d2), etc.
# Must start with alphanumeric and contain only alphanumeric, dot, dash, underscore.
# For git hashes, recommend prefixing with timestamp for sortability: 20260124-c1b87d2
# Returns 0 if valid, 1 if invalid
function appdeploy_validate_version() {
	local version="$1"
	if [[ -z "$version" ]]; then
		return 1
	fi
	# Allow versions starting with digit or letter (for git hashes, v-prefixes, etc.)
	if [[ ! "$version" =~ ^[0-9a-zA-Z][0-9a-zA-Z._-]*$ ]]; then
		appdeploy_error "Invalid version: '$version' (must start with alphanumeric, contain only alphanumeric, dot, dash, underscore)"
		return 1
	fi
	# Prevent path traversal
	if [[ "$version" == *".."* ]]; then
		appdeploy_error "Invalid version: '$version' (path traversal not allowed)"
		return 1
	fi
	# Limit length
	if [[ ${#version} -gt 64 ]]; then
		appdeploy_error "Invalid version: '$version' (exceeds 64 characters)"
		return 1
	fi
	return 0
}

# Function: appdeploy_validate_path PATH
# Validates that PATH is a safe absolute path without traversal
# Returns 0 if valid, 1 if invalid
function appdeploy_validate_path() {
	local path="$1"
	if [[ -z "$path" ]]; then
		return 1
	fi
	# Must be absolute path
	if [[ "$path" != /* ]]; then
		appdeploy_error "Invalid path: '$path' (must be absolute)"
		return 1
	fi
	# Prevent path traversal
	if [[ "$path" == *".."* ]]; then
		appdeploy_error "Invalid path: '$path' (path traversal not allowed)"
		return 1
	fi
	# Only allow safe characters in paths
	if [[ ! "$path" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
		appdeploy_error "Invalid path: '$path' (contains unsafe characters)"
		return 1
	fi
	return 0
}

# Function: appdeploy_escape_single_quotes STRING
# Escapes single quotes in STRING for safe use in single-quoted shell strings
function appdeploy_escape_single_quotes() {
	local str="$1"
	printf '%s' "${str//\'/\'\\\'\'}"
}

# Function: appdeploy_make_temp_file [SUFFIX]
# Creates a secure temporary file and returns its path
function appdeploy_make_temp_file() {
	local suffix="${1:-}"
	local tmpfile
	tmpfile=$(mktemp "/tmp/appdeploy.XXXXXXXXXX${suffix}") || {
		appdeploy_error "Failed to create temporary file"
		return 1
	}
	chmod 600 "$tmpfile"
	printf '%s' "$tmpfile"
}

# ============================================================================
# RUNNER DEPLOYMENT
# ============================================================================

# Function: appdeploy_runner_path
# Returns the path to the runner script (sibling of this script)
function appdeploy_runner_path() {
	local script_path
	script_path=$(realpath "${BASH_SOURCE[0]}")
	printf '%s/appdeploy.runner.sh' "$(dirname "$script_path")"
}

# Function: appdeploy_runner_deploy TARGET
# Deploys the runner script to $TARGET_PATH/appdeploy.runner.sh
function appdeploy_runner_deploy() {
	local target="$1"
	local runner_src
	runner_src=$(appdeploy_runner_path)
	
	if [[ ! -f "$runner_src" ]]; then
		appdeploy_error "Runner script not found: $runner_src"
		return 1
	fi
	
	local path user host
	path=$(appdeploy_target_path "$target")
	user=$(appdeploy_target_user "$target")
	host=$(appdeploy_target_host "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local runner_dest="$path/appdeploy.runner.sh"
	local escaped_dest
	escaped_dest=$(appdeploy_escape_single_quotes "$runner_dest")
	
	appdeploy_debug "Deploying runner to $runner_dest"
	
	if [[ -z "$host" || "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
		# Local copy
		if ! cp "$runner_src" "$runner_dest"; then
			appdeploy_error "Failed to copy runner script"
			return 1
		fi
		chmod 755 "$runner_dest"
	else
		# Remote copy via rsync
		if ! rsync -az "$runner_src" "${user}@${host}:${runner_dest}"; then
			appdeploy_error "Failed to deploy runner script to remote"
			return 1
		fi
		ssh -o BatchMode=yes -- "${user}@${host}" "chmod 755 '${escaped_dest}'"
	fi
	
	appdeploy_debug "Runner deployed successfully"
	return 0
}

# Function: appdeploy_runner_ensure TARGET
# Ensures runner is deployed (idempotent, checks if exists)
function appdeploy_runner_ensure() {
	local target="$1"
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local runner_dest="$path/appdeploy.runner.sh"
	local escaped_dest
	escaped_dest=$(appdeploy_escape_single_quotes "$runner_dest")
	
	# Check if runner exists on target
	if ! appdeploy_cmd_run "$target" "test -x '${escaped_dest}'" 2>/dev/null; then
		appdeploy_log "Deploying runner script to target"
		appdeploy_runner_deploy "$target"
	fi
}

# Function: appdeploy_runner_invoke TARGET PACKAGE COMMAND [ARGS...]
# Invokes the runner script on target with proper environment
function appdeploy_runner_invoke() {
	local target="$1"
	local package="$2"
	local cmd="$3"
	shift 3
	local args="$*"
	
	local path user
	path=$(appdeploy_target_path "$target")
	user=$(appdeploy_target_user "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	if ! appdeploy_validate_name "$package"; then
		return 1
	fi
	
	local escaped_path escaped_package
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	escaped_package=$(appdeploy_escape_single_quotes "$package")
	
	# Build environment variables for runner
	local env_vars="APP_NAME='${escaped_package}'"
	env_vars+=" APP_SCRIPT='${escaped_path}/${escaped_package}/run/run.sh'"
	env_vars+=" APP_ENV_SCRIPT='${escaped_path}/${escaped_package}/run/env.sh'"
	env_vars+=" APP_LOG_DIR='${escaped_path}/${escaped_package}/var/logs'"
	env_vars+=" APP_PID_FILE='${escaped_path}/${escaped_package}/.pid'"
	[[ -n "$user" ]] && env_vars+=" APP_RUN_USER='${user}'"
	env_vars+=" APP_USE_SYSTEMD=auto"
	
	# Invoke runner
	appdeploy_cmd_run "$target" "${env_vars} '${escaped_path}/appdeploy.runner.sh' ${cmd} ${args}"
}

# ============================================================================
# LOGGING
# ============================================================================

# Function: appdeploy_format_path PATH
# Formats a path with bold styling for better visibility
function appdeploy_format_path() {
	printf '%s%s%s' "$BOLD" "$1" "$RESET"
}

function appdeploy_log() {
	local prefix="_._"
	printf '%s%s %s%s\n' "$BLUE" "$prefix" "$*" "$RESET"
}

function appdeploy_warn() {
	local prefix="-!-"
	printf '%s%s %s%s\n' "$YELLOW" "$prefix" "$*" "$RESET"
}

function appdeploy_error() {
	local prefix="~!~"
	printf '%s%s %s%s\n' "$RED" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_info MESSAGE
# Outputs an informational event message in green
function appdeploy_info() {
	local prefix="<|>"
	printf '%s%s %s%s\n' "$GREEN" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_debug MESSAGE
# Outputs a debug message in gray (only shown when DEBUG=1)
function appdeploy_debug() {
	if [ -n "${DEBUG:-}" ]; then
		local prefix="[debug] _._"
		printf '%s%s %s%s\n' "$GRAY" "$prefix" "$*" "$RESET"
	fi
}

# ============================================================================
# PROCESS LOGGING (rap-2025 format)
# ============================================================================

# Function: appdeploy_program NAME
# Outputs a program start marker: >-- NAME
function appdeploy_program() {
	local prefix=">--"
	printf '%s%s %s%s\n' "$BOLD" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_step MESSAGE
# Outputs a step marker: --> MESSAGE
function appdeploy_step() {
	local prefix="-->"
	printf '%s%s %s%s\n' "$BLUE" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_step_ok MESSAGE
# Outputs a step success marker: <OK MESSAGE
function appdeploy_step_ok() {
	local prefix="<OK"
	printf '%s%s %s%s\n' "$GREEN" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_step_fail MESSAGE
# Outputs a step failure marker: <!! MESSAGE
function appdeploy_step_fail() {
	local prefix="<!!"
	printf '%s%s %s%s\n' "$RED" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_result MESSAGE
# Outputs a result marker: <-- MESSAGE
function appdeploy_result() {
	local prefix="<--"
	printf '%s%s %s%s\n' "$GRAY" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_program_ok MESSAGE
# Outputs a program success marker: EOK MESSAGE
function appdeploy_program_ok() {
	local prefix="EOK"
	printf '%s%s %s%s\n' "$GREEN" "$prefix" "$*" "$RESET"
}

# Function: appdeploy_program_fail MESSAGE
# Outputs a program failure marker: E!! MESSAGE
function appdeploy_program_fail() {
	local prefix="E!!"
	printf '%s%s %s%s\n' "$RED" "$prefix" "$*" "$RESET"
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================
function appdeploy_target_user() {
	if [[ $1 =~ ^([^@:]+)(@.*)?$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	fi
	return 0
}

function appdeploy_target_host() {
	if [[ $1 =~ ^([^@]*@)?([^:@]+)(:.*)?$ ]]; then
		printf '%s\n' "${BASH_REMATCH[2]}"
	fi
	return 0
}

function appdeploy_target_path() {
	if [[ $1 =~ :(.*)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	else
		# No path specified, use default
		printf '%s\n' "$APPDEPLOY_DEFAULT_PATH"
	fi
}

function appdeploy_package_name() {
	# Try digit-starting version first (most common: semver, timestamps), then letter-starting (git hashes, v-prefix)
	if [[ $1 =~ ^(.*)-([0-9][0-9a-zA-Z._-]*)\.tar\.(gz|bz2|xz)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	elif [[ $1 =~ ^(.*)-([a-zA-Z][0-9a-zA-Z._-]*)\.tar\.(gz|bz2|xz)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	fi
}

function appdeploy_package_version() { # $1 = filename
	# Try digit-starting version first (most common: semver, timestamps), then letter-starting (git hashes, v-prefix)
	if [[ $1 =~ ^.*-([0-9][0-9a-zA-Z._-]*)\.tar\.(gz|bz2|xz)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	elif [[ $1 =~ ^.*-([a-zA-Z][0-9a-zA-Z._-]*)\.tar\.(gz|bz2|xz)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
	fi
}

function appdeploy_package_ext() { # $1 = filename
	[[ $1 =~ \.tar\.(gz|bz2|xz)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

# Function: appdeploy_package_parse PACKAGE_SPEC
# Parses a PACKAGE[:VERSION] spec, outputting "name version" (version may be empty)
function appdeploy_package_parse() {
	local spec="$1"
	local name version
	if [[ "$spec" == *:* ]]; then
		name="${spec%%:*}"
		version="${spec#*:}"
	else
		name="$spec"
		version=""
	fi
	printf '%s %s\n' "$name" "$version"
}

# Function: appdeploy_version_compare V1 V2
# Compares two semver-like versions. Returns: 0 if V1=V2, 1 if V1>V2, 2 if V1<V2
function appdeploy_version_compare() {
	if [[ "$1" == "$2" ]]; then
		return 0
	fi
	local IFS=.
	local i
	local v1=()
	local v2=()

	read -r -a v1 <<< "$1"
	read -r -a v2 <<< "$2"
	# Fill empty positions with zeros
	for ((i=${#v1[@]}; i<${#v2[@]}; i++)); do
		v1[i]=0
	done
	for ((i=0; i<${#v1[@]}; i++)); do
		[[ -z ${v2[i]:-} ]] && v2[i]=0
		# Compare numeric parts
		local n1="${v1[i]%%[^0-9]*}"
		local n2="${v2[i]%%[^0-9]*}"
		[[ -z "$n1" ]] && n1=0
		[[ -z "$n2" ]] && n2=0
		if ((n1 > n2)); then
			return 1
		elif ((n1 < n2)); then
			return 2
		fi
		# Compare remaining string parts (e.g., alpha, beta, rc)
		local s1="${v1[i]#$n1}"
		local s2="${v2[i]#$n2}"
		if [[ "$s1" < "$s2" ]]; then
			return 2
		elif [[ "$s1" > "$s2" ]]; then
			return 1
		fi
	done
	return 0
}

# Function: appdeploy_version_latest VERSIONS...
# Returns the highest version from the provided list using semver comparison
function appdeploy_version_latest() {
	local latest=""
	local v
	for v in "$@"; do
		if [[ -z "$latest" ]]; then
			latest="$v"
		else
			appdeploy_version_compare "$v" "$latest"
			local cmp=$?
			if ((cmp == 1)); then
				latest="$v"
			fi
		fi
	done
	printf '%s\n' "$latest"
}

# ----------------------------------------------------------------------------
#
# TARGET DETECTION
# 
# ----------------------------------------------------------------------------

# Function: appdeploy_is_target ARG
# Returns 0 if ARG looks like a TARGET (contains @ or /), 1 otherwise
function appdeploy_is_target() {
	local arg="$1"
	[[ "$arg" == *"@"* || "$arg" == *"/"* ]]
}

# Function: appdeploy_default_target
# Returns the default target string
function appdeploy_default_target() {
	printf ':%s' "$APPDEPLOY_TARGET"
}

# ----------------------------------------------------------------------------
#
# UTILITIES
# 
# ----------------------------------------------------------------------------

# Function: appdeploy_version_infer [PATH]
# Infers a version from git/jj commit hash or falls back to timestamp.
# For git/jj, returns format: YYYYMMDD-{short_hash} for sortability.
# For fallback, returns timestamp: YYYYMMDDHHMMSS
function appdeploy_version_infer() {
	local path="${1:-.}"
	local version=""
	
	# Try git first
	if command -v git &>/dev/null && git -C "$path" rev-parse HEAD &>/dev/null 2>&1; then
		local hash
		hash=$(git -C "$path" rev-parse --short HEAD 2>/dev/null)
		local date
		date=$(date +%Y%m%d)
		version="${date}-${hash}"
	# Try jj (Jujutsu)
	elif command -v jj &>/dev/null && jj -R "$path" log -r @ --no-graph -T 'commit_id.short()' &>/dev/null 2>&1; then
		local hash
		hash=$(jj -R "$path" log -r @ --no-graph -T 'commit_id.short()' 2>/dev/null)
		local date
		date=$(date +%Y%m%d)
		version="${date}-${hash}"
	else
		# Fallback to timestamp
		version=$(date +%Y%m%d%H%M%S)
	fi
	
	printf '%s' "$version"
}

# Function: appdeploy_cmd_run TARGET COMMAND [ARGS...]
# Runs COMMAND with ARGS on TARGET via SSH, in the target path, unless TARGET
# has no host part, in which case runs locally.
# SECURITY: Commands are executed via bash -c with proper escaping
function appdeploy_cmd_run() {
	local user
	local host
	local path
	user=$(appdeploy_target_user "$1")
	host=$(appdeploy_target_host "$1")
	path=$(appdeploy_target_path "$1")
	shift
	local cmd="$*"
	local out
	
	# Validate path to prevent injection
	if [[ -n "$path" ]] && ! appdeploy_validate_path "$path"; then
		appdeploy_error "Invalid target path: $path"
		return 1
	fi
	
	# Escape the path for safe use in single quotes
	local escaped_path
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	
	if [[ -z "$host" || "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
		# Run locally using bash -c instead of eval
		# This provides better isolation than eval
		if ! out=$(set +x; cd "$path" && bash -c "$cmd" 2>&1); then
			return 1
		fi
	else
		# Run via SSH with proper escaping
		# Use -- to prevent option injection, escape the command properly
		local ssh_cmd="cd '${escaped_path}' && ${cmd}"
		if ! out=$(ssh -o BatchMode=yes -- "${user}@${host}" "$ssh_cmd" 2>&1); then
			return 1
		fi
	fi
	echo -n "$out"
}
# Function: appdeploy_dir_ensure TARGET
# Ensures that the given PATH exists on TARGET, creating it if necessary.
function appdeploy_dir_ensure() {
	local path
	local user
	path=$(appdeploy_target_path "$1")
	user=$(appdeploy_target_user "$1")
	local dir="$path/$2"
	
	# Validate inputs
	if ! appdeploy_validate_path "$dir"; then
		return 1
	fi
	if ! appdeploy_validate_name "$user"; then
		appdeploy_error "Invalid user: $user"
		return 1
	fi
	
	local escaped_dir
	escaped_dir=$(appdeploy_escape_single_quotes "$dir")
	local escaped_user
	escaped_user=$(appdeploy_escape_single_quotes "$user")
	
	appdeploy_cmd_run "$1" "mkdir -p '${escaped_dir}' && chown '${escaped_user}:${escaped_user}' '${escaped_dir}'"
}

# Function: appdeploy_file_exists FILE [TARGET]
# Checks if the given FILE exists, on TARGET if given, otherwise locally.
function appdeploy_file_exists () {
	if [ $# -eq 1 ]; then
		[ -e "$1" ]
	else
		appdeploy_cmd_run "$2" "test -e '$1'"
	fi
}

# ----------------------------------------------------------------------------
#
# PACKAGES
# 
# ----------------------------------------------------------------------------

# Function: appdeploy_package_upload TARGET PACKAGE [NAME] [VERSION]
# Uploads `PACKAGE` to `TARGET`, optionally renaming it to `NAME` and `VERSION`.
# Names and versions are used to construct the filename as `NAME-VERSION.EXT`.
# If TARGET has no host, performs a local copy instead of rsync over SSH.
function appdeploy_package_upload() {
	local target="$1"
	local package="$2"
	# Parse name/version with || true to prevent set -e from exiting before error messages
	local parsed_name parsed_version
	parsed_name=$(appdeploy_package_name "$(basename "$package")") || true
	parsed_version=$(appdeploy_package_version "$(basename "$package")") || true
	local name="${3:-$parsed_name}"
	local version="${4:-$parsed_version}"
	local ext
	ext=$(appdeploy_package_ext "$(basename "$package")")
	
	# Validate inputs
	if [[ -z "$name" ]]; then
		appdeploy_error "Could not determine package name from: $package"
		return 1
	fi
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	if [[ -z "$version" ]]; then
		appdeploy_error "Could not determine package version from: $package"
		return 1
	fi
	if ! appdeploy_validate_version "$version"; then
		return 1
	fi
	if [[ ! -f "$package" ]]; then
		appdeploy_error "Package file does not exist: $package"
		return 1
	fi
	
	local user
	local host
	local path
	user=$(appdeploy_target_user "$target")
	host=$(appdeploy_target_host "$target")
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local dest_dir="$path/$name/packages"
	local dest_file="$name-$version.tar.$ext"
	
	appdeploy_program "Upload package $name:$version"
	appdeploy_step "Uploading $(appdeploy_format_path "$package") to $(appdeploy_format_path "$target")"
	
	# Ensure destination directory exists
	local escaped_dest_dir
	escaped_dest_dir=$(appdeploy_escape_single_quotes "$dest_dir")
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_dest_dir}'"
	
	if [[ -z "$host" || "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
		# Local copy
		if ! cp "$package" "${dest_dir}/${dest_file}"; then
			appdeploy_step_fail "Failed to copy package"
			return 1
		fi
	else
		# Upload using rsync
		if ! rsync -az --progress "$package" "${user}@${host}:${dest_dir}/${dest_file}"; then
			appdeploy_step_fail "Failed to upload package"
			return 1
		fi
	fi
	
	appdeploy_step_ok "Uploaded $(appdeploy_format_path "$dest_file")"
}

# Function: appdeploy_package_install TARGET PACKAGE[:VERSION]
# Given a `PACKAGE` (`VERSION` or latest) uploaded on `TARGET`, installs
# the package so that it can be activated.
function appdeploy_package_install() {
	local target="$1"
	local spec="$2"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local user
	local host
	local path
	user=$(appdeploy_target_user "$target")
	host=$(appdeploy_target_host "$target")
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local pkg_dir="$path/$name/packages"
	local dist_dir="$path/$name/dist"
	
	# Escape for shell commands
	local escaped_name escaped_pkg_dir escaped_dist_dir
	escaped_name=$(appdeploy_escape_single_quotes "$name")
	escaped_pkg_dir=$(appdeploy_escape_single_quotes "$pkg_dir")
	escaped_dist_dir=$(appdeploy_escape_single_quotes "$dist_dir")
	
	# If no version specified, find the latest
	if [[ -z "$version" ]]; then
		local versions
		versions=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_pkg_dir}' 2>/dev/null | grep -E '^${escaped_name}-[0-9].*\\.tar\\.(gz|bz2|xz)\$' | sed -E 's/^${escaped_name}-//;s/\\.tar\\.(gz|bz2|xz)\$//'")
		if [[ -z "$versions" ]]; then
			appdeploy_error "No packages found for $name on $target"
			return 1
		fi
		local version_list=()
		readarray -t version_list <<< "$versions"
		version=$(appdeploy_version_latest "${version_list[@]}")
		# Validate the resolved version
		if ! appdeploy_validate_version "$version"; then
			return 1
		fi
		appdeploy_log "Resolved latest version: $(appdeploy_format_path "$version")"
	fi

	local escaped_version
	escaped_version=$(appdeploy_escape_single_quotes "$version")

	# Find the package file
	local pkg_file
	pkg_file=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_pkg_dir}/${escaped_name}-${escaped_version}'.tar.* 2>/dev/null | head -1")
	if [[ -z "$pkg_file" ]]; then
		appdeploy_error "Package not found: $name-$version"
		return 1
	fi
	
	# Determine compression type
	local tar_opts=""
	case "$pkg_file" in
		*.tar.gz)  tar_opts="-xzf" ;;
		*.tar.bz2) tar_opts="-xjf" ;;
		*.tar.xz)  tar_opts="-xJf" ;;
		*) appdeploy_error "Unknown compression: $pkg_file"; return 1 ;;
	esac
	
	# Check if already installed
	if appdeploy_cmd_run "$target" "test -d '${escaped_dist_dir}/${escaped_version}'" 2>/dev/null; then
		appdeploy_info "Package $name:$version is already installed"
		return 0
	fi
	
	appdeploy_program "Install package $name:$version"
	appdeploy_step "Extracting to $(appdeploy_format_path "$dist_dir/$version")"
	
	# Escape pkg_file for the command
	local escaped_pkg_file
	escaped_pkg_file=$(appdeploy_escape_single_quotes "$pkg_file")
	
	# Create dist directory and extract
	if ! appdeploy_cmd_run "$target" "mkdir -p '${escaped_dist_dir}/${escaped_version}' && tar $tar_opts '${escaped_pkg_file}' -C '${escaped_dist_dir}/${escaped_version}'"; then
		appdeploy_step_fail "Failed to extract package"
		return 1
	fi
	
	appdeploy_step_ok "Installed $(appdeploy_format_path "$name:$version")"
}

# Function: appdeploy_package_activate TARGET PACKAGE[:VERSION]
# Given a `PACKAGE` (`VERSION` or latest) uploaded on `TARGET`, ensures
# the package is installed (unpacked) and actives it.
function appdeploy_package_activate() {
	local target="$1"
	local spec="$2"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local user
	local host
	local path
	user=$(appdeploy_target_user "$target")
	host=$(appdeploy_target_host "$target")
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local pkg_dir="$path/$name/packages"
	local dist_dir="$path/$name/dist"
	local var_dir="$path/$name/var"
	local run_dir="$path/$name/run"
	
	# Escape for shell commands
	local escaped_name escaped_pkg_dir escaped_dist_dir escaped_var_dir escaped_run_dir escaped_path
	escaped_name=$(appdeploy_escape_single_quotes "$name")
	escaped_pkg_dir=$(appdeploy_escape_single_quotes "$pkg_dir")
	escaped_dist_dir=$(appdeploy_escape_single_quotes "$dist_dir")
	escaped_var_dir=$(appdeploy_escape_single_quotes "$var_dir")
	escaped_run_dir=$(appdeploy_escape_single_quotes "$run_dir")
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	
	# If no version specified, find the latest installed or uploaded
	if [[ -z "$version" ]]; then
		# First check installed versions
		local versions
		versions=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_dist_dir}' 2>/dev/null | grep -E '^[0-9]'")
		if [[ -z "$versions" ]]; then
			# Fall back to uploaded packages
			versions=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_pkg_dir}' 2>/dev/null | grep -E '^${escaped_name}-[0-9].*\\.tar\\.(gz|bz2|xz)\$' | sed -E 's/^${escaped_name}-//;s/\\.tar\\.(gz|bz2|xz)\$//'")
		fi
		if [[ -z "$versions" ]]; then
			appdeploy_error "No packages found for $name on $target"
			return 1
		fi
		local version_list=()
		readarray -t version_list <<< "$versions"
		version=$(appdeploy_version_latest "${version_list[@]}")
		# Validate the resolved version
		if ! appdeploy_validate_version "$version"; then
			return 1
		fi
		appdeploy_log "Resolved latest version: $(appdeploy_format_path "$version")"
	fi

	local escaped_version
	escaped_version=$(appdeploy_escape_single_quotes "$version")

	# Ensure package is installed
	if ! appdeploy_cmd_run "$target" "test -d '${escaped_dist_dir}/${escaped_version}'" 2>/dev/null; then
		appdeploy_log "Package not installed, installing first..."
		if ! appdeploy_package_install "$target" "$name:$version"; then
			appdeploy_step_fail "Failed to install package"
			return 1
		fi
	fi
	
	appdeploy_program "Activate package $name:$version"
	appdeploy_step "Creating symlinks in $(appdeploy_format_path "$run_dir")"
	
	# Create run and var directories
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_run_dir}' '${escaped_var_dir}'"
	
	# Clear existing symlinks in run directory
	appdeploy_cmd_run "$target" "find '${escaped_run_dir}' -maxdepth 1 -type l -delete"
	
	# Create symlinks from dist/VERSION to run
	appdeploy_cmd_run "$target" "for item in '${escaped_dist_dir}/${escaped_version}'/*; do [ -e \"\$item\" ] && ln -sf \"\$item\" '${escaped_run_dir}/'; done; true"
	
	# Overlay symlinks from var to run (these take precedence)
	appdeploy_cmd_run "$target" "for item in '${escaped_var_dir}'/*; do [ -e \"\$item\" ] && ln -sf \"\$item\" '${escaped_run_dir}/'; done; true"
	
	# Store active version marker (save previous active to .last-active first)
	appdeploy_cmd_run "$target" "[ -f '${escaped_path}/${escaped_name}/.active' ] && cp '${escaped_path}/${escaped_name}/.active' '${escaped_path}/${escaped_name}/.last-active' 2>/dev/null || true"
	appdeploy_cmd_run "$target" "echo '${escaped_version}' > '${escaped_path}/${escaped_name}/.active'"
	
	# Create var/logs directory for service logs
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_var_dir}/logs'"
	
	# Deploy runner script to target
	appdeploy_step "Deploying runner script"
	appdeploy_runner_ensure "$target"
	
	appdeploy_step_ok "Activated $(appdeploy_format_path "$name:$version")"
}

# Function: appdeploy_package_deactivate TARGET PACKAGE[:VERSION]
# If `PACKAGE` (specific `VERSION` or active) is active on `TARGET`, ensures
# it is deactivated.
function appdeploy_package_deactivate() {
	local target="$1"
	local spec="$2"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local run_dir="$path/$name/run"
	local active_file="$path/$name/.active"
	
	# Escape for shell commands
	local escaped_run_dir escaped_active_file
	escaped_run_dir=$(appdeploy_escape_single_quotes "$run_dir")
	escaped_active_file=$(appdeploy_escape_single_quotes "$active_file")
	
	# Get currently active version
	local active_version
	active_version=$(appdeploy_cmd_run "$target" "cat '${escaped_active_file}' 2>/dev/null" || true)
	
	if [[ -z "$active_version" ]]; then
		appdeploy_info "No active version for $name"
		return 0
	fi
	
	# If a specific version was requested, check if it matches
	if [[ -n "$version" && "$version" != "$active_version" ]]; then
		appdeploy_info "$name:$version is not active (active: $active_version)"
		return 0
	fi
	
	appdeploy_program "Deactivate package $name:$active_version"
	
	# Stop and disable the service before deactivating
	appdeploy_step "Stopping and disabling service"
	appdeploy_runner_invoke "$target" "$name" stop 2>/dev/null || true
	appdeploy_runner_invoke "$target" "$name" disable 2>/dev/null || true
	
	appdeploy_step "Removing symlinks from $(appdeploy_format_path "$run_dir")"
	
	# Remove all symlinks in run directory
	appdeploy_cmd_run "$target" "find '${escaped_run_dir}' -maxdepth 1 -type l -delete"
	
	# Remove active marker
	appdeploy_cmd_run "$target" "rm -f '${escaped_active_file}'"
	
	appdeploy_step_ok "Deactivated $name:$active_version"
}

# Function: appdeploy_package_uninstall TARGET PACKAGE[:VERSION]
# If `PACKAGE` (specific `VERSION` or all matching) is installed on `TARGET`, ensures
# it is deactivated and uninstalled (archive kept)
function appdeploy_package_uninstall() {
	local target="$1"
	local spec="$2"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local dist_dir="$path/$name/dist"
	local active_file="$path/$name/.active"
	
	# Escape for shell commands
	local escaped_dist_dir escaped_active_file
	escaped_dist_dir=$(appdeploy_escape_single_quotes "$dist_dir")
	escaped_active_file=$(appdeploy_escape_single_quotes "$active_file")
	
	# Get currently active version
	local active_version
	active_version=$(appdeploy_cmd_run "$target" "cat '${escaped_active_file}' 2>/dev/null" || true)
	
	# If no version specified, uninstall all versions
	if [[ -z "$version" ]]; then
		local versions
		versions=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_dist_dir}' 2>/dev/null | grep -E '^[0-9]'")
		if [[ -z "$versions" ]]; then
			appdeploy_info "No installed versions for $name"
			return 0
		fi
		for v in $versions; do
			appdeploy_package_uninstall "$target" "$name:$v"
		done
		return 0
	fi
	
	local escaped_version
	escaped_version=$(appdeploy_escape_single_quotes "$version")
	
	# Check if version is installed
	if ! appdeploy_cmd_run "$target" "test -d '${escaped_dist_dir}/${escaped_version}'" 2>/dev/null; then
		appdeploy_info "$name:$version is not installed"
		return 0
	fi
	
	# Deactivate if this version is active
	if [[ "$active_version" == "$version" ]]; then
		appdeploy_log "Deactivating active version first..."
		appdeploy_package_deactivate "$target" "$name:$version"
	fi
	
	appdeploy_program "Uninstall package $name:$version"
	appdeploy_step "Removing $(appdeploy_format_path "$dist_dir/$version")"
	
	# Remove the dist directory for this version
	# Files are read-only (555/444), so we need to restore write permissions first
	appdeploy_cmd_run "$target" "chmod -R u+w '${escaped_dist_dir}/${escaped_version}' && rm -rf '${escaped_dist_dir}/${escaped_version}'"
	
	appdeploy_step_ok "Uninstalled $name:$version (archive kept)"
}

# Function: appdeploy_package_remove TARGET PACKAGE[:VERSION]
# If `PACKAGE` (`VERSION` or all matching) is installed on `TARGET`, ensures
# it is deactivated, uninstalled and archive removed.
function appdeploy_package_remove() {
	local target="$1"
	local spec="$2"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local pkg_dir="$path/$name/packages"
	
	# Escape for shell commands
	local escaped_name escaped_pkg_dir
	escaped_name=$(appdeploy_escape_single_quotes "$name")
	escaped_pkg_dir=$(appdeploy_escape_single_quotes "$pkg_dir")
	
	# If no version specified, remove all versions
	if [[ -z "$version" ]]; then
		local versions
		versions=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_pkg_dir}' 2>/dev/null | grep -E '^${escaped_name}-[0-9].*\\.tar\\.(gz|bz2|xz)\$' | sed -E 's/^${escaped_name}-//;s/\\.tar\\.(gz|bz2|xz)\$//'")
		if [[ -z "$versions" ]]; then
			appdeploy_info "No packages found for $name"
			return 0
		fi
		for v in $versions; do
			appdeploy_package_remove "$target" "$name:$v"
		done
		return 0
	fi
	
	local escaped_version
	escaped_version=$(appdeploy_escape_single_quotes "$version")
	
	# Stop and disable service if running (ignore errors - might not be running)
	appdeploy_log "Stopping and disabling service if running..."
	appdeploy_runner_invoke "$target" "$name" stop 2>/dev/null || true
	appdeploy_runner_invoke "$target" "$name" disable 2>/dev/null || true
	
	# Uninstall first (this handles deactivation too)
	appdeploy_package_uninstall "$target" "$name:$version"
	
	appdeploy_program "Remove package $name:$version"
	appdeploy_step "Removing archive from $(appdeploy_format_path "$pkg_dir")"
	
	# Remove the package archive
	appdeploy_cmd_run "$target" "rm -f '${escaped_pkg_dir}/${escaped_name}-${escaped_version}'.tar.*"
	
	appdeploy_step_ok "Removed $name:$version"
}

# Function: appdeploy_package_list TARGET [PACKAGE][:VERSION]
# Lists the packages that match the given PACKAGE and VERSION on TARGET, 
# supporting wildcards. 

# Function: appdeploy_package_current TARGET PACKAGE_NAME
# Returns the currently active version of a package on the target
# Returns empty string if no package is active
function appdeploy_package_current() {
	local target="$1"
	local package_name="$2"
	
	# Validate arguments
	if [[ -z "$target" ]] || [[ -z "$package_name" ]]; then
		appdeploy_error "Usage: appdeploy_package_current TARGET PACKAGE_NAME"
		return 1
	fi
	
	if ! appdeploy_validate_name "$package_name"; then
		return 1
	fi
	
	if ! appdeploy_target_check "$target"; then
		return 1
	fi
	
	local target_path
	target_path=$(appdeploy_target_path "$target")
	local active_file="${target_path}/${package_name}/.active"
	
	# Escape for shell commands
	local escaped_active_file
	escaped_active_file=$(appdeploy_escape_single_quotes "$active_file")
	
	# Read the active version using appdeploy_cmd_run (handles both local and remote)
	local active_version
	active_version=$(appdeploy_cmd_run "$target" "cat '${escaped_active_file}' 2>/dev/null" || true)
	
	if [[ -z "$active_version" ]]; then
		return 0
	fi
	
	echo "${package_name}:${active_version}"
	return 0
}

# supporting wildcards. 
function appdeploy_package_list() {
	local target="$1"
	local spec="${2:-*}"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Default to wildcard if no name given
	[[ -z "$name" ]] && name="*"
	
	# Validate name if not wildcard
	if [[ "$name" != "*" ]] && ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided and not wildcard
	if [[ -n "$version" && "$version" != "*" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local escaped_path
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	
	# List all matching apps
	local apps
	apps=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_path}' 2>/dev/null | grep -v '^\\.' || true")
	
	if [[ -z "$apps" ]]; then
		appdeploy_log "No packages found on $target"
		return 0
	fi
	
	printf "%-20s %-15s %-10s %-10s\n" "PACKAGE" "VERSION" "STATUS" "LOCATION"
	printf "%-20s %-15s %-10s %-10s\n" "-------" "-------" "------" "--------"
	
	for app in $apps; do
		# Validate app name from filesystem to prevent injection
		if ! appdeploy_validate_name "$app" 2>/dev/null; then
			continue
		fi
		
		# Check if app matches the pattern
		if [[ "$name" != "*" && "$app" != "$name" ]]; then
			continue
		fi
		
		local pkg_dir="$path/$app/packages"
		local dist_dir="$path/$app/dist"
		local active_file="$path/$app/.active"
		
		# Escape for shell commands
		local escaped_app escaped_pkg_dir escaped_dist_dir escaped_active_file
		escaped_app=$(appdeploy_escape_single_quotes "$app")
		escaped_pkg_dir=$(appdeploy_escape_single_quotes "$pkg_dir")
		escaped_dist_dir=$(appdeploy_escape_single_quotes "$dist_dir")
		escaped_active_file=$(appdeploy_escape_single_quotes "$active_file")
		
		# Get active version
		local active_version
		active_version=$(appdeploy_cmd_run "$target" "cat '${escaped_active_file}' 2>/dev/null" || true)
		
		# List uploaded packages
			local pkg_versions
			pkg_versions=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_pkg_dir}' 2>/dev/null | grep -E '^${escaped_app}-[0-9].*\\.tar\\.(gz|bz2|xz)\$' | sed -E 's/^${escaped_app}-//;s/\\.tar\\.(gz|bz2|xz)\$//' || true")
		
		# List installed versions
			local installed_versions
			installed_versions=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_dist_dir}' 2>/dev/null | grep -E '^[0-9]' || true")
		
		# Combine and deduplicate versions
		local all_versions
		all_versions=$(printf '%s\n%s' "$pkg_versions" "$installed_versions" | sort -V | uniq)
		
		if [[ -z "$all_versions" ]]; then
			continue
		fi
		
			for v in $all_versions; do
			# Validate version from filesystem
			if ! appdeploy_validate_version "$v" 2>/dev/null; then
				continue
			fi
			
			# Filter by version if specified
				if [[ -n "$version" && "$v" != "$version" ]]; then
				continue
			fi
			
			local status=""
			local location=""
			
			# Check if uploaded
			if echo "$pkg_versions" | grep -q "^${v}$"; then
				location="packages"
			fi
			
			# Check if installed
			if echo "$installed_versions" | grep -q "^${v}$"; then
				if [[ -n "$location" ]]; then
					location="both"
				else
					location="dist"
				fi
				status="installed"
			else
				status="uploaded"
			fi
			
			# Check if active
			if [[ "$v" == "$active_version" ]]; then
				status="active"
			fi
			
			printf "%-20s %-15s %-10s %-10s\n" "$app" "$v" "$status" "$location"
		done
	done
}

# Function: appdeploy_conf_push TARGET PACKAGE[:VERSION] CONF_ARCHIVE
# Uploads the given `CONF_ARCHIVE` (tarball) to `TARGET` and unpacks it
# into the `var/` directory of the given `PACKAGE` (`VERSION` or latest).
# If TARGET has no host, performs a local copy instead of rsync over SSH.
function appdeploy_package_deploy_conf() {
	local target="$1"
	local spec="$2"
	local conf_archive="$3"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	
	if [[ ! -f "$conf_archive" ]]; then
		appdeploy_error "Configuration archive does not exist: $conf_archive"
		return 1
	fi
	
	local user
	local host
	local path
	user=$(appdeploy_target_user "$target")
	host=$(appdeploy_target_host "$target")
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local var_dir="$path/$name/var"
	
	# Determine compression type
	local tar_opts=""
	case "$conf_archive" in
		*.tar.gz|*.tgz)   tar_opts="-xzf" ;;
		*.tar.bz2|*.tbz2) tar_opts="-xjf" ;;
		*.tar.xz|*.txz)   tar_opts="-xJf" ;;
		*.tar)            tar_opts="-xf" ;;
		*) appdeploy_error "Unknown archive format: $conf_archive"; return 1 ;;
	esac
	
	appdeploy_log "Deploying configuration for $name"
	
	# Escape for shell commands
	local escaped_var_dir
	escaped_var_dir=$(appdeploy_escape_single_quotes "$var_dir")
	
	# Ensure var directory exists
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_var_dir}'"
	
	# Create secure temporary file using mktemp
	local temp_archive
	if [[ -z "$host" || "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
		# Local: use our secure temp file function
		temp_archive=$(appdeploy_make_temp_file ".tar") || return 1
		# Local copy
		if ! cp "$conf_archive" "${temp_archive}"; then
			rm -f "$temp_archive"
			appdeploy_error "Failed to copy configuration archive"
			return 1
		fi
	else
		# Remote: create temp file on remote host using mktemp
		temp_archive=$(appdeploy_cmd_run "$target" "mktemp /tmp/appdeploy_conf.XXXXXXXXXX.tar")
		if [[ -z "$temp_archive" ]]; then
			appdeploy_error "Failed to create temporary file on remote host"
			return 1
		fi
		# Upload using rsync
		if ! rsync -az "$conf_archive" "${user}@${host}:${temp_archive}"; then
			appdeploy_cmd_run "$target" "rm -f '$(appdeploy_escape_single_quotes "$temp_archive")'"
			appdeploy_error "Failed to upload configuration archive"
			return 1
		fi
	fi
	
	local escaped_temp_archive
	escaped_temp_archive=$(appdeploy_escape_single_quotes "$temp_archive")
	
	# Extract to var directory and clean up temp file
	if ! appdeploy_cmd_run "$target" "tar $tar_opts '${escaped_temp_archive}' -C '${escaped_var_dir}' && rm -f '${escaped_temp_archive}'"; then
		# Clean up on failure
		appdeploy_cmd_run "$target" "rm -f '${escaped_temp_archive}'" 2>/dev/null || true
		appdeploy_error "Failed to extract configuration archive"
		return 1
	fi
	
	appdeploy_log "Successfully deployed configuration to $var_dir"
	
	# If package is active, re-activate to update symlinks
	local active_file="$path/$name/.active"
	local escaped_active_file
	escaped_active_file=$(appdeploy_escape_single_quotes "$active_file")
	local active_version
	active_version=$(appdeploy_cmd_run "$target" "cat '${escaped_active_file}' 2>/dev/null" || true)
	if [[ -n "$active_version" ]]; then
		appdeploy_log "Re-activating $name:$active_version to apply configuration"
		appdeploy_package_activate "$target" "$name:$active_version"
	fi
}

# Function: appdeploy_package_create SOURCE DESTINATION [FORCE]
# Creates a package from the given SOURCE directory, placing the package
# tarball as DESTINATION. DESTINATION must be like `${NAME}-${VERSION}.tar.[gz|bz2|xz]`
# If FORCE is "true", overwrites existing destination file.
# All files in the package are made readonly (preserving +x flags).
function appdeploy_package_create () {
	local source="$1"
	local destination="$2"
	local force="${3:-false}"
	
	if [[ ! -d "$source" ]]; then
		appdeploy_error "Package directory does not exist: $source"
		return 1
	fi
	
	# Check env.sh exists and is executable
	if [[ ! -e "$source/env.sh" ]]; then
		appdeploy_error "No 'env.sh' found in source: $source"
		return 1
	elif [[ ! -x "$source/env.sh" ]]; then
		appdeploy_error "'env.sh' is not executable in source: $source"
		return 1
	fi
	# Check run.sh exists and is executable
	if [[ ! -e "$source/run.sh" ]]; then
		appdeploy_error "No 'run.sh' found in source: $source"
		return 1
	elif [[ ! -x "$source/run.sh" ]]; then
		appdeploy_error "'run.sh' is not executable in source: $source"
		return 1
	fi
	
	# Validate destination filename format
	# Use || true to prevent set -e from exiting before we can show error messages
	local name version
	name=$(appdeploy_package_name "$(basename "$destination")") || true
	version=$(appdeploy_package_version "$(basename "$destination")") || true
	
	if [[ -z "$name" ]]; then
		appdeploy_error "Invalid destination filename format: $destination (expected NAME-VERSION.tar.[gz|bz2|xz])"
		return 1
	fi
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	if [[ -z "$version" ]]; then
		appdeploy_error "Could not determine version from: $destination (expected NAME-VERSION.tar.[gz|bz2|xz])"
		return 1
	fi
	if ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	# Check if destination exists (fail unless force=true)
	if [[ -e "$destination" && "$force" != "true" ]]; then
		appdeploy_error "Destination already exists: $destination (use -f/--force to overwrite)"
		return 1
	fi
	
	# Determine compression based on extension
	local tar_opts=""
	case "$destination" in
		*.tar.gz)  tar_opts="-czf" ;;
		*.tar.bz2) tar_opts="-cjf" ;;
		*.tar.xz)  tar_opts="-cJf" ;;
		*.tar)     tar_opts="-cf" ;;
		*) appdeploy_error "Unknown compression format: $destination"; return 1 ;;
	esac
	
	# Ensure destination directory exists
	local dest_dir
	dest_dir=$(dirname "$destination")
	if [[ -n "$dest_dir" && "$dest_dir" != "." ]]; then
		mkdir -p "$dest_dir"
	fi
	
	appdeploy_program "Create package $name-$version"
	appdeploy_step "Staging from $(appdeploy_format_path "$source")"
	
	# Create staging directory for readonly copy
	local staging
	staging=$(mktemp -d) || {
		appdeploy_step_fail "Failed to create staging directory"
		return 1
	}
	
	# Copy source to staging
	if ! cp -a "$source/." "$staging/"; then
		appdeploy_step_fail "Failed to copy source to staging directory"
		chmod -R u+w "$staging" 2>/dev/null || true
		rm -rf "$staging"
		return 1
	fi
	
	appdeploy_step "Setting permissions (readonly)"
	
	# Make all files readonly, preserving +x flag
	# Files: readable by all, executable only if originally executable
	while IFS= read -r -d '' file; do
		if [[ -x "$file" ]]; then
			chmod 555 "$file"  # r-xr-xr-x
		else
			chmod 444 "$file"  # r--r--r--
		fi
	done < <(find "$staging" -type f -print0)
	
	# Make directories readonly (r-xr-xr-x)
	find "$staging" -type d -exec chmod 555 {} \;
	
	appdeploy_step "Creating tarball $(appdeploy_format_path "$destination")"
	
	# Create the tarball from the staging directory contents
	if ! tar $tar_opts "$destination" -C "$staging" .; then
		appdeploy_step_fail "Failed to create package"
		chmod -R u+w "$staging" 2>/dev/null || true
		rm -rf "$staging"
		return 1
	fi
	
	# Cleanup staging directory
	chmod -R u+w "$staging" 2>/dev/null || true
	rm -rf "$staging"
	
	appdeploy_step_ok "Created package $(appdeploy_format_path "$destination")"
}

# Function: appdeploy_package PATH [VERSION|OUTPUT] [-f|--force]
# Creates an appdeploy package from PATH with auto-inferred name/version.
# - NAME is inferred from the basename of PATH
# - VERSION can be specified explicitly, or is inferred from git/jj commit or timestamp
# - OUTPUT can be a full path matching NAME-VERSION.tar.[gz|bz2|xz] format
# - If only VERSION is given, output is written to current directory as NAME-VERSION.tar.gz
function appdeploy_package() {
	local path=""
	local version_or_output=""
	local force="false"
	
	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-f|--force)
				force="true"
				shift
				;;
			-*)
				appdeploy_error "Unknown option: $1"
				return 1
				;;
			*)
				if [[ -z "$path" ]]; then
					path="$1"
				elif [[ -z "$version_or_output" ]]; then
					version_or_output="$1"
				else
					appdeploy_error "Too many arguments"
					return 1
				fi
				shift
				;;
		esac
	done
	
	# Validate path argument
	if [[ -z "$path" ]]; then
		appdeploy_error "Usage: appdeploy package PATH [VERSION|OUTPUT] [-f|--force]"
		return 1
	fi
	
	if [[ ! -d "$path" ]]; then
		appdeploy_error "Path does not exist or is not a directory: $path"
		return 1
	fi
	
	# Infer name from basename of path
	local name
	name=$(basename "$(realpath "$path")")
	
	if ! appdeploy_validate_name "$name"; then
		appdeploy_error "Cannot infer valid package name from path: $path"
		return 1
	fi
	
	# Determine output path and version
	local output=""
	local version=""
	
	if [[ -n "$version_or_output" ]]; then
		# Check if it looks like a full output path (contains .tar.)
		if [[ "$version_or_output" =~ \.tar\.(gz|bz2|xz)$ ]]; then
			output="$version_or_output"
			# Validate it matches expected format
			local parsed_name
			parsed_name=$(appdeploy_package_name "$(basename "$output")") || true
			if [[ -z "$parsed_name" ]]; then
				appdeploy_error "Invalid output format: $output (expected NAME-VERSION.tar.[gz|bz2|xz])"
				return 1
			fi
		else
			# Treat as version
			version="$version_or_output"
			if ! appdeploy_validate_version "$version"; then
				return 1
			fi
		fi
	fi
	
	# Infer version if not set
	if [[ -z "$version" && -z "$output" ]]; then
		version=$(appdeploy_version_infer "$path")
		appdeploy_log "Inferred version: $(appdeploy_format_path "$version")"
	fi
	
	# Build output path if not set (default: current directory, .tar.gz)
	if [[ -z "$output" ]]; then
		output="${name}-${version}.tar.gz"
	fi
	
	# Call the core create function
	appdeploy_package_create "$path" "$output" "$force"
}

# Function: appdeploy_package_run TARGET PACKAGE_ARCHIVE [CONF_ARCHIVE] [DRY_RUN] [OVERLAY_PATHS...]
# Runs a package in the specified TARGET directory, creating a temporary deployment
# and executing the application. Cleans up the target directory after execution.
#
# Arguments:
#   TARGET           Target directory in format [:PATH] for local execution
#   PACKAGE_ARCHIVE  Path to the package archive file
#   CONF_ARCHIVE     Optional configuration archive to deploy
#   DRY_RUN          If "true", set up without executing (optional, defaults to false)
#   OVERLAY_PATHS    Optional space-separated list of overlay paths to symlink
#
# Returns: Exit status of the executed application
function appdeploy_package_run() {
	local target="$1"
	local package_archive="$2"
	local conf_archive="${3:-}"
	local dry_run="${4:-false}"
	local overlay_paths=("${@:5}")
	local start_time end_time runtime exit_status
	
	# Validate package archive
	if [[ ! -f "$package_archive" ]]; then
		appdeploy_error "Package archive does not exist: $package_archive"
		return 1
	fi
	
	# Extract package name and version from archive filename
	# Use || true to prevent set -e from exiting before we can show error messages
	local name version
	name=$(appdeploy_package_name "$(basename "$package_archive")") || true
	version=$(appdeploy_package_version "$(basename "$package_archive")") || true
	
	if [[ -z "$name" ]]; then
		appdeploy_error "Could not determine package name from: $package_archive"
		return 1
	fi
	
	if [[ -z "$version" ]]; then
		appdeploy_error "Could not determine package version from: $package_archive"
		return 1
	fi
	
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	
	if ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	appdeploy_program "Run package $name:$version"
	
	# Step 1: Install target structure
	appdeploy_step "#1/5 Installing target structure"
	if ! appdeploy_target_install "$target"; then
		appdeploy_step_fail "#1/5 Failed to install target structure"
		appdeploy_program_fail "Run package $name:$version"
		return 1
	fi
	
	# Step 2: Upload package to target
	appdeploy_step "#2/5 Uploading package"
	if ! appdeploy_package_upload "$target" "$package_archive" "$name" "$version"; then
		appdeploy_step_fail "#2/5 Failed to upload package"
		appdeploy_program_fail "Run package $name:$version"
		return 1
	fi
	
	# Step 3: Install package
	appdeploy_step "#3/5 Installing package"
	if ! appdeploy_package_install "$target" "$name:$version"; then
		appdeploy_step_fail "#3/5 Failed to install package"
		appdeploy_program_fail "Run package $name:$version"
		return 1
	fi
	
	# Step 4: Deploy configuration if provided
	if [[ -n "$conf_archive" ]]; then
		appdeploy_step "#4/5 Deploying configuration"
		if ! appdeploy_package_deploy_conf "$target" "$name:$version" "$conf_archive"; then
			appdeploy_step_fail "#4/5 Failed to deploy configuration"
			appdeploy_program_fail "Run package $name:$version"
			return 1
		fi
	fi
	
	# Step 5: Activate package
	appdeploy_step "#5/5 Activating package"
	if ! appdeploy_package_activate "$target" "$name:$version"; then
		appdeploy_step_fail "#5/5 Failed to activate package"
		appdeploy_program_fail "Run package $name:$version"
		return 1
	fi
	
	# Create overlay symlinks if provided
	if [[ ${#overlay_paths[@]} -gt 0 ]]; then
		local path
		path=$(appdeploy_target_path "$target")
		local run_dir="$path/$name/run"
		local escaped_run_dir
		escaped_run_dir=$(appdeploy_escape_single_quotes "$run_dir")
		
		for overlay_path in "${overlay_paths[@]}"; do
			if [[ -e "$overlay_path" ]]; then
				local overlay_name
				overlay_name=$(basename "$overlay_path")
				local escaped_overlay_name
				escaped_overlay_name=$(appdeploy_escape_single_quotes "$overlay_name")
				local escaped_overlay_path
				escaped_overlay_path=$(appdeploy_escape_single_quotes "$overlay_path")
				
				# Create symlink from overlay to run directory
				if ! appdeploy_cmd_run "$target" "ln -sf '${escaped_overlay_path}' '${escaped_run_dir}/${escaped_overlay_name}'"; then
					appdeploy_warn "Failed to create symlink for overlay: $overlay_path"
				fi
			else
				appdeploy_warn "Overlay path does not exist: $overlay_path"
			fi
		done
	fi
	
	local path
	path=$(appdeploy_target_path "$target")
	local run_dir="$path/$name/run"
	local env_file="$run_dir/env.sh"
	local run_file="$run_dir/run.sh"
	
	# Check required files exist and are executable
	if [[ ! -f "$env_file" ]]; then
		appdeploy_step_fail "Required file env.sh not found in package"
		appdeploy_program_fail "Run package $name:$version"
		return 1
	fi
	if [[ ! -x "$env_file" ]]; then
		appdeploy_step_fail "Required file env.sh is not executable"
		appdeploy_program_fail "Run package $name:$version"
		return 1
	fi
	
	if [[ ! -f "$run_file" ]]; then
		appdeploy_step_fail "Required file run.sh not found in package"
		appdeploy_program_fail "Run package $name:$version"
		return 1
	fi
	if [[ ! -x "$run_file" ]]; then
		appdeploy_step_fail "Required file run.sh is not executable"
		appdeploy_program_fail "Run package $name:$version"
		return 1
	fi
	
	# Handle dry run - skip execution
	if [[ "$dry_run" == "true" ]]; then
		appdeploy_info "Dry run mode - package set up at $(appdeploy_format_path "$run_dir")"
		appdeploy_program_ok "Run package $name:$version (dry run)"
		return 0
	fi
	
	# Execute the application
	appdeploy_step "Executing application"
	start_time=$(date +%s)
	
	# Execute with proper environment
	# Use bash -c to source env.sh and then execute run.sh in the same shell
	if ! bash -c "source '${env_file}' && '${run_file}'"; then
		exit_status=$?
		appdeploy_step_fail "Application exited with status $exit_status"
	else
		exit_status=0
		appdeploy_step_ok "Application completed"
	fi
	
	end_time=$(date +%s)
	runtime=$((end_time - start_time))
	
	appdeploy_result "Runtime: ${runtime}s, exit: ${exit_status}"
	
	if [[ $exit_status -eq 0 ]]; then
		appdeploy_program_ok "Run package $name:$version"
	else
		appdeploy_program_fail "Run package $name:$version"
	fi
	
	return $exit_status
}

# ----------------------------------------------------------------------------
#
# TARGET
# 
# ----------------------------------------------------------------------------

# Function: appdeploy_target_install TARGET
# Creates the appdeploy target directory structure on TARGET.
function appdeploy_target_install() {
	local target="$1"
	local path
	local user
	local host
	path=$(appdeploy_target_path "$target")
	user=$(appdeploy_target_user "$target")
	host=$(appdeploy_target_host "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	appdeploy_program "Install target structure"
	appdeploy_step "Creating $(appdeploy_format_path "$path")"
	
	local escaped_path
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	
	# Create base directory
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_path}'"
	
	appdeploy_step_ok "Installed on $(appdeploy_format_path "$target")"
}

# Function: appdeploy_target_check TARGET
# Checks that the appdeploy target directory structure exists on TARGET, and-
# has the expected subdirectories, creating them if necessary.
function appdeploy_target_check() {
	local target="$1"
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local escaped_path
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	
	# Check if base directory exists
	if ! appdeploy_cmd_run "$target" "test -d '${escaped_path}'" 2>/dev/null; then
		appdeploy_error "Target directory does not exist: $path"
		appdeploy_log "Run 'appdeploy target install' first"
		return 1
	fi
	
	appdeploy_log "Target directory verified: $path"
	return 0
}

# Function: appdeploy_run PACKAGE_ARCHIVE [-c CONF_ARCHIVE] [-r RUN_PATH] [-d|--dry] [OVERLAY_PATHS...]
# CLI wrapper for running packages. Creates temporary target and calls appdeploy_package_run().
#
# Arguments:
#   PACKAGE_ARCHIVE  Path to the package archive file
#   -c CONF_ARCHIVE  Optional configuration archive
#   -r RUN_PATH      Optional run path (defaults to temporary directory)
#   -d, --dry        Dry run mode - set up without executing env.sh or run.sh
#   OVERLAY_PATHS    Optional overlay paths to symlink
#
# Returns: Exit status of the executed application
function appdeploy_run() {
	local package_archive=""
	local conf_archive=""
	local run_path=""
	local dry_run="false"
	local overlay_paths=()
	
	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-c|--config)
				if [[ $# -lt 2 ]]; then
					appdeploy_error "Missing argument for -c/--config"
					return 1
				fi
				conf_archive="$2"
				shift 2
			;;
			-r|--run)
				if [[ $# -lt 2 ]]; then
					appdeploy_error "Missing argument for -r/--run"
					return 1
				fi
				run_path="$2"
				shift 2
			;;
			-d|--dry)
				dry_run="true"
				shift
			;;
			-*)
				appdeploy_error "Unknown option: $1"
				return 1
			;;
			*)
				if [[ -z "$package_archive" ]]; then
					package_archive="$1"
				else
					overlay_paths+=("$1")
				fi
				shift
			;;
		esac
	done
	
	# Validate required argument
	if [[ -z "$package_archive" ]]; then
		appdeploy_error "Missing required argument: PACKAGE_ARCHIVE"
		return 1
	fi
	
	# Create temporary run directory if not provided
	if [[ -z "$run_path" ]]; then
		# Create temporary directory in current working directory
		# Use absolute path to ensure proper validation
		run_path=$(mktemp -d "$(pwd)/appdeploy.run.XXXX") || {
			appdeploy_error "Failed to create temporary run directory"
			return 1
		}
		appdeploy_log "Created temporary run directory: $run_path"
		# Set cleanup trap for temporary directory
		# Use a simple approach that doesn't rely on function scope
		APPDEPLOY_RUN_TEMP_DIR="$run_path"
		trap '[[ -n "$APPDEPLOY_RUN_TEMP_DIR" && -d "$APPDEPLOY_RUN_TEMP_DIR" ]] && { appdeploy_log "Cleaning up temporary run directory: $APPDEPLOY_RUN_TEMP_DIR"; find "$APPDEPLOY_RUN_TEMP_DIR" -type l -delete 2>/dev/null || true; rm -rf "$APPDEPLOY_RUN_TEMP_DIR" 2>/dev/null || true; }' EXIT INT TERM
	else
		# For user-provided run path, just ensure it exists
		if [[ ! -d "$run_path" ]]; then
			mkdir -p "$run_path" || {
				appdeploy_error "Failed to create run directory: $run_path"
				return 1
			}
		fi
	fi
	
	# Set up target in appdeploy format
	local target=":$run_path"
	
	# Call the core package run function
	appdeploy_package_run "$target" "$package_archive" "$conf_archive" "$dry_run" "${overlay_paths[@]}"
	
	# Return exit status from package execution
	return $?
}

# ----------------------------------------------------------------------------
#
# SERVICE MANAGEMENT
#
# ----------------------------------------------------------------------------

# Function: appdeploy_service_resolve_version TARGET PACKAGE [VERSION]
# Resolves version using priority: active > last-active > latest
# Returns the resolved version string, or empty if no version found
function appdeploy_service_resolve_version() {
	local target="$1"
	local package="$2"
	local version="${3:-}"
	
	# If version specified, return it
	if [[ -n "$version" ]]; then
		printf '%s' "$version"
		return 0
	fi
	
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local escaped_path escaped_package
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	escaped_package=$(appdeploy_escape_single_quotes "$package")
	
	# Try active version
	local active
	active=$(appdeploy_cmd_run "$target" "cat '${escaped_path}/${escaped_package}/.active' 2>/dev/null" || true)
	if [[ -n "$active" ]]; then
		printf '%s' "$active"
		return 0
	fi
	
	# Try last-active version
	local last_active
	last_active=$(appdeploy_cmd_run "$target" "cat '${escaped_path}/${escaped_package}/.last-active' 2>/dev/null" || true)
	if [[ -n "$last_active" ]]; then
		printf '%s' "$last_active"
		return 0
	fi
	
	# Fall back to latest installed version
	local dist_dir="$path/$package/dist"
	local escaped_dist_dir
	escaped_dist_dir=$(appdeploy_escape_single_quotes "$dist_dir")
	
	local installed_versions
	installed_versions=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_dist_dir}' 2>/dev/null | grep -E '^[0-9a-zA-Z]' || true")
	
	if [[ -n "$installed_versions" ]]; then
		local version_list=()
		readarray -t version_list <<< "$installed_versions"
		local latest
		latest=$(appdeploy_version_latest "${version_list[@]}")
		if [[ -n "$latest" ]]; then
			printf '%s' "$latest"
			return 0
		fi
	fi
	
	# Fall back to latest uploaded package
	local pkg_dir="$path/$package/packages"
	local escaped_pkg_dir
	escaped_pkg_dir=$(appdeploy_escape_single_quotes "$pkg_dir")
	
	local pkg_versions
	pkg_versions=$(appdeploy_cmd_run "$target" "ls -1 '${escaped_pkg_dir}' 2>/dev/null | grep -E '^${escaped_package}-[0-9].*\\.tar\\.(gz|bz2|xz)\$' | sed -E 's/^${escaped_package}-//;s/\\.tar\\.(gz|bz2|xz)\$//' || true")
	
	if [[ -n "$pkg_versions" ]]; then
		local version_list=()
		readarray -t version_list <<< "$pkg_versions"
		local latest
		latest=$(appdeploy_version_latest "${version_list[@]}")
		if [[ -n "$latest" ]]; then
			printf '%s' "$latest"
			return 0
		fi
	fi
	
	# No version found
	return 1
}

# Function: appdeploy_service_start TARGET PACKAGE[:VERSION]
# Starts the service daemon, auto-activating if needed
function appdeploy_service_start() {
	local target="$1"
	local spec="$2"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	
	# Resolve version
	version=$(appdeploy_service_resolve_version "$target" "$name" "$version")
	if [[ -z "$version" ]]; then
		appdeploy_error "No version found for $name on $target"
		appdeploy_log "Upload a package first with: appdeploy upload PACKAGE $target"
		return 1
	fi
	
	# Validate resolved version
	if ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	appdeploy_program "Start service $name:$version"
	
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local escaped_path escaped_name escaped_version
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	escaped_name=$(appdeploy_escape_single_quotes "$name")
	escaped_version=$(appdeploy_escape_single_quotes "$version")
	
	# Ensure runner is deployed
	appdeploy_step "Ensuring runner is deployed"
	appdeploy_runner_ensure "$target"
	
	# Check if activated, auto-activate if needed
	local active
	active=$(appdeploy_cmd_run "$target" "cat '${escaped_path}/${escaped_name}/.active' 2>/dev/null" || true)
	
	if [[ -z "$active" || "$active" != "$version" ]]; then
		appdeploy_step "Auto-activating $name:$version"
		if ! appdeploy_package_activate "$target" "$name:$version"; then
			appdeploy_step_fail "Failed to activate package"
			appdeploy_program_fail "Start service $name:$version"
			return 1
		fi
	fi
	
	# Create logs directory
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_path}/${escaped_name}/var/logs'"
	
	# Invoke runner start
	appdeploy_step "Starting service"
	if ! appdeploy_runner_invoke "$target" "$name" "start"; then
		appdeploy_step_fail "Failed to start service"
		appdeploy_program_fail "Start service $name:$version"
		return 1
	fi
	
	appdeploy_step_ok "Service started"
	appdeploy_program_ok "Start service $name:$version"
	return 0
}

# Function: appdeploy_service_stop TARGET PACKAGE[:VERSION]
# Stops the service daemon (does not deactivate)
function appdeploy_service_stop() {
	local target="$1"
	local spec="$2"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	
	# Resolve version (for logging, stop works on any running instance)
	version=$(appdeploy_service_resolve_version "$target" "$name" "$version")
	if [[ -z "$version" ]]; then
		version="(unknown)"
	fi
	
	appdeploy_program "Stop service $name:$version"
	
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local escaped_path escaped_name
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	escaped_name=$(appdeploy_escape_single_quotes "$name")
	
	# Check if runner exists
	if ! appdeploy_cmd_run "$target" "test -x '${escaped_path}/appdeploy.runner.sh'" 2>/dev/null; then
		appdeploy_info "Runner not deployed, service likely not running"
		appdeploy_program_ok "Stop service $name:$version"
		return 0
	fi
	
	# Invoke runner stop
	appdeploy_step "Stopping service"
	if ! appdeploy_runner_invoke "$target" "$name" "stop"; then
		appdeploy_step_fail "Failed to stop service"
		appdeploy_program_fail "Stop service $name:$version"
		return 1
	fi
	
	appdeploy_step_ok "Service stopped"
	appdeploy_program_ok "Stop service $name:$version"
	return 0
}

# Function: appdeploy_service_restart TARGET PACKAGE[:VERSION]
# Restarts the service (stop + start)
function appdeploy_service_restart() {
	local target="$1"
	local spec="$2"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	
	# Resolve version
	version=$(appdeploy_service_resolve_version "$target" "$name" "$version")
	if [[ -z "$version" ]]; then
		appdeploy_error "No version found for $name on $target"
		return 1
	fi
	
	appdeploy_program "Restart service $name:$version"
	
	# Stop (ignore errors - might not be running)
	appdeploy_step "Stopping service"
	appdeploy_service_stop "$target" "$name:$version" 2>/dev/null || true
	
	# Brief pause
	sleep 2
	
	# Start
	appdeploy_step "Starting service"
	if ! appdeploy_service_start "$target" "$name:$version"; then
		appdeploy_step_fail "Failed to start service"
		appdeploy_program_fail "Restart service $name:$version"
		return 1
	fi
	
	appdeploy_program_ok "Restart service $name:$version"
	return 0
}

# Function: appdeploy_service_status TARGET PACKAGE[:VERSION]
# Shows the service status (running/stopped/inactive)
function appdeploy_service_status() {
	local target="$1"
	local spec="$2"
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local escaped_path escaped_name
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	escaped_name=$(appdeploy_escape_single_quotes "$name")
	
	# Check if package directory exists
	if ! appdeploy_cmd_run "$target" "test -d '${escaped_path}/${escaped_name}'" 2>/dev/null; then
		appdeploy_info "Package $name not found on $target"
		return 1
	fi
	
	# Get active version
	local active
	active=$(appdeploy_cmd_run "$target" "cat '${escaped_path}/${escaped_name}/.active' 2>/dev/null" || true)
	
	if [[ -z "$active" ]]; then
		printf '%s%s%s: %sinactive%s (not activated)\n' "$BOLD" "$name" "$RESET" "$YELLOW" "$RESET"
		return 0
	fi
	
	# If specific version requested, check it matches
	if [[ -n "$version" && "$version" != "$active" ]]; then
		printf '%s%s:%s%s: %sinactive%s (active version is %s)\n' "$BOLD" "$name" "$version" "$RESET" "$YELLOW" "$RESET" "$active"
		return 0
	fi
	
	# Check if runner exists and get status
	if ! appdeploy_cmd_run "$target" "test -x '${escaped_path}/appdeploy.runner.sh'" 2>/dev/null; then
		printf '%s%s:%s%s: %sstopped%s (runner not deployed)\n' "$BOLD" "$name" "$active" "$RESET" "$YELLOW" "$RESET"
		return 0
	fi
	
	# Invoke runner status
	local status_output
	status_output=$(appdeploy_runner_invoke "$target" "$name" "status" 2>&1) || true
	
	# Parse status output to determine if running
	if echo "$status_output" | grep -qiE '(running|active)'; then
		printf '%s%s:%s%s: %srunning%s\n' "$BOLD" "$name" "$active" "$RESET" "$GREEN" "$RESET"
	else
		printf '%s%s:%s%s: %sstopped%s\n' "$BOLD" "$name" "$active" "$RESET" "$YELLOW" "$RESET"
	fi
	
	return 0
}

# Function: appdeploy_service_logs TARGET PACKAGE[:VERSION] [OPTIONS]
# Shows service logs (-f to follow)
function appdeploy_service_logs() {
	local target="$1"
	local spec="$2"
	shift 2
	local follow=""
	
	# Parse options
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-f|--follow)
				follow="-f"
				shift
				;;
			*)
				appdeploy_warn "Unknown option: $1"
				shift
				;;
		esac
	done
	
	local name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	
	local path
	path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local escaped_path escaped_name
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	escaped_name=$(appdeploy_escape_single_quotes "$name")
	
	# Check if runner exists
	if ! appdeploy_cmd_run "$target" "test -x '${escaped_path}/appdeploy.runner.sh'" 2>/dev/null; then
		appdeploy_warn "Runner not deployed, trying direct log access"
		# Fall back to direct log file access
		local log_dir="$path/$name/var/logs"
		local escaped_log_dir
		escaped_log_dir=$(appdeploy_escape_single_quotes "$log_dir")
		
		if [[ -n "$follow" ]]; then
			appdeploy_cmd_run "$target" "tail -f '${escaped_log_dir}/current.log' 2>/dev/null || tail -f \$(ls -t '${escaped_log_dir}'/*.log 2>/dev/null | head -1)"
		else
			appdeploy_cmd_run "$target" "tail -50 '${escaped_log_dir}/current.log' 2>/dev/null || tail -50 \$(ls -t '${escaped_log_dir}'/*.log 2>/dev/null | head -1)"
		fi
		return $?
	fi
	
	# Invoke runner logs
	appdeploy_runner_invoke "$target" "$name" "logs" "$follow"
}

# ----------------------------------------------------------------------------
#
# HELP SYSTEM
#
# ----------------------------------------------------------------------------

# Function: appdeploy_show_help
# Displays comprehensive help for the CLI
function appdeploy_show_help() {
	local show_all="${1:-false}"
	
	echo "${BOLD}AppDeploy - Application Deployment Manager${RESET}"
	echo "Version: $APPDEPLOY_VERSION"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy [GLOBAL_OPTIONS] COMMAND [ARGS...]"
	echo ""
	echo "${BOLD}Global Options:${RESET}"
	printf "  %-20s %s\n" "--help, -h" "Show this help message"
	printf "  %-20s %s\n" "--version, -v" "Show version information"
	printf "  %-20s %s\n" "--debug" "Enable debug output"
	echo ""
	echo "${BOLD}Commands:${RESET}"
	printf "  %-20s %s\n" "run" "Run a package archive locally"
	printf "  %-20s %s\n" "package" "Create a package archive"
	printf "  %-20s %s\n" "deploy" "Deploy package (full lifecycle)"
	printf "  %-20s %s\n" "prepare" "Prepare target for deployment"
	printf "  %-20s %s\n" "check" "Verify target directory exists"
	printf "  %-20s %s\n" "upload" "Upload package to target"
	printf "  %-20s %s\n" "install" "Install (unpack) package on target"
	printf "  %-20s %s\n" "activate" "Activate package on target"
	printf "  %-20s %s\n" "deactivate" "Deactivate package on target"
	printf "  %-20s %s\n" "uninstall" "Uninstall package (keep archive)"
	printf "  %-20s %s\n" "remove" "Remove package completely"
	printf "  %-20s %s\n" "list" "List packages on target"
	printf "  %-20s %s\n" "configure" "Deploy configuration to package"
	echo ""
	echo "${BOLD}Service Management:${RESET}"
	printf "  %-20s %s\n" "start" "Start service daemon"
	printf "  %-20s %s\n" "stop" "Stop service daemon"
	printf "  %-20s %s\n" "restart" "Restart service daemon"
	printf "  %-20s %s\n" "status" "Show service status"
	printf "  %-20s %s\n" "logs" "Show/follow service logs"
	echo ""
	echo "${BOLD}Use 'appdeploy COMMAND --help' for more information on a specific command.${RESET}"
	
	if [[ "$show_all" == "true" ]]; then
		echo ""
		echo "${BOLD}Examples:${RESET}"
		echo "  appdeploy run myapp-1.0.0.tar.gz"
		echo "  appdeploy package /path/to/app v1.0.0"
		echo "  appdeploy deploy myapp-1.0.0.tar.gz user@host:/opt/apps"
		echo "  appdeploy list user@host:/opt/apps"
		echo "  appdeploy activate myapp:1.0.0 user@host:/opt/apps"
	fi
}

# Function: appdeploy_terraform_apply TARGET
# Applies terraform configuration to ensure target is properly configured
# This is a basic implementation that can be enhanced with actual terraform integration
function appdeploy_terraform_apply() {
	local target="$1"
	
	# Extract target host and path
	local target_host
	local target_path
	target_host=$(appdeploy_target_host "$target")
	target_path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$target_path"; then
		appdeploy_error "Invalid target path: $target_path"
		return 1
	fi
	
	appdeploy_log "Ensuring target '$target' is properly configured"
	
	if [[ -n "$target_host" ]] && [[ "$target_host" != "localhost" ]] && [[ "$target_host" != "127.0.0.1" ]]; then
		# Remote target
		local target_user
		target_user=$(appdeploy_target_user "$target")
		local ssh_target="${target_host}"
		if [[ -n "$target_user" ]]; then
			ssh_target="${target_user}@${target_host}"
		fi
		
		# Escape path for shell
		local escaped_path
		escaped_path=$(appdeploy_escape_single_quotes "$target_path")
		
		# For remote targets, ensure the directory exists using direct SSH
		# (can't use appdeploy_cmd_run because that requires the directory to exist)
		appdeploy_log "Setting up remote target directory structure"
		if ! ssh -o BatchMode=yes -- "$ssh_target" "mkdir -p '${escaped_path}' && chmod 755 '${escaped_path}'" 2>&1; then
			appdeploy_error "Failed to create remote target directory: $target_path"
			return 1
		fi
	else
		# Local target (including :path format)
		appdeploy_log "Setting up local target directory structure"
		if ! mkdir -p "$target_path" || ! chmod 755 "$target_path"; then
			appdeploy_error "Failed to create local target directory: $target_path"
			return 1
		fi
	fi
	
	# Verify target is now accessible
	if ! appdeploy_target_check "$target"; then
		appdeploy_error "Target '$target' is not accessible after setup"
		return 1
	fi
	
	appdeploy_log "Target '$target' is ready for deployment"
	return 0
}

# Function: appdeploy_prepare [TARGET]
# Prepares the target for deployment:
# - Creates target directory structure if it doesn't exist
# - Displays list of installed packages and versions, highlighting active ones
function appdeploy_prepare() {
	local target="${1:-}"
	
	# Default target to local APPDEPLOY_DEFAULT_TARGET
	if [[ -z "$target" ]]; then
		target=":$APPDEPLOY_DEFAULT_TARGET"
	fi
	
	appdeploy_log "Preparing target: $target"
	
	# Step 1: Terraform/setup target directory
	if ! appdeploy_terraform_apply "$target"; then
		appdeploy_error "Failed to prepare target '$target'"
		return 1
	fi
	
	# Step 2: Display installed packages
	appdeploy_log ""
	appdeploy_log "${BOLD}Installed packages on $target:${RESET}"
	appdeploy_package_list "$target"
	
	return 0
}

# Function: appdeploy_deploy [-p|--package NAME[-VERSION]] PACKAGE_PATH [CONF_ARCHIVE] [TARGET]
# Deploys a package to the specified target, handling the full deployment lifecycle
function appdeploy_deploy() {
	local package_name_override=""
	local package_path=""
	local conf_archive=""
	local target=""
	
	# Parse arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-p|--package)
				if [[ $# -lt 2 ]]; then
					appdeploy_error "Missing argument for -p/--package"
					return 1
				fi
				package_name_override="$2"
				shift 2
				;;
			-*)
				appdeploy_error "Unknown option: $1"
				return 1
				;;
			*)
				# Positional arguments: PACKAGE_PATH [CONF_ARCHIVE] [TARGET]
				if [[ -z "$package_path" ]]; then
					package_path="$1"
				elif [[ -z "$conf_archive" ]] && [[ -z "$target" ]]; then
					# Could be CONF_ARCHIVE or TARGET
					# If it's an existing file, treat as conf_archive
					# Otherwise, treat as target
					if [[ -f "$1" ]]; then
						conf_archive="$1"
					else
						target="$1"
					fi
				elif [[ -z "$target" ]]; then
					target="$1"
				else
					appdeploy_error "Too many arguments"
					return 1
				fi
				shift
				;;
		esac
	done
	
	# Validate package_path is provided
	if [[ -z "$package_path" ]]; then
		appdeploy_error "Usage: appdeploy deploy [-p|--package NAME[-VERSION]] PACKAGE_PATH [CONF_ARCHIVE] [TARGET]"
		return 1
	fi
	
	# Default target to local APPDEPLOY_DEFAULT_TARGET
	if [[ -z "$target" ]]; then
		target=":$APPDEPLOY_DEFAULT_TARGET"
	fi
	
	# Validate package path
	if [[ ! -e "$package_path" ]]; then
		appdeploy_error "Package path '$package_path' does not exist"
		return 1
	fi
	
	# Validate configuration archive if provided
	if [[ -n "$conf_archive" ]] && [[ ! -f "$conf_archive" ]]; then
		appdeploy_error "Configuration archive '$conf_archive' does not exist"
		return 1
	fi
	
	appdeploy_program "Deploy to $target"
	
	# Step 1: Terraform target configuration
	appdeploy_step "#1/8 Configuring target with terraform"
	if ! appdeploy_terraform_apply "$target"; then
		appdeploy_step_fail "#1/8 Failed to configure target with terraform"
		appdeploy_program_fail "Deploy to $target"
		return 1
	fi
	
	# Step 2: Create package if it's a directory
	local package_archive="$package_path"
	local is_directory=false
	
	if [[ -d "$package_path" ]]; then
		appdeploy_step "#2/8 Creating package archive"
		is_directory=true
		
		# Determine package name and version
		local package_name=""
		local package_version=""
		
		if [[ -n "$package_name_override" ]]; then
			# Parse NAME[-VERSION] from override
			if [[ "$package_name_override" == *-* ]]; then
				# Contains dash - could be name-version or just a name with dashes
				# Try to extract version (last part after dash if it looks like a version)
				local potential_version="${package_name_override##*-}"
				if [[ "$potential_version" =~ ^[0-9] ]] || [[ "$potential_version" =~ ^v[0-9] ]]; then
					package_name="${package_name_override%-*}"
					package_version="$potential_version"
				else
					package_name="$package_name_override"
				fi
			else
				package_name="$package_name_override"
			fi
		else
			# Infer package name from directory
			package_name=$(basename "$package_path")
		fi
		
		# Infer version if not set
		if [[ -z "$package_version" ]]; then
			package_version=$(appdeploy_version_infer "$package_path")
			if [[ -z "$package_version" ]]; then
				package_version=$(date +"%Y%m%d-%H%M%S")
			fi
		fi
		
		local temp_archive
		temp_archive=$(mktemp -t "${package_name}-${package_version}.XXXXXX.tar.gz")
		
		if ! appdeploy_package_create "$package_path" "$temp_archive" "true"; then
			appdeploy_step_fail "#2/8 Failed to create package archive"
			appdeploy_program_fail "Deploy to $target"
			return 1
		fi
		
		package_archive="$temp_archive"
	fi
	
	# Extract package name and version from archive
	local package_name
	local package_version
	package_name=$(appdeploy_package_name "$(basename "$package_archive")")
	package_version=$(appdeploy_package_version "$(basename "$package_archive")")
	
	if [[ -z "$package_name" ]] || [[ -z "$package_version" ]]; then
		appdeploy_step_fail "Failed to extract package name and version from archive"
		appdeploy_program_fail "Deploy to $target"
		if [[ "$is_directory" == true ]]; then
			rm -f "$package_archive"
		fi
		return 1
	fi
	
	appdeploy_info "Deploying ${package_name}:${package_version}"
	
	# Step 3: Upload package
	appdeploy_step "#3/8 Uploading package to target"
	if ! appdeploy_package_upload "$target" "$package_archive"; then
		appdeploy_step_fail "#3/8 Failed to upload package to target"
		appdeploy_program_fail "Deploy to $target"
		if [[ "$is_directory" == true ]]; then
			rm -f "$package_archive"
		fi
		return 1
	fi
	
	# Clean up temporary archive if we created it
	if [[ "$is_directory" == true ]]; then
		rm -f "$package_archive"
	fi
	
	# Step 4: Install package
	appdeploy_step "#4/8 Installing package on target"
	if ! appdeploy_package_install "$target" "${package_name}:${package_version}"; then
		appdeploy_step_fail "#4/8 Failed to install package on target"
		appdeploy_program_fail "Deploy to $target"
		return 1
	fi
	
	# Step 5: Deactivate current package if any
	appdeploy_step "#5/8 Deactivating current package"
	local current_package
	current_package=$(appdeploy_package_current "$target" "$package_name")
	
	if [[ -n "$current_package" ]]; then
		appdeploy_log "Deactivating current package: $current_package"
		if ! appdeploy_package_deactivate "$target" "$package_name"; then
			appdeploy_step_fail "#5/8 Failed to deactivate current package"
			appdeploy_program_fail "Deploy to $target"
			return 1
		fi
	else
		appdeploy_info "No current package to deactivate"
	fi
	
	# Step 6: Activate new package
	appdeploy_step "#6/8 Activating new package"
	if ! appdeploy_package_activate "$target" "${package_name}:${package_version}"; then
		appdeploy_step_fail "#6/8 Failed to activate new package"
		appdeploy_program_fail "Deploy to $target"
		return 1
	fi
	
	# Step 7: Deploy configuration if provided
	if [[ -n "$conf_archive" ]]; then
		appdeploy_step "#7/8 Deploying configuration"
		if ! appdeploy_package_deploy_conf "$target" "${package_name}:${package_version}" "$conf_archive"; then
			appdeploy_step_fail "#7/8 Failed to deploy configuration"
			appdeploy_program_fail "Deploy to $target"
			return 1
		fi
	else
		appdeploy_step "#7/8 No configuration to deploy"
	fi
	
	# Step 8: Ready to start
	appdeploy_step "#8/8 Package ready"
	appdeploy_result "Package ${package_name}:${package_version} is ready on ${target}"
	appdeploy_result "To start: appdeploy run ${package_name}-${package_version}.tar.gz"
	
	appdeploy_program_ok "Deploy ${package_name}:${package_version} to $target"
	
	return 0
}

# ----------------------------------------------------------------------------
#
# CLI WRAPPER FUNCTIONS
# 
# These functions provide the new flat CLI interface with TARGET as optional
# last argument. They parse args and call the underlying appdeploy_package_*
# and appdeploy_target_* functions.
#
# ----------------------------------------------------------------------------

# Function: appdeploy_check [TARGET]
# Verify target directory exists (wrapper for appdeploy_target_check)
function appdeploy_check() {
	local target="${1:-$(appdeploy_default_target)}"
	appdeploy_target_check "$target"
}

# Function: appdeploy_upload PACKAGE [NAME] [VERSION] [TARGET]
# Upload a package archive to target
function appdeploy_upload() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy upload PACKAGE [NAME] [VERSION] [TARGET]"
		return 1
	fi
	
	local package="$1"
	shift
	
	local name=""
	local version=""
	local target=""
	
	# Parse remaining args - last one might be TARGET
	local args=("$@")
	local arg_count=${#args[@]}
	
	if [[ $arg_count -gt 0 ]]; then
		local last_arg="${args[$((arg_count-1))]}"
		if appdeploy_is_target "$last_arg"; then
			target="$last_arg"
			unset 'args[$((arg_count-1))]'
		fi
	fi
	
	# Remaining args are NAME and VERSION
	[[ ${#args[@]} -ge 1 ]] && name="${args[0]}"
	[[ ${#args[@]} -ge 2 ]] && version="${args[1]}"
	
	# Default target
	[[ -z "$target" ]] && target="$(appdeploy_default_target)"
	
	appdeploy_package_upload "$target" "$package" "$name" "$version"
}

# Function: appdeploy_install PACKAGE[:VERSION] [TARGET]
# Install (unpack) an uploaded package on target
function appdeploy_install() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy install PACKAGE[:VERSION] [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local target="${2:-$(appdeploy_default_target)}"
	
	# Check if second arg looks like target
	if [[ $# -eq 2 ]] && ! appdeploy_is_target "$2"; then
		# Second arg doesn't look like target, maybe user error
		appdeploy_warn "Second argument '$2' doesn't look like a target, treating as target anyway"
	fi
	
	appdeploy_package_install "$target" "$spec"
}

# Function: appdeploy_activate PACKAGE[:VERSION] [TARGET]
# Activate a package (create symlinks in run/ from dist/ and var/)
function appdeploy_activate() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy activate PACKAGE[:VERSION] [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local target="${2:-$(appdeploy_default_target)}"
	
	appdeploy_package_activate "$target" "$spec"
}

# Function: appdeploy_deactivate PACKAGE[:VERSION] [TARGET]
# Deactivate a package (remove symlinks from run/)
function appdeploy_deactivate() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy deactivate PACKAGE[:VERSION] [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local target="${2:-$(appdeploy_default_target)}"
	
	appdeploy_package_deactivate "$target" "$spec"
}

# Function: appdeploy_uninstall PACKAGE[:VERSION] [TARGET]
# Uninstall a package (remove dist/, keep archive)
function appdeploy_uninstall() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy uninstall PACKAGE[:VERSION] [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local target="${2:-$(appdeploy_default_target)}"
	
	appdeploy_package_uninstall "$target" "$spec"
}

# Function: appdeploy_remove PACKAGE[:VERSION] [TARGET]
# Remove a package completely (uninstall + delete archive)
function appdeploy_remove() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy remove PACKAGE[:VERSION] [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local target="${2:-$(appdeploy_default_target)}"
	
	appdeploy_package_remove "$target" "$spec"
}

# Function: appdeploy_list [PACKAGE[:VERSION]] [TARGET]
# List packages on target with status
# Note: With 1 arg, assumes TARGET (not PACKAGE)
function appdeploy_list() {
	local spec=""
	local target=""
	
	if [[ $# -eq 0 ]]; then
		target="$(appdeploy_default_target)"
	elif [[ $# -eq 1 ]]; then
		# Single arg = TARGET
		target="$1"
	else
		# Two args = PACKAGE TARGET
		spec="$1"
		target="$2"
	fi
	
	[[ -z "$target" ]] && target="$(appdeploy_default_target)"
	
	appdeploy_package_list "$target" "$spec"
}

# Function: appdeploy_configure PACKAGE[:VERSION] CONF_ARCHIVE [TARGET]
# Deploy configuration archive to package var/ directory
function appdeploy_configure() {
	if [[ $# -lt 2 ]]; then
		appdeploy_error "Usage: appdeploy configure PACKAGE[:VERSION] CONF_ARCHIVE [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local conf_archive="$2"
	local target="${3:-$(appdeploy_default_target)}"
	
	appdeploy_package_deploy_conf "$target" "$spec" "$conf_archive"
}

# Function: appdeploy_start PACKAGE[:VERSION] [TARGET]
# Start service daemon (auto-activates if needed)
function appdeploy_start() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy start PACKAGE[:VERSION] [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local target="${2:-$(appdeploy_default_target)}"
	
	appdeploy_service_start "$target" "$spec"
}

# Function: appdeploy_stop PACKAGE[:VERSION] [TARGET]
# Stop service daemon
function appdeploy_stop() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy stop PACKAGE[:VERSION] [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local target="${2:-$(appdeploy_default_target)}"
	
	appdeploy_service_stop "$target" "$spec"
}

# Function: appdeploy_restart PACKAGE[:VERSION] [TARGET]
# Restart service daemon
function appdeploy_restart() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy restart PACKAGE[:VERSION] [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local target="${2:-$(appdeploy_default_target)}"
	
	appdeploy_service_restart "$target" "$spec"
}

# Function: appdeploy_status PACKAGE[:VERSION] [TARGET]
# Show service status
function appdeploy_status() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy status PACKAGE[:VERSION] [TARGET]"
		return 1
	fi
	
	local spec="$1"
	local target="${2:-$(appdeploy_default_target)}"
	
	appdeploy_service_status "$target" "$spec"
}

# Function: appdeploy_logs PACKAGE[:VERSION] [TARGET] [-f]
# Show service logs
function appdeploy_logs() {
	if [[ $# -lt 1 ]]; then
		appdeploy_error "Usage: appdeploy logs PACKAGE[:VERSION] [TARGET] [-f]"
		return 1
	fi
	
	local spec="$1"
	shift
	local target=""
	local follow_args=()
	
	# Parse remaining arguments
	while [[ $# -gt 0 ]]; do
		case "$1" in
			-f|--follow)
				follow_args+=("-f")
				shift
				;;
			*)
				if [[ -z "$target" ]]; then
					target="$1"
				fi
				shift
				;;
		esac
	done
	
	[[ -z "$target" ]] && target="$(appdeploy_default_target)"
	
	appdeploy_service_logs "$target" "$spec" "${follow_args[@]}"
}

# ----------------------------------------------------------------------------
#
# HELP SYSTEM
#
# ----------------------------------------------------------------------------

# Function: appdeploy_help_run
# Shows help for the 'run' command
function appdeploy_help_run() {
	echo "${BOLD}appdeploy run - Run a package archive${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy run PACKAGE_ARCHIVE [OPTIONS] [OVERLAY_PATHS...]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE_ARCHIVE" "Path to the package archive file"
	echo "  OVERLAY_PATHS     Optional overlay paths to symlink"
	echo ""
	echo "${BOLD}Options:${RESET}"
	printf "  %-20s %s\n" "-c, --config" "Configuration archive to deploy"
	printf "  %-20s %s\n" "-r, --run" "Run path (defaults to temporary directory)"
	printf "  %-20s %s\n" "-d, --dry" "Dry run mode (setup without execution)"
	printf "  %-20s %s\n" "--help" "Show this help message"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy run myapp-1.0.0.tar.gz"
	echo "  appdeploy run myapp-1.0.0.tar.gz -c config.tar.gz"
	echo "  appdeploy run myapp-1.0.0.tar.gz -r /tmp/myapp --dry"
}

# Function: appdeploy_help_package
# Shows help for the 'package' command
function appdeploy_help_package() {
	echo "${BOLD}appdeploy package - Create a package archive${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy package PATH [VERSION|OUTPUT] [-f|--force]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PATH" "Source directory to package"
	printf "  %-20s %s\n" "VERSION" "Version string (e.g., 1.0.0)"
	printf "  %-20s %s\n" "OUTPUT" "Output path (e.g., myapp-1.0.0.tar.gz)"
	echo ""
	echo "${BOLD}Options:${RESET}"
	printf "  %-20s %s\n" "-f, --force" "Overwrite existing output file"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy package /path/to/app v1.0.0"
	echo "  appdeploy package /path/to/app myapp-1.0.0.tar.gz"
	echo "  appdeploy package /path/to/app -f"
}

# Function: appdeploy_help_check
# Shows help for the 'check' command
function appdeploy_help_check() {
	echo "${BOLD}appdeploy check - Verify target directory exists${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy check [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy check"
	echo "  appdeploy check user@host:/opt/apps"
	echo "  appdeploy check :/opt/apps"
}

# Function: appdeploy_help_upload
# Shows help for the 'upload' command
function appdeploy_help_upload() {
	echo "${BOLD}appdeploy upload - Upload package to target${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy upload PACKAGE [NAME] [VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Path to package archive file"
	printf "  %-20s %s\n" "NAME" "Optional package name override"
	printf "  %-20s %s\n" "VERSION" "Optional version override"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy upload myapp-1.0.0.tar.gz"
	echo "  appdeploy upload myapp-1.0.0.tar.gz user@host:/opt/apps"
}

# Function: appdeploy_help_install
# Shows help for the 'install' command
function appdeploy_help_install() {
	echo "${BOLD}appdeploy install - Install (unpack) package on target${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy install PACKAGE[:VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version (default: latest)"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy install myapp"
	echo "  appdeploy install myapp:1.0.0"
	echo "  appdeploy install myapp user@host:/opt/apps"
}

# Function: appdeploy_help_activate
# Shows help for the 'activate' command
function appdeploy_help_activate() {
	echo "${BOLD}appdeploy activate - Activate package on target${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy activate PACKAGE[:VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version (default: latest)"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy activate myapp"
	echo "  appdeploy activate myapp:1.0.0"
	echo "  appdeploy activate myapp user@host:/opt/apps"
}

# Function: appdeploy_help_deactivate
# Shows help for the 'deactivate' command
function appdeploy_help_deactivate() {
	echo "${BOLD}appdeploy deactivate - Deactivate package on target${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy deactivate PACKAGE[:VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version (default: active)"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy deactivate myapp"
	echo "  appdeploy deactivate myapp:1.0.0"
}

# Function: appdeploy_help_uninstall
# Shows help for the 'uninstall' command
function appdeploy_help_uninstall() {
	echo "${BOLD}appdeploy uninstall - Uninstall package (keep archive)${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy uninstall PACKAGE[:VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version (default: all)"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy uninstall myapp"
	echo "  appdeploy uninstall myapp:1.0.0"
}

# Function: appdeploy_help_remove
# Shows help for the 'remove' command
function appdeploy_help_remove() {
	echo "${BOLD}appdeploy remove - Remove package completely${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy remove PACKAGE[:VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version (default: all)"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy remove myapp"
	echo "  appdeploy remove myapp:1.0.0"
}

# Function: appdeploy_help_list
# Shows help for the 'list' command
function appdeploy_help_list() {
	echo "${BOLD}appdeploy list - List packages on target${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy list [PACKAGE[:VERSION]] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Optional package name filter"
	printf "  %-20s %s\n" "VERSION" "Optional version filter"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Note:${RESET}"
	echo "  With one argument, it's treated as TARGET (not PACKAGE)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy list"
	echo "  appdeploy list user@host:/opt/apps"
	echo "  appdeploy list myapp user@host:/opt/apps"
}

# Function: appdeploy_help_configure
# Shows help for the 'configure' command
function appdeploy_help_configure() {
	echo "${BOLD}appdeploy configure - Deploy configuration to package${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy configure PACKAGE[:VERSION] CONF_ARCHIVE [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version"
	printf "  %-20s %s\n" "CONF_ARCHIVE" "Configuration archive file"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy configure myapp config.tar.gz"
	echo "  appdeploy configure myapp:1.0.0 config.tar.gz user@host:/opt/apps"
}

# Function: appdeploy_help_start
# Shows help for the 'start' command
function appdeploy_help_start() {
	echo "${BOLD}appdeploy start - Start service daemon${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy start PACKAGE[:VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Version (default: active or latest)"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Description:${RESET}"
	echo "  Starts the service daemon. Auto-activates if package is not active."
	echo "  Version resolution: active > last-active > latest"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy start myapp"
	echo "  appdeploy start myapp:1.0.0"
	echo "  appdeploy start myapp user@host:/opt/apps"
}

# Function: appdeploy_help_stop
# Shows help for the 'stop' command
function appdeploy_help_stop() {
	echo "${BOLD}appdeploy stop - Stop service daemon${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy stop PACKAGE[:VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Description:${RESET}"
	echo "  Stops the service daemon gracefully."
	echo "  Does NOT deactivate the package (symlinks remain)."
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy stop myapp"
	echo "  appdeploy stop myapp:1.0.0 user@host:/opt/apps"
}

# Function: appdeploy_help_restart
# Shows help for the 'restart' command
function appdeploy_help_restart() {
	echo "${BOLD}appdeploy restart - Restart service daemon${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy restart PACKAGE[:VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version (default: active)"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Description:${RESET}"
	echo "  Restarts the service (equivalent to stop + start)."
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy restart myapp"
	echo "  appdeploy restart myapp user@host:/opt/apps"
}

# Function: appdeploy_help_status
# Shows help for the 'status' command
function appdeploy_help_status() {
	echo "${BOLD}appdeploy status - Show service status${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy status PACKAGE[:VERSION] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Status Values:${RESET}"
	printf "  %-20s %s\n" "running" "Service is active and running (green)"
	printf "  %-20s %s\n" "stopped" "Package activated but service not running"
	printf "  %-20s %s\n" "inactive" "Package exists but not activated"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy status myapp"
	echo "  appdeploy status myapp:1.0.0 user@host:/opt/apps"
}

# Function: appdeploy_help_logs
# Shows help for the 'logs' command
function appdeploy_help_logs() {
	echo "${BOLD}appdeploy logs - Show service logs${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy logs PACKAGE[:VERSION] [TARGET] [-f]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE" "Package name"
	printf "  %-20s %s\n" "VERSION" "Optional version"
	printf "  %-20s %s\n" "TARGET" "Target (default: :$APPDEPLOY_TARGET)"
	echo ""
	echo "${BOLD}Options:${RESET}"
	printf "  %-20s %s\n" "-f, --follow" "Follow logs in real-time (like tail -f)"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy logs myapp"
	echo "  appdeploy logs myapp -f"
	echo "  appdeploy logs myapp user@host:/opt/apps -f"
}

# Function: appdeploy_help_prepare
# Shows help for the 'prepare' command
function appdeploy_help_prepare() {
	echo "${BOLD}appdeploy prepare - Prepare target for deployment${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy prepare [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "TARGET" "Target in format [user@]host[:path] (default: :$APPDEPLOY_DEFAULT_TARGET)"
	echo ""
	echo "${BOLD}Description:${RESET}"
	echo "  Prepares the target for deployment:"
	echo "  - Creates target directory structure if it doesn't exist"
	echo "  - Displays list of installed packages and versions"
	echo "  - Active packages are highlighted in green"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy prepare                           # Prepare local default target"
	echo "  appdeploy prepare agent@stage               # Prepare remote target with default path"
	echo "  appdeploy prepare user@host:/opt/apps       # Prepare remote target with custom path"
}

# Function: appdeploy_help_deploy
# Shows help for the 'deploy' command
function appdeploy_help_deploy() {
	echo "${BOLD}appdeploy deploy - Deploy a package to target${RESET}"
	echo ""
	echo "${BOLD}Usage:${RESET}"
	echo "  appdeploy deploy [-p|--package NAME[-VERSION]] PACKAGE_PATH [CONF_ARCHIVE] [TARGET]"
	echo ""
	echo "${BOLD}Arguments:${RESET}"
	printf "  %-20s %s\n" "PACKAGE_PATH" "Package directory or archive"
	printf "  %-20s %s\n" "CONF_ARCHIVE" "Optional configuration archive"
	printf "  %-20s %s\n" "TARGET" "Target in format [user@]host:path (default: :$APPDEPLOY_DEFAULT_TARGET)"
	echo ""
	echo "${BOLD}Options:${RESET}"
	printf "  %-20s %s\n" "-p, --package NAME" "Override package name (and optionally version with NAME-VERSION)"
	echo ""
	echo "${BOLD}Description:${RESET}"
	echo "  Deploys a package to the specified target, handling the full deployment lifecycle:"
	echo "  1. Terraforms target configuration"
	echo "  2. Creates package archive if directory"
	echo "  3. Uploads package to target"
	echo "  4. Installs package on target"
	echo "  5. Deactivates current package if any"
	echo "  6. Activates new package"
	echo "  7. Deploys configuration if provided"
	echo "  8. Starts the package"
	echo ""
	echo "${BOLD}Examples:${RESET}"
	echo "  appdeploy deploy myapp-1.0.0.tar.gz"
	echo "  appdeploy deploy myapp-1.0.0.tar.gz user@host:/opt/apps"
	echo "  appdeploy deploy /path/to/myapp config.tar.gz user@host:/opt/apps"
	echo "  appdeploy deploy -p myapp-2.0.0 /path/to/myapp"
}

# ----------------------------------------------------------------------------
#
# MAIN
#
# ----------------------------------------------------------------------------

function appdeploy_cli() {
	# Check if we have any arguments
	if [[ $# -eq 0 ]]; then
		# No arguments - show comprehensive help
		appdeploy_show_help "true"
		return 0
	fi
	
	# Handle global options before parsing subcommand
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--help|-h)
				appdeploy_show_help "true"
				return 0
				;;
			--version|-v)
				echo "appdeploy version $APPDEPLOY_VERSION"
				return 0
				;;
			--debug)
				DEBUG=1
				;;
			-*)
				# Unknown global option, let subcommand handle it
				break
				;;
			*)
				# Not an option, break to parse subcommand
				break
				;;
		esac
		shift
	done

	# Check if we have any arguments left after processing global options
	if [[ $# -eq 0 ]]; then
		# No arguments left - show comprehensive help
		appdeploy_show_help "true"
		return 0
	fi

	# Parse subcommand
	local subcommand="$1"
	shift

	# Handle help requests for specific subcommands
	if [[ "$subcommand" == "help" || "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
		local help_target="$subcommand"
		if [[ "$help_target" == "help" ]]; then
			# 'appdeploy help' - show general help
			appdeploy_show_help "true"
			return 0
		elif [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
			# 'appdeploy COMMAND --help' - show help for specific command
			shift
		fi
		
		# Show help for the specified command
		case "$help_target" in
			run)
				appdeploy_help_run
				;;
			package)
				appdeploy_help_package
				;;
			check)
				appdeploy_help_check
				;;
			prepare)
				appdeploy_help_prepare
				;;
			deploy)
				appdeploy_help_deploy
				;;
			upload)
				appdeploy_help_upload
				;;
			install)
				appdeploy_help_install
				;;
			activate)
				appdeploy_help_activate
				;;
			deactivate)
				appdeploy_help_deactivate
				;;
			uninstall)
				appdeploy_help_uninstall
				;;
			remove)
				appdeploy_help_remove
				;;
		list)
			appdeploy_help_list
			;;
		configure)
			appdeploy_help_configure
			;;
		start)
			appdeploy_help_start
			;;
		stop)
			appdeploy_help_stop
			;;
		restart)
			appdeploy_help_restart
			;;
		status)
			appdeploy_help_status
			;;
		logs)
			appdeploy_help_logs
			;;
		*)
				appdeploy_error "Unknown command: $help_target"
				appdeploy_error "Use 'appdeploy --help' for usage information"
				return 1
				;;
		esac
		return 0
	fi

	case "$subcommand" in
		run)
			appdeploy_run "$@"
		;;
		package)
			# appdeploy package PATH [VERSION|OUTPUT] [-f|--force]
			if [[ $# -eq 0 ]]; then
				appdeploy_help_package
				return 1
			fi
			appdeploy_package "$@"
		;;
		check)
			appdeploy_check "$@"
		;;
		prepare)
			appdeploy_prepare "$@"
		;;
		deploy)
			if [[ $# -lt 1 ]]; then
				appdeploy_help_deploy
				return 1
			fi
			appdeploy_deploy "$@"
		;;
		upload)
			appdeploy_upload "$@"
		;;
		install)
			appdeploy_install "$@"
		;;
		activate)
			appdeploy_activate "$@"
		;;
		deactivate)
			appdeploy_deactivate "$@"
		;;
		uninstall)
			appdeploy_uninstall "$@"
		;;
		remove)
			appdeploy_remove "$@"
		;;
		list)
			appdeploy_list "$@"
		;;
		configure)
			appdeploy_configure "$@"
		;;
		start)
			appdeploy_start "$@"
		;;
		stop)
			appdeploy_stop "$@"
		;;
		restart)
			appdeploy_restart "$@"
		;;
		status)
			appdeploy_status "$@"
		;;
		logs)
			appdeploy_logs "$@"
		;;
		--help|-h|help)
			appdeploy_show_help "true"
		;;
		--version|-v)
			echo "appdeploy version $APPDEPLOY_VERSION"
		;;
		*)
			appdeploy_error "Unknown command: $subcommand"
			appdeploy_error "Use 'appdeploy --help' for usage information"
			return 1
		;;
	esac
}

# Only run CLI if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	appdeploy_cli "$@"
fi

# EOF
