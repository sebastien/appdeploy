#!/usr/bin/env python3
# --
# File: appdeploy.py
#
# `appdeploy` packages, deploys, and manages applications on local/remote targets.
# It uses `daemonctl`, `daemonrun`, and `teelog` to manage the packaged applications.
#
# ## Usage
#
# >   appdeploy COMMAND [OPTIONS] [ARGS...]
#
# ## Package Structure
#
# >   [conf.toml]     - Optional package and daemon configuration
# >   [env.sh]        - Optional environment script
# >   run[.sh]        - Required: runs the application in foreground
# >   [check[.sh]]    - Optional health check script
# >   [on-start[.sh]] - Hook: after start
# >   [on-stop[.sh]]  - Hook: after stop
# >   [VERSION]       - Optional version file

import argparse
import contextlib
import dataclasses
import fnmatch
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import tomllib
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Optional, Any, NoReturn

# -----------------------------------------------------------------------------
#
# GLOBALS AND CONFIGURATION
#
# -----------------------------------------------------------------------------

APPDEPLOY_VERSION = "1.0.0"
APPDEPLOY_TARGET = os.environ.get("APPDEPLOY_TARGET", "/opt/apps")
APPDEPLOY_SSH_OPTIONS = os.environ.get("APPDEPLOY_SSH_OPTIONS", "")
APPDEPLOY_KEEP_VERSIONS = int(os.environ.get("APPDEPLOY_KEEP_VERSIONS", "5"))
APPDEPLOY_OP_TIMEOUT = int(os.environ.get("APPDEPLOY_OP_TIMEOUT", "30"))
APPDEPLOY_NO_COLOR = os.environ.get("APPDEPLOY_NO_COLOR", "") == "1"

# Tool discovery (resolve symlinks to find bundled tools)
_SCRIPT_DIR = Path(__file__).resolve().parent
BUNDLED_DAEMONCTL = _SCRIPT_DIR / "appdeploy.daemonctl"
BUNDLED_DAEMONRUN = _SCRIPT_DIR / "appdeploy.daemonrun"
BUNDLED_TEELOG = _SCRIPT_DIR / "appdeploy.teelog"

# Global runtime state
_verbose = False
_quiet = False
_no_color = APPDEPLOY_NO_COLOR
_dry_run = False
_yes = False
_op_timeout = APPDEPLOY_OP_TIMEOUT

# Logging context for consistent output format
_log_target: Optional[str] = None  # Current target string for logging
_log_first_op = True  # Whether next operation is the first (shows time)
_log_first_ssh = True  # Whether next SSH command is the first (shows connecting status)

# -----------------------------------------------------------------------------
#
# TYPES
#
# -----------------------------------------------------------------------------


class SSHConnectionError(Exception):
	"""Raised when SSH connection to remote host fails."""

	pass


@dataclasses.dataclass
class Target:
	"""Parsed target specification."""

	host: Optional[str]  # None for local
	user: Optional[str]
	path: Path
	is_remote: bool


@dataclasses.dataclass
class Package:
	"""Loaded package information."""

	name: str
	version: str
	path: Path  # Directory or archive path
	is_archive: bool
	config: dict[str, Any]  # Parsed conf.toml


@dataclasses.dataclass
class InstalledVersion:
	"""Installed version information."""

	name: str
	version: str
	status: str  # "active", "inactive"
	installed: str  # ISO timestamp
	size: int  # bytes


# -----------------------------------------------------------------------------
#
# UTILITIES
#
# -----------------------------------------------------------------------------


def appdeploy_util_confirm(message: str, yes: bool = False) -> bool:
	"""Prompt for confirmation. Returns True if confirmed."""
	if yes or _yes:
		return True
	if not sys.stdin.isatty():
		return False
	try:
		response = input(f"{message} [y/N] ").strip().lower()
		return response in ("y", "yes")
	except (EOFError, KeyboardInterrupt):
		return False


def appdeploy_util_output(message: str, quiet: bool = False) -> None:
	"""Print message to stdout unless quiet mode."""
	if not quiet and not _quiet:
		print(message)


def appdeploy_util_verbose(message: str) -> None:
	"""Print message only in verbose mode."""
	if _verbose:
		print(f"[verbose] {message}", file=sys.stderr)


def appdeploy_util_error(message: str) -> None:
	"""Print error message to stderr."""
	color = "" if _no_color else "\033[31m"
	reset = "" if _no_color else "\033[0m"
	print(f"{color}error:{reset} {message}", file=sys.stderr)


def appdeploy_util_warn(message: str) -> None:
	"""Print warning message to stderr."""
	color = "" if _no_color else "\033[33m"
	reset = "" if _no_color else "\033[0m"
	print(f"{color}warning:{reset} {message}", file=sys.stderr)


def appdeploy_util_status(message: str) -> None:
	"""Print status message for ongoing operations.

	Used for transient status updates during slow operations.
	Respects --quiet flag.
	"""
	if _quiet:
		return

	parts = []
	if _log_target:
		parts.append(f"[{_log_target}]")
	parts.append(message)
	print(" ".join(parts))


@contextlib.contextmanager
def appdeploy_util_delayed_status(message: str, delay: float = 1.0):
	"""Context manager that shows status message only if operation takes longer than delay.

	Args:
		message: Status message to display (with trailing ... added automatically)
		delay: Seconds to wait before showing message (default 1.0)
	"""
	timer = None

	def show_status():
		appdeploy_util_status(f"{message}...")

	if not _quiet:
		timer = threading.Timer(delay, show_status)
		timer.start()

	try:
		yield
	finally:
		if timer:
			timer.cancel()


def appdeploy_util_set_log_target(target: "Target") -> None:
	"""Set the current target for logging context."""
	global _log_target, _log_first_op, _log_first_ssh
	if target.is_remote:
		if target.user:
			_log_target = f"{target.user}@{target.host}:{target.path}"
		else:
			_log_target = f"{target.host}:{target.path}"
	else:
		_log_target = str(target.path)
	_log_first_op = True
	_log_first_ssh = True


def appdeploy_util_log_op(message: str, version: Optional[str] = None) -> None:
	"""Log an operation message with consistent format.

	Format: [TARGET] [TIME] MESSAGE [version=VERSION]
	- TARGET: always shown
	- TIME: shown only for first operation
	- VERSION: shown for app lifecycle operations (pass version param)
	"""
	global _log_first_op
	if _quiet:
		return

	parts = []

	# Target prefix
	if _log_target:
		parts.append(f"[{_log_target}]")

	# Time prefix (first operation only)
	if _log_first_op:
		timestamp = datetime.now().strftime("%H:%M:%S")
		parts.append(f"[{timestamp}]")
		_log_first_op = False

	# Message
	parts.append(message)

	# Version suffix for app lifecycle operations
	if version:
		parts.append(f"version={version}")

	print(" ".join(parts))


def appdeploy_util_color(text: str, color: str) -> str:
	"""Colorize text if colors are enabled."""
	if _no_color:
		return text
	colors = {
		"red": "\033[31m",
		"green": "\033[32m",
		"yellow": "\033[33m",
		"blue": "\033[34m",
		"magenta": "\033[35m",
		"cyan": "\033[36m",
		"bold": "\033[1m",
		"reset": "\033[0m",
	}
	return f"{colors.get(color, '')}{text}{colors.get('reset', '')}"


def appdeploy_util_parse_time(time_str: str) -> datetime:
	"""Parse time string for --since/--until.

	Supports:
	- Relative: Ns, Nm, Nh, Nd, Nw (seconds, minutes, hours, days, weeks ago)
	- Absolute: YYYY-MM-DD, YYYY-MM-DDTHH:MM:SS, with optional timezone
	"""
	now = datetime.now(timezone.utc)

	# Relative time patterns
	match = re.match(r"^(\d+)([smhdw])$", time_str)
	if match:
		value = int(match.group(1))
		unit = match.group(2)
		deltas = {
			"s": timedelta(seconds=value),
			"m": timedelta(minutes=value),
			"h": timedelta(hours=value),
			"d": timedelta(days=value),
			"w": timedelta(weeks=value),
		}
		return now - deltas[unit]

	# Absolute time patterns
	formats = [
		"%Y-%m-%d",
		"%Y-%m-%dT%H:%M:%S",
		"%Y-%m-%dT%H:%M:%S%z",
	]
	for fmt in formats:
		try:
			dt = datetime.strptime(time_str, fmt)
			if dt.tzinfo is None:
				dt = dt.replace(tzinfo=timezone.utc)
			return dt
		except ValueError:
			continue

	raise ValueError(f"Invalid time format: {time_str}")


def appdeploy_util_format_size(size: int) -> str:
	"""Format byte size as human-readable string."""
	for unit in ["B", "KB", "MB", "GB", "TB"]:
		if size < 1024:
			return f"{size:.1f}{unit}" if unit != "B" else f"{size}{unit}"
		size /= 1024
	return f"{size:.1f}PB"


def appdeploy_util_format_duration(seconds: float) -> str:
	"""Format duration as human-readable string."""
	if seconds < 60:
		return f"{seconds:.1f}s"
	elif seconds < 3600:
		return f"{seconds / 60:.1f}m"
	else:
		return f"{seconds / 3600:.1f}h"


def appdeploy_util_format_time_ago(timestamp: float) -> str:
	"""Format a timestamp as a relative time string (e.g., '2m ago', '1h ago')."""
	import time

	now = time.time()
	diff = now - timestamp

	if diff < 0:
		return "future"
	elif diff < 60:
		return f"{int(diff)}s ago"
	elif diff < 3600:
		return f"{int(diff / 60)}m ago"
	elif diff < 86400:
		return f"{int(diff / 3600)}h ago"
	else:
		return f"{int(diff / 86400)}d ago"


# -----------------------------------------------------------------------------
#
# TARGET RESOLUTION AND EXECUTION
#
# -----------------------------------------------------------------------------


def appdeploy_target_parse(
	target_str: str, force_local: bool = False, force_remote: bool = False
) -> Target:
	"""Parse TARGET string into Target dataclass.

	Resolution rules:
	1. Contains '@' -> remote
	2. Contains ':' (not position 2 on Windows) -> remote
	3. Starts with '/', './', '../', '~' -> local
	4. Exists as local directory -> local
	5. 'localhost' or '127.0.0.1' -> local
	6. Otherwise -> remote
	"""
	user: Optional[str] = None
	host: Optional[str] = None
	path = Path(APPDEPLOY_TARGET)

	if force_local and force_remote:
		raise ValueError("Cannot specify both --local and --remote")

	# Check for user@host pattern
	if "@" in target_str and not force_local:
		user_host, _, path_str = target_str.partition(":")
		user, _, host = user_host.rpartition("@")
		if not user:
			user = None
		if path_str:
			path = Path(path_str)
		return Target(host=host, user=user, path=path, is_remote=True)

	# Check for host:path pattern (not Windows drive like C:)
	if ":" in target_str and not force_local:
		colon_pos = target_str.index(":")
		# Windows drive check: single letter followed by colon at position 1
		if not (colon_pos == 1 and target_str[0].isalpha()):
			host, _, path_str = target_str.partition(":")
			if path_str:
				path = Path(path_str)
			return Target(host=host, user=None, path=path, is_remote=True)

	# Force remote interpretation
	if force_remote:
		return Target(host=target_str, user=None, path=path, is_remote=True)

	# Check for local path patterns
	if target_str.startswith(("/", "./", "../", "~")):
		expanded = Path(target_str).expanduser()
		return Target(host=None, user=None, path=expanded, is_remote=False)

	# Check if exists as local directory
	if Path(target_str).exists():
		return Target(host=None, user=None, path=Path(target_str), is_remote=False)

	# Special localhost handling
	if target_str in ("localhost", "127.0.0.1"):
		return Target(host=None, user=None, path=path, is_remote=False)

	# Default: treat as remote hostname
	if force_local:
		return Target(host=None, user=None, path=Path(target_str), is_remote=False)

	return Target(host=target_str, user=None, path=path, is_remote=True)


def appdeploy_exec_ssh_cmd(target: Target) -> list[str]:
	"""Build SSH command prefix for target."""
	cmd = ["ssh"]
	if APPDEPLOY_SSH_OPTIONS:
		cmd.extend(shlex.split(APPDEPLOY_SSH_OPTIONS))
	if target.user:
		cmd.append(f"{target.user}@{target.host}")
	else:
		cmd.append(target.host or "")
	return cmd


def _format_ssh_connection_error(host: str, stderr: Optional[str]) -> str:
	"""Format a user-friendly SSH connection error message with hints."""
	stderr_lower = stderr.lower() if stderr else ""

	if "connection refused" in stderr_lower:
		hint = "Check that SSH is running on the remote host"
	elif "no route to host" in stderr_lower or "network is unreachable" in stderr_lower:
		hint = "Check your network connection and that the host is reachable"
	elif (
		"name or service not known" in stderr_lower
		or "could not resolve" in stderr_lower
	):
		hint = "Check that the hostname is correct"
	elif "permission denied" in stderr_lower:
		hint = "Check your SSH credentials or key configuration"
	elif "connection timed out" in stderr_lower:
		hint = "The host may be down or blocked by a firewall"
	else:
		hint = "Check that the host is reachable and SSH is running"

	return f"Cannot connect to '{host}' via SSH\nhint: {hint}"


def appdeploy_exec_run(
	target: Target,
	command: str,
	timeout: Optional[int] = None,
	check: bool = True,
	capture: bool = True,
) -> subprocess.CompletedProcess:
	"""Execute command on target (SSH for remote, direct for local)."""
	global _log_first_ssh

	if timeout is None:
		timeout = _op_timeout

	appdeploy_util_verbose(
		f"exec on {'remote' if target.is_remote else 'local'}: {command}"
	)

	if _dry_run:
		appdeploy_util_output(f"[dry-run] Would execute: {command}")
		return subprocess.CompletedProcess(
			args=command, returncode=0, stdout="", stderr=""
		)

	if target.is_remote:
		cmd = appdeploy_exec_ssh_cmd(target) + [command]
		# Show "Connecting..." status for first SSH command if it takes >1s
		if _log_first_ssh:
			_log_first_ssh = False
			with appdeploy_util_delayed_status("Connecting"):
				return _appdeploy_exec_run_impl(cmd, capture, timeout, check, target)
		else:
			return _appdeploy_exec_run_impl(cmd, capture, timeout, check, target)
	else:
		cmd = ["sh", "-c", command]
		return _appdeploy_exec_run_impl(cmd, capture, timeout, check, target)


def _appdeploy_exec_run_impl(
	cmd: list[str],
	capture: bool,
	timeout: Optional[int],
	check: bool,
	target: Target,
) -> subprocess.CompletedProcess:
	"""Internal implementation of command execution."""
	try:
		result = subprocess.run(
			cmd,
			capture_output=capture,
			text=True,
			timeout=timeout if timeout > 0 else None,
			check=False,
		)
		if check and result.returncode != 0:
			# SSH exit code 255 indicates connection failure
			if target.is_remote and result.returncode == 255:
				raise SSHConnectionError(
					_format_ssh_connection_error(target.host or "", result.stderr)
				)
			# For remote commands, provide a clearer error message
			if target.is_remote:
				remote_cmd = cmd[-1] if cmd else ""
				stderr_msg = result.stderr.strip() if result.stderr else ""
				error_msg = f"Remote command failed (exit code {result.returncode}): {remote_cmd}"
				if stderr_msg:
					error_msg += f"\n{stderr_msg}"
				raise RuntimeError(error_msg)
			raise subprocess.CalledProcessError(
				result.returncode, cmd, result.stdout, result.stderr
			)
		return result
	except subprocess.TimeoutExpired as e:
		raise TimeoutError(
			f"Command timed out after {timeout}s: {' '.join(cmd)}"
		) from e


def appdeploy_exec_copy(target: Target, local_path: Path, remote_path: str) -> None:
	"""Copy file to target (scp for remote, shutil.copy for local)."""
	appdeploy_util_verbose(f"copy {local_path} -> {remote_path}")

	if _dry_run:
		appdeploy_util_output(f"[dry-run] Would copy {local_path} to {remote_path}")
		return

	if target.is_remote:
		cmd = ["scp"]
		if APPDEPLOY_SSH_OPTIONS:
			cmd.extend(shlex.split(APPDEPLOY_SSH_OPTIONS))
		dest = (
			f"{target.user}@{target.host}:{remote_path}"
			if target.user
			else f"{target.host}:{remote_path}"
		)
		cmd.extend([str(local_path), dest])
		try:
			subprocess.run(cmd, check=True, capture_output=True, text=True)
		except subprocess.CalledProcessError as e:
			# SCP exit code 255 indicates connection failure
			if e.returncode == 255:
				raise SSHConnectionError(
					_format_ssh_connection_error(target.host or "", e.stderr)
				) from e
			raise
	else:
		dest = Path(remote_path)
		dest.parent.mkdir(parents=True, exist_ok=True)
		shutil.copy2(local_path, dest)


def appdeploy_exec_read(target: Target, remote_path: str) -> str:
	"""Read file from target (ssh cat for remote, Path.read_text for local)."""
	appdeploy_util_verbose(f"read {remote_path}")

	if target.is_remote:
		result = appdeploy_exec_run(
			target, f"cat {shlex.quote(remote_path)}", check=True
		)
		return result.stdout
	else:
		return Path(remote_path).read_text()


def appdeploy_exec_exists(target: Target, path: str) -> bool:
	"""Check if path exists on target."""
	appdeploy_util_verbose(f"exists? {path}")

	if target.is_remote:
		result = appdeploy_exec_run(target, f"test -e {shlex.quote(path)}", check=False)
		return result.returncode == 0
	else:
		return Path(path).exists()


def appdeploy_exec_mkdir(target: Target, path: str) -> None:
	"""Create directory on target (mkdir -p)."""
	appdeploy_util_verbose(f"mkdir -p {path}")

	if _dry_run:
		appdeploy_util_output(f"[dry-run] Would create directory {path}")
		return

	if target.is_remote:
		appdeploy_exec_run(target, f"mkdir -p {shlex.quote(path)}", check=True)
	else:
		Path(path).mkdir(parents=True, exist_ok=True)


def appdeploy_exec_rm(target: Target, path: str, recursive: bool = False) -> None:
	"""Remove file or directory on target."""
	appdeploy_util_verbose(f"rm {'-r ' if recursive else ''}{path}")

	if _dry_run:
		appdeploy_util_output(f"[dry-run] Would remove {path}")
		return

	if target.is_remote:
		if not appdeploy_exec_exists(target, path):
			return  # Nothing to remove
		# Make writable before deletion (handles read-only dist/ directories)
		if recursive:
			appdeploy_exec_run(target, f"chmod -R +w {shlex.quote(path)}", check=False)
		flag = "-rf" if recursive else "-f"
		appdeploy_exec_run(target, f"rm {flag} {shlex.quote(path)}", check=True)
	else:
		p = Path(path)
		if p.exists():
			if recursive and p.is_dir():
				# Make writable before deletion (handles read-only dist/ directories)
				for item in p.rglob("*"):
					try:
						item.chmod(item.stat().st_mode | stat.S_IWUSR)
					except OSError:
						pass
				try:
					p.chmod(p.stat().st_mode | stat.S_IWUSR)
				except OSError:
					pass
				shutil.rmtree(p)
			else:
				p.unlink()


def appdeploy_exec_symlink(target: Target, link_path: str, target_path: str) -> None:
	"""Create symlink on target."""
	appdeploy_util_verbose(f"symlink {link_path} -> {target_path}")

	if _dry_run:
		appdeploy_util_output(
			f"[dry-run] Would create symlink {link_path} -> {target_path}"
		)
		return

	if target.is_remote:
		appdeploy_exec_run(
			target,
			f"ln -sf {shlex.quote(target_path)} {shlex.quote(link_path)}",
			check=True,
		)
	else:
		link = Path(link_path)
		if link.exists() or link.is_symlink():
			link.unlink()
		link.symlink_to(target_path)


def appdeploy_exec_rename(target: Target, src: str, dst: str) -> None:
	"""Atomically rename file/directory on target."""
	appdeploy_util_verbose(f"rename {src} -> {dst}")

	if _dry_run:
		appdeploy_util_output(f"[dry-run] Would rename {src} to {dst}")
		return

	if target.is_remote:
		appdeploy_exec_run(
			target, f"mv {shlex.quote(src)} {shlex.quote(dst)}", check=True
		)
	else:
		Path(src).rename(dst)


# -----------------------------------------------------------------------------
#
# PACKAGE OPERATIONS
#
# -----------------------------------------------------------------------------


def appdeploy_package_resolve_name(
	path: Path, config: dict[str, Any], cli_name: Optional[str] = None
) -> str:
	"""Resolve package name: CLI -> conf.toml -> directory basename -> archive prefix."""
	if cli_name:
		return cli_name

	if config.get("package", {}).get("name"):
		return config["package"]["name"]

	if path.is_dir():
		return path.name

	# Archive: parse from filename
	name, _ = appdeploy_package_parse_archive(path.name)
	return name


def appdeploy_package_resolve_version(
	path: Path, config: dict[str, Any], cli_version: Optional[str] = None
) -> str:
	"""Resolve version: CLI -> conf.toml -> VERSION file -> git hash -> error."""
	if cli_version:
		return cli_version

	if config.get("package", {}).get("version"):
		return config["package"]["version"]

	if path.is_dir():
		version_file = path / "VERSION"
		if version_file.exists():
			return version_file.read_text().strip()

		# Try git hash
		try:
			result = subprocess.run(
				["git", "rev-parse", "--short", "HEAD"],
				cwd=path,
				capture_output=True,
				text=True,
				check=True,
			)
			return result.stdout.strip()
		except (subprocess.CalledProcessError, FileNotFoundError):
			pass

		raise ValueError(
			f"Cannot determine version for {path}. "
			"Use --release, add [package] version to conf.toml, or create VERSION file."
		)

	# Archive: parse from filename
	_, version = appdeploy_package_parse_archive(path.name)
	return version


def appdeploy_package_parse_archive(filename: str) -> tuple[str, str]:
	"""Parse name and version from archive filename.

	Split on first '-' followed by digit, or '-' followed by git hash (7+ hex chars).
	Examples:
	  my-app-2.0-rc1.tar.gz -> (my-app, 2.0-rc1)
	  littlenotes-c1b87d2.tar.bz2 -> (littlenotes, c1b87d2)
	"""
	# Remove known extensions
	base = filename
	for ext in (".tar.gz", ".tar.bz2", ".tar.xz", ".tgz"):
		if base.endswith(ext):
			base = base[: -len(ext)]
			break

	# Find first '-' followed by digit, or '-' followed by git hash (7+ hex chars)
	match = re.search(r"-(\d|[0-9a-f]{7,})", base)
	if not match:
		raise ValueError(f"Cannot parse name/version from archive: {filename}")

	split_pos = match.start()
	name = base[:split_pos]
	version = base[split_pos + 1 :]

	if not name:
		raise ValueError(f"Empty name in archive: {filename}")
	if not version:
		raise ValueError(f"Empty version in archive: {filename}")

	return name, version


def appdeploy_package_load_config(path: Path) -> dict[str, Any]:
	"""Load conf.toml from package path."""
	if path.is_dir():
		conf_file = path / "conf.toml"
	else:
		# Extract conf.toml from archive
		try:
			with tarfile.open(path, "r:*") as tar:
				for member in tar.getmembers():
					if member.name == "conf.toml" or member.name.endswith("/conf.toml"):
						f = tar.extractfile(member)
						if f:
							return tomllib.loads(f.read().decode("utf-8"))
		except Exception:
			pass
		return {}

	if conf_file.exists():
		return tomllib.loads(conf_file.read_text())
	return {}


def appdeploy_package_load(
	path: Path,
	cli_name: Optional[str] = None,
	cli_version: Optional[str] = None,
) -> Package:
	"""Load package from directory or archive path."""
	if not path.exists():
		raise FileNotFoundError(f"Package path not found: {path}")

	is_archive = not path.is_dir()
	config = appdeploy_package_load_config(path)
	name = appdeploy_package_resolve_name(path, config, cli_name)
	version = appdeploy_package_resolve_version(path, config, cli_version)

	return Package(
		name=name,
		version=version,
		path=path,
		is_archive=is_archive,
		config=config,
	)


def appdeploy_package_validate(pkg: Package, strict: bool = False) -> list[str]:
	"""Validate package structure. Returns list of errors/warnings.

	Checks:
	- run or run.sh exists and is executable
	- conf.toml is valid TOML (if present)
	- env.sh has valid shell syntax (if present)
	- No forbidden paths (.git/, __pycache__/, *.pyc, .env)
	"""
	errors: list[str] = []
	warnings: list[str] = []

	def check_dir(base: Path) -> None:
		# Check for run script
		run_script = None
		for name in ("run", "run.sh"):
			script = base / name
			if script.exists():
				run_script = script
				break

		if not run_script:
			errors.append("Missing required 'run' or 'run.sh' script")
		elif not os.access(run_script, os.X_OK):
			errors.append(f"'{run_script.name}' is not executable")

		# Check conf.toml
		conf_file = base / "conf.toml"
		if conf_file.exists():
			try:
				tomllib.loads(conf_file.read_text())
			except tomllib.TOMLDecodeError as e:
				errors.append(f"Invalid conf.toml: {e}")

		# Check env.sh syntax
		env_file = base / "env.sh"
		if env_file.exists():
			result = subprocess.run(
				["sh", "-n", str(env_file)],
				capture_output=True,
				text=True,
			)
			if result.returncode != 0:
				errors.append(
					f"Invalid shell syntax in env.sh: {result.stderr.strip()}"
				)

		# Check for forbidden paths
		forbidden_patterns = [".git", "__pycache__", ".env"]
		for item in base.rglob("*"):
			rel = item.relative_to(base)
			for pattern in forbidden_patterns:
				if pattern in str(rel):
					warnings.append(f"Forbidden path found: {rel}")
					break
			if item.suffix == ".pyc":
				warnings.append(f"Compiled Python file found: {rel}")

	if pkg.is_archive:
		# Extract to temp and validate
		with tempfile.TemporaryDirectory() as tmpdir:
			with tarfile.open(pkg.path, "r:*") as tar:
				tar.extractall(tmpdir)
			# Find the root directory
			extracted = list(Path(tmpdir).iterdir())
			if len(extracted) == 1 and extracted[0].is_dir():
				check_dir(extracted[0])
			else:
				check_dir(Path(tmpdir))
	else:
		check_dir(pkg.path)

	if strict:
		errors.extend(warnings)
		return errors

	for w in warnings:
		appdeploy_util_warn(w)

	return errors


def appdeploy_package_create(
	pkg: Package,
	output: Optional[Path] = None,
	compression: str = "gz",
	exclude: Optional[list[str]] = None,
) -> Path:
	"""Create archive from package directory."""
	if pkg.is_archive:
		raise ValueError("Cannot create archive from archive")

	exclude = exclude or []
	default_excludes = [".git", "__pycache__", "*.pyc", ".env", ".DS_Store"]
	all_excludes = set(exclude + default_excludes)

	# Determine output path
	ext_map = {"gz": ".tar.gz", "bz2": ".tar.bz2", "xz": ".tar.xz"}
	ext = ext_map.get(compression, ".tar.gz")
	if output is None:
		output = Path.cwd() / f"{pkg.name}-{pkg.version}{ext}"

	mode_map = {"gz": "w:gz", "bz2": "w:bz2", "xz": "w:xz"}
	mode = mode_map.get(compression, "w:gz")

	appdeploy_util_verbose(f"Creating archive: {output}")

	if _dry_run:
		appdeploy_util_output(f"[dry-run] Would create archive: {output}")
		return output

	def exclude_filter(tarinfo: tarfile.TarInfo) -> Optional[tarfile.TarInfo]:
		name = tarinfo.name
		for pattern in all_excludes:
			if pattern.startswith("*"):
				if name.endswith(pattern[1:]):
					return None
			elif pattern in name:
				return None
		return tarinfo

	with tarfile.open(output, mode) as tar:
		for item in pkg.path.iterdir():
			tar.add(item, arcname=item.name, filter=exclude_filter)

	return output


# -----------------------------------------------------------------------------
#
# TARGET OPERATIONS
#
# -----------------------------------------------------------------------------


def _compute_file_checksum(path: Path, algorithm: str = "sha256") -> str:
	"""Compute checksum of a local file."""
	h = hashlib.new(algorithm)
	with open(path, "rb") as f:
		for chunk in iter(lambda: f.read(8192), b""):
			h.update(chunk)
	return h.hexdigest()


def _get_remote_checksum(target: Target, path: str) -> tuple[Optional[str], str]:
	"""Get checksum of a remote file.

	Returns (checksum, algorithm) or (None, "") if file doesn't exist.
	Tries sha256sum, then openssl sha256, then md5sum.
	"""
	# Try sha256sum first
	result = appdeploy_exec_run(
		target,
		f"sha256sum {shlex.quote(path)} 2>/dev/null",
		check=False,
	)
	if result.returncode == 0 and result.stdout:
		return result.stdout.split()[0], "sha256"

	# Try openssl sha256
	result = appdeploy_exec_run(
		target,
		f"openssl sha256 {shlex.quote(path)} 2>/dev/null",
		check=False,
	)
	if result.returncode == 0 and result.stdout:
		# openssl output: "SHA256(filename)= hexdigest"
		match = re.search(r"=\s*([a-fA-F0-9]+)", result.stdout)
		if match:
			return match.group(1).lower(), "sha256"

	# Try md5sum as last resort
	result = appdeploy_exec_run(
		target,
		f"md5sum {shlex.quote(path)} 2>/dev/null",
		check=False,
	)
	if result.returncode == 0 and result.stdout:
		return result.stdout.split()[0], "md5"

	return None, ""


def appdeploy_target_bootstrap(
	target: Target,
	force: bool = False,
	check_only: bool = False,
	upgrade: bool = False,
	tools_path: Optional[Path] = None,
) -> bool:
	"""Install/upgrade tools on target.

	Installs daemonctl, daemonrun, teelog to ${TARGET}/bin/
	Returns True if tools are up-to-date.
	"""
	bin_dir = str(target.path / "bin")

	# Determine tool sources
	if tools_path:
		daemonctl_src = tools_path / "daemonctl"
		daemonrun_src = tools_path / "daemonrun"
		teelog_src = tools_path / "teelog"
	else:
		daemonctl_src = BUNDLED_DAEMONCTL
		daemonrun_src = BUNDLED_DAEMONRUN
		teelog_src = BUNDLED_TEELOG

	tools = [
		("daemonctl", daemonctl_src),
		("daemonrun", daemonrun_src),
		("teelog", teelog_src),
	]

	# Verify bundled tools exist
	for name, src in tools:
		if not src.exists():
			appdeploy_util_error(f"Bundled tool not found: {src}")
			return False

	# Check which tools need updating (missing or checksum mismatch)
	tools_to_update = []
	with appdeploy_util_delayed_status("Checking tools"):
		for name, src in tools:
			tool_path = f"{bin_dir}/{name}"
			remote_checksum, algorithm = _get_remote_checksum(target, tool_path)

			if remote_checksum is None:
				appdeploy_util_verbose(f"Tool missing: {name}")
				tools_to_update.append((name, src))
			elif force or upgrade:
				appdeploy_util_verbose(f"Tool force update: {name}")
				tools_to_update.append((name, src))
			else:
				local_checksum = _compute_file_checksum(src, algorithm)
				if local_checksum != remote_checksum:
					appdeploy_util_verbose(f"Tool outdated: {name}")
					tools_to_update.append((name, src))
				else:
					appdeploy_util_verbose(f"Tool up-to-date: {name}")

	if not tools_to_update:
		appdeploy_util_verbose("All tools up-to-date")
		return True

	if check_only:
		return False

	# Install/update only tools that need it
	appdeploy_util_log_op(f"Updating tools in {bin_dir}")
	appdeploy_exec_mkdir(target, bin_dir)

	for name, src in tools_to_update:
		tool_path = f"{bin_dir}/{name}"
		appdeploy_util_verbose(f"Installing {name}")
		appdeploy_exec_copy(target, src, tool_path)
		appdeploy_exec_run(target, f"chmod +x {shlex.quote(tool_path)}", check=True)

	return True


def appdeploy_target_install(
	target: Target,
	pkg: Package,
	activate: bool = False,
	keep: int = APPDEPLOY_KEEP_VERSIONS,
) -> None:
	"""Upload and unpack archive to target."""
	app_dir = str(target.path / pkg.name)
	packages_dir = f"{app_dir}/packages"
	dist_dir = f"{app_dir}/dist"
	version_dir = f"{dist_dir}/{pkg.version}"

	# Ensure directories exist
	appdeploy_exec_mkdir(target, packages_dir)
	appdeploy_exec_mkdir(target, dist_dir)

	# Create archive if needed
	if not pkg.is_archive:
		appdeploy_util_log_op(f"Packaging {pkg.name}")
		with tempfile.TemporaryDirectory() as tmpdir:
			archive_path = Path(tmpdir) / f"{pkg.name}-{pkg.version}.tar.gz"
			appdeploy_package_create(pkg, archive_path)
			pkg = Package(
				name=pkg.name,
				version=pkg.version,
				path=archive_path,
				is_archive=True,
				config=pkg.config,
			)
			_do_install(target, pkg, packages_dir, version_dir)
	else:
		_do_install(target, pkg, packages_dir, version_dir)

	# Activate if requested
	if activate:
		appdeploy_target_activate(target, pkg.name, pkg.version)

	# Clean old versions
	if keep > 0:
		appdeploy_target_clean(target, pkg.name, keep)


def _do_install(
	target: Target, pkg: Package, packages_dir: str, version_dir: str
) -> None:
	"""Internal: perform actual install of archive."""
	archive_name = pkg.path.name
	remote_archive = f"{packages_dir}/{archive_name}"

	# Upload archive
	appdeploy_util_log_op(f"Uploading {archive_name}")
	appdeploy_exec_copy(target, pkg.path, remote_archive)

	# Extract to version directory
	appdeploy_util_log_op(f"Extracting to {version_dir}")
	appdeploy_exec_mkdir(target, version_dir)

	# Determine tar flags based on compression
	if archive_name.endswith(".tar.gz") or archive_name.endswith(".tgz"):
		tar_flag = "z"
	elif archive_name.endswith(".tar.bz2"):
		tar_flag = "j"
	elif archive_name.endswith(".tar.xz"):
		tar_flag = "J"
	else:
		tar_flag = ""

	appdeploy_exec_run(
		target,
		f"tar -x{tar_flag}f {shlex.quote(remote_archive)} -C {shlex.quote(version_dir)} --strip-components=0",
		check=True,
	)


def appdeploy_target_uninstall(
	target: Target,
	name: str,
	version: Optional[str] = None,
	all_versions: bool = False,
	keep_data: bool = False,
	keep_logs: bool = False,
) -> None:
	"""Remove installed version(s)."""
	app_dir = str(target.path / name)

	if all_versions:
		# Check not active
		run_dir = f"{app_dir}/run"
		if appdeploy_exec_exists(target, f"{run_dir}/.version"):
			raise RuntimeError(
				f"Cannot uninstall {name}: app is active. Deactivate first."
			)

		# Remove everything except optionally data/logs
		if keep_data or keep_logs:
			for subdir in ["packages", "dist", "run"]:
				appdeploy_exec_rm(target, f"{app_dir}/{subdir}", recursive=True)
			if not keep_data:
				appdeploy_exec_rm(target, f"{app_dir}/data", recursive=True)
				appdeploy_exec_rm(target, f"{app_dir}/conf", recursive=True)
			if not keep_logs:
				appdeploy_exec_rm(target, f"{app_dir}/logs", recursive=True)
		else:
			appdeploy_exec_rm(target, app_dir, recursive=True)
		return

	if not version:
		raise ValueError("Version required for uninstall (or use --all)")

	# Check if this version is active
	run_dir = f"{app_dir}/run"
	if appdeploy_exec_exists(target, f"{run_dir}/.version"):
		active_version = appdeploy_exec_read(target, f"{run_dir}/.version").strip()
		if active_version == version:
			raise RuntimeError(
				f"Cannot uninstall {name}:{version}: version is active. Deactivate first."
			)

	# Remove specific version
	version_dir = f"{app_dir}/dist/{version}"
	appdeploy_exec_rm(target, version_dir, recursive=True)

	# Remove archive
	for ext in [".tar.gz", ".tar.bz2", ".tar.xz"]:
		archive = f"{app_dir}/packages/{name}-{version}{ext}"
		if appdeploy_exec_exists(target, archive):
			appdeploy_exec_rm(target, archive)


def appdeploy_target_activate(
	target: Target,
	name: str,
	version: Optional[str] = None,
	no_restart: bool = False,
) -> None:
	"""Set active version (atomic symlink creation)."""
	app_dir = str(target.path / name)
	dist_dir = f"{app_dir}/dist"
	run_dir = f"{app_dir}/run"
	run_new = f"{app_dir}/run.new"
	run_old = f"{app_dir}/run.old"

	# Resolve version if not specified (most recent)
	if not version:
		version = _get_latest_version(target, name)
		if not version:
			raise ValueError(f"No versions installed for {name}")

	version_dir = f"{dist_dir}/{version}"
	if not appdeploy_exec_exists(target, version_dir):
		raise ValueError(f"Version {version} not found for {name}")

	# Check if already active
	was_running = False
	if appdeploy_exec_exists(target, f"{run_dir}/.version"):
		current = appdeploy_exec_read(target, f"{run_dir}/.version").strip()
		if current == version:
			appdeploy_util_log_op(
				f"{name}:{version} is already active", version=version
			)
			return
		# Check if running
		was_running = appdeploy_exec_exists(target, f"{run_dir}/.pid")

	appdeploy_util_log_op(f"Activating {name}", version=version)

	# Create run.new with layer symlinks
	appdeploy_exec_rm(target, run_new, recursive=True)
	appdeploy_exec_mkdir(target, run_new)
	appdeploy_target_populate_run(target, name, version, run_new)

	# Write version file
	if target.is_remote:
		appdeploy_exec_run(
			target,
			f"echo {shlex.quote(version)} > {shlex.quote(run_new + '/.version')}",
			check=True,
		)
	else:
		(Path(run_new) / ".version").write_text(version)

	# Atomic swap
	if appdeploy_exec_exists(target, run_dir):
		appdeploy_exec_rename(target, run_dir, run_old)

	appdeploy_exec_rename(target, run_new, run_dir)
	appdeploy_exec_rm(target, run_old, recursive=True)

	appdeploy_util_log_op(f"Activated {name}", version=version)

	# Restart if was running
	if was_running and not no_restart:
		appdeploy_daemon_restart(target, name)


def appdeploy_target_deactivate(target: Target, name: str) -> None:
	"""Remove active symlinks."""
	app_dir = str(target.path / name)
	run_dir = f"{app_dir}/run"

	# Check if running
	if appdeploy_exec_exists(target, f"{run_dir}/.pid"):
		raise RuntimeError(f"Cannot deactivate {name}: app is running. Stop it first.")

	# Get version for logging
	version = None
	if appdeploy_exec_exists(target, f"{run_dir}/.version"):
		version = appdeploy_exec_read(target, f"{run_dir}/.version").strip()
	else:
		appdeploy_util_log_op(f"{name} is not active")
		return

	appdeploy_exec_rm(target, run_dir, recursive=True)
	appdeploy_util_log_op(f"Deactivated {name}", version=version)


def appdeploy_target_populate_run(
	target: Target, name: str, version: str, run_dir: str
) -> None:
	"""Populate run/ directory with layer symlinks.

	Layer order (last wins): dist/ -> data/ -> conf/ -> logs symlink
	"""
	app_dir = str(target.path / name)
	dist_dir = f"{app_dir}/dist/{version}"
	data_dir = f"{app_dir}/data"
	conf_dir = f"{app_dir}/conf"
	logs_dir = f"{app_dir}/logs"

	# Ensure logs directory exists
	appdeploy_exec_mkdir(target, logs_dir)

	# Helper to list directory entries
	def list_entries(path: str) -> list[str]:
		if not appdeploy_exec_exists(target, path):
			return []
		result = appdeploy_exec_run(target, f"ls -1 {shlex.quote(path)}", check=False)
		if result.returncode != 0:
			return []
		return [e for e in result.stdout.strip().split("\n") if e]

	# Layer 1: dist (symlinks)
	for entry in list_entries(dist_dir):
		src = f"../dist/{version}/{entry}"
		dst = f"{run_dir}/{entry}"
		appdeploy_exec_symlink(target, dst, src)

	# Layer 2: data (symlinks to preserve write capability)
	for entry in list_entries(data_dir):
		dst = f"{run_dir}/{entry}"
		# Remove existing if present
		if appdeploy_exec_exists(target, dst):
			appdeploy_exec_rm(target, dst, recursive=False)
		src = f"../data/{entry}"
		appdeploy_exec_symlink(target, dst, src)

	# Layer 3: conf (symlinks, highest priority)
	for entry in list_entries(conf_dir):
		dst = f"{run_dir}/{entry}"
		if appdeploy_exec_exists(target, dst):
			appdeploy_exec_rm(target, dst, recursive=False)
		src = f"../conf/{entry}"
		appdeploy_exec_symlink(target, dst, src)

	# Always add logs symlink
	appdeploy_exec_symlink(target, f"{run_dir}/logs", "../logs")


def appdeploy_target_list(
	target: Target,
	name: Optional[str] = None,
	long_format: bool = False,
	active_only: bool = False,
	json_format: bool = False,
) -> list[InstalledVersion]:
	"""List installed packages/versions.

	The name parameter supports glob patterns (*, ?, [seq]).
	"""
	results: list[InstalledVersion] = []

	# Check if name contains glob pattern characters
	has_glob = name and any(c in name for c in "*?[")

	# List app directories
	if name and not has_glob:
		# Exact name match - use directly
		app_names = [name]
	else:
		# List all apps, then optionally filter by glob pattern
		result = appdeploy_exec_run(
			target, f"ls -1 {shlex.quote(str(target.path))}", check=False
		)
		if result.returncode != 0:
			return results
		app_names = [
			n
			for n in result.stdout.strip().split("\n")
			if n
			and n != "bin"
			and appdeploy_exec_exists(target, str(target.path / n / "dist"))
		]
		# Apply glob filter if pattern was given
		if has_glob and name:
			app_names = fnmatch.filter(app_names, name)

	for app_name in app_names:
		app_dir = str(target.path / app_name)
		dist_dir = f"{app_dir}/dist"
		run_dir = f"{app_dir}/run"

		# Get active version
		active_version = None
		if appdeploy_exec_exists(target, f"{run_dir}/.version"):
			active_version = appdeploy_exec_read(target, f"{run_dir}/.version").strip()

		# List versions
		result = appdeploy_exec_run(
			target, f"ls -1 {shlex.quote(dist_dir)}", check=False
		)
		if result.returncode != 0:
			continue

		versions = [v for v in result.stdout.strip().split("\n") if v]

		for ver in versions:
			status = "active" if ver == active_version else "inactive"
			if active_only and status != "active":
				continue

			# Get install time and size if long format
			installed = ""
			size = 0
			if long_format:
				ver_dir = f"{dist_dir}/{ver}"
				result = appdeploy_exec_run(
					target,
					f"stat -c '%Y' {shlex.quote(ver_dir)} 2>/dev/null || stat -f '%m' {shlex.quote(ver_dir)}",
					check=False,
				)
				if result.returncode == 0:
					try:
						ts = int(result.stdout.strip())
						installed = datetime.fromtimestamp(ts).isoformat()
					except ValueError:
						pass

				result = appdeploy_exec_run(
					target,
					f"du -sb {shlex.quote(ver_dir)} 2>/dev/null || du -sk {shlex.quote(ver_dir)}",
					check=False,
				)
				if result.returncode == 0:
					try:
						size = int(result.stdout.split()[0])
					except (ValueError, IndexError):
						pass

			results.append(
				InstalledVersion(
					name=app_name,
					version=ver,
					status=status,
					installed=installed,
					size=size,
				)
			)

	return results


def appdeploy_target_clean(
	target: Target, name: str, keep: int = APPDEPLOY_KEEP_VERSIONS
) -> list[str]:
	"""Remove old inactive versions. Returns list of removed versions."""
	if keep <= 0:
		return []

	app_dir = str(target.path / name)
	dist_dir = f"{app_dir}/dist"
	run_dir = f"{app_dir}/run"

	# Get active version
	active_version = None
	if appdeploy_exec_exists(target, f"{run_dir}/.version"):
		active_version = appdeploy_exec_read(target, f"{run_dir}/.version").strip()

	# List versions by mtime
	result = appdeploy_exec_run(
		target,
		f"ls -1t {shlex.quote(dist_dir)}",
		check=False,
	)
	if result.returncode != 0:
		return []

	versions = [v for v in result.stdout.strip().split("\n") if v]
	removed: list[str] = []

	# Keep the most recent `keep` versions, plus the active version
	kept = 0
	for ver in versions:
		if ver == active_version:
			continue  # Always keep active
		if kept < keep:
			kept += 1
			continue
		# Remove this version
		ver_dir = f"{dist_dir}/{ver}"
		appdeploy_exec_rm(target, ver_dir, recursive=True)
		# Also remove archive
		for ext in [".tar.gz", ".tar.bz2", ".tar.xz"]:
			archive = f"{app_dir}/packages/{name}-{ver}{ext}"
			if appdeploy_exec_exists(target, archive):
				appdeploy_exec_rm(target, archive)
		removed.append(ver)
		appdeploy_util_verbose(f"Removed {name}:{ver}")

	return removed


def _get_latest_version(target: Target, name: str) -> Optional[str]:
	"""Get the most recently installed version for an app."""
	dist_dir = str(target.path / name / "dist")
	result = appdeploy_exec_run(target, f"ls -1t {shlex.quote(dist_dir)}", check=False)
	if result.returncode != 0:
		return None
	versions = [v for v in result.stdout.strip().split("\n") if v]
	return versions[0] if versions else None


def _get_previous_version(target: Target, name: str) -> Optional[str]:
	"""Get the second most recently installed version for an app."""
	dist_dir = str(target.path / name / "dist")
	result = appdeploy_exec_run(target, f"ls -1t {shlex.quote(dist_dir)}", check=False)
	if result.returncode != 0:
		return None
	versions = [v for v in result.stdout.strip().split("\n") if v]
	return versions[1] if len(versions) > 1 else None


# -----------------------------------------------------------------------------
#
# DAEMON OPERATIONS
#
# -----------------------------------------------------------------------------


def _daemonctl_cmd(target: Target, name: str) -> str:
	"""Build daemonctl command prefix."""
	bin_dir = str(target.path / "bin")
	app_base = str(target.path)
	return f"DAEMONCTL_PATH={shlex.quote(app_base)} {bin_dir}/daemonctl"


def appdeploy_daemon_start(
	target: Target,
	name: str,
	attach: bool = False,
	wait: bool = False,
	timeout: int = 60,
	verbose: bool = False,
) -> None:
	"""Start daemon via daemonctl."""
	cmd = f"{_daemonctl_cmd(target, name)} start {shlex.quote(name)}"
	if wait:
		cmd += " --wait"
	if timeout:
		cmd += f" --timeout {timeout}"
	if verbose:
		cmd += " --verbose"

	app_dir = str(target.path / name)
	run_dir = f"{app_dir}/run"
	version = None
	if appdeploy_exec_exists(target, f"{run_dir}/.version"):
		version = appdeploy_exec_read(target, f"{run_dir}/.version").strip()

	appdeploy_util_log_op(f"Starting {name}", version=version)
	result = appdeploy_exec_run(target, cmd, check=False, timeout=timeout + 10)

	if result.returncode != 0:
		appdeploy_util_error(f"Failed to start {name}")
		if result.stderr:
			print(result.stderr, file=sys.stderr)
		raise RuntimeError(f"Start failed with code {result.returncode}")

	if result.stdout:
		print(result.stdout, end="")

	if attach:
		appdeploy_daemon_logs(target, name, follow=True)


def appdeploy_daemon_stop(
	target: Target,
	name: str,
	signal_name: str = "TERM",
	force: bool = False,
	timeout: int = 30,
	wait: bool = False,
) -> None:
	"""Stop daemon via daemonctl."""
	cmd = f"{_daemonctl_cmd(target, name)} stop {shlex.quote(name)}"
	cmd += f" --signal {signal_name}"
	cmd += f" --timeout {timeout}"
	if force:
		cmd += " --force"
	if wait:
		cmd += " --wait"

	# Get version for logging
	app_dir = str(target.path / name)
	run_dir = f"{app_dir}/run"
	version = None
	if appdeploy_exec_exists(target, f"{run_dir}/.version"):
		version = appdeploy_exec_read(target, f"{run_dir}/.version").strip()

	appdeploy_util_log_op(f"Stopping {name}", version=version)
	result = appdeploy_exec_run(target, cmd, check=False, timeout=timeout + 10)

	if result.returncode != 0:
		appdeploy_util_error(f"Failed to stop {name}")
		if result.stderr:
			print(result.stderr, file=sys.stderr)
		raise RuntimeError(f"Stop failed with code {result.returncode}")

	if result.stdout:
		print(result.stdout, end="")


def appdeploy_daemon_restart(
	target: Target,
	name: str,
	force: bool = False,
	wait: bool = False,
	stop_timeout: int = 30,
	start_timeout: int = 60,
	delay: int = 0,
	verbose: bool = False,
) -> None:
	"""Restart daemon via daemonctl."""
	cmd = f"{_daemonctl_cmd(target, name)} restart {shlex.quote(name)}"
	cmd += f" --stop-timeout {stop_timeout}"
	cmd += f" --start-timeout {start_timeout}"
	if force:
		cmd += " --force"
	if wait:
		cmd += " --wait"
	if delay:
		cmd += f" --delay {delay}"
	if verbose:
		cmd += " --verbose"

	# Get version for logging
	app_dir = str(target.path / name)
	run_dir = f"{app_dir}/run"
	version = None
	if appdeploy_exec_exists(target, f"{run_dir}/.version"):
		version = appdeploy_exec_read(target, f"{run_dir}/.version").strip()

	appdeploy_util_log_op(f"Restarting {name}", version=version)
	total_timeout = stop_timeout + start_timeout + delay + 10
	result = appdeploy_exec_run(target, cmd, check=False, timeout=total_timeout)

	if result.returncode != 0:
		appdeploy_util_error(f"Failed to restart {name}")
		if result.stderr:
			print(result.stderr, file=sys.stderr)
		raise RuntimeError(f"Restart failed with code {result.returncode}")

	if result.stdout:
		print(result.stdout, end="")


def appdeploy_daemon_status(
	target: Target,
	name: Optional[str] = None,
	long_format: bool = False,
	json_format: bool = False,
) -> dict[str, Any]:
	"""Get daemon status via daemonctl."""
	cmd = f"{_daemonctl_cmd(target, name or '')} status"
	if name:
		cmd += f" {shlex.quote(name)}"
	if long_format:
		cmd += " --long"
	if json_format:
		cmd += " --json"

	result = appdeploy_exec_run(target, cmd, check=False)

	if json_format and result.returncode == 0:
		try:
			return json.loads(result.stdout)
		except json.JSONDecodeError:
			pass

	if result.stdout:
		print(result.stdout, end="")

	return {"returncode": result.returncode}


def appdeploy_daemon_logs(
	target: Target,
	name: str,
	follow: bool = False,
	lines: int = 50,
	stream: str = "all",
	since: Optional[str] = None,
	until: Optional[str] = None,
	grep: Optional[str] = None,
) -> None:
	"""Show logs (streams output)."""
	cmd = f"{_daemonctl_cmd(target, name)} logs {shlex.quote(name)}"
	cmd += f" --lines {lines}"

	if stream == "stdout":
		cmd += " --stdout"
	elif stream == "stderr":
		cmd += " --stderr"
	elif stream == "ops":
		cmd += " --ops"
	elif stream == "all":
		cmd += " --all"

	if since:
		cmd += f" --since {shlex.quote(since)}"
	if until:
		cmd += f" --until {shlex.quote(until)}"
	if grep:
		cmd += f" --grep {shlex.quote(grep)}"
	if follow:
		cmd += " --follow"

	if follow:
		# Stream output for follow mode
		if target.is_remote:
			ssh_cmd = appdeploy_exec_ssh_cmd(target) + [cmd]
			try:
				subprocess.run(ssh_cmd)
			except KeyboardInterrupt:
				pass
		else:
			try:
				subprocess.run(["sh", "-c", cmd])
			except KeyboardInterrupt:
				pass
	else:
		result = appdeploy_exec_run(target, cmd, check=False, timeout=0)
		if result.stdout:
			print(result.stdout, end="")
		if result.stderr:
			print(result.stderr, end="", file=sys.stderr)


def appdeploy_daemon_kill(
	target: Target,
	name: str,
	signal_name: str = "TERM",
	all_processes: bool = False,
	wait: bool = False,
	timeout: int = 30,
) -> None:
	"""Send signal to daemon."""
	cmd = f"{_daemonctl_cmd(target, name)} kill {shlex.quote(name)} {signal_name}"
	if all_processes:
		cmd += " --all"
	if wait:
		cmd += " --wait"
		cmd += f" --timeout {timeout}"

	result = appdeploy_exec_run(
		target, cmd, check=False, timeout=timeout + 10 if wait else _op_timeout
	)

	if result.returncode != 0:
		appdeploy_util_error(f"Failed to send signal to {name}")
		if result.stderr:
			print(result.stderr, file=sys.stderr)
		raise RuntimeError(f"Kill failed with code {result.returncode}")

	if result.stdout:
		print(result.stdout, end="")


# -----------------------------------------------------------------------------
#
# HIGH-LEVEL COMMANDS
#
# -----------------------------------------------------------------------------


def appdeploy_health_check(
	target: Target,
	name: str,
	timeout: int = 60,
	grace: int = 5,
) -> bool:
	"""Run health check.

	If check.sh exists: poll every 2s until exit 0 or timeout
	Otherwise: verify process still running after grace period
	"""
	app_dir = str(target.path / name)
	run_dir = f"{app_dir}/run"
	check_script = f"{run_dir}/check.sh"
	check_script_alt = f"{run_dir}/check"

	has_check = appdeploy_exec_exists(target, check_script) or appdeploy_exec_exists(
		target, check_script_alt
	)

	start_time = datetime.now()
	deadline = start_time + timedelta(seconds=timeout)

	if has_check:
		# Poll check script
		check_cmd = (
			check_script
			if appdeploy_exec_exists(target, check_script)
			else check_script_alt
		)
		while datetime.now() < deadline:
			result = appdeploy_exec_run(
				target,
				f"cd {shlex.quote(run_dir)} && {shlex.quote(check_cmd)}",
				check=False,
				timeout=10,
			)
			if result.returncode == 0:
				appdeploy_util_log_op("Health check passed")
				return True
			appdeploy_util_verbose(f"Health check failed, retrying...")
			import time

			time.sleep(2)

		appdeploy_util_error("Health check timed out")
		return False
	else:
		# Just check process is still running after grace period
		appdeploy_util_verbose(f"No check script, waiting {grace}s grace period...")
		import time

		time.sleep(grace)

		pid_file = f"{run_dir}/.pid"
		if not appdeploy_exec_exists(target, pid_file):
			appdeploy_util_error("Process died during grace period")
			return False

		appdeploy_util_log_op("Process still running after grace period")
		return True


def appdeploy_cmd_upgrade(
	target: Target,
	pkg: Package,
	keep: int = APPDEPLOY_KEEP_VERSIONS,
	rollback_on_fail: bool = True,
	health_timeout: int = 60,
	startup_grace: int = 5,
) -> bool:
	"""Atomic upgrade with health check and rollback.

	1. Install new version
	2. Record current active version (for rollback)
	3. Stop current (if running)
	4. Activate new version
	5. Start new version
	6. Health check
	7. On failure: rollback to previous
	"""
	app_dir = str(target.path / pkg.name)
	run_dir = f"{app_dir}/run"

	# Get current state
	previous_version = None
	was_running = False
	if appdeploy_exec_exists(target, f"{run_dir}/.version"):
		previous_version = appdeploy_exec_read(target, f"{run_dir}/.version").strip()
	if appdeploy_exec_exists(target, f"{run_dir}/.pid"):
		was_running = True

	appdeploy_util_log_op(f"Upgrading {pkg.name} to {pkg.version}", version=pkg.version)

	# 1. Install new version
	appdeploy_target_install(target, pkg, activate=False, keep=keep)

	# 2. Stop current if running
	if was_running:
		try:
			appdeploy_daemon_stop(target, pkg.name, timeout=30, wait=True)
		except RuntimeError:
			appdeploy_util_warn("Failed to stop gracefully, continuing...")

	# 3. Activate new version
	appdeploy_target_activate(target, pkg.name, pkg.version, no_restart=True)

	# 4. Start new version
	try:
		appdeploy_daemon_start(target, pkg.name, wait=True, timeout=startup_grace)
	except RuntimeError as e:
		appdeploy_util_error(f"Failed to start: {e}")
		if rollback_on_fail and previous_version:
			appdeploy_util_log_op(
				f"Rolling back to {previous_version}", version=previous_version
			)
			appdeploy_target_activate(
				target, pkg.name, previous_version, no_restart=True
			)
			if was_running:
				appdeploy_daemon_start(target, pkg.name)
		return False

	# 5. Health check
	if not appdeploy_health_check(target, pkg.name, health_timeout, startup_grace):
		if rollback_on_fail and previous_version:
			appdeploy_util_log_op(
				f"Rolling back to {previous_version}", version=previous_version
			)
			appdeploy_daemon_stop(target, pkg.name, force=True)
			appdeploy_target_activate(
				target, pkg.name, previous_version, no_restart=True
			)
			if was_running:
				appdeploy_daemon_start(target, pkg.name)
			appdeploy_util_log_op(
				f"Rolled back to {previous_version}", version=previous_version
			)
		return False

	appdeploy_util_log_op(f"Upgrade to {pkg.version} successful", version=pkg.version)
	return True


def appdeploy_cmd_rollback(
	target: Target,
	name: str,
	to_version: Optional[str] = None,
	no_restart: bool = False,
) -> None:
	"""Rollback to previous (or specified) version."""
	if not to_version:
		to_version = _get_previous_version(target, name)
		if not to_version:
			raise ValueError(f"No previous version available for {name}")

	app_dir = str(target.path / name)
	run_dir = f"{app_dir}/run"

	was_running = appdeploy_exec_exists(target, f"{run_dir}/.pid")

	appdeploy_util_log_op(f"Rolling back {name} to {to_version}", version=to_version)

	if was_running:
		appdeploy_daemon_stop(target, name, force=True)

	appdeploy_target_activate(target, name, to_version, no_restart=True)

	if was_running and not no_restart:
		appdeploy_daemon_start(target, name)

	appdeploy_util_log_op(f"Rolled back to {to_version}", version=to_version)


def appdeploy_cmd_run_local(
	pkg: Package,
	keep_temp: bool = False,
	timeout: int = 0,
	env: Optional[dict[str, str]] = None,
	chdir: Optional[Path] = None,
	no_layers: bool = False,
	data_dir: Optional[Path] = None,
	conf_dir: Optional[Path] = None,
) -> int:
	"""Run package in simulated deployment environment."""
	env = env or {}

	if no_layers:
		# Run directly in package directory
		run_dir = pkg.path if not pkg.is_archive else None
		if pkg.is_archive:
			# Extract to temp
			tmpdir = tempfile.mkdtemp(prefix="appdeploy-run-")
			with tarfile.open(pkg.path, "r:*") as tar:
				tar.extractall(tmpdir)
			run_dir = Path(tmpdir)
			# Handle single directory in archive
			contents = list(run_dir.iterdir())
			if len(contents) == 1 and contents[0].is_dir():
				run_dir = contents[0]
	else:
		# Create simulated layer structure
		tmpdir = tempfile.mkdtemp(prefix="appdeploy-run-")
		base = Path(tmpdir)

		dist_dir = base / "dist" / "current"
		sim_data_dir = base / "data"
		sim_conf_dir = base / "conf"
		sim_run_dir = base / "run"
		sim_logs_dir = base / "logs"

		dist_dir.mkdir(parents=True)
		sim_data_dir.mkdir()
		sim_conf_dir.mkdir()
		sim_run_dir.mkdir()
		sim_logs_dir.mkdir()

		# Unpack/copy package to dist
		if pkg.is_archive:
			with tarfile.open(pkg.path, "r:*") as tar:
				tar.extractall(dist_dir)
			# Handle single directory
			contents = list(dist_dir.iterdir())
			if len(contents) == 1 and contents[0].is_dir():
				for item in contents[0].iterdir():
					shutil.move(str(item), str(dist_dir / item.name))
				contents[0].rmdir()
		else:
			for item in pkg.path.iterdir():
				if item.is_dir():
					shutil.copytree(item, dist_dir / item.name)
				else:
					shutil.copy2(item, dist_dir / item.name)

		# Copy data layer
		if data_dir and data_dir.exists():
			for item in data_dir.iterdir():
				if item.is_dir():
					shutil.copytree(item, sim_data_dir / item.name)
				else:
					shutil.copy2(item, sim_data_dir / item.name)

		# Copy conf layer
		if conf_dir and conf_dir.exists():
			for item in conf_dir.iterdir():
				if item.is_dir():
					shutil.copytree(item, sim_conf_dir / item.name)
				else:
					shutil.copy2(item, sim_conf_dir / item.name)

		# Populate run directory with layers
		# Layer 1: dist
		for item in dist_dir.iterdir():
			(sim_run_dir / item.name).symlink_to(f"../dist/current/{item.name}")

		# Layer 2: data (overwrite)
		for item in sim_data_dir.iterdir():
			link = sim_run_dir / item.name
			if link.exists() or link.is_symlink():
				link.unlink()
			link.symlink_to(f"../data/{item.name}")

		# Layer 3: conf (overwrite)
		for item in sim_conf_dir.iterdir():
			link = sim_run_dir / item.name
			if link.exists() or link.is_symlink():
				link.unlink()
			link.symlink_to(f"../conf/{item.name}")

		# logs symlink
		(sim_run_dir / "logs").symlink_to("../logs")

		run_dir = sim_run_dir

	# Find run script
	run_script = None
	for name in ("run", "run.sh"):
		script = run_dir / name
		if script.exists():
			run_script = script
			break

	if not run_script:
		appdeploy_util_error("No run script found")
		return 1

	# Build environment
	run_env = os.environ.copy()
	run_env.update(env)

	# Execute
	appdeploy_util_output(f"Running {pkg.name} from {run_dir}...")

	try:
		result = subprocess.run(
			[str(run_script)],
			cwd=chdir or run_dir,
			env=run_env,
			timeout=timeout if timeout > 0 else None,
		)
		return result.returncode
	except KeyboardInterrupt:
		return 130
	except subprocess.TimeoutExpired:
		appdeploy_util_error(f"Timeout after {timeout}s")
		return 1
	finally:
		if not keep_temp and not no_layers:
			shutil.rmtree(tmpdir, ignore_errors=True)


# -----------------------------------------------------------------------------
#
# CLI IMPLEMENTATION
#
# -----------------------------------------------------------------------------


class AppDeployArgumentParser(argparse.ArgumentParser):
	"""ArgumentParser with improved error messages."""

	def error(self, message: str) -> NoReturn:
		"""Print error with available commands."""
		self.print_usage(sys.stderr)

		commands = [
			"check",
			"package",
			"run",
			"install",
			"uninstall",
			"activate",
			"deactivate",
			"list",
			"upgrade",
			"rollback",
			"clean",
			"bootstrap",
			"start",
			"stop",
			"restart",
			"status",
			"logs",
			"show",
			"kill",
		]

		sys.stderr.write(f"\n{self.prog}: error: {message}\n")
		sys.stderr.write(f"\nAvailable commands: {', '.join(commands)}\n")
		sys.stderr.write(
			f"Run '{self.prog} COMMAND --help' for command-specific help.\n"
		)
		sys.exit(2)


def appdeploy_build_parser() -> argparse.ArgumentParser:
	"""Build argument parser with all subcommands."""
	parser = AppDeployArgumentParser(
		prog="appdeploy",
		description="Package, deploy, and manage applications on local/remote targets",
	)

	# Global options
	parser.add_argument(
		"-t",
		"--target",
		default=APPDEPLOY_TARGET,
		help=f"Target specification (default: {APPDEPLOY_TARGET})",
	)
	parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
	parser.add_argument(
		"-q", "--quiet", action="store_true", help="Suppress non-error output"
	)
	parser.add_argument(
		"-n", "--dry-run", action="store_true", help="Show what would be done"
	)
	parser.add_argument(
		"-y", "--yes", action="store_true", help="Skip confirmation prompts"
	)
	parser.add_argument("-f", "--force", action="store_true", help="Force operation")
	parser.add_argument(
		"-T",
		"--op-timeout",
		type=int,
		default=APPDEPLOY_OP_TIMEOUT,
		help=f"Operation timeout in seconds (default: {APPDEPLOY_OP_TIMEOUT})",
	)
	parser.add_argument("--local", action="store_true", help="Force local target")
	parser.add_argument("--remote", action="store_true", help="Force remote target")
	parser.add_argument(
		"--no-color", action="store_true", help="Disable colored output"
	)
	parser.add_argument("--version", action="store_true", help="Show version")
	parser.add_argument(
		"--tool-versions", action="store_true", help="Show bundled tool versions"
	)

	subparsers = parser.add_subparsers(dest="command", metavar="COMMAND")

	# --- Package Commands ---

	# check
	p_check = subparsers.add_parser("check", help="Validate package structure")
	p_check.add_argument("package", help="Package path or archive")
	p_check.add_argument("--strict", action="store_true", help="Fail on warnings")

	# package
	p_package = subparsers.add_parser(
		"package", help="Create archive from package directory"
	)
	p_package.add_argument("package_path", help="Package directory")
	p_package.add_argument("output", nargs="?", help="Output path")
	p_package.add_argument("-n", "--name", help="Override package name")
	p_package.add_argument("-r", "--release", help="Override package version")
	p_package.add_argument(
		"-c",
		"--compression",
		choices=["gz", "bz2", "xz"],
		default="gz",
		help="Compression type (default: gz)",
	)
	p_package.add_argument(
		"--exclude",
		action="append",
		default=[],
		help="Exclude glob pattern (repeatable)",
	)
	p_package.add_argument("--no-check", action="store_true", help="Skip validation")

	# run
	p_run = subparsers.add_parser("run", help="Run package locally")
	p_run.add_argument("package", help="Package path or archive")
	p_run.add_argument("-k", "--keep", action="store_true", help="Keep temp directory")
	p_run.add_argument("--timeout", type=int, default=0, help="Kill after timeout")
	p_run.add_argument(
		"-e", "--env", action="append", default=[], help="Set environment variable"
	)
	p_run.add_argument("--env-file", help="Load environment from file")
	p_run.add_argument("-C", "--chdir", help="Working directory")
	p_run.add_argument(
		"--no-layers", action="store_true", help="Run without simulating layers"
	)
	p_run.add_argument("--data", help="Data layer directory")
	p_run.add_argument("--conf", help="Conf layer directory")

	# --- Deployment Commands ---

	# install
	p_install = subparsers.add_parser(
		"install", help="Upload and unpack archive to target"
	)
	p_install.add_argument("package", help="Package path or archive")
	p_install.add_argument("-n", "--name", help="Override package name")
	p_install.add_argument("-r", "--release", help="Override package version")
	p_install.add_argument(
		"--activate", action="store_true", help="Activate after install"
	)
	p_install.add_argument(
		"--keep",
		type=int,
		default=APPDEPLOY_KEEP_VERSIONS,
		help=f"Keep N versions (default: {APPDEPLOY_KEEP_VERSIONS})",
	)
	p_install.add_argument("--checksum", help="Verify archive checksum")

	# uninstall
	p_uninstall = subparsers.add_parser("uninstall", help="Remove installed version")
	p_uninstall.add_argument("package", help="Package name")
	p_uninstall.add_argument("version", nargs="?", help="Version (or use name:version)")
	p_uninstall.add_argument("--all", action="store_true", help="Remove all versions")
	p_uninstall.add_argument(
		"--keep-data", action="store_true", help="Preserve data/conf"
	)
	p_uninstall.add_argument("--keep-logs", action="store_true", help="Preserve logs")

	# activate
	p_activate = subparsers.add_parser("activate", help="Set active version")
	p_activate.add_argument("package", help="Package name")
	p_activate.add_argument("version", nargs="?", help="Version (or use name:version)")
	p_activate.add_argument(
		"--no-restart", action="store_true", help="Don't restart if running"
	)

	# deactivate
	p_deactivate = subparsers.add_parser("deactivate", help="Remove active symlinks")
	p_deactivate.add_argument("package", help="Package name")

	# list
	p_list = subparsers.add_parser("list", help="List installed packages/versions")
	p_list.add_argument("package", nargs="?", help="Package name")
	p_list.add_argument("-l", "--long", action="store_true", help="Detailed output")
	p_list.add_argument(
		"--active-only", action="store_true", help="Show only active versions"
	)
	p_list.add_argument("--json", action="store_true", help="JSON output")

	# upgrade
	p_upgrade = subparsers.add_parser("upgrade", help="Atomic upgrade with rollback")
	p_upgrade.add_argument("package", help="Package path or archive")
	p_upgrade.add_argument("-n", "--name", help="Override package name")
	p_upgrade.add_argument("-r", "--release", help="Override package version")
	p_upgrade.add_argument(
		"--no-restart", action="store_true", help="Don't restart after activate"
	)
	p_upgrade.add_argument(
		"--keep",
		type=int,
		default=APPDEPLOY_KEEP_VERSIONS,
		help=f"Keep N versions (default: {APPDEPLOY_KEEP_VERSIONS})",
	)
	p_upgrade.add_argument(
		"--no-rollback-on-fail",
		action="store_true",
		help="Disable automatic rollback",
	)
	p_upgrade.add_argument(
		"--health-timeout",
		type=int,
		default=60,
		help="Health check timeout (default: 60)",
	)
	p_upgrade.add_argument(
		"--startup-grace",
		type=int,
		default=5,
		help="Startup grace period (default: 5)",
	)

	# rollback
	p_rollback = subparsers.add_parser("rollback", help="Rollback to previous version")
	p_rollback.add_argument("package", help="Package name")
	p_rollback.add_argument(
		"--to", dest="to_version", help="Specific version to rollback to"
	)
	p_rollback.add_argument(
		"--no-restart", action="store_true", help="Don't restart after rollback"
	)

	# clean
	p_clean = subparsers.add_parser("clean", help="Remove old inactive versions")
	p_clean.add_argument("package", help="Package name")
	p_clean.add_argument(
		"--keep",
		type=int,
		default=APPDEPLOY_KEEP_VERSIONS,
		help=f"Keep N versions (default: {APPDEPLOY_KEEP_VERSIONS})",
	)

	# bootstrap
	p_bootstrap = subparsers.add_parser(
		"bootstrap", help="Install/update tools on target"
	)
	p_bootstrap.add_argument(
		"--check", action="store_true", help="Check only, don't install"
	)
	p_bootstrap.add_argument(
		"--upgrade", action="store_true", help="Upgrade if newer available"
	)
	p_bootstrap.add_argument("--tools-path", help="Use tools from this path")

	# --- Runtime Commands ---

	# start
	p_start = subparsers.add_parser("start", help="Start the active version")
	p_start.add_argument("package", help="Package name[:version]")
	p_start.add_argument("-a", "--attach", action="store_true", help="Attach to output")
	p_start.add_argument("-w", "--wait", action="store_true", help="Wait for startup")
	p_start.add_argument(
		"-v", "--verbose", action="store_true", help="Verbose startup output"
	)
	p_start.add_argument(
		"--start-timeout", type=int, default=60, help="Startup timeout"
	)

	# stop
	p_stop = subparsers.add_parser("stop", help="Stop running application")
	p_stop.add_argument("package", help="Package name[:version]")
	p_stop.add_argument("-s", "--signal", default="TERM", help="Signal to send")
	p_stop.add_argument("-t", "--timeout", type=int, default=30, help="Stop timeout")
	p_stop.add_argument("-w", "--wait", action="store_true", help="Wait for full exit")

	# restart
	p_restart = subparsers.add_parser("restart", help="Restart running application")
	p_restart.add_argument("package", help="Package name[:version]")
	p_restart.add_argument(
		"-w", "--wait", action="store_true", help="Wait for stop before start"
	)
	p_restart.add_argument(
		"-v", "--verbose", action="store_true", help="Verbose startup output"
	)
	p_restart.add_argument(
		"--stop-timeout", type=int, default=30, help="Stop phase timeout"
	)
	p_restart.add_argument(
		"--start-timeout", type=int, default=60, help="Start phase timeout"
	)
	p_restart.add_argument(
		"--delay", type=int, default=0, help="Delay between stop and start"
	)

	# status
	p_status = subparsers.add_parser("status", help="Show application status")
	p_status.add_argument("package", nargs="?", help="Package name")
	p_status.add_argument("-l", "--long", action="store_true", help="Detailed status")
	p_status.add_argument(
		"-w", "--watch", action="store_true", help="Watch continuously"
	)
	p_status.add_argument(
		"--refresh", type=int, default=2, help="Watch refresh interval"
	)
	p_status.add_argument(
		"-p", "--processes", action="store_true", help="Show process tree"
	)
	p_status.add_argument(
		"--health", action="store_true", help="Show health check status"
	)
	p_status.add_argument("--json", action="store_true", help="JSON output")

	# logs
	p_logs = subparsers.add_parser("logs", help="Show application logs")
	p_logs.add_argument("package", help="Package name")
	p_logs.add_argument("-f", "--follow", action="store_true", help="Follow log output")
	p_logs.add_argument("-n", "--lines", type=int, default=50, help="Number of lines")
	p_logs.add_argument("--stdout", action="store_true", help="Stdout log only")
	p_logs.add_argument("--stderr", action="store_true", help="Stderr log only")
	p_logs.add_argument("--ops", action="store_true", help="Operations log only")
	p_logs.add_argument("--all", action="store_true", help="All logs interleaved")
	p_logs.add_argument("--since", help="Logs since time")
	p_logs.add_argument("--until", help="Logs until time")
	p_logs.add_argument("--level", help="Filter by log level")
	p_logs.add_argument("--grep", help="Filter lines matching pattern")
	p_logs.add_argument(
		"-T", "--no-timestamps", action="store_true", help="Hide timestamps"
	)
	p_logs.add_argument("--tail", action="store_true", help="Start from end")
	p_logs.add_argument("--head", action="store_true", help="Start from beginning")

	# show
	p_show = subparsers.add_parser(
		"show", help="Show package contents and configuration"
	)
	p_show.add_argument("package", help="Package name")
	p_show.add_argument("version", nargs="?", help="Version (or use name:version)")
	p_show.add_argument("--files", action="store_true", help="List all files")
	p_show.add_argument("--config", action="store_true", help="Show conf.toml")
	p_show.add_argument("--run", action="store_true", help="Show run script")
	p_show.add_argument("--tree", action="store_true", help="Show directory tree")

	# kill
	p_kill = subparsers.add_parser("kill", help="Send signal to running application")
	p_kill.add_argument("package", help="Package name")
	p_kill.add_argument("signal", nargs="?", default="TERM", help="Signal to send")
	p_kill.add_argument(
		"-a", "--all-processes", action="store_true", help="Send to all processes"
	)
	p_kill.add_argument(
		"-w", "--wait", action="store_true", help="Wait for signal processing"
	)
	p_kill.add_argument("--timeout", type=int, default=30, help="Wait timeout")

	return parser


def _parse_package_version(pkg_str: str) -> tuple[str, Optional[str]]:
	"""Parse package[:version] string."""
	if ":" in pkg_str:
		name, version = pkg_str.rsplit(":", 1)
		return name, version
	return pkg_str, None


# --- Command Handlers ---


def appdeploy_cmd_handler_check(args: argparse.Namespace) -> int:
	"""Handle 'check' command."""
	path = Path(args.package)
	try:
		pkg = appdeploy_package_load(path)
		errors = appdeploy_package_validate(pkg, strict=args.strict)
		if errors:
			for err in errors:
				appdeploy_util_error(err)
			return 1
		appdeploy_util_output(f"Package {pkg.name}:{pkg.version} is valid")
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_package(args: argparse.Namespace) -> int:
	"""Handle 'package' command."""
	path = Path(args.package_path)
	try:
		pkg = appdeploy_package_load(path, args.name, args.release)

		if not args.no_check:
			errors = appdeploy_package_validate(pkg)
			if errors:
				for err in errors:
					appdeploy_util_error(err)
				return 1

		output = Path(args.output) if args.output else None
		archive = appdeploy_package_create(
			pkg,
			output=output,
			compression=args.compression,
			exclude=args.exclude,
		)
		appdeploy_util_output(f"Created {archive}")
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_run(args: argparse.Namespace) -> int:
	"""Handle 'run' command."""
	path = Path(args.package)
	try:
		pkg = appdeploy_package_load(path)

		# Parse environment variables
		env = {}
		for e in args.env:
			if "=" in e:
				k, v = e.split("=", 1)
				env[k] = v

		# Load env file
		if args.env_file:
			env_file = Path(args.env_file)
			if env_file.exists():
				for line in env_file.read_text().splitlines():
					line = line.strip()
					if line and not line.startswith("#") and "=" in line:
						k, v = line.split("=", 1)
						env[k.strip()] = v.strip()

		return appdeploy_cmd_run_local(
			pkg,
			keep_temp=args.keep,
			timeout=args.timeout,
			env=env,
			chdir=Path(args.chdir) if args.chdir else None,
			no_layers=args.no_layers,
			data_dir=Path(args.data) if args.data else None,
			conf_dir=Path(args.conf) if args.conf else None,
		)
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_install(args: argparse.Namespace) -> int:
	"""Handle 'install' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		# Auto-bootstrap
		appdeploy_target_bootstrap(target)

		path = Path(args.package)
		pkg = appdeploy_package_load(path, args.name, args.release)

		appdeploy_target_install(
			target,
			pkg,
			activate=args.activate,
			keep=args.keep,
		)
		appdeploy_util_log_op(f"Installed {pkg.name}:{pkg.version}")
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_uninstall(args: argparse.Namespace) -> int:
	"""Handle 'uninstall' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		# Support both "package version" and "package:version" syntax
		name, version = _parse_package_version(args.package)
		if args.version:
			if version:
				raise ValueError(
					"Version specified twice (both in package:version and as argument)"
				)
			version = args.version

		pkg_display = f"{name}:{version}" if version else name
		if not appdeploy_util_confirm(f"Uninstall {pkg_display}?"):
			return 3

		appdeploy_target_uninstall(
			target,
			name,
			version=version,
			all_versions=args.all,
			keep_data=args.keep_data,
			keep_logs=args.keep_logs,
		)
		appdeploy_util_log_op(f"Uninstalled {pkg_display}")
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_activate(args: argparse.Namespace) -> int:
	"""Handle 'activate' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		# Support both "package version" and "package:version" syntax
		name, version = _parse_package_version(args.package)
		if args.version:
			if version:
				raise ValueError(
					"Version specified twice (both in package:version and as argument)"
				)
			version = args.version
		appdeploy_target_activate(target, name, version, no_restart=args.no_restart)
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_deactivate(args: argparse.Namespace) -> int:
	"""Handle 'deactivate' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		if not appdeploy_util_confirm(f"Deactivate {args.package}?"):
			return 3

		appdeploy_target_deactivate(target, args.package)
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_list(args: argparse.Namespace) -> int:
	"""Handle 'list' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		versions = appdeploy_target_list(
			target,
			name=args.package,
			long_format=args.long,
			active_only=args.active_only,
			json_format=args.json,
		)

		if args.json:
			print(json.dumps([dataclasses.asdict(v) for v in versions], indent=2))
		else:
			if not versions:
				appdeploy_util_output("No packages installed")
			else:
				# Header
				if args.long:
					print(
						f"{'NAME':<20} {'VERSION':<15} {'STATUS':<10} {'INSTALLED':<20} {'SIZE':<10}"
					)
				else:
					print(f"{'NAME':<20} {'VERSION':<15} {'STATUS':<10}")

				for v in versions:
					status_color = "green" if v.status == "active" else ""
					status = (
						appdeploy_util_color(v.status, status_color)
						if status_color
						else v.status
					)
					if args.long:
						size = appdeploy_util_format_size(v.size)
						print(
							f"{v.name:<20} {v.version:<15} {status:<10} {v.installed:<20} {size:<10}"
						)
					else:
						print(f"{v.name:<20} {v.version:<15} {status:<10}")
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_upgrade(args: argparse.Namespace) -> int:
	"""Handle 'upgrade' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		if not appdeploy_util_confirm(f"Upgrade from {args.package}?"):
			return 3

		# Auto-bootstrap
		appdeploy_target_bootstrap(target)

		path = Path(args.package)
		pkg = appdeploy_package_load(path, args.name, args.release)

		success = appdeploy_cmd_upgrade(
			target,
			pkg,
			keep=args.keep,
			rollback_on_fail=not args.no_rollback_on_fail,
			health_timeout=args.health_timeout,
			startup_grace=args.startup_grace,
		)
		return 0 if success else 1
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_rollback(args: argparse.Namespace) -> int:
	"""Handle 'rollback' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		if not appdeploy_util_confirm(f"Rollback {args.package}?"):
			return 3

		appdeploy_cmd_rollback(
			target,
			args.package,
			to_version=args.to_version,
			no_restart=args.no_restart,
		)
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_clean(args: argparse.Namespace) -> int:
	"""Handle 'clean' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		if not appdeploy_util_confirm(f"Clean old versions of {args.package}?"):
			return 3

		removed = appdeploy_target_clean(target, args.package, keep=args.keep)
		if removed:
			appdeploy_util_log_op(f"Removed {len(removed)} old version(s)")
		else:
			appdeploy_util_log_op("Nothing to clean")
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_bootstrap(args: argparse.Namespace) -> int:
	"""Handle 'bootstrap' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		tools_path = Path(args.tools_path) if args.tools_path else None

		if args.check:
			ok = appdeploy_target_bootstrap(
				target, check_only=True, tools_path=tools_path
			)
			if ok:
				appdeploy_util_log_op("Tools are installed")
				return 0
			else:
				appdeploy_util_log_op("Tools are missing or outdated")
				return 1

		ok = appdeploy_target_bootstrap(
			target,
			force=getattr(args, "force", False),
			upgrade=args.upgrade,
			tools_path=tools_path,
		)
		return 0 if ok else 1
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_start(args: argparse.Namespace) -> int:
	"""Handle 'start' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		# Parse package:version and auto-activate if version specified
		name, version = _parse_package_version(args.package)

		# Auto-bootstrap (ensures tools are up-to-date)
		appdeploy_target_bootstrap(target)

		# If version specified, ensure it's activated
		if version:
			appdeploy_target_activate(target, name, version, no_restart=True)

		appdeploy_daemon_start(
			target,
			name,
			attach=args.attach,
			wait=args.wait,
			timeout=args.start_timeout,
			verbose=getattr(args, "verbose", False),
		)
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_stop(args: argparse.Namespace) -> int:
	"""Handle 'stop' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		# Parse package:version and auto-activate if version specified
		name, version = _parse_package_version(args.package)

		# If version specified, ensure it's activated first
		if version:
			appdeploy_target_activate(target, name, version, no_restart=True)

		if not appdeploy_util_confirm(f"Stop {name}?"):
			return 3

		appdeploy_daemon_stop(
			target,
			name,
			signal_name=args.signal,
			force=getattr(args, "force", False),
			timeout=args.timeout,
			wait=args.wait,
		)
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_restart(args: argparse.Namespace) -> int:
	"""Handle 'restart' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		# Parse package:version and auto-activate if version specified
		name, version = _parse_package_version(args.package)

		# If version specified, ensure it's activated first
		if version:
			appdeploy_target_activate(target, name, version, no_restart=True)

		if not appdeploy_util_confirm(f"Restart {name}?"):
			return 3

		appdeploy_daemon_restart(
			target,
			name,
			force=getattr(args, "force", False),
			wait=args.wait,
			stop_timeout=args.stop_timeout,
			start_timeout=args.start_timeout,
			delay=args.delay,
			verbose=getattr(args, "verbose", False),
		)
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def _appdeploy_get_app_runtime_info(target: Target, app_name: str) -> dict[str, Any]:
	"""Get runtime info for an app: PID, running state, memory, log file mtimes."""
	app_dir = str(target.path / app_name)
	run_dir = f"{app_dir}/run"

	info: dict[str, Any] = {
		"running": False,
		"state": "stopped",
		"pid": None,
		"memory": None,
		"started": None,
		"log_mtime": None,
		"err_mtime": None,
	}

	# Check PID file and if process is running
	pid_file = f"{run_dir}/.pid"
	result = appdeploy_exec_run(
		target, f"cat {shlex.quote(pid_file)} 2>/dev/null", check=False
	)
	if result.returncode == 0 and result.stdout.strip():
		pid = result.stdout.strip()
		# Check if process is running
		check_result = appdeploy_exec_run(
			target, f"kill -0 {pid} 2>/dev/null", check=False
		)
		if check_result.returncode == 0:
			info["running"] = True
			info["state"] = "running"
			info["pid"] = int(pid)

			# Get memory usage from /proc/{pid}/statm
			mem_result = appdeploy_exec_run(
				target,
				f"cat /proc/{pid}/statm 2>/dev/null",
				check=False,
			)
			if mem_result.returncode == 0 and mem_result.stdout.strip():
				try:
					statm = mem_result.stdout.strip().split()
					if len(statm) >= 2:
						# RSS is second field, in pages (typically 4096 bytes)
						rss_pages = int(statm[1])
						info["memory"] = rss_pages * 4096  # bytes
				except (ValueError, IndexError):
					pass

			# Get process start time from /proc/{pid}/stat field 21 and boot time
			start_result = appdeploy_exec_run(
				target,
				f"cat /proc/{pid}/stat /proc/stat 2>/dev/null",
				check=False,
			)
			if start_result.returncode == 0 and start_result.stdout.strip():
				try:
					lines = start_result.stdout.strip().split("\n")
					stat_fields = lines[0].split()
					# Field 21 (0-indexed) is starttime in clock ticks since boot
					if len(stat_fields) > 21:
						starttime_ticks = int(stat_fields[21])
						clk_tck = 100  # Standard on Linux
						# Find btime (boot time) from /proc/stat
						for line in lines[1:]:
							if line.startswith("btime "):
								btime = int(line.split()[1])
								info["started"] = btime + (starttime_ticks / clk_tck)
								break
				except (ValueError, IndexError):
					pass

	# Get log file modification times
	# Check logs/ subdir first (new location), then legacy locations for backward compat
	log_locations = [
		(f"{app_dir}/logs/{app_name}.log", f"{app_dir}/logs/{app_name}.err"),
		(f"{run_dir}/logs/{app_name}.log", f"{run_dir}/logs/{app_name}.err"),
		(f"{app_dir}/{app_name}.log", f"{app_dir}/{app_name}.err"),
		(f"{run_dir}/{app_name}.log", f"{run_dir}/{app_name}.err"),
	]

	for log_file, err_file in log_locations:
		# Only check if we haven't found logs yet
		if info["log_mtime"] is None:
			result = appdeploy_exec_run(
				target,
				f"stat -c '%Y' {shlex.quote(log_file)} 2>/dev/null || stat -f '%m' {shlex.quote(log_file)} 2>/dev/null",
				check=False,
			)
			if result.returncode == 0 and result.stdout.strip():
				try:
					info["log_mtime"] = float(result.stdout.strip())
				except ValueError:
					pass

		if info["err_mtime"] is None:
			result = appdeploy_exec_run(
				target,
				f"stat -c '%Y' {shlex.quote(err_file)} 2>/dev/null || stat -f '%m' {shlex.quote(err_file)} 2>/dev/null",
				check=False,
			)
			if result.returncode == 0 and result.stdout.strip():
				try:
					info["err_mtime"] = float(result.stdout.strip())
				except ValueError:
					pass

	return info


def _appdeploy_show_status(
	target: Target,
	package: Optional[str] = None,
	long_format: bool = False,
	json_format: bool = False,
) -> int:
	"""Display status table for apps."""
	import time

	# Get list of installed versions
	versions = appdeploy_target_list(target, name=package, long_format=long_format)

	if not versions:
		appdeploy_util_output("No packages installed")
		return 0

	# Group versions by app name and get runtime info for each app
	apps: dict[str, list[InstalledVersion]] = {}
	for v in versions:
		if v.name not in apps:
			apps[v.name] = []
		apps[v.name].append(v)

	# Get runtime info for each app
	runtime_info: dict[str, dict[str, Any]] = {}
	for app_name in apps:
		runtime_info[app_name] = _appdeploy_get_app_runtime_info(target, app_name)

	# Build output data
	rows: list[dict[str, Any]] = []
	for app_name, app_versions in apps.items():
		info = runtime_info[app_name]
		for v in app_versions:
			# Calculate memory in Mb if available
			mem_str = "-"
			if v.status == "active" and info.get("memory"):
				mem_mb = info["memory"] / (1024 * 1024)
				mem_str = f"{mem_mb:.0f}"

			row: dict[str, Any] = {
				"name": v.name,
				"version": v.version,
				"status": v.status,
				"state": info["state"] if v.status == "active" else "-",
				"pid": str(info["pid"])
				if v.status == "active" and info["pid"]
				else "-",
				"mem": mem_str,
				"started": (
					appdeploy_util_format_time_ago(info["started"])
					if v.status == "active" and info.get("started")
					else "-"
				),
				"log": (
					appdeploy_util_format_time_ago(info["log_mtime"])
					if v.status == "active" and info["log_mtime"]
					else "-"
				),
				"err": (
					appdeploy_util_format_time_ago(info["err_mtime"])
					if v.status == "active" and info["err_mtime"]
					else "-"
				),
			}
			if long_format:
				row["installed"] = v.installed
				row["size"] = v.size
			rows.append(row)

	if json_format:
		print(json.dumps(rows, indent=2))
		return 0

	# Print target info
	if target.host:
		if target.user:
			target_str = f"{target.user}@{target.host}:{target.path}"
		else:
			target_str = f"{target.host}:{target.path}"
	else:
		target_str = str(target.path)
	print(f"Target: {target_str}")
	print()

	# Print table header
	if long_format:
		print(
			f"{'NAME':<20} {'VERSION':<15} {'STATUS':<10} {'STATE':<10} {'PID':<8} {'MEM(Mb)':<8} {'STARTED':<10} {'LOG':<10} {'ERR':<10} {'INSTALLED':<20} {'SIZE':<10}"
		)
	else:
		print(
			f"{'NAME':<20} {'VERSION':<15} {'STATUS':<10} {'STATE':<10} {'PID':<8} {'MEM(Mb)':<8} {'STARTED':<10} {'LOG':<10} {'ERR':<10}"
		)

	# Print rows
	for row in rows:
		# Pad text first, then apply color to preserve alignment
		status_padded = f"{row['status']:<10}"
		state_padded = f"{row['state']:<10}"

		if row["status"] == "active":
			status_padded = appdeploy_util_color(status_padded, "blue")
		if row["state"] == "running":
			state_padded = appdeploy_util_color(state_padded, "green")
		elif row["state"] == "stopped":
			state_padded = appdeploy_util_color(state_padded, "red")

		if long_format:
			size_str = appdeploy_util_format_size(row["size"])
			print(
				f"{row['name']:<20} {row['version']:<15} {status_padded} {state_padded} {row['pid']:<8} {row['mem']:<8} {row['started']:<10} {row['log']:<10} {row['err']:<10} {row['installed']:<20} {size_str:<10}"
			)
		else:
			print(
				f"{row['name']:<20} {row['version']:<15} {status_padded} {state_padded} {row['pid']:<8} {row['mem']:<8} {row['started']:<10} {row['log']:<10} {row['err']:<10}"
			)

	return 0


def appdeploy_cmd_handler_status(args: argparse.Namespace) -> int:
	"""Handle 'status' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		if args.watch:
			import time

			try:
				while True:
					# Clear screen
					print("\033[2J\033[H", end="")
					_appdeploy_show_status(
						target,
						args.package,
						long_format=args.long,
						json_format=args.json,
					)
					time.sleep(args.refresh)
			except KeyboardInterrupt:
				return 0
		else:
			_appdeploy_show_status(
				target,
				args.package,
				long_format=args.long,
				json_format=args.json,
			)
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_logs(args: argparse.Namespace) -> int:
	"""Handle 'logs' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		# Determine stream: explicit flags take precedence, default is stdout only
		stream = "stdout"  # Default to stdout only
		if args.all:
			stream = "all"
		elif args.stdout:
			stream = "stdout"
		elif args.stderr:
			stream = "stderr"
		elif args.ops:
			stream = "ops"

		appdeploy_daemon_logs(
			target,
			args.package,
			follow=args.follow,
			lines=args.lines,
			stream=stream,
			since=args.since,
			until=args.until,
			grep=args.grep,
		)
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_show(args: argparse.Namespace) -> int:
	"""Handle 'show' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		# Support both "package version" and "package:version" syntax
		name, version = _parse_package_version(args.package)
		if args.version:
			if version:
				raise ValueError(
					"Version specified twice (both in package:version and as argument)"
				)
			version = args.version

		if not version:
			# Get active version
			run_dir = str(target.path / name / "run")
			if appdeploy_exec_exists(target, f"{run_dir}/.version"):
				version = appdeploy_exec_read(target, f"{run_dir}/.version").strip()
			else:
				version = _get_latest_version(target, name)

		if not version:
			appdeploy_util_error(f"No version found for {name}")
			return 1

		ver_dir = str(target.path / name / "dist" / version)

		if args.files or args.tree:
			result = appdeploy_exec_run(
				target,
				f"find {shlex.quote(ver_dir)} -type f"
				if args.files
				else f"ls -laR {shlex.quote(ver_dir)}",
				check=False,
			)
			print(result.stdout)
		elif args.config:
			conf_path = f"{ver_dir}/conf.toml"
			if appdeploy_exec_exists(target, conf_path):
				print(appdeploy_exec_read(target, conf_path))
			else:
				appdeploy_util_output("No conf.toml found")
		elif args.run:
			for script_name in ("run", "run.sh"):
				run_path = f"{ver_dir}/{script_name}"
				if appdeploy_exec_exists(target, run_path):
					print(appdeploy_exec_read(target, run_path))
					break
			else:
				appdeploy_util_output("No run script found")
		else:
			# Default: show summary
			appdeploy_util_output(f"Package: {name}")
			appdeploy_util_output(f"Version: {version}")
			appdeploy_util_output(f"Path: {ver_dir}")

			# Show run path and its contents
			run_dir = str(target.path / name / "run")
			appdeploy_util_output(f"Run path: {run_dir}")

			# List top-level contents of run directory
			result = appdeploy_exec_run(
				target, f"ls -la {shlex.quote(run_dir)}", check=False
			)
			if result.returncode == 0 and result.stdout.strip():
				appdeploy_util_output("\nRun directory contents:")
				print(result.stdout)

			# Show log file paths
			log_dir = str(target.path / name / "logs")
			appdeploy_util_output("Log files:")
			appdeploy_util_output(f"  Stdout: {log_dir}/{name}.log")
			appdeploy_util_output(f"  Stderr: {log_dir}/{name}.err")

			# Show config if exists
			conf_path = f"{ver_dir}/conf.toml"
			if appdeploy_exec_exists(target, conf_path):
				appdeploy_util_output("\nConfiguration:")
				print(appdeploy_exec_read(target, conf_path))

		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


def appdeploy_cmd_handler_kill(args: argparse.Namespace) -> int:
	"""Handle 'kill' command."""
	try:
		target = appdeploy_target_parse(
			args.target,
			force_local=getattr(args, "local", False),
			force_remote=getattr(args, "remote", False),
		)
		appdeploy_util_set_log_target(target)

		appdeploy_daemon_kill(
			target,
			args.package,
			signal_name=args.signal,
			all_processes=args.all_processes,
			wait=args.wait,
			timeout=args.timeout,
		)
		return 0
	except Exception as e:
		appdeploy_util_error(str(e))
		return 1


# --- Main Entry Point ---


def appdeploy_main() -> int:
	"""Main entry point."""
	global _verbose, _quiet, _no_color, _dry_run, _yes, _op_timeout

	parser = appdeploy_build_parser()
	args = parser.parse_args()

	# Handle --version
	if args.version:
		print(f"appdeploy {APPDEPLOY_VERSION}")
		return 0

	# Handle --tool-versions
	if args.tool_versions:
		print(f"appdeploy {APPDEPLOY_VERSION}")
		print(f"daemonctl: {BUNDLED_DAEMONCTL}")
		print(f"daemonrun: {BUNDLED_DAEMONRUN}")
		print(f"teelog: {BUNDLED_TEELOG}")
		return 0

	# Set globals from args
	_verbose = args.verbose
	_quiet = args.quiet
	_no_color = args.no_color or APPDEPLOY_NO_COLOR
	_dry_run = args.dry_run
	_yes = args.yes
	_op_timeout = args.op_timeout

	# No command - show help
	if not args.command:
		parser.print_help()
		return 0

	# Command dispatch
	handlers = {
		"check": appdeploy_cmd_handler_check,
		"package": appdeploy_cmd_handler_package,
		"run": appdeploy_cmd_handler_run,
		"install": appdeploy_cmd_handler_install,
		"uninstall": appdeploy_cmd_handler_uninstall,
		"activate": appdeploy_cmd_handler_activate,
		"deactivate": appdeploy_cmd_handler_deactivate,
		"list": appdeploy_cmd_handler_list,
		"upgrade": appdeploy_cmd_handler_upgrade,
		"rollback": appdeploy_cmd_handler_rollback,
		"clean": appdeploy_cmd_handler_clean,
		"bootstrap": appdeploy_cmd_handler_bootstrap,
		"start": appdeploy_cmd_handler_start,
		"stop": appdeploy_cmd_handler_stop,
		"restart": appdeploy_cmd_handler_restart,
		"status": appdeploy_cmd_handler_status,
		"logs": appdeploy_cmd_handler_logs,
		"show": appdeploy_cmd_handler_show,
		"kill": appdeploy_cmd_handler_kill,
	}

	handler = handlers.get(args.command)
	if not handler:
		appdeploy_util_error(f"Unknown command: {args.command}")
		return 1

	try:
		return handler(args)
	except KeyboardInterrupt:
		return 130


if __name__ == "__main__":
	sys.exit(appdeploy_main())

# EOF
