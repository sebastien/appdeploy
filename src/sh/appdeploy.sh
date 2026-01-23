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
# Validates that VERSION is a valid semver-like version string
# Returns 0 if valid, 1 if invalid
function appdeploy_validate_version() {
	local version="$1"
	if [[ -z "$version" ]]; then
		return 1
	fi
	# Only allow semver-like versions: digits, dots, dashes, alphanumeric suffixes
	if [[ ! "$version" =~ ^[0-9][0-9a-zA-Z._-]*$ ]]; then
		appdeploy_error "Invalid version: '$version' (must start with digit, contain only alphanumeric, dot, dash, underscore)"
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
# LOGGING
# ============================================================================

function appdeploy_log() {
	local prefix="_._"
	printf '%s %s\n' "$prefix" "$*"
}

function appdeploy_warn() {
	local prefix="-!-"
	printf '%s %s\n' "$prefix" "$*"
}

function appdeploy_error() {
	local prefix="~!~"
	printf '%s %s\n' "$prefix" "$*"
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================
function appdeploy_target_user() {
	[[ $1 =~ ^([^@:]+)(@.*)?$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

function appdeploy_target_host() {
	[[ $1 =~ ^([^@]*@)?([^:@]+)(:.*)?$ ]] && printf '%s\n' "${BASH_REMATCH[2]}"
}

function appdeploy_target_path() {
	[[ $1 =~ :(.*)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

function appdeploy_package_name() {
	[[ $1 =~ ^(.*)-[0-9].*\.tar\.(gz|bz2|xz)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

function appdeploy_package_version() { # $1 = filename
	[[ $1 =~ ^.*-([0-9][0-9.a-zA-Z-]*)\.tar\.(gz|bz2|xz)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
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
	local i v1=($1) v2=($2)
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
	for v in "$@"; do
		if [[ -z "$latest" ]]; then
			latest="$v"
		else
			appdeploy_version_compare "$v" "$latest"
			if [[ $? -eq 1 ]]; then
				latest="$v"
			fi
		fi
	done
	printf '%s\n' "$latest"
}

# ----------------------------------------------------------------------------
#
# UTILITIES
# 
# ----------------------------------------------------------------------------

# Function: appdeploy_cmd_run TARGET COMMAND [ARGS...]
# Runs COMMAND with ARGS on TARGET via SSH, in the target path, unless TARGET
# has no host part, in which case runs locally.
# SECURITY: Commands are executed via bash -c with proper escaping
function appdeploy_cmd_run() {
	local user=$(appdeploy_target_user "$1")
	local host=$(appdeploy_target_host "$1")
	local path=$(appdeploy_target_path "$1")
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
	local path=$(appdeploy_target_path "$1")
	local user=$(appdeploy_target_user "$1")
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
	local name="${3:-$(appdeploy_package_name "$(basename "$package")")}"
	local version="${4:-$(appdeploy_package_version "$(basename "$package")")}"
	local ext=$(appdeploy_package_ext "$(basename "$package")")
	
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
	
	local user=$(appdeploy_target_user "$target")
	local host=$(appdeploy_target_host "$target")
	local path=$(appdeploy_target_path "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	local dest_dir="$path/$name/packages"
	local dest_file="$name-$version.tar.$ext"
	
	appdeploy_log "Uploading $package to $target as $dest_file"
	
	# Ensure destination directory exists
	local escaped_dest_dir
	escaped_dest_dir=$(appdeploy_escape_single_quotes "$dest_dir")
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_dest_dir}'"
	
	if [[ -z "$host" || "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
		# Local copy
		if ! cp "$package" "${dest_dir}/${dest_file}"; then
			appdeploy_error "Failed to copy package"
			return 1
		fi
	else
		# Upload using rsync
		if ! rsync -az --progress "$package" "${user}@${host}:${dest_dir}/${dest_file}"; then
			appdeploy_error "Failed to upload package"
			return 1
		fi
	fi
	
	appdeploy_log "Successfully uploaded $dest_file"
}

# Function: appdeploy_package_install TARGET PACKAGE[:VERSION]
# Given a `PACKAGE` (`VERSION` or latest) uploaded on `TARGET`, installs
# the package so that it can be activated.
function appdeploy_package_install() {
	local target="$1"
	local spec="$2"
	local parsed name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local user=$(appdeploy_target_user "$target")
	local host=$(appdeploy_target_host "$target")
	local path=$(appdeploy_target_path "$target")
	
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
		version=$(appdeploy_version_latest $versions)
		# Validate the resolved version
		if ! appdeploy_validate_version "$version"; then
			return 1
		fi
		appdeploy_log "Resolved latest version: $version"
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
		appdeploy_log "Package $name:$version is already installed"
		return 0
	fi
	
	appdeploy_log "Installing $name:$version"
	
	# Escape pkg_file for the command
	local escaped_pkg_file
	escaped_pkg_file=$(appdeploy_escape_single_quotes "$pkg_file")
	
	# Create dist directory and extract
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_dist_dir}/${escaped_version}' && tar $tar_opts '${escaped_pkg_file}' -C '${escaped_dist_dir}/${escaped_version}'"
	
	if [[ $? -ne 0 ]]; then
		appdeploy_error "Failed to extract package"
		return 1
	fi
	
	appdeploy_log "Successfully installed $name:$version to $dist_dir/$version"
}

# Function: appdeploy_package_activate TARGET PACKAGE[:VERSION]
# Given a `PACKAGE` (`VERSION` or latest) uploaded on `TARGET`, ensures
# the package is installed (unpacked) and actives it.
function appdeploy_package_activate() {
	local target="$1"
	local spec="$2"
	local parsed name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local user=$(appdeploy_target_user "$target")
	local host=$(appdeploy_target_host "$target")
	local path=$(appdeploy_target_path "$target")
	
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
		version=$(appdeploy_version_latest $versions)
		# Validate the resolved version
		if ! appdeploy_validate_version "$version"; then
			return 1
		fi
		appdeploy_log "Resolved latest version: $version"
	fi
	
	local escaped_version
	escaped_version=$(appdeploy_escape_single_quotes "$version")
	
	# Ensure package is installed
	if ! appdeploy_cmd_run "$target" "test -d '${escaped_dist_dir}/${escaped_version}'" 2>/dev/null; then
		appdeploy_log "Package not installed, installing first..."
		appdeploy_package_install "$target" "$name:$version"
		if [[ $? -ne 0 ]]; then
			appdeploy_error "Failed to install package"
			return 1
		fi
	fi
	
	appdeploy_log "Activating $name:$version"
	
	# Create run and var directories
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_run_dir}' '${escaped_var_dir}'"
	
	# Clear existing symlinks in run directory
	appdeploy_cmd_run "$target" "find '${escaped_run_dir}' -maxdepth 1 -type l -delete"
	
	# Create symlinks from dist/VERSION to run
	appdeploy_cmd_run "$target" "for item in '${escaped_dist_dir}/${escaped_version}'/*; do [ -e \"\$item\" ] && ln -sf \"\$item\" '${escaped_run_dir}/'; done; true"
	
	# Overlay symlinks from var to run (these take precedence)
	appdeploy_cmd_run "$target" "for item in '${escaped_var_dir}'/*; do [ -e \"\$item\" ] && ln -sf \"\$item\" '${escaped_run_dir}/'; done; true"
	
	# Store active version marker
	appdeploy_cmd_run "$target" "echo '${escaped_version}' > '${escaped_path}/${escaped_name}/.active'"
	
	appdeploy_log "Successfully activated $name:$version"
}

# Function: appdeploy_package_deactivate TARGET PACKAGE[:VERSION]
# If `PACKAGE` (specific `VERSION` or active) is active on `TARGET`, ensures
# it is deactivated.
function appdeploy_package_deactivate() {
	local target="$1"
	local spec="$2"
	local parsed name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local path=$(appdeploy_target_path "$target")
	
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
		appdeploy_log "No active version for $name"
		return 0
	fi
	
	# If a specific version was requested, check if it matches
	if [[ -n "$version" && "$version" != "$active_version" ]]; then
		appdeploy_log "$name:$version is not active (active: $active_version)"
		return 0
	fi
	
	appdeploy_log "Deactivating $name:$active_version"
	
	# Remove all symlinks in run directory
	appdeploy_cmd_run "$target" "find '${escaped_run_dir}' -maxdepth 1 -type l -delete"
	
	# Remove active marker
	appdeploy_cmd_run "$target" "rm -f '${escaped_active_file}'"
	
	appdeploy_log "Successfully deactivated $name:$active_version"
}

# Function: appdeploy_package_uninstall TARGET PACKAGE[:VERSION]
# If `PACKAGE` (specific `VERSION` or all matching) is installed on `TARGET`, ensures
# it is deactivated and uninstalled (archive kept)
function appdeploy_package_uninstall() {
	local target="$1"
	local spec="$2"
	local parsed name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local path=$(appdeploy_target_path "$target")
	
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
			appdeploy_log "No installed versions for $name"
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
		appdeploy_log "$name:$version is not installed"
		return 0
	fi
	
	# Deactivate if this version is active
	if [[ "$active_version" == "$version" ]]; then
		appdeploy_log "Deactivating active version first..."
		appdeploy_package_deactivate "$target" "$name:$version"
	fi
	
	appdeploy_log "Uninstalling $name:$version"
	
	# Remove the dist directory for this version
	appdeploy_cmd_run "$target" "rm -rf '${escaped_dist_dir}/${escaped_version}'"
	
	appdeploy_log "Successfully uninstalled $name:$version (archive kept)"
}

# Function: appdeploy_package_remove TARGET PACKAGE[:VERSION]
# If `PACKAGE` (`VERSION` or all matching) is installed on `TARGET`, ensures
# it is deactivated, uninstalled and archive removed.
function appdeploy_package_remove() {
	local target="$1"
	local spec="$2"
	local parsed name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	# Validate version if provided
	if [[ -n "$version" ]] && ! appdeploy_validate_version "$version"; then
		return 1
	fi
	
	local path=$(appdeploy_target_path "$target")
	
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
			appdeploy_log "No packages found for $name"
			return 0
		fi
		for v in $versions; do
			appdeploy_package_remove "$target" "$name:$v"
		done
		return 0
	fi
	
	local escaped_version
	escaped_version=$(appdeploy_escape_single_quotes "$version")
	
	# Uninstall first (this handles deactivation too)
	appdeploy_package_uninstall "$target" "$name:$version"
	
	appdeploy_log "Removing package archive for $name:$version"
	
	# Remove the package archive
	appdeploy_cmd_run "$target" "rm -f '${escaped_pkg_dir}/${escaped_name}-${escaped_version}'.tar.*"
	
	appdeploy_log "Successfully removed $name:$version"
}

# Function: appdeploy_package_list TARGET [PACKAGE][:VERSION]
# Lists the packages that match the given PACKAGE and VERSION on TARGET, 
# supporting wildcards. 
function appdeploy_package_list() {
	local target="$1"
	local spec="${2:-*}"
	local parsed name version
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
	
	local path=$(appdeploy_target_path "$target")
	
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
		if [[ "$name" != "*" && "$app" != $name ]]; then
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
			if [[ -n "$version" && "$v" != $version ]]; then
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
	local parsed name version
	read -r name version <<< "$(appdeploy_package_parse "$spec")"
	
	# Validate name
	if ! appdeploy_validate_name "$name"; then
		return 1
	fi
	
	if [[ ! -f "$conf_archive" ]]; then
		appdeploy_error "Configuration archive does not exist: $conf_archive"
		return 1
	fi
	
	local user=$(appdeploy_target_user "$target")
	local host=$(appdeploy_target_host "$target")
	local path=$(appdeploy_target_path "$target")
	
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

# Function: appdeploy_package_create SOURCE DESTINATION
# Creates a package from the given SOURCE directory, placing the package
# tarball as DESTINATION. DESTINATION must be like `${NAME}-${VERSION}.tar.[gz|bz2|xz]`
function appdeploy_package_create () {
	local source="$1"
	local destination="$2"
	
	if [[ ! -d "$source" ]]; then
		appdeploy_error "Package directory does not exist: $source"
		return 1
	fi
	
	[[ ! -e "$source/env.sh" ]] && appdeploy_warn "No 'env.sh' found in source: $source"
	[[ ! -e "$source/run.sh" ]] && appdeploy_warn "No 'run.sh' found in source: $source"
	
	# Validate destination filename format
	local name=$(appdeploy_package_name "$(basename "$destination")")
	local version=$(appdeploy_package_version "$(basename "$destination")")
	
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
	local dest_dir=$(dirname "$destination")
	if [[ -n "$dest_dir" && "$dest_dir" != "." ]]; then
		mkdir -p "$dest_dir"
	fi
	
	appdeploy_log "Creating package $name-$version from $source"
	
	# Create the tarball from the source directory contents
	if ! tar $tar_opts "$destination" -C "$source" .; then
		appdeploy_error "Failed to create package"
		return 1
	fi
	
	appdeploy_log "Successfully created package: $destination"
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
	local path=$(appdeploy_target_path "$target")
	local user=$(appdeploy_target_user "$target")
	local host=$(appdeploy_target_host "$target")
	
	if ! appdeploy_validate_path "$path"; then
		return 1
	fi
	
	appdeploy_log "Installing appdeploy directory structure on $target"
	
	local escaped_path
	escaped_path=$(appdeploy_escape_single_quotes "$path")
	
	# Create base directory
	appdeploy_cmd_run "$target" "mkdir -p '${escaped_path}'"
	
	appdeploy_log "Successfully installed appdeploy on $target at $path"
}

# Function: appdeploy_target_check TARGET
# Checks that the appdeploy target directory structure exists on TARGET, and-
# has the expected subdirectories, creating them if necessary.
function appdeploy_target_check() {
	local target="$1"
	local path=$(appdeploy_target_path "$target")
	
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

# ----------------------------------------------------------------------------
#
# MAIN
# 
# ----------------------------------------------------------------------------

function appdeploy_cli() {
	appdeploy_target_check ":$APPDEPLOY_TARGET"
}

# Only run CLI if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	appdeploy_cli "$@"
fi

# EOF
