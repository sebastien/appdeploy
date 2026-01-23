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
function appdeploy_cmd_run() {
	local user=$(appdeploy_target_user "$1")
	local host=$(appdeploy_target_host "$1")
	local path=$(appdeploy_target_path "$1")
	shift
	local cmd="$*"
	local out
	
	if [[ -z "$host" || "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
		# Run locally (disable xtrace to avoid trace output in captured result)
		if ! out=$(set +x; cd "$path" && eval "$cmd" 2>&1); then
			return 1
		fi
	else
		# Run via SSH
		if ! out=$(ssh "${user}@${host}" "cd '$path';$cmd" 2>&1); then
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
	appdeploy_cmd_run "$1" "mkdir -p '$dir';chown $user:$user '$dir'"
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
	
	if [[ -z "$name" ]]; then
		appdeploy_error "Could not determine package name from: $package"
		return 1
	fi
	if [[ -z "$version" ]]; then
		appdeploy_error "Could not determine package version from: $package"
		return 1
	fi
	if [[ ! -f "$package" ]]; then
		appdeploy_error "Package file does not exist: $package"
		return 1
	fi
	
	local user=$(appdeploy_target_user "$target")
	local host=$(appdeploy_target_host "$target")
	local path=$(appdeploy_target_path "$target")
	local dest_dir="$path/$name/packages"
	local dest_file="$name-$version.tar.$ext"
	
	appdeploy_log "Uploading $package to $target as $dest_file"
	
	# Ensure destination directory exists
	appdeploy_cmd_run "$target" "mkdir -p '$dest_dir'"
	
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
	
	local user=$(appdeploy_target_user "$target")
	local host=$(appdeploy_target_host "$target")
	local path=$(appdeploy_target_path "$target")
	local pkg_dir="$path/$name/packages"
	local dist_dir="$path/$name/dist"
	
	# If no version specified, find the latest
	if [[ -z "$version" ]]; then
		local versions
		versions=$(appdeploy_cmd_run "$target" "ls -1 '$pkg_dir' 2>/dev/null | grep -E '^${name}-[0-9].*\.tar\.(gz|bz2|xz)$' | sed -E 's/^${name}-//;s/\.tar\.(gz|bz2|xz)$//'")
		if [[ -z "$versions" ]]; then
			appdeploy_error "No packages found for $name on $target"
			return 1
		fi
		version=$(appdeploy_version_latest $versions)
		appdeploy_log "Resolved latest version: $version"
	fi
	
	# Find the package file
	local pkg_file
	pkg_file=$(appdeploy_cmd_run "$target" "ls -1 '$pkg_dir/${name}-${version}'.tar.* 2>/dev/null | head -1")
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
	if appdeploy_cmd_run "$target" "test -d '$dist_dir/$version'" 2>/dev/null; then
		appdeploy_log "Package $name:$version is already installed"
		return 0
	fi
	
	appdeploy_log "Installing $name:$version"
	
	# Create dist directory and extract
	appdeploy_cmd_run "$target" "mkdir -p '$dist_dir/$version' && tar $tar_opts '$pkg_file' -C '$dist_dir/$version'"
	
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
	
	local user=$(appdeploy_target_user "$target")
	local host=$(appdeploy_target_host "$target")
	local path=$(appdeploy_target_path "$target")
	local pkg_dir="$path/$name/packages"
	local dist_dir="$path/$name/dist"
	local var_dir="$path/$name/var"
	local run_dir="$path/$name/run"
	
	# If no version specified, find the latest installed or uploaded
	if [[ -z "$version" ]]; then
		# First check installed versions
		local versions
		versions=$(appdeploy_cmd_run "$target" "ls -1 '$dist_dir' 2>/dev/null | grep -E '^[0-9]'")
		if [[ -z "$versions" ]]; then
			# Fall back to uploaded packages
			versions=$(appdeploy_cmd_run "$target" "ls -1 '$pkg_dir' 2>/dev/null | grep -E '^${name}-[0-9].*\.tar\.(gz|bz2|xz)$' | sed -E 's/^${name}-//;s/\.tar\.(gz|bz2|xz)$//'")
		fi
		if [[ -z "$versions" ]]; then
			appdeploy_error "No packages found for $name on $target"
			return 1
		fi
		version=$(appdeploy_version_latest $versions)
		appdeploy_log "Resolved latest version: $version"
	fi
	
	# Ensure package is installed
	if ! appdeploy_cmd_run "$target" "test -d '$dist_dir/$version'" 2>/dev/null; then
		appdeploy_log "Package not installed, installing first..."
		appdeploy_package_install "$target" "$name:$version"
		if [[ $? -ne 0 ]]; then
			appdeploy_error "Failed to install package"
			return 1
		fi
	fi
	
	appdeploy_log "Activating $name:$version"
	
	# Create run and var directories
	appdeploy_cmd_run "$target" "mkdir -p '$run_dir' '$var_dir'"
	
	# Clear existing symlinks in run directory
	appdeploy_cmd_run "$target" "find '$run_dir' -maxdepth 1 -type l -delete"
	
	# Create symlinks from dist/VERSION to run
	appdeploy_cmd_run "$target" "for item in '$dist_dir/$version'/*; do [ -e \"\$item\" ] && ln -sf \"\$item\" '$run_dir/'; done; true"
	
	# Overlay symlinks from var to run (these take precedence)
	appdeploy_cmd_run "$target" "for item in '$var_dir'/*; do [ -e \"\$item\" ] && ln -sf \"\$item\" '$run_dir/'; done; true"
	
	# Store active version marker
	appdeploy_cmd_run "$target" "echo '$version' > '$path/$name/.active'"
	
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
	
	local path=$(appdeploy_target_path "$target")
	local run_dir="$path/$name/run"
	local active_file="$path/$name/.active"
	
	# Get currently active version
	local active_version
	active_version=$(appdeploy_cmd_run "$target" "cat '$active_file' 2>/dev/null" || true)
	
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
	appdeploy_cmd_run "$target" "find '$run_dir' -maxdepth 1 -type l -delete"
	
	# Remove active marker
	appdeploy_cmd_run "$target" "rm -f '$active_file'"
	
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
	
	local path=$(appdeploy_target_path "$target")
	local dist_dir="$path/$name/dist"
	local active_file="$path/$name/.active"
	
	# Get currently active version
	local active_version
	active_version=$(appdeploy_cmd_run "$target" "cat '$active_file' 2>/dev/null" || true)
	
	# If no version specified, uninstall all versions
	if [[ -z "$version" ]]; then
		local versions
		versions=$(appdeploy_cmd_run "$target" "ls -1 '$dist_dir' 2>/dev/null | grep -E '^[0-9]'")
		if [[ -z "$versions" ]]; then
			appdeploy_log "No installed versions for $name"
			return 0
		fi
		for v in $versions; do
			appdeploy_package_uninstall "$target" "$name:$v"
		done
		return 0
	fi
	
	# Check if version is installed
	if ! appdeploy_cmd_run "$target" "test -d '$dist_dir/$version'" 2>/dev/null; then
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
	appdeploy_cmd_run "$target" "rm -rf '$dist_dir/$version'"
	
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
	
	local path=$(appdeploy_target_path "$target")
	local pkg_dir="$path/$name/packages"
	
	# If no version specified, remove all versions
	if [[ -z "$version" ]]; then
		local versions
		versions=$(appdeploy_cmd_run "$target" "ls -1 '$pkg_dir' 2>/dev/null | grep -E '^${name}-[0-9].*\.tar\.(gz|bz2|xz)$' | sed -E 's/^${name}-//;s/\.tar\.(gz|bz2|xz)$//'")
		if [[ -z "$versions" ]]; then
			appdeploy_log "No packages found for $name"
			return 0
		fi
		for v in $versions; do
			appdeploy_package_remove "$target" "$name:$v"
		done
		return 0
	fi
	
	# Uninstall first (this handles deactivation too)
	appdeploy_package_uninstall "$target" "$name:$version"
	
	appdeploy_log "Removing package archive for $name:$version"
	
	# Remove the package archive
	appdeploy_cmd_run "$target" "rm -f '$pkg_dir/${name}-${version}'.tar.*"
	
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
	
	local path=$(appdeploy_target_path "$target")
	
	# List all matching apps
	local apps
	apps=$(appdeploy_cmd_run "$target" "ls -1 '$path' 2>/dev/null | grep -v '^\.' || true")
	
	if [[ -z "$apps" ]]; then
		appdeploy_log "No packages found on $target"
		return 0
	fi
	
	printf "%-20s %-15s %-10s %-10s\n" "PACKAGE" "VERSION" "STATUS" "LOCATION"
	printf "%-20s %-15s %-10s %-10s\n" "-------" "-------" "------" "--------"
	
	for app in $apps; do
		# Check if app matches the pattern
		if [[ "$name" != "*" && "$app" != $name ]]; then
			continue
		fi
		
		local pkg_dir="$path/$app/packages"
		local dist_dir="$path/$app/dist"
		local active_file="$path/$app/.active"
		
		# Get active version
		local active_version
		active_version=$(appdeploy_cmd_run "$target" "cat '$active_file' 2>/dev/null" || true)
		
		# List uploaded packages
		local pkg_versions
		pkg_versions=$(appdeploy_cmd_run "$target" "ls -1 '$pkg_dir' 2>/dev/null | grep -E '^${app}-[0-9].*\.tar\.(gz|bz2|xz)$' | sed -E 's/^${app}-//;s/\.tar\.(gz|bz2|xz)$//' || true")
		
		# List installed versions
		local installed_versions
		installed_versions=$(appdeploy_cmd_run "$target" "ls -1 '$dist_dir' 2>/dev/null | grep -E '^[0-9]' || true")
		
		# Combine and deduplicate versions
		local all_versions
		all_versions=$(printf '%s\n%s' "$pkg_versions" "$installed_versions" | sort -V | uniq)
		
		if [[ -z "$all_versions" ]]; then
			continue
		fi
		
		for v in $all_versions; do
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
	
	if [[ ! -f "$conf_archive" ]]; then
		appdeploy_error "Configuration archive does not exist: $conf_archive"
		return 1
	fi
	
	local user=$(appdeploy_target_user "$target")
	local host=$(appdeploy_target_host "$target")
	local path=$(appdeploy_target_path "$target")
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
	
	# Ensure var directory exists
	appdeploy_cmd_run "$target" "mkdir -p '$var_dir'"
	
	# Upload/copy the archive to a temp location
	local temp_archive="/tmp/appdeploy_conf_$(date +%s).tar${conf_archive##*.tar}"
	if [[ -z "$host" || "$host" == "localhost" || "$host" == "127.0.0.1" ]]; then
		# Local copy
		if ! cp "$conf_archive" "${temp_archive}"; then
			appdeploy_error "Failed to copy configuration archive"
			return 1
		fi
	else
		# Upload using rsync
		if ! rsync -az "$conf_archive" "${user}@${host}:${temp_archive}"; then
			appdeploy_error "Failed to upload configuration archive"
			return 1
		fi
	fi
	
	# Extract to var directory
	if ! appdeploy_cmd_run "$target" "tar $tar_opts '$temp_archive' -C '$var_dir' && rm -f '$temp_archive'"; then
		appdeploy_error "Failed to extract configuration archive"
		return 1
	fi
	
	appdeploy_log "Successfully deployed configuration to $var_dir"
	
	# If package is active, re-activate to update symlinks
	local active_file="$path/$name/.active"
	local active_version
	active_version=$(appdeploy_cmd_run "$target" "cat '$active_file' 2>/dev/null" || true)
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
	if [[ -z "$version" ]]; then
		appdeploy_error "Could not determine version from: $destination (expected NAME-VERSION.tar.[gz|bz2|xz])"
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
	
	appdeploy_log "Installing appdeploy directory structure on $target"
	
	# Create base directory
	appdeploy_cmd_run "$target" "mkdir -p '$path'"
	
	appdeploy_log "Successfully installed appdeploy on $target at $path"
}

# Function: appdeploy_target_check TARGET
# Checks that the appdeploy target directory structure exists on TARGET, and-
# has the expected subdirectories, creating them if necessary.
function appdeploy_target_check() {
	local target="$1"
	local path=$(appdeploy_target_path "$target")
	
	# Check if base directory exists
	if ! appdeploy_cmd_run "$target" "test -d '$path'" 2>/dev/null; then
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
