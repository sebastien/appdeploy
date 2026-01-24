#!/usr/bin/env bash
#
# Bash completion script for appdeploy
#
# This script provides autocomplete support for the appdeploy command and its subcommands.
#

# Function: _appdeploy_complete()
# Provides completion for the appdeploy command and its subcommands.
_appdeploy_complete() {
	# shellcheck disable=SC2034  # words and cword required by completion API
	local cur prev words cword
	_init_completion || return

	# Extract current word and previous word
	cur="${COMP_WORDS[COMP_CWORD]}"
	prev="${COMP_WORDS[COMP_CWORD - 1]}"

	# Define the main commands and subcommands
	local commands="package target run"
	local package_subcommands="create upload install activate deactivate uninstall remove list deploy-conf"
	local target_subcommands="install check"

	# Case statement to handle completion based on the current context
	case "$prev" in
	appdeploy)
		# Complete main commands
		readarray -t COMPREPLY < <(compgen -W "$commands" -- "$cur")
		;;
	package)
		# Complete package subcommands
		readarray -t COMPREPLY < <(compgen -W "$package_subcommands" -- "$cur")
		;;
	target)
		# Complete target subcommands
		readarray -t COMPREPLY < <(compgen -W "$target_subcommands" -- "$cur")
		;;
	run)
		# Complete run subcommands (if any)
		COMPREPLY=()
		;;
	*)
		# Default completion (e.g., file paths)
		COMPREPLY=()
		;;
	esac
}

# Register the completion function
complete -F _appdeploy_complete appdeploy
# EOF
