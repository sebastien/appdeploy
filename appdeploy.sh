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
APPDEPLOY_TARGET=${APPDEPLOY_TARGET:/opt/apps}

# ============================================================================
# LOGGING
# ============================================================================

function appdeploy_log() {
	local prefix="--- "
	printf '%s %s\n' "$prefix" "$*"
}

function appdeploy_warn() {
	local prefix="-!-"
	printf '%s %s\n' "$prefix" "$*"
}

function appdeploy_error() {
	local prefix="[!]"
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
	[[ $1 =~ ^(.*)-[0-9].*\.[^.]+$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

function appdeploy_package_version() { # $1 = filename
	[[ $1 =~ ^.*-([0-9][^.]*)\.[^.]+$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

function appdeploy_package_ext() { # $1 = filename
	[[ $1 =~ \.([^.]+)$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
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
	local out
	if ! out=$(ssh "${user}@${host}" "cd '$path';$@ 2>&1"); then
		return 1
	else
		echo -n "$out"
	fi
}
# Function: appdeploy_dir_ensure TARGET
# Ensures that the given PATH exists on TARGET, creating it if necessary.
function appdeploy_dir_ensure() {
	local path=$(appdeploy_target_path "$1")
	local user=$(appdeploy_target_user "$1")
	local dir="$path/$2"
	appdeploy_run "$1" "mkdir -p '$dir';chown $user:$user '$dir'"
}

# Function: appdeploy_file_exists FILE [TARGET]
# Checks if the given FILE exists, on TARGET if given, otherwise locally.
function appdeploy_file_exists () {
	if [ $# -eq 1 ]; then
		[ -e "$1" ]
	else
		appdeploy_run "$2" "test -e '$1'"
	fi
}

# ----------------------------------------------------------------------------
#
# PACKAGES
# 
# ----------------------------------------------------------------------------

# Function: appdeploy_package_upload TAREGET PACKAGE [NAME] [VERSION]
# Uploads `PACKAGE` to `TARGET`, optionally renaming it to `NAME` and `VERSION`.
# Names and versions are used to construct the filename as `NAME-VERSION.EXT`.
function appdeploy_package_upload() {
	echo TODO
}

# Function: appdeploy_package_install TARGET PACKAGE[:VERSION]
# Given a `PACKAGE` (`VERSION` or latest) uploaded on `TARGET`, installs
# the package so that it can be activated.
function appdeploy_package_install() {
	echo TODO
}

# Function: appdeploy_package_activate TARGET PACKAGE[:VERSION]
# Given a `PACKAGE` (`VERSION` or latest) uploaded on `TARGET`, ensures
# the package is installed (unpacked) and actives it.
function appdeploy_package_activate() {
	echo TODO
}

# Function: appdeploy_package_deactivate TARGET PACKAGE[:VERSION]
# If `PACKAGE` (specific `VERSION` or active) is active on `TARGET`, ensures
# it is deactivated.
function appdeploy_package_deactivate() {
	echo TODO
}

# Function: appdeploy_package_uninstall TARGET PACKAGE[:VERSION]
# If `PACKAGE` (specific `VERSION` or all matching) is installed on `TARGET`, ensures
# it is deactivated and uninstalled (archive kept)
function appdeploy_package_uninstall() {
	echo TODO
}

# Function: appdeploy_package_remove TARGET PACKAGE[:VERSION]
# If `PACKAGE` (`VERSION` or all matching) is installed on `TARGET`, ensures
# it is deactivated, uninstalled and archive removed.
function appdeploy_package_remove() {
	echo TODO
}

# Function: appdeploy_package_list TARGET [PACKAGE][:VERSION]
# Lists the packages that match the given PACKAGE and VERSION on TARGET, 
# supporting wildcards. 
function appdeploy_package_list() {
}

# Function: appdeploy_conf_push TARGET PACKAGE[:VERSION] CONF_ARCHIVE
# Uploads the given `CONF_ARCHIVE` (tarball) to `TARGET` and unpacks it
# into the `var/` directory of the given `PACKAGE` (`VERSION` or latest).
function appdeploy_package_deploy_conf() {
	echo TODO
}

# Function: appdeploy_package_create SOURCE DESTINATION
# Creates a package from the given SOURCE directory, placing the package
# tarball as DESTINATION. DESTINATION must be like `${NAME}-${VERSION}.tar.[gz|bz2|xz]`
function appdeploy_package_create () {
	if [ ! -e "$1" ]; then
		appdeploy_error "Package directory does not exist: $1"
		return 1
	fi
	[ ! -e "$1/env.sh" ] && appdeploy_warn "No 'env.sh' found in source: $1"
	[ ! -e "$1/run.sh" ] && appdeploy_warn "No 'run.sh' found in source: $1"
}

# ----------------------------------------------------------------------------
#
# TARGET
# 
# ----------------------------------------------------------------------------

# Function: appdeploy_target_install TARGET
# Creates the appdeploy target directory structure on TARGET.
function appdeploy_target_install() {
	appdeploy_ensure_dir $APPDEPLOY_TARGET "packages"
	appdeploy_ensure_dir $APPDEPLOY_TARGET "app"
}

# Function: appdeploy_target_check TARGET
# Checks that the appdeploy target directory structure exists on TARGET, and-
# has the expected subdirectories, creating them if necessary.
function appdeploy_target_check() {
	appdeploy_ensure_dir $APPDEPLOY_TARGET "packages"
	appdeploy_ensure_dir $APPDEPLOY_TARGET "app"
}

# ----------------------------------------------------------------------------
#
# MAIN
# 
# ----------------------------------------------------------------------------

function appdeploy_cli() {
	appdeploy_check $APPDEPLOY_TARGET
}

appdeploy_cli "$@"

# EOF
