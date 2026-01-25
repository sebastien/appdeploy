#!/usr/bin/env python
# --
# File: daemonctl.py
#
# `daemonctl` is a daemon management wrapper around `daemonrun` and `teelog`.
# It provides convention-based app discovery, TOML configuration, process
# lifecycle management, and health monitoring.
#
# ## Usage
#
# >   daemonctl COMMAND [OPTIONS] [APP_NAME]
#
# ## App Directory Convention
#
# >   ${DAEMONCTL_PATH}/${APP_NAME}/run/
# >     [conf.toml]     - Optional configuration
# >     [env.sh]        - Optional environment script
# >     run[.sh]        - Runs the application (required)
# >     [check[.sh]]    - Health check script
# >     [on-start[.sh]] - Hook: after start
# >     [on-stop[.sh]]  - Hook: after stop

import argparse
import os
import re
import shutil
import signal
import subprocess
import sys
import time
import tomllib
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# -----------------------------------------------------------------------------
#
# CONFIGURATION
#
# -----------------------------------------------------------------------------

VERSION = "1.0.0"
DAEMONCTL_PATH = Path(os.environ.get("DAEMONCTL_PATH", os.getcwd()))
DAEMONCTL_CONFIG = os.environ.get("DAEMONCTL_CONFIG", "")
DAEMONCTL_LOG_LEVEL = os.environ.get("DAEMONCTL_LOG_LEVEL", "info")
DAEMONCTL_OP_TIMEOUT = int(os.environ.get("DAEMONCTL_OP_TIMEOUT", "30"))
DAEMONCTL_NO_COLOR = os.environ.get("DAEMONCTL_NO_COLOR", "") == "1"

# Tool paths - look in same directory as this script first
_SCRIPT_DIR = Path(__file__).parent.resolve()


def _find_tool(names: list[str], fallback: str) -> str:
	"""Find tool in script directory, trying multiple names."""
	for name in names:
		path = _SCRIPT_DIR / name
		if path.exists():
			return str(path)
	return fallback


DAEMONRUN_CMD = _find_tool(["daemonrun", "daemonrun.sh"], "daemonrun")
TEELOG_CMD = _find_tool(["teelog", "teelog.sh"], "teelog")

# Global runtime state
_verbose = False
_quiet = False
_no_color = DAEMONCTL_NO_COLOR
_dry_run = False
_op_timeout = DAEMONCTL_OP_TIMEOUT
_base_path = DAEMONCTL_PATH

# -----------------------------------------------------------------------------
#
# TYPES
#
# -----------------------------------------------------------------------------


@dataclass
class DaemonConfig:
	"""Daemon behavior settings."""

	name: str = ""
	description: str = ""
	enabled: bool = True
	foreground: bool = False
	double_fork: bool = True
	setsid: bool = True
	working_directory: str = ""
	umask: str = "022"


@dataclass
class ProcessConfig:
	"""Process execution settings."""

	command: str = ""
	args: list[str] = field(default_factory=list)
	environment: dict[str, str] = field(default_factory=dict)
	environment_file: str = ""
	clear_env: bool = False
	priority: int = 0
	restart: bool = False
	restart_delay: int = 5
	restart_max_attempts: int = 3
	start_timeout: int = 60
	stop_timeout: int = 30


@dataclass
class SecurityConfig:
	"""User/group and security settings."""

	user: str = ""
	group: str = ""
	capabilities_drop: list[str] = field(default_factory=list)
	capabilities_keep: list[str] = field(default_factory=list)


@dataclass
class LoggingConfig:
	"""Logging configuration."""

	file: str = ""
	level: str = "info"
	stdout_file: str = ""
	stderr_file: str = ""
	syslog: bool = False
	quiet: bool = False
	verbose: bool = False
	# Log rotation (teelog integration)
	max_size: str = ""  # e.g., "10M", "1G"
	max_age: str = ""  # e.g., "7d", "24h"
	max_count: int = 0  # Max rotated files to keep


@dataclass
class PIDFileConfig:
	"""PID file settings."""

	enabled: bool = True
	path: str = ""


@dataclass
class SignalsConfig:
	"""Signal handling configuration."""

	forward_all: bool = True
	forward_list: list[str] = field(default_factory=list)
	preserve_signals: list[str] = field(default_factory=list)
	kill_timeout: int = 30
	stop_signal: str = "TERM"
	reload_signal: str = "HUP"


@dataclass
class SandboxConfig:
	"""Sandbox/isolation configuration."""

	type: str = "none"  # none, firejail, unshare
	profile: str = ""
	private_tmp: bool = False
	private_dev: bool = False
	readonly_paths: list[str] = field(default_factory=list)
	no_network: bool = False
	seccomp: bool = False
	seccomp_profile: str = ""


@dataclass
class LimitsConfig:
	"""Resource limits configuration."""

	memory_limit: str = ""  # e.g., "512M"
	cpu_limit: int = 0  # 1-100
	file_limit: int = 0
	process_limit: int = 0
	core_limit: str = ""
	stack_limit: str = ""
	timeout: int = 0


@dataclass
class MonitoringConfig:
	"""Health monitoring configuration."""

	enabled: bool = False
	check_interval: int = 30  # seconds
	check_command: str = ""  # or use check[.sh] script
	check_timeout: int = 10  # seconds
	failure_threshold: int = 3  # failures before restart
	success_threshold: int = 1  # successes to mark healthy
	startup_delay: int = 60  # delay before first check


@dataclass
class AppConfig:
	"""Complete application configuration."""

	daemon: DaemonConfig = field(default_factory=DaemonConfig)
	process: ProcessConfig = field(default_factory=ProcessConfig)
	security: SecurityConfig = field(default_factory=SecurityConfig)
	logging: LoggingConfig = field(default_factory=LoggingConfig)
	pidfile: PIDFileConfig = field(default_factory=PIDFileConfig)
	signals: SignalsConfig = field(default_factory=SignalsConfig)
	sandbox: SandboxConfig = field(default_factory=SandboxConfig)
	limits: LimitsConfig = field(default_factory=LimitsConfig)
	monitoring: MonitoringConfig = field(default_factory=MonitoringConfig)


# -----------------------------------------------------------------------------
#
# UTILITIES
#
# -----------------------------------------------------------------------------

# =============================================================================
# Logging
# =============================================================================


# Function: daemonctl_util_log LEVEL MESSAGE
# Log message respecting verbose/quiet settings.
def daemonctl_util_log(level: str, msg: str) -> None:
	"""Log message respecting verbose/quiet settings."""
	levels = {"debug": 0, "info": 1, "warn": 2, "error": 3}
	level_num = levels.get(level, 1)
	if _quiet and level_num < 2:
		return
	if level == "debug" and not _verbose:
		return
	prefix = {"debug": "DBG", "info": "---", "warn": "WRN", "error": "ERR"}.get(
		level, "---"
	)
	color = {"debug": "dim", "info": "", "warn": "yellow", "error": "red"}.get(
		level, ""
	)
	line = f"{prefix} {msg}"
	if color:
		line = daemonctl_util_color(line, color)
	print(line, file=sys.stderr if level == "error" else sys.stdout)


# =============================================================================
# Colors
# =============================================================================


# Function: daemonctl_util_color TEXT COLOR
# Colorize text if colors enabled.
def daemonctl_util_color(text: str, color: str) -> str:
	"""Colorize text if colors enabled."""
	if _no_color or not sys.stdout.isatty():
		return text
	codes = {
		"red": "\033[31m",
		"green": "\033[32m",
		"yellow": "\033[33m",
		"blue": "\033[34m",
		"magenta": "\033[35m",
		"cyan": "\033[36m",
		"dim": "\033[2m",
		"bold": "\033[1m",
		"reset": "\033[0m",
	}
	return f"{codes.get(color, '')}{text}{codes['reset']}"


# =============================================================================
# Subprocess
# =============================================================================


# Function: daemonctl_util_run CMD TIMEOUT CAPTURE
# Run command with timeout, return (code, stdout, stderr).
def daemonctl_util_run(
	cmd: list[str], timeout: int = 30, capture: bool = True, env: Optional[dict] = None
) -> tuple[int, str, str]:
	"""Run command with timeout, return (code, stdout, stderr)."""
	if _dry_run:
		daemonctl_util_log("info", f"[dry-run] Would run: {' '.join(cmd)}")
		return 0, "", ""
	try:
		result = subprocess.run(
			cmd,
			capture_output=capture,
			text=True,
			timeout=timeout,
			env=env if env else None,
		)
		return result.returncode, result.stdout or "", result.stderr or ""
	except subprocess.TimeoutExpired:
		return -1, "", "Command timed out"
	except FileNotFoundError:
		return 127, "", f"Command not found: {cmd[0]}"
	except Exception as e:
		return 1, "", str(e)


# =============================================================================
# Parsing
# =============================================================================


# Function: daemonctl_util_parse_duration STRING
# Parse '5s', '30m', '1h', '7d' to seconds.
def daemonctl_util_parse_duration(s: str) -> int:
	"""Parse duration string to seconds."""
	if not s:
		return 0
	match = re.match(r"^(\d+)([smhd])?$", s.lower())
	if not match:
		raise ValueError(f"Invalid duration: {s}")
	num, unit = int(match.group(1)), match.group(2) or "s"
	multipliers = {"s": 1, "m": 60, "h": 3600, "d": 86400}
	return num * multipliers[unit]


# Function: daemonctl_util_parse_size STRING
# Parse '512M', '1G' to bytes.
def daemonctl_util_parse_size(s: str) -> int:
	"""Parse size string to bytes."""
	if not s:
		return 0
	match = re.match(r"^(\d+)([kmg])?b?$", s.lower())
	if not match:
		raise ValueError(f"Invalid size: {s}")
	num, unit = int(match.group(1)), match.group(2) or ""
	multipliers = {"": 1, "k": 1024, "m": 1024**2, "g": 1024**3}
	return num * multipliers[unit]


# Function: daemonctl_util_format_size BYTES
# Format bytes as human-readable size.
def daemonctl_util_format_size(n: int) -> str:
	"""Format bytes as human-readable size."""
	size = float(n)
	for unit in ["B", "K", "M", "G"]:
		if size < 1024:
			return f"{size:.0f}{unit}" if unit == "B" else f"{size:.1f}{unit}"
		size /= 1024
	return f"{size:.1f}T"


# -----------------------------------------------------------------------------
#
# CONFIG
#
# -----------------------------------------------------------------------------


# Function: daemonctl_config_load APP_NAME
# Load and merge config: defaults + conf.toml + env vars.
def daemonctl_config_load(app_name: str) -> AppConfig:
	"""Load configuration for an app."""
	config = AppConfig()
	config.daemon.name = app_name

	# Load from conf.toml if exists
	conf_path = daemonctl_app_path(app_name) / "conf.toml"
	if conf_path.exists():
		try:
			with open(conf_path, "rb") as f:
				data = tomllib.load(f)
			config = daemonctl_config_from_dict(data, config)
		except Exception as e:
			daemonctl_util_log("warn", f"Failed to load {conf_path}: {e}")

	# Apply environment overrides
	config = daemonctl_config_from_env(app_name, config)

	# Set default PID file path if not specified
	if not config.pidfile.path:
		config.pidfile.path = f"/tmp/{app_name}.pid"

	return config


# Function: daemonctl_config_from_dict DATA CONFIG
# Apply TOML data to config object.
def daemonctl_config_from_dict(data: dict, config: AppConfig) -> AppConfig:
	"""Apply dictionary data to config object."""
	if "daemon" in data:
		d = data["daemon"]
		if "name" in d:
			config.daemon.name = d["name"]
		if "description" in d:
			config.daemon.description = d["description"]
		if "enabled" in d:
			config.daemon.enabled = d["enabled"]
		if "foreground" in d:
			config.daemon.foreground = d["foreground"]
		if "double_fork" in d:
			config.daemon.double_fork = d["double_fork"]
		if "setsid" in d:
			config.daemon.setsid = d["setsid"]
		if "working_directory" in d:
			config.daemon.working_directory = d["working_directory"]
		if "umask" in d:
			config.daemon.umask = str(d["umask"])

	if "process" in data:
		p = data["process"]
		if "command" in p:
			config.process.command = p["command"]
		if "args" in p:
			config.process.args = list(p["args"])
		if "environment" in p:
			config.process.environment = dict(p["environment"])
		if "environment_file" in p:
			config.process.environment_file = p["environment_file"]
		if "clear_env" in p:
			config.process.clear_env = p["clear_env"]
		if "priority" in p:
			config.process.priority = p["priority"]
		if "restart" in p:
			config.process.restart = p["restart"]
		if "restart_delay" in p:
			config.process.restart_delay = p["restart_delay"]
		if "restart_max_attempts" in p:
			config.process.restart_max_attempts = p["restart_max_attempts"]
		if "start_timeout" in p:
			config.process.start_timeout = p["start_timeout"]
		if "stop_timeout" in p:
			config.process.stop_timeout = p["stop_timeout"]

	if "security" in data:
		s = data["security"]
		if "user" in s:
			config.security.user = s["user"]
		if "group" in s:
			config.security.group = s["group"]
		if "capabilities_drop" in s:
			config.security.capabilities_drop = list(s["capabilities_drop"])
		if "capabilities_keep" in s:
			config.security.capabilities_keep = list(s["capabilities_keep"])

	if "logging" in data:
		l = data["logging"]
		if "file" in l:
			config.logging.file = l["file"]
		if "level" in l:
			config.logging.level = l["level"]
		if "stdout_file" in l:
			config.logging.stdout_file = l["stdout_file"]
		if "stderr_file" in l:
			config.logging.stderr_file = l["stderr_file"]
		if "syslog" in l:
			config.logging.syslog = l["syslog"]
		if "quiet" in l:
			config.logging.quiet = l["quiet"]
		if "verbose" in l:
			config.logging.verbose = l["verbose"]
		if "max_size" in l:
			config.logging.max_size = l["max_size"]
		if "max_age" in l:
			config.logging.max_age = l["max_age"]
		if "max_count" in l:
			config.logging.max_count = l["max_count"]

	if "pidfile" in data:
		pf = data["pidfile"]
		if "enabled" in pf:
			config.pidfile.enabled = pf["enabled"]
		if "path" in pf:
			config.pidfile.path = pf["path"]

	if "signals" in data:
		sg = data["signals"]
		if "forward_all" in sg:
			config.signals.forward_all = sg["forward_all"]
		if "forward_list" in sg:
			config.signals.forward_list = list(sg["forward_list"])
		if "preserve_signals" in sg:
			config.signals.preserve_signals = list(sg["preserve_signals"])
		if "kill_timeout" in sg:
			config.signals.kill_timeout = sg["kill_timeout"]
		if "stop_signal" in sg:
			config.signals.stop_signal = sg["stop_signal"]
		if "reload_signal" in sg:
			config.signals.reload_signal = sg["reload_signal"]

	if "sandbox" in data:
		sb = data["sandbox"]
		if "type" in sb:
			config.sandbox.type = sb["type"]
		if "profile" in sb:
			config.sandbox.profile = sb["profile"]
		if "private_tmp" in sb:
			config.sandbox.private_tmp = sb["private_tmp"]
		if "private_dev" in sb:
			config.sandbox.private_dev = sb["private_dev"]
		if "readonly_paths" in sb:
			config.sandbox.readonly_paths = list(sb["readonly_paths"])
		if "no_network" in sb:
			config.sandbox.no_network = sb["no_network"]
		if "seccomp" in sb:
			config.sandbox.seccomp = sb["seccomp"]
		if "seccomp_profile" in sb:
			config.sandbox.seccomp_profile = sb["seccomp_profile"]

	if "limits" in data:
		lm = data["limits"]
		if "memory_limit" in lm:
			config.limits.memory_limit = lm["memory_limit"]
		if "cpu_limit" in lm:
			config.limits.cpu_limit = lm["cpu_limit"]
		if "file_limit" in lm:
			config.limits.file_limit = lm["file_limit"]
		if "process_limit" in lm:
			config.limits.process_limit = lm["process_limit"]
		if "core_limit" in lm:
			config.limits.core_limit = lm["core_limit"]
		if "stack_limit" in lm:
			config.limits.stack_limit = lm["stack_limit"]
		if "timeout" in lm:
			config.limits.timeout = lm["timeout"]

	if "monitoring" in data:
		mo = data["monitoring"]
		if "enabled" in mo:
			config.monitoring.enabled = mo["enabled"]
		if "check_interval" in mo:
			config.monitoring.check_interval = mo["check_interval"]
		if "check_command" in mo:
			config.monitoring.check_command = mo["check_command"]
		if "check_timeout" in mo:
			config.monitoring.check_timeout = mo["check_timeout"]
		if "failure_threshold" in mo:
			config.monitoring.failure_threshold = mo["failure_threshold"]
		if "success_threshold" in mo:
			config.monitoring.success_threshold = mo["success_threshold"]
		if "startup_delay" in mo:
			config.monitoring.startup_delay = mo["startup_delay"]

	return config


# Function: daemonctl_config_from_env APP_NAME CONFIG
# Load config overrides from DAEMONCTL_{APP}_{KEY} env vars.
def daemonctl_config_from_env(app_name: str, config: AppConfig) -> AppConfig:
	"""Apply environment variable overrides to config."""
	prefix = f"DAEMONCTL_{app_name.upper().replace('-', '_')}_"
	for key, value in os.environ.items():
		if not key.startswith(prefix):
			continue
		config_key = key[len(prefix) :].lower()
		# Map common overrides
		if config_key == "user":
			config.security.user = value
		elif config_key == "group":
			config.security.group = value
		elif config_key == "memory_limit":
			config.limits.memory_limit = value
		elif config_key == "cpu_limit":
			config.limits.cpu_limit = int(value)
		elif config_key == "file_limit":
			config.limits.file_limit = int(value)
		elif config_key == "process_limit":
			config.limits.process_limit = int(value)
		elif config_key == "timeout":
			config.limits.timeout = int(value)
		elif config_key == "sandbox":
			config.sandbox.type = value
		elif config_key == "log_level":
			config.logging.level = value
		elif config_key == "log_file":
			config.logging.file = value
		elif config_key == "monitoring_enabled":
			config.monitoring.enabled = value.lower() in ("1", "true", "yes")
		elif config_key == "check_interval":
			config.monitoring.check_interval = int(value)
	return config


# Function: daemonctl_config_to_daemonrun_args CONFIG APP_NAME
# Convert AppConfig to daemonrun CLI arguments.
def daemonctl_config_to_daemonrun_args(
	config: AppConfig, app_name: str = ""
) -> list[str]:
	"""Convert config to daemonrun command-line arguments."""
	args = []

	# Daemon settings
	if config.daemon.name:
		args.extend(["--group", config.daemon.name])
	if config.daemon.foreground:
		args.append("--foreground")
	if not config.daemon.setsid:
		args.append("--no-setsid")
	# Set working directory: explicit config, or default to run script directory
	if config.daemon.working_directory:
		args.extend(["--chdir", config.daemon.working_directory])
	elif app_name:
		# Default to the directory containing run.sh so relative paths work
		run_dir = daemonctl_app_get_run_dir(app_name)
		args.extend(["--chdir", str(run_dir)])
	if config.daemon.umask and config.daemon.umask != "022":
		args.extend(["--umask", config.daemon.umask])

	# Process settings
	if config.process.priority != 0:
		args.extend(["--nice", str(config.process.priority)])
	if config.process.clear_env:
		args.append("--clear-env")

	# Security settings
	if config.security.user:
		args.extend(["--user", config.security.user])
	if config.security.group:
		args.extend(["--run-group", config.security.group])
	if config.security.capabilities_drop:
		args.extend(["--caps-drop", ",".join(config.security.capabilities_drop)])
	if config.security.capabilities_keep:
		args.extend(["--caps-keep", ",".join(config.security.capabilities_keep)])

	# Logging settings - always specify stdout/stderr to avoid /dev/null
	if config.logging.file:
		args.extend(["--log", config.logging.file])
	if config.logging.level and config.logging.level != "info":
		args.extend(["--log-level", config.logging.level])

	# Determine app path for default log locations
	log_name = config.daemon.name or app_name or "daemon"
	app_path = daemonctl_app_path(app_name) if app_name else Path(".")

	stdout_file = config.logging.stdout_file or str(app_path / f"{log_name}.log")
	stderr_file = config.logging.stderr_file or str(app_path / f"{log_name}.err")
	args.extend(["--stdout", stdout_file])
	args.extend(["--stderr", stderr_file])

	if config.logging.syslog:
		args.append("--syslog")
	if config.logging.quiet:
		args.append("--quiet")
	if config.logging.verbose:
		args.append("--verbose")

	# PID file
	if config.pidfile.enabled and config.pidfile.path:
		args.extend(["--pidfile", config.pidfile.path])

	# Signals
	if not config.signals.forward_all:
		args.append("--no-signal-forward")
	for sig in config.signals.forward_list:
		args.extend(["--signal", sig])
	for sig in config.signals.preserve_signals:
		args.extend(["--preserve-signal", sig])
	if config.signals.kill_timeout != 30:
		args.extend(["--kill-timeout", str(config.signals.kill_timeout)])
	if config.signals.stop_signal != "TERM":
		args.extend(["--stop-signal", config.signals.stop_signal])
	if config.signals.reload_signal != "HUP":
		args.extend(["--reload-signal", config.signals.reload_signal])

	# Resource limits
	if config.limits.memory_limit:
		args.extend(["--memory-limit", config.limits.memory_limit])
	if config.limits.cpu_limit:
		args.extend(["--cpu-limit", str(config.limits.cpu_limit)])
	if config.limits.file_limit:
		args.extend(["--file-limit", str(config.limits.file_limit)])
	if config.limits.process_limit:
		args.extend(["--proc-limit", str(config.limits.process_limit)])
	if config.limits.core_limit:
		args.extend(["--core-limit", config.limits.core_limit])
	if config.limits.stack_limit:
		args.extend(["--stack-limit", config.limits.stack_limit])
	if config.limits.timeout:
		args.extend(["--timeout", str(config.limits.timeout)])

	# Sandbox settings
	if config.sandbox.type and config.sandbox.type != "none":
		args.extend(["--sandbox", config.sandbox.type])
	if config.sandbox.profile:
		args.extend(["--sandbox-profile", config.sandbox.profile])
	if config.sandbox.private_tmp:
		args.append("--private-tmp")
	if config.sandbox.private_dev:
		args.append("--private-dev")
	if config.sandbox.no_network:
		args.append("--no-network")
	if config.sandbox.readonly_paths:
		args.extend(["--readonly-paths", ":".join(config.sandbox.readonly_paths)])
	if config.sandbox.seccomp:
		args.append("--seccomp")
	if config.sandbox.seccomp_profile:
		args.extend(["--seccomp-profile", config.sandbox.seccomp_profile])

	return args


# Function: daemonctl_config_to_dict CONFIG
# Convert AppConfig to dictionary for serialization.
def daemonctl_config_to_dict(config: AppConfig) -> dict:
	"""Convert config to dictionary."""
	return {
		"daemon": {
			"name": config.daemon.name,
			"description": config.daemon.description,
			"enabled": config.daemon.enabled,
			"foreground": config.daemon.foreground,
			"double_fork": config.daemon.double_fork,
			"setsid": config.daemon.setsid,
			"working_directory": config.daemon.working_directory,
			"umask": config.daemon.umask,
		},
		"process": {
			"command": config.process.command,
			"args": config.process.args,
			"environment": config.process.environment,
			"environment_file": config.process.environment_file,
			"clear_env": config.process.clear_env,
			"priority": config.process.priority,
			"restart": config.process.restart,
			"restart_delay": config.process.restart_delay,
			"restart_max_attempts": config.process.restart_max_attempts,
			"start_timeout": config.process.start_timeout,
			"stop_timeout": config.process.stop_timeout,
		},
		"security": {
			"user": config.security.user,
			"group": config.security.group,
			"capabilities_drop": config.security.capabilities_drop,
			"capabilities_keep": config.security.capabilities_keep,
		},
		"logging": {
			"file": config.logging.file,
			"level": config.logging.level,
			"stdout_file": config.logging.stdout_file,
			"stderr_file": config.logging.stderr_file,
			"syslog": config.logging.syslog,
			"quiet": config.logging.quiet,
			"verbose": config.logging.verbose,
			"max_size": config.logging.max_size,
			"max_age": config.logging.max_age,
			"max_count": config.logging.max_count,
		},
		"pidfile": {
			"enabled": config.pidfile.enabled,
			"path": config.pidfile.path,
		},
		"signals": {
			"forward_all": config.signals.forward_all,
			"forward_list": config.signals.forward_list,
			"preserve_signals": config.signals.preserve_signals,
			"kill_timeout": config.signals.kill_timeout,
			"stop_signal": config.signals.stop_signal,
			"reload_signal": config.signals.reload_signal,
		},
		"sandbox": {
			"type": config.sandbox.type,
			"profile": config.sandbox.profile,
			"private_tmp": config.sandbox.private_tmp,
			"private_dev": config.sandbox.private_dev,
			"readonly_paths": config.sandbox.readonly_paths,
			"no_network": config.sandbox.no_network,
			"seccomp": config.sandbox.seccomp,
			"seccomp_profile": config.sandbox.seccomp_profile,
		},
		"limits": {
			"memory_limit": config.limits.memory_limit,
			"cpu_limit": config.limits.cpu_limit,
			"file_limit": config.limits.file_limit,
			"process_limit": config.limits.process_limit,
			"core_limit": config.limits.core_limit,
			"stack_limit": config.limits.stack_limit,
			"timeout": config.limits.timeout,
		},
		"monitoring": {
			"enabled": config.monitoring.enabled,
			"check_interval": config.monitoring.check_interval,
			"check_command": config.monitoring.check_command,
			"check_timeout": config.monitoring.check_timeout,
			"failure_threshold": config.monitoring.failure_threshold,
			"success_threshold": config.monitoring.success_threshold,
			"startup_delay": config.monitoring.startup_delay,
		},
	}


# Function: daemonctl_config_to_toml CONFIG
# Convert AppConfig to TOML string.
def daemonctl_config_to_toml(config: AppConfig) -> str:
	"""Convert config to TOML format."""
	data = daemonctl_config_to_dict(config)
	lines = []
	for section, values in data.items():
		# Skip empty sections
		if not any(v for v in values.values() if v not in (None, "", [], {}, 0, False)):
			continue
		lines.append(f"[{section}]")
		for key, value in values.items():
			if value in (None, "", [], {}, 0, False):
				continue
			if isinstance(value, bool):
				lines.append(f"{key} = {str(value).lower()}")
			elif isinstance(value, int):
				lines.append(f"{key} = {value}")
			elif isinstance(value, str):
				lines.append(f'{key} = "{value}"')
			elif isinstance(value, list):
				items = ", ".join(f'"{v}"' for v in value)
				lines.append(f"{key} = [{items}]")
			elif isinstance(value, dict):
				items = ", ".join(f'"{k}" = "{v}"' for k, v in value.items())
				lines.append(f"{key} = {{{items}}}")
		lines.append("")
	return "\n".join(lines)


# Function: daemonctl_config_to_json CONFIG
# Convert AppConfig to JSON string.
def daemonctl_config_to_json(config: AppConfig) -> str:
	"""Convert config to JSON format."""
	import json

	data = daemonctl_config_to_dict(config)
	return json.dumps(data, indent=2)


# Function: daemonctl_config_to_yaml CONFIG
# Convert AppConfig to YAML string.
def daemonctl_config_to_yaml(config: AppConfig) -> str:
	"""Convert config to YAML format."""
	data = daemonctl_config_to_dict(config)
	lines = []

	def yaml_value(v):
		if isinstance(v, bool):
			return str(v).lower()
		elif isinstance(v, (int, float)):
			return str(v)
		elif isinstance(v, str):
			if v == "" or any(c in v for c in ":#{}[]&*!|>'\"%@`"):
				return f'"{v}"'
			return v
		elif isinstance(v, list):
			return None  # Handle separately
		elif isinstance(v, dict):
			return None  # Handle separately
		return str(v)

	for section, values in data.items():
		# Skip empty sections
		if not any(v for v in values.values() if v not in (None, "", [], {}, 0, False)):
			continue
		lines.append(f"{section}:")
		for key, value in values.items():
			if value in (None, "", [], {}, 0, False):
				continue
			if isinstance(value, list):
				lines.append(f"  {key}:")
				for item in value:
					lines.append(f"    - {yaml_value(item)}")
			elif isinstance(value, dict):
				lines.append(f"  {key}:")
				for k, v in value.items():
					lines.append(f"    {k}: {yaml_value(v)}")
			else:
				lines.append(f"  {key}: {yaml_value(value)}")
	return "\n".join(lines)


# Function: daemonctl_config_set APP_NAME KEY VALUE
# Set a config value and save to conf.toml.
def daemonctl_config_set(app_name: str, key: str, value: str) -> bool:
	"""Set a config value. Key format: section.key (e.g., daemon.enabled)."""
	app_path = daemonctl_app_path(app_name)
	conf_path = app_path / "conf.toml"

	# Load existing config or create new
	data = {}
	if conf_path.exists():
		try:
			with open(conf_path, "rb") as f:
				data = tomllib.load(f)
		except Exception as e:
			daemonctl_util_log("error", f"Failed to load config: {e}")
			return False

	# Parse key path
	parts = key.split(".")
	if len(parts) != 2:
		daemonctl_util_log("error", f"Invalid key format: {key} (expected section.key)")
		return False

	section, keyname = parts

	# Parse value
	parsed_value: object
	if value.lower() in ("true", "false"):
		parsed_value = value.lower() == "true"
	elif value.isdigit():
		parsed_value = int(value)
	elif value.startswith("[") and value.endswith("]"):
		# Simple list parsing
		items = value[1:-1].split(",")
		parsed_value = [
			item.strip().strip('"').strip("'") for item in items if item.strip()
		]
	else:
		parsed_value = value

	# Set value
	if section not in data:
		data[section] = {}
	data[section][keyname] = parsed_value

	# Write back as TOML
	try:
		# Create minimal TOML output
		lines = []
		for sec, values in data.items():
			lines.append(f"[{sec}]")
			for k, v in values.items():
				if isinstance(v, bool):
					lines.append(f"{k} = {str(v).lower()}")
				elif isinstance(v, int):
					lines.append(f"{k} = {v}")
				elif isinstance(v, str):
					lines.append(f'{k} = "{v}"')
				elif isinstance(v, list):
					items = ", ".join(f'"{i}"' for i in v)
					lines.append(f"{k} = [{items}]")
			lines.append("")
		conf_path.write_text("\n".join(lines))
		return True
	except Exception as e:
		daemonctl_util_log("error", f"Failed to write config: {e}")
		return False


# -----------------------------------------------------------------------------
#
# PROCESS
#
# -----------------------------------------------------------------------------


# Function: daemonctl_process_PID_path APP_NAME
# Get PID file path for an app.
def daemonctl_process_PID_path(app_name: str) -> Path:
	"""Return PID file path for app."""
	config = daemonctl_config_load(app_name)
	return Path(config.pidfile.path)


# Function: daemonctl_process_PID_read APP_NAME
# Read PID from pidfile, return None if missing/invalid.
def daemonctl_process_PID_read(app_name: str) -> Optional[int]:
	"""Read PID from file, return None if missing or invalid."""
	pidfile = daemonctl_process_PID_path(app_name)
	if not pidfile.exists():
		return None
	try:
		content = pidfile.read_text().strip()
		return int(content) if content.isdigit() else None
	except (OSError, ValueError):
		return None


# Function: daemonctl_process_PID_write APP_NAME PID
# Write PID to file.
def daemonctl_process_PID_write(app_name: str, PID: int) -> None:
	"""Write PID to file."""
	pidfile = daemonctl_process_PID_path(app_name)
	pidfile.parent.mkdir(parents=True, exist_ok=True)
	pidfile.write_text(str(PID))


# Function: daemonctl_process_PID_remove APP_NAME
# Remove PID file.
def daemonctl_process_PID_remove(app_name: str) -> None:
	"""Remove PID file."""
	pidfile = daemonctl_process_PID_path(app_name)
	if pidfile.exists():
		pidfile.unlink()


# Function: daemonctl_process_is_running PID
# Check if process is running.
def daemonctl_process_is_running(PID: int) -> bool:
	"""Check if process with given PID is running."""
	try:
		os.kill(PID, 0)
		return True
	except (OSError, ProcessLookupError):
		return False


# Function: daemonctl_process_info PID
# Get process info from /proc.
def daemonctl_process_info(PID: int) -> dict:
	"""Get process info from /proc: memory, cpu, state, cmdline."""
	info = {
		"PID": PID,
		"running": False,
		"memory": 0,
		"cpu": 0.0,
		"state": "?",
		"cmdline": "",
	}
	proc = Path(f"/proc/{PID}")
	if not proc.exists():
		return info

	info["running"] = True

	# Read cmdline
	try:
		cmdline = (proc / "cmdline").read_text()
		info["cmdline"] = cmdline.replace("\x00", " ").strip()
	except OSError:
		pass

	# Read stat for state and basic info
	try:
		stat = (proc / "stat").read_text().split()
		info["state"] = stat[2] if len(stat) > 2 else "?"
	except OSError:
		pass

	# Read statm for memory (in pages)
	try:
		statm = (proc / "statm").read_text().split()
		if statm:
			page_size = os.sysconf("SC_PAGE_SIZE")
			info["memory"] = int(statm[1]) * page_size  # RSS in bytes
	except (OSError, ValueError):
		pass

	return info


# Function: daemonctl_process_signal PID SIGNAL
# Send signal to process.
def daemonctl_process_signal(PID: int, sig: int) -> bool:
	"""Send signal to process. Returns True if successful."""
	try:
		os.kill(PID, sig)
		return True
	except (OSError, ProcessLookupError):
		return False


# Function: daemonctl_process_wait PID TIMEOUT
# Wait for process to exit, return exit code or None on timeout.
def daemonctl_process_wait(PID: int, timeout: int) -> Optional[int]:
	"""Wait for process to exit. Returns True if exited, False on timeout."""
	start = time.time()
	while time.time() - start < timeout:
		if not daemonctl_process_is_running(PID):
			return True
		time.sleep(0.1)
	return False


# Function: daemonctl_process_tree PID
# Get process tree starting from PID.
def daemonctl_process_tree(PID: int) -> list[dict]:
	"""Get process tree starting from PID."""
	tree = []
	proc = Path("/proc")

	def get_children(parent_pid: int, depth: int = 0) -> list[dict]:
		"""Recursively get child processes."""
		children = []
		info = daemonctl_process_info(parent_pid)
		if not info["running"]:
			return children

		info["depth"] = depth
		children.append(info)

		# Find children by scanning /proc for matching ppid
		try:
			for entry in proc.iterdir():
				if not entry.name.isdigit():
					continue
				child_pid = int(entry.name)
				if child_pid == parent_pid:
					continue
				try:
					stat = (entry / "stat").read_text().split()
					if len(stat) > 3 and int(stat[3]) == parent_pid:
						children.extend(get_children(child_pid, depth + 1))
				except (OSError, ValueError, IndexError):
					continue
		except OSError:
			pass

		return children

	return get_children(PID)


# Function: daemonctl_process_resources PID
# Get detailed resource usage for a process.
def daemonctl_process_resources(PID: int) -> dict:
	"""Get detailed resource usage for a process."""
	resources = {
		"PID": PID,
		"memory_rss": 0,
		"memory_vms": 0,
		"cpu_user": 0.0,
		"cpu_system": 0.0,
		"threads": 0,
		"open_files": 0,
		"state": "?",
	}

	proc = Path(f"/proc/{PID}")
	if not proc.exists():
		return resources

	# Read stat for CPU and threads
	try:
		stat = (proc / "stat").read_text().split()
		if len(stat) > 19:
			resources["cpu_user"] = int(stat[13]) / os.sysconf("SC_CLK_TCK")
			resources["cpu_system"] = int(stat[14]) / os.sysconf("SC_CLK_TCK")
			resources["threads"] = int(stat[19])
			resources["state"] = stat[2]
	except (OSError, ValueError, IndexError):
		pass

	# Read statm for memory
	try:
		statm = (proc / "statm").read_text().split()
		if len(statm) >= 2:
			page_size = os.sysconf("SC_PAGE_SIZE")
			resources["memory_vms"] = int(statm[0]) * page_size
			resources["memory_rss"] = int(statm[1]) * page_size
	except (OSError, ValueError, IndexError):
		pass

	# Count open files
	try:
		fd_dir = proc / "fd"
		if fd_dir.exists():
			resources["open_files"] = len(list(fd_dir.iterdir()))
	except (OSError, PermissionError):
		pass

	return resources


# -----------------------------------------------------------------------------
#
# APP
#
# -----------------------------------------------------------------------------


# Function: daemonctl_app_path APP_NAME
# Return path to app's base directory.
def daemonctl_app_path(app_name: str) -> Path:
	"""Return path to app's base directory."""
	return _base_path / app_name


# Function: daemonctl_app_exists APP_NAME
# Check if app exists in DAEMONCTL_PATH.
def daemonctl_app_exists(app_name: str) -> bool:
	"""Check if app exists."""
	app_path = daemonctl_app_path(app_name)
	if not app_path.is_dir():
		return False
	run_script = daemonctl_app_get_run_script(app_name)
	return run_script is not None


# Function: daemonctl_app_list
# List all apps in DAEMONCTL_PATH.
def daemonctl_app_list() -> list[str]:
	"""List all apps in DAEMONCTL_PATH."""
	apps = []
	if not _base_path.is_dir():
		return apps
	for entry in _base_path.iterdir():
		if entry.is_dir():
			# Check for run script directly in app dir or in run/ subdir
			run_subdir = entry / "run"
			if run_subdir.is_dir():
				# runit-style: app/run/run or app/run/run.sh
				if (run_subdir / "run").exists() or (run_subdir / "run.sh").exists():
					apps.append(entry.name)
			else:
				# Simple style: app/run or app/run.sh
				if (entry / "run").exists() or (entry / "run.sh").exists():
					apps.append(entry.name)
	return sorted(apps)


# Function: daemonctl_app_get_run_script APP_NAME
# Get the run script path for an app.
def daemonctl_app_get_run_script(app_name: str) -> Optional[Path]:
	"""Get the run script path, checking for run or run.sh in both simple and runit-style layouts."""
	app_path = daemonctl_app_path(app_name)

	# Check simple style first: app/run or app/run.sh
	for name in ["run", "run.sh"]:
		script = app_path / name
		if script.exists() and script.is_file():
			return script

	# Check runit-style: app/run/run or app/run/run.sh
	run_subdir = app_path / "run"
	if run_subdir.is_dir():
		for name in ["run", "run.sh"]:
			script = run_subdir / name
			if script.exists() and script.is_file():
				return script

	return None


# Function: daemonctl_app_get_run_cmd APP_NAME
# Get the run command for an app.
def daemonctl_app_get_run_cmd(app_name: str) -> list[str]:
	"""Get the run command for an app."""
	script = daemonctl_app_get_run_script(app_name)
	if not script:
		raise ValueError(f"No run script found for app: {app_name}")

	# Check if script is executable
	if os.access(script, os.X_OK):
		return [str(script)]
	# If not executable, try running with bash
	return ["bash", str(script)]


# Function: daemonctl_app_status APP_NAME
# Get app status.
def daemonctl_app_status(app_name: str) -> dict:
	"""Get app status: running, PID, memory, cpu, etc."""
	status = {
		"name": app_name,
		"exists": daemonctl_app_exists(app_name),
		"running": False,
		"PID": None,
		"memory": 0,
		"cpu": 0.0,
		"state": "stopped",
		"path": str(daemonctl_app_path(app_name)),
	}

	if not status["exists"]:
		status["state"] = "not found"
		return status

	PID = daemonctl_process_PID_read(app_name)
	if PID and daemonctl_process_is_running(PID):
		info = daemonctl_process_info(PID)
		status["running"] = True
		status["PID"] = PID
		status["memory"] = info["memory"]
		status["cpu"] = info["cpu"]
		status["state"] = "running"
	else:
		# Clean up stale PID file
		if PID:
			daemonctl_process_PID_remove(app_name)

	return status


# Function: daemonctl_app_get_run_dir APP_NAME
# Get the directory containing the run script (for env.sh sourcing and working directory).
def daemonctl_app_get_run_dir(app_name: str) -> Path:
	"""Get the directory containing the run script."""
	run_script = daemonctl_app_get_run_script(app_name)
	if run_script:
		return run_script.parent
	return daemonctl_app_path(app_name)


# Function: daemonctl_app_source_env APP_NAME
# Source env.sh and return environment variables.
def daemonctl_app_source_env(app_name: str) -> dict[str, str]:
	"""Source env.sh and return resulting environment variables."""
	# Look for env.sh in the same directory as run.sh
	run_dir = daemonctl_app_get_run_dir(app_name)
	env_script = run_dir / "env.sh"
	if not env_script.exists():
		# Fall back to app root
		env_script = daemonctl_app_path(app_name) / "env.sh"
		if not env_script.exists():
			return {}

	# Source the script and dump environment
	# Run from the run directory so relative paths work correctly
	cmd = f"set -a; source {env_script} >/dev/null 2>&1; env"
	try:
		result = subprocess.run(
			["bash", "-c", cmd],
			capture_output=True,
			text=True,
			timeout=5,
			cwd=str(run_dir),
		)
		if result.returncode != 0:
			return {}
		env = {}
		for line in result.stdout.splitlines():
			if "=" in line:
				key, _, value = line.partition("=")
				env[key] = value
		return env
	except Exception:
		return {}


# Function: daemonctl_app_run_hook APP_NAME HOOK
# Run on-start or on-stop hook.
def daemonctl_app_run_hook(app_name: str, hook: str) -> int:
	"""Run a lifecycle hook (on-start, on-stop). Returns exit code."""
	app_path = daemonctl_app_path(app_name)
	for name in [hook, f"{hook}.sh"]:
		script = app_path / name
		if script.exists():
			daemonctl_util_log("debug", f"Running hook: {script}")
			cmd = [str(script)] if os.access(script, os.X_OK) else ["bash", str(script)]
			code, _, stderr = daemonctl_util_run(cmd, timeout=30)
			if code != 0:
				daemonctl_util_log("warn", f"Hook {hook} failed: {stderr}")
			return code
	return 0


# Function: daemonctl_app_get_check_cmd APP_NAME
# Get the health check command for an app.
def daemonctl_app_get_check_cmd(app_name: str) -> Optional[list[str]]:
	"""Get the health check command, if any."""
	app_path = daemonctl_app_path(app_name)
	for name in ["check", "check.sh"]:
		script = app_path / name
		if script.exists():
			if os.access(script, os.X_OK):
				return [str(script)]
			return ["bash", str(script)]
	return None


# Function: daemonctl_health_check APP_NAME CONFIG
# Run health check for an app.
def daemonctl_health_check(app_name: str, config: AppConfig) -> dict:
	"""Run health check and return result."""
	result = {"healthy": False, "error": None, "exit_code": -1}

	# Determine check command
	check_cmd = None
	if config.monitoring.check_command:
		check_cmd = config.monitoring.check_command.split()
	else:
		check_cmd = daemonctl_app_get_check_cmd(app_name)

	if not check_cmd:
		result["error"] = "No health check configured"
		return result

	# Run check with timeout
	timeout = config.monitoring.check_timeout or 10
	code, stdout, stderr = daemonctl_util_run(check_cmd, timeout=timeout)

	result["exit_code"] = code
	if code == 0:
		result["healthy"] = True
	else:
		result["error"] = stderr or f"Exit code {code}"

	return result


# Function: daemonctl_app_build_teelog_cmd CONFIG
# Build teelog command for log rotation.
def daemonctl_app_build_teelog_cmd(config: AppConfig) -> list[str]:
	"""Build teelog command with rotation options."""
	cmd = [TEELOG_CMD]

	if config.logging.max_size:
		cmd.extend(["--max-size", config.logging.max_size])
	if config.logging.max_age:
		cmd.extend(["--max-age", config.logging.max_age])
	if config.logging.max_count:
		cmd.extend(["--max-count", str(config.logging.max_count)])

	# Output files
	stdout_file = config.logging.stdout_file or config.logging.file
	stderr_file = config.logging.stderr_file

	if stdout_file:
		cmd.append(stdout_file)
	if stderr_file and stderr_file != stdout_file:
		cmd.append(stderr_file)

	return cmd


# Function: daemonctl_app_needs_teelog CONFIG
# Check if teelog is needed for log rotation.
def daemonctl_app_needs_teelog(config: AppConfig) -> bool:
	"""Check if teelog is needed for log rotation."""
	return bool(
		config.logging.max_size or config.logging.max_age or config.logging.max_count
	) and bool(config.logging.stdout_file or config.logging.file)


# Function: daemonctl_app_start_with_teelog APP_NAME CONFIG
# Start app with teelog for log rotation.
def daemonctl_app_start_with_teelog(
	app_name: str, config: AppConfig, foreground: bool = False
) -> tuple[list[str], dict]:
	"""Build command to start app with teelog for log rotation.

	Returns (command_list, environment_dict).
	"""
	# Build teelog command
	teelog_cmd = daemonctl_app_build_teelog_cmd(config)

	# Build daemonrun command
	daemonrun_args = daemonctl_config_to_daemonrun_args(config, app_name)
	run_cmd = daemonctl_app_get_run_cmd(app_name)

	# Combine: teelog ... -- daemonrun ... -- ./run
	mode_flag = "--foreground" if foreground else "--daemon"
	cmd = (
		teelog_cmd
		+ ["--"]
		+ [DAEMONRUN_CMD, mode_flag]
		+ daemonrun_args
		+ ["--"]
		+ run_cmd
	)

	# Source environment
	env = os.environ.copy()
	env.update(daemonctl_app_source_env(app_name))
	env.update(config.process.environment)

	return cmd, env


# Function: daemonctl_supervisor_run APP_NAME CONFIG
# Run as persistent supervisor with health monitoring.
def daemonctl_supervisor_run(app_name: str, config: AppConfig) -> int:
	"""Run as persistent supervisor with health monitoring."""
	daemonctl_util_log("info", f"Starting supervisor for {app_name}")

	# Build command
	daemonrun_args = daemonctl_config_to_daemonrun_args(config, app_name)
	run_cmd = daemonctl_app_get_run_cmd(app_name)

	# Source environment
	env = os.environ.copy()
	env.update(daemonctl_app_source_env(app_name))
	env.update(config.process.environment)

	# Supervisor state
	consecutive_failures = 0
	restart_count = 0
	max_restarts = config.process.restart_max_attempts
	restart_delay = config.process.restart_delay
	monitoring = config.monitoring
	should_exit = False

	# Signal handling for supervisor
	def handle_signal(signum: int, frame: object) -> None:
		nonlocal should_exit
		daemonctl_util_log("info", f"Supervisor received signal {signum}")
		should_exit = True

	original_sigint = signal.signal(signal.SIGINT, handle_signal)
	original_sigterm = signal.signal(signal.SIGTERM, handle_signal)

	try:
		while not should_exit:
			# Start the process
			cmd = [DAEMONRUN_CMD, "--foreground"] + daemonrun_args + ["--"] + run_cmd
			daemonctl_util_log("info", f"Starting process (restart #{restart_count})")

			# Run on-start hook
			daemonctl_app_run_hook(app_name, "on-start")

			# Start process
			process = subprocess.Popen(
				cmd, env=env, cwd=str(daemonctl_app_path(app_name))
			)
			child_pid = process.pid
			daemonctl_util_log("info", f"Process started (PID: {child_pid})")

			# Initial startup delay before health checks
			if monitoring.enabled and monitoring.startup_delay > 0:
				daemonctl_util_log(
					"debug", f"Waiting {monitoring.startup_delay}s before health checks"
				)
				startup_wait = monitoring.startup_delay
				while startup_wait > 0 and not should_exit and process.poll() is None:
					time.sleep(min(1, startup_wait))
					startup_wait -= 1

			# Monitor loop
			consecutive_successes = 0
			is_healthy = False

			while not should_exit:
				# Check if process exited
				ret = process.poll()
				if ret is not None:
					daemonctl_util_log("info", f"Process exited with code {ret}")
					break

				# Run health check if enabled
				if monitoring.enabled:
					result = daemonctl_health_check(app_name, config)

					if result["healthy"]:
						consecutive_failures = 0
						consecutive_successes += 1
						if consecutive_successes >= monitoring.success_threshold:
							if not is_healthy:
								daemonctl_util_log("info", "Process is healthy")
								is_healthy = True
					else:
						consecutive_successes = 0
						consecutive_failures += 1
						daemonctl_util_log(
							"warn",
							f"Health check failed ({consecutive_failures}/{monitoring.failure_threshold}): {result.get('error', 'unknown')}",
						)

						if consecutive_failures >= monitoring.failure_threshold:
							daemonctl_util_log(
								"error", "Failure threshold reached, restarting process"
							)
							# Terminate the process
							process.terminate()
							try:
								process.wait(timeout=config.signals.kill_timeout)
							except subprocess.TimeoutExpired:
								process.kill()
								process.wait()
							break

					# Wait for next check
					time.sleep(monitoring.check_interval)
				else:
					# No monitoring, just wait and check process status
					time.sleep(1)

			# Process ended, run on-stop hook
			daemonctl_app_run_hook(app_name, "on-stop")

			# Check if we should restart
			if should_exit:
				daemonctl_util_log("info", "Supervisor shutting down")
				break

			if config.process.restart:
				restart_count += 1
				if max_restarts > 0 and restart_count > max_restarts:
					daemonctl_util_log(
						"error", f"Max restarts ({max_restarts}) reached, giving up"
					)
					return 1

				daemonctl_util_log("info", f"Restarting in {restart_delay}s...")
				time.sleep(restart_delay)
			else:
				daemonctl_util_log("info", "Restart disabled, exiting")
				return process.returncode if process.returncode else 0

	finally:
		# Restore signal handlers
		signal.signal(signal.SIGINT, original_sigint)
		signal.signal(signal.SIGTERM, original_sigterm)

	return 0


# -----------------------------------------------------------------------------
#
# COMMANDS
#
# -----------------------------------------------------------------------------


# Function: daemonctl_cmd_config_show ARGS
# Show configuration for app(s).
def daemonctl_cmd_config_show(args: argparse.Namespace) -> int:
	"""Show configuration for app(s)."""
	app_name = getattr(args, "app_name", None)
	show_all = getattr(args, "all", False)
	show_global = getattr(args, "glob", False)
	output_format = getattr(args, "format", "toml")
	show_resolved = getattr(args, "resolved", False)
	config_path = getattr(args, "config_path", None)

	# Global config only
	if show_global:
		print(f"# Global configuration")
		print(f"DAEMONCTL_PATH = {_base_path}")
		print(f"DAEMONCTL_CONFIG = {DAEMONCTL_CONFIG or '(none)'}")
		print(f"DAEMONCTL_LOG_LEVEL = {DAEMONCTL_LOG_LEVEL}")
		print(f"DAEMONCTL_OP_TIMEOUT = {DAEMONCTL_OP_TIMEOUT}")
		return 0

	# Collect apps to show
	if show_all or not app_name:
		apps = daemonctl_app_list()
	else:
		apps = [app_name]

	if not apps:
		daemonctl_util_log("info", "No apps found")
		return 0

	for name in apps:
		if not daemonctl_app_exists(name):
			daemonctl_util_log("warn", f"App not found: {name}")
			continue

		config = daemonctl_config_load(name)

		# Show specific path
		if config_path:
			parts = config_path.split(".")
			data = daemonctl_config_to_dict(config)
			try:
				for part in parts:
					data = data[part]
				print(f"{config_path} = {data}")
			except (KeyError, TypeError):
				daemonctl_util_log("error", f"Config path not found: {config_path}")
				return 1
			continue

		# Format and output
		if len(apps) > 1:
			print(f"# App: {name}")
			print()

		if output_format == "json":
			print(daemonctl_config_to_json(config))
		elif output_format == "yaml":
			print(daemonctl_config_to_yaml(config))
		else:
			print(daemonctl_config_to_toml(config))

		if len(apps) > 1:
			print()

	return 0


# Function: daemonctl_cmd_config_set ARGS
# Set configuration value.
def daemonctl_cmd_config_set(args: argparse.Namespace) -> int:
	"""Set configuration value."""
	app_name = args.app_name
	key_value = args.key_value

	if not daemonctl_app_exists(app_name):
		daemonctl_util_log("error", f"App not found: {app_name}")
		return 1

	# Parse KEY=VALUE
	if "=" not in key_value:
		daemonctl_util_log("error", f"Invalid format: {key_value} (expected KEY=VALUE)")
		return 1

	key, _, value = key_value.partition("=")

	if _dry_run:
		daemonctl_util_log("info", f"[dry-run] Would set {key} = {value}")
		return 0

	if daemonctl_config_set(app_name, key, value):
		daemonctl_util_log("info", f"Set {key} = {value}")
		return 0
	else:
		return 1


# Function: daemonctl_config_apply_CLI_overrides ARGS CONFIG
# Apply CLI argument overrides to config.
def daemonctl_config_apply_CLI_overrides(
	args: argparse.Namespace, config: AppConfig
) -> AppConfig:
	"""Apply CLI argument overrides to config."""
	# Skip config if requested
	if getattr(args, "no_config", False):
		config = AppConfig()
		config.daemon.name = args.app_name

	# Process Management
	if getattr(args, "user", None):
		config.security.user = args.user
	if getattr(args, "run_group", None):
		config.security.group = args.run_group
	if getattr(args, "chdir", None):
		config.daemon.working_directory = args.chdir
	if getattr(args, "umask", None):
		config.daemon.umask = args.umask
	if getattr(args, "nice", None) is not None:
		config.process.priority = args.nice

	# Signal Handling
	if getattr(args, "forward_all_signals", False):
		config.signals.forward_all = True
	if getattr(args, "no_signal_forward", False):
		config.signals.forward_all = False
	if getattr(args, "signal", None):
		config.signals.forward_list = args.signal
	if getattr(args, "preserve_signals", None):
		config.signals.preserve_signals = args.preserve_signals.split(",")
	if getattr(args, "kill_timeout", None) is not None:
		config.signals.kill_timeout = args.kill_timeout
	if getattr(args, "stop_signal", None):
		config.signals.stop_signal = args.stop_signal
	if getattr(args, "reload_signal", None):
		config.signals.reload_signal = args.reload_signal

	# Logging
	if getattr(args, "log", None):
		config.logging.file = args.log
	if getattr(args, "log_level", None):
		config.logging.level = args.log_level
	if getattr(args, "stdout", None):
		config.logging.stdout_file = args.stdout
	if getattr(args, "stderr", None):
		config.logging.stderr_file = args.stderr
	if getattr(args, "syslog", False):
		config.logging.syslog = True

	# Resource Limits
	if getattr(args, "memory_limit", None):
		config.limits.memory_limit = args.memory_limit
	if getattr(args, "cpu_limit", None) is not None:
		config.limits.cpu_limit = args.cpu_limit
	if getattr(args, "file_limit", None) is not None:
		config.limits.file_limit = args.file_limit
	if getattr(args, "proc_limit", None) is not None:
		config.limits.process_limit = args.proc_limit
	if getattr(args, "core_limit", None):
		config.limits.core_limit = args.core_limit
	if getattr(args, "stack_limit", None):
		config.limits.stack_limit = args.stack_limit
	if getattr(args, "timeout", None) is not None:
		config.limits.timeout = args.timeout

	# Sandboxing
	if getattr(args, "sandbox", None):
		config.sandbox.type = args.sandbox
	if getattr(args, "sandbox_profile", None):
		config.sandbox.profile = args.sandbox_profile
	if getattr(args, "private_tmp", False):
		config.sandbox.private_tmp = True
	if getattr(args, "private_dev", False):
		config.sandbox.private_dev = True
	if getattr(args, "no_network", False):
		config.sandbox.no_network = True
	if getattr(args, "readonly_paths", None):
		config.sandbox.readonly_paths = args.readonly_paths.split(":")
	if getattr(args, "caps_drop", None):
		config.security.capabilities_drop = args.caps_drop.split(",")
	if getattr(args, "caps_keep", None):
		config.security.capabilities_keep = args.caps_keep.split(",")
	if getattr(args, "seccomp", False):
		config.sandbox.seccomp = True
	if getattr(args, "seccomp_profile", None):
		config.sandbox.seccomp_profile = args.seccomp_profile

	# Environment
	if getattr(args, "clear_env", False):
		config.process.clear_env = True
	if getattr(args, "env_file", None):
		config.process.environment_file = args.env_file

	# Config overrides (key=value format)
	for override in getattr(args, "config_override", None) or []:
		if "=" in override:
			key, _, value = override.partition("=")
			# Apply as nested config (e.g., daemon.foreground=true)
			parts = key.split(".")
			if len(parts) == 2:
				section, keyname = parts
				# Use setattr for simple cases
				if hasattr(config, section):
					section_obj = getattr(config, section)
					if hasattr(section_obj, keyname):
						current = getattr(section_obj, keyname)
						if isinstance(current, bool):
							setattr(section_obj, keyname, value.lower() == "true")
						elif isinstance(current, int):
							setattr(section_obj, keyname, int(value))
						else:
							setattr(section_obj, keyname, value)

	return config


# Function: daemonctl_cmd_run ARGS
# Run app as daemon with optional attach.
def daemonctl_cmd_run(args: argparse.Namespace) -> int:
	"""Run app as daemon (foreground supervisor mode)."""
	app_name = args.app_name
	if not daemonctl_app_exists(app_name):
		daemonctl_util_log("error", f"App not found: {app_name}")
		return 1

	# Check if already running
	status = daemonctl_app_status(app_name)
	if status["running"]:
		daemonctl_util_log("error", f"App already running (PID: {status['PID']})")
		return 1

	config = daemonctl_config_load(app_name)

	# Apply CLI overrides
	config = daemonctl_config_apply_CLI_overrides(args, config)
	if getattr(args, "foreground", False):
		config.daemon.foreground = True

	if _dry_run:
		daemonctl_util_log(
			"info",
			f"[dry-run] Would run {app_name} (supervisor={config.monitoring.enabled})",
		)
		return 0

	# Use supervisor mode if monitoring is enabled or restart is configured
	if config.monitoring.enabled or config.process.restart:
		return daemonctl_supervisor_run(app_name, config)

	# Simple foreground mode without supervisor
	daemonrun_args = daemonctl_config_to_daemonrun_args(config, app_name)
	run_cmd = daemonctl_app_get_run_cmd(app_name)

	# Source environment
	env = os.environ.copy()
	env.update(daemonctl_app_source_env(app_name))
	env.update(config.process.environment)
	# Apply CLI --env options
	for env_kv in getattr(args, "env", None) or []:
		if "=" in env_kv:
			k, _, v = env_kv.partition("=")
			env[k] = v

	# For run command, use foreground mode with attach
	cmd = [DAEMONRUN_CMD, "--foreground"] + daemonrun_args + ["--"] + run_cmd

	daemonctl_util_log("info", f"Starting {app_name}...")

	# Run on-start hook
	daemonctl_app_run_hook(app_name, "on-start")

	try:
		# Run in foreground, passing through signals
		result = subprocess.run(cmd, env=env, cwd=str(daemonctl_app_path(app_name)))
		return result.returncode
	except KeyboardInterrupt:
		daemonctl_util_log("info", "Interrupted")
		return 130
	finally:
		daemonctl_app_run_hook(app_name, "on-stop")


# Function: daemonctl_cmd_start ARGS
# Start daemon in background.
def daemonctl_cmd_start(args: argparse.Namespace) -> int:
	"""Start app in background."""
	app_name = args.app_name
	if not daemonctl_app_exists(app_name):
		daemonctl_util_log("error", f"App not found: {app_name}")
		return 1

	# Check if already running
	status = daemonctl_app_status(app_name)
	if status["running"]:
		daemonctl_util_log("error", f"App already running (PID: {status['PID']})")
		return 1

	config = daemonctl_config_load(app_name)

	# Apply CLI overrides
	config = daemonctl_config_apply_CLI_overrides(args, config)

	# Apply verbose flag from CLI
	if getattr(args, "verbose", False):
		config.logging.verbose = True

	# Check if teelog is needed for log rotation
	if daemonctl_app_needs_teelog(config):
		cmd, env = daemonctl_app_start_with_teelog(app_name, config, foreground=False)
	else:
		# Build daemonrun command directly
		daemonrun_args = daemonctl_config_to_daemonrun_args(config, app_name)
		run_cmd = daemonctl_app_get_run_cmd(app_name)
		cmd = [DAEMONRUN_CMD, "--daemon"] + daemonrun_args + ["--"] + run_cmd

		# Source environment
		env = os.environ.copy()
		env.update(daemonctl_app_source_env(app_name))
		env.update(config.process.environment)

	# Apply CLI --env options
	for env_kv in getattr(args, "env", None) or []:
		if "=" in env_kv:
			k, _, v = env_kv.partition("=")
			env[k] = v

	if _dry_run:
		daemonctl_util_log("info", f"[dry-run] Would run: {' '.join(cmd)}")
		return 0

	daemonctl_util_log("info", f"Starting {app_name}...")

	# Run on-start hook
	daemonctl_app_run_hook(app_name, "on-start")

	code, stdout, stderr = daemonctl_util_run(
		cmd, timeout=config.process.start_timeout, env=env
	)

	if code != 0:
		daemonctl_util_log("error", f"Failed to start: {stderr}")
		return code

	# Wait briefly and verify it started
	time.sleep(0.5)
	status = daemonctl_app_status(app_name)
	if status["running"]:
		daemonctl_util_log("info", f"Started {app_name} (PID: {status['PID']})")
		return 0
	else:
		daemonctl_util_log("error", "Process exited immediately")
		return 1


# Function: daemonctl_cmd_stop ARGS
# Stop running daemon.
def daemonctl_cmd_stop(args: argparse.Namespace) -> int:
	"""Stop running app."""
	app_name = args.app_name

	status = daemonctl_app_status(app_name)
	if not status["running"]:
		daemonctl_util_log("info", f"App not running: {app_name}")
		return 0

	PID = status["PID"]
	timeout = getattr(args, "timeout", 30)
	force = getattr(args, "force", False)

	if _dry_run:
		daemonctl_util_log("info", f"[dry-run] Would stop PID {PID}")
		return 0

	daemonctl_util_log("info", f"Stopping {app_name} (PID: {PID})...")

	# Send SIGTERM
	sig = getattr(args, "signal", None)
	if sig:
		sig_num = getattr(signal, f"SIG{sig.upper()}", signal.SIGTERM)
	else:
		sig_num = signal.SIGTERM

	daemonctl_process_signal(PID, sig_num)

	# Wait for exit
	if daemonctl_process_wait(PID, timeout):
		daemonctl_util_log("info", f"Stopped {app_name}")
		daemonctl_app_run_hook(app_name, "on-stop")
		return 0

	# Force kill if requested
	if force:
		daemonctl_util_log("warn", "Graceful stop timed out, sending SIGKILL")
		daemonctl_process_signal(PID, signal.SIGKILL)
		time.sleep(0.5)
		if not daemonctl_process_is_running(PID):
			daemonctl_app_run_hook(app_name, "on-stop")
			return 0

	daemonctl_util_log("error", "Failed to stop process")
	return 1


# Function: daemonctl_cmd_restart ARGS
# Restart daemon.
def daemonctl_cmd_restart(args: argparse.Namespace) -> int:
	"""Restart app (stop + start)."""
	app_name = args.app_name

	status = daemonctl_app_status(app_name)
	if status["running"]:
		code = daemonctl_cmd_stop(args)
		if code != 0 and not getattr(args, "force", False):
			return code
		time.sleep(0.5)  # Brief delay between stop and start

	return daemonctl_cmd_start(args)


# Function: daemonctl_cmd_status ARGS
# Show status of daemon(s).
def daemonctl_cmd_status(args: argparse.Namespace) -> int:
	"""Show status of app(s)."""
	# Handle watch mode
	if getattr(args, "watch", False):
		return daemonctl_cmd_status_watch(args)

	app_name = getattr(args, "app_name", None)
	show_all = getattr(args, "all", False) or not app_name
	long_format = getattr(args, "long", False)
	show_processes = getattr(args, "processes", False)
	show_resources = getattr(args, "resources", False)
	show_health = getattr(args, "health", False)

	if show_all or not app_name:
		apps = daemonctl_app_list()
	else:
		apps = [app_name]

	if not apps:
		daemonctl_util_log("info", "No apps found")
		return 0

	for name in apps:
		status = daemonctl_app_status(name)
		state_color = "green" if status["running"] else "dim"
		state_str = daemonctl_util_color(status["state"], state_color)

		if long_format or show_processes or show_resources or show_health:
			print(f"App: {name}")
			print(f"  Status: {state_str}")
			print(f"  PID: {status['PID'] or '-'}")
			print(
				f"  Memory: {daemonctl_util_format_size(status['memory']) if status['memory'] else '-'}"
			)
			print(f"  Path: {status['path']}")

			# Show process tree
			if show_processes and status["PID"]:
				print("  Process Tree:")
				tree = daemonctl_process_tree(status["PID"])
				for proc in tree:
					indent = "    " + "  " * proc.get("depth", 0)
					cmd = proc.get("cmdline", "")[:50]
					print(f"{indent}{proc['PID']} {proc['state']} {cmd}")

			# Show resource usage
			if show_resources and status["PID"]:
				res = daemonctl_process_resources(status["PID"])
				print("  Resources:")
				print(
					f"    Memory RSS: {daemonctl_util_format_size(res['memory_rss'])}"
				)
				print(
					f"    Memory VMS: {daemonctl_util_format_size(res['memory_vms'])}"
				)
				print(f"    CPU User: {res['cpu_user']:.2f}s")
				print(f"    CPU System: {res['cpu_system']:.2f}s")
				print(f"    Threads: {res['threads']}")
				print(f"    Open Files: {res['open_files']}")

			# Show health status
			if show_health:
				config = daemonctl_config_load(name)
				print("  Health:")
				if config.monitoring.enabled:
					health = daemonctl_health_check(name, config)
					health_color = "green" if health["healthy"] else "red"
					health_str = daemonctl_util_color(
						"healthy" if health["healthy"] else "unhealthy", health_color
					)
					print(f"    Status: {health_str}")
					if health.get("error"):
						print(f"    Error: {health['error']}")
				else:
					print("    Monitoring: disabled")

			print()
		else:
			PID_str = str(status["PID"]) if status["PID"] else "-"
			mem_str = (
				daemonctl_util_format_size(status["memory"])
				if status["memory"]
				else "-"
			)
			print(f"{name}: {state_str} (PID: {PID_str}, mem: {mem_str})")

	return 0


# Function: daemonctl_cmd_status_watch ARGS
# Continuously display status with refresh.
def daemonctl_cmd_status_watch(args: argparse.Namespace) -> int:
	"""Continuously display status with refresh."""
	refresh = getattr(args, "refresh", 2)

	# Create a copy of args without watch to avoid recursion
	import copy

	display_args = copy.copy(args)
	display_args.watch = False

	try:
		while True:
			# Clear screen
			print("\033[2J\033[H", end="")  # ANSI clear screen + home
			print(
				daemonctl_util_color(
					f"daemonctl status (refreshing every {refresh}s, Ctrl+C to exit)",
					"dim",
				)
			)
			print()
			daemonctl_cmd_status(display_args)
			time.sleep(refresh)
	except KeyboardInterrupt:
		print()
		return 0


# Function: daemonctl_cmd_list ARGS
# List all managed daemons.
def daemonctl_cmd_list(args: argparse.Namespace) -> int:
	"""List all apps with status."""
	apps = daemonctl_app_list()

	if not apps:
		daemonctl_util_log("info", "No apps found")
		return 0

	# Header
	print(daemonctl_util_color("# NAME       STATUS   PID    MEMORY  PATH", "dim"))

	for name in apps:
		status = daemonctl_app_status(name)
		state = status["state"]
		PID = str(status["PID"]) if status["PID"] else "-"
		mem = daemonctl_util_format_size(status["memory"]) if status["memory"] else "-"
		path = status["path"]

		state_color = "green" if status["running"] else "dim"
		state_str = daemonctl_util_color(f"{state:<8}", state_color)

		print(f"  {name:<10} {state_str} {PID:<6} {mem:<7} {path}")

	return 0


# Function: daemonctl_cmd_logs ARGS
# Show daemon logs.
def daemonctl_cmd_logs(args: argparse.Namespace) -> int:
	"""Show/follow app logs."""
	app_name = args.app_name

	if not daemonctl_app_exists(app_name):
		daemonctl_util_log("error", f"App not found: {app_name}")
		return 1

	config = daemonctl_config_load(app_name)

	# Determine log file
	log_file = config.logging.stdout_file or config.logging.file
	if not log_file:
		# Try common locations
		for candidate in [
			f"/var/log/{app_name}.log",
			f"/tmp/{app_name}.log",
			str(daemonctl_app_path(app_name) / f"{app_name}.log"),
		]:
			if Path(candidate).exists():
				log_file = candidate
				break

	if not log_file or not Path(log_file).exists():
		daemonctl_util_log("error", "No log file found")
		return 1

	follow = getattr(args, "follow", False)
	lines = getattr(args, "lines", 50)
	grep_pattern = getattr(args, "grep", None)
	level_filter = getattr(args, "level", None)
	show_timestamps = getattr(args, "timestamps", False)
	since_time = getattr(args, "since", None)
	until_time = getattr(args, "until", None)
	use_head = getattr(args, "head", False)

	# Level filter keywords
	level_keywords = {
		"debug": ["debug", "dbg"],
		"info": ["info", "---"],
		"warn": ["warn", "warning", "wrn"],
		"error": ["error", "err", "fatal"],
	}

	# Build command pipeline
	if follow:
		cmd = ["tail", "-f", "-n", str(lines), log_file]
	elif use_head:
		cmd = ["head", "-n", str(lines), log_file]
	else:
		cmd = ["tail", "-n", str(lines), log_file]

	# For simple cases without filtering, use direct subprocess
	if not grep_pattern and not level_filter and not since_time and not until_time:
		try:
			subprocess.run(cmd)
			return 0
		except KeyboardInterrupt:
			return 0

	# For filtering, read and process in Python
	try:
		log_path = Path(log_file)
		content = log_path.read_text()
		log_lines = content.splitlines()

		# Apply head/tail
		if use_head:
			log_lines = log_lines[:lines]
		else:
			log_lines = log_lines[-lines:]

		# Filter by pattern
		if grep_pattern:
			import fnmatch

			log_lines = [
				l
				for l in log_lines
				if fnmatch.fnmatch(l.lower(), f"*{grep_pattern.lower()}*")
			]

		# Filter by level (simple keyword match)
		if level_filter:
			keywords = level_keywords.get(level_filter, [])
			log_lines = [
				l for l in log_lines if any(kw in l.lower() for kw in keywords)
			]

		# Output
		for line in log_lines:
			print(line)

		# If follow mode with filters, continue tailing
		if follow:
			daemonctl_util_log("info", "(Following with filter, Ctrl+C to exit)")
			with open(log_file, "r") as f:
				f.seek(0, 2)  # Go to end
				while True:
					line = f.readline()
					if line:
						line = line.rstrip()
						# Apply filters
						if grep_pattern and grep_pattern.lower() not in line.lower():
							continue
						if level_filter:
							keywords = level_keywords.get(level_filter, [])
							if not any(kw in line.lower() for kw in keywords):
								continue
						print(line)
					else:
						time.sleep(0.1)

	except KeyboardInterrupt:
		return 0
	except Exception as e:
		daemonctl_util_log("error", f"Failed to read logs: {e}")
		return 1

	return 0


# Function: daemonctl_cmd_kill ARGS
# Send signal to daemon.
def daemonctl_cmd_kill(args: argparse.Namespace) -> int:
	"""Send signal to app."""
	app_name = args.app_name
	sig_name = getattr(args, "signal", "TERM")
	all_processes = getattr(args, "all_processes", False)
	pid_only = getattr(args, "pid_only", False)
	wait = getattr(args, "wait", False)
	timeout = getattr(args, "timeout", 30)

	status = daemonctl_app_status(app_name)
	if not status["running"]:
		daemonctl_util_log("error", f"App not running: {app_name}")
		return 1

	PID = status["PID"]

	# Parse signal
	sig_name = sig_name.upper()
	if not sig_name.startswith("SIG"):
		sig_name = f"SIG{sig_name}"

	try:
		sig_num = getattr(signal, sig_name)
	except AttributeError:
		daemonctl_util_log("error", f"Unknown signal: {sig_name}")
		return 1

	if _dry_run:
		daemonctl_util_log("info", f"[dry-run] Would send {sig_name} to PID {PID}")
		return 0

	# Determine targets
	if all_processes:
		# Send to process group
		daemonctl_util_log("info", f"Sending {sig_name} to process group of {app_name}")
		try:
			os.killpg(os.getpgid(PID), sig_num)
		except (OSError, ProcessLookupError) as e:
			daemonctl_util_log("error", f"Failed to send to process group: {e}")
			return 1
	elif pid_only:
		# Send only to main process
		daemonctl_util_log("info", f"Sending {sig_name} to {app_name} (PID: {PID})")
		if not daemonctl_process_signal(PID, sig_num):
			daemonctl_util_log("error", "Failed to send signal")
			return 1
	else:
		# Default: send to main process
		daemonctl_util_log("info", f"Sending {sig_name} to {app_name} (PID: {PID})")
		if not daemonctl_process_signal(PID, sig_num):
			daemonctl_util_log("error", "Failed to send signal")
			return 1

	# Wait if requested
	if wait:
		daemonctl_util_log(
			"info", f"Waiting for signal to be processed (timeout: {timeout}s)"
		)
		if daemonctl_process_wait(PID, timeout):
			daemonctl_util_log("info", "Process exited")
		else:
			daemonctl_util_log("warn", "Process still running after timeout")

	return 0


# -----------------------------------------------------------------------------
#
# CLI
#
# -----------------------------------------------------------------------------


# Function: daemonctl_CLI_add_process_options PARSER
# Add common process/daemon options to a subparser.
def daemonctl_CLI_add_process_options(parser: argparse.ArgumentParser) -> None:
	"""Add common process management options to a parser."""
	# Process Management
	proc = parser.add_argument_group("process management")
	proc.add_argument("-u", "--user", metavar="USER", help="Run as specific user")
	proc.add_argument(
		"-G", "--run-group", metavar="GROUP", help="Run as specific group"
	)
	proc.add_argument("-C", "--chdir", metavar="DIR", help="Change working directory")
	proc.add_argument("--umask", metavar="MASK", help="Set file creation mask")
	proc.add_argument(
		"--nice", type=int, metavar="PRI", help="Set process niceness (-20 to 19)"
	)

	# Signal Handling
	sig = parser.add_argument_group("signal handling")
	sig.add_argument(
		"-A",
		"--forward-all-signals",
		action="store_true",
		help="Forward all signals (default)",
	)
	sig.add_argument(
		"--no-signal-forward", action="store_true", help="Disable signal forwarding"
	)
	sig.add_argument(
		"-S", "--signal", action="append", metavar="SIG", help="Forward specific signal"
	)
	sig.add_argument(
		"--preserve-signals", metavar="LIST", help="Don't forward these signals"
	)
	sig.add_argument(
		"-k", "--kill-timeout", type=int, metavar="SEC", help="Timeout for SIGKILL"
	)
	sig.add_argument(
		"--stop-signal", metavar="SIG", help="Signal for graceful stop (default: TERM)"
	)
	sig.add_argument(
		"--reload-signal", metavar="SIG", help="Signal for reload (default: HUP)"
	)

	# Logging
	log = parser.add_argument_group("logging")
	log.add_argument("-l", "--log", metavar="FILE", help="Log file location")
	log.add_argument(
		"--log-level",
		choices=["debug", "info", "warn", "error"],
		help="Log level",
	)
	log.add_argument("--stdout", metavar="FILE", help="Redirect stdout to file")
	log.add_argument("--stderr", metavar="FILE", help="Redirect stderr to file")
	log.add_argument("--syslog", action="store_true", help="Log to syslog")

	# Resource Limits
	limits = parser.add_argument_group("resource limits")
	limits.add_argument(
		"--memory-limit", metavar="SIZE", help="Memory limit (e.g., 512M, 1G)"
	)
	limits.add_argument(
		"--cpu-limit", type=int, metavar="PCT", help="CPU limit (1-100)"
	)
	limits.add_argument("--file-limit", type=int, metavar="N", help="Max open files")
	limits.add_argument(
		"--proc-limit", type=int, metavar="N", help="Max processes/threads"
	)
	limits.add_argument("--core-limit", metavar="SIZE", help="Core dump size limit")
	limits.add_argument("--stack-limit", metavar="SIZE", help="Stack size limit")
	limits.add_argument("--timeout", type=int, metavar="SEC", help="Kill after timeout")

	# Sandboxing
	sandbox = parser.add_argument_group("sandboxing")
	sandbox.add_argument(
		"--sandbox",
		choices=["none", "firejail", "unshare"],
		help="Enable sandbox",
	)
	sandbox.add_argument(
		"--sandbox-profile", metavar="FILE", help="Custom sandbox profile"
	)
	sandbox.add_argument("--private-tmp", action="store_true", help="Use private /tmp")
	sandbox.add_argument("--private-dev", action="store_true", help="Use private /dev")
	sandbox.add_argument("--no-network", action="store_true", help="Disable network")
	sandbox.add_argument(
		"--readonly-paths", metavar="PATHS", help="Colon-separated read-only paths"
	)
	sandbox.add_argument("--caps-drop", metavar="CAPS", help="Drop capabilities")
	sandbox.add_argument("--caps-keep", metavar="CAPS", help="Keep only these caps")
	sandbox.add_argument(
		"--seccomp", action="store_true", help="Enable seccomp filtering"
	)
	sandbox.add_argument(
		"--seccomp-profile", metavar="FILE", help="Custom seccomp profile"
	)

	# Environment
	env = parser.add_argument_group("environment")
	env.add_argument(
		"--env", action="append", metavar="K=V", help="Set environment variable"
	)
	env.add_argument("--env-file", metavar="FILE", help="Load environment from file")
	env.add_argument(
		"--clear-env", action="store_true", help="Clear inherited environment"
	)
	env.add_argument(
		"--config-override",
		action="append",
		metavar="K=V",
		help="Override config value",
	)
	env.add_argument("--no-config", action="store_true", help="Ignore config files")


# Function: daemonctl_CLI_build_parser
# Build argument parser with all subcommands.
def daemonctl_CLI_build_parser() -> argparse.ArgumentParser:
	"""Build the argument parser."""
	parser = argparse.ArgumentParser(
		prog="daemonctl",
		description="Daemon management wrapper around daemonrun and teelog.",
		formatter_class=argparse.RawDescriptionHelpFormatter,
	)

	# Global options
	parser.add_argument(
		"-V", "--version", action="version", version=f"daemonctl {VERSION}"
	)
	parser.add_argument(
		"-c", "--config", metavar="FILE", help="Use specific config file"
	)
	parser.add_argument("-p", "--path", metavar="DIR", help="Set DAEMONCTL_PATH")
	parser.add_argument(
		"-e", "--env", metavar="FILE", help="Additional environment file"
	)
	parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
	parser.add_argument(
		"-q", "--quiet", action="store_true", help="Suppress non-error output"
	)
	parser.add_argument(
		"--no-color", action="store_true", help="Disable colored output"
	)
	parser.add_argument(
		"-n", "--dry-run", action="store_true", help="Show what would be done"
	)
	parser.add_argument(
		"-T",
		"--op-timeout",
		type=int,
		default=30,
		metavar="SEC",
		help="Operation timeout",
	)

	subparsers = parser.add_subparsers(dest="command", title="commands")

	# config command (with sub-subcommands)
	p_config = subparsers.add_parser("config", help="Configuration management")
	config_sub = p_config.add_subparsers(dest="config_command", title="config commands")

	# config show
	p_config_show = config_sub.add_parser("show", help="Show configuration")
	p_config_show.add_argument(
		"app_name", nargs="?", metavar="APP", help="Application name"
	)
	p_config_show.add_argument(
		"-a", "--all", action="store_true", help="Show all app configs"
	)
	p_config_show.add_argument(
		"-g", "--glob", action="store_true", help="Show global config only"
	)
	p_config_show.add_argument(
		"--format",
		choices=["toml", "json", "yaml"],
		default="toml",
		help="Output format",
	)
	p_config_show.add_argument(
		"--resolved", action="store_true", help="Show resolved config (after overrides)"
	)
	p_config_show.add_argument(
		"--config-path",
		dest="config_path",
		metavar="PATH",
		help="Show specific config path",
	)

	# config set
	p_config_set = config_sub.add_parser("set", help="Set configuration value")
	p_config_set.add_argument("app_name", metavar="APP", help="Application name")
	p_config_set.add_argument(
		"key_value", metavar="KEY=VALUE", help="Configuration key=value"
	)

	# run command
	p_run = subparsers.add_parser("run", help="Run app as daemon (foreground)")
	p_run.add_argument("app_name", metavar="APP", help="Application name")
	p_run.add_argument(
		"-F", "--foreground", action="store_true", help="Keep in foreground"
	)
	p_run.add_argument("-a", "--attach", action="store_true", help="Attach to output")
	# Add extended options to run
	daemonctl_CLI_add_process_options(p_run)

	# start command
	p_start = subparsers.add_parser("start", help="Start app in background")
	p_start.add_argument("app_name", metavar="APP", help="Application name")
	p_start.add_argument(
		"-a", "--attach", action="store_true", help="Attach after starting"
	)
	p_start.add_argument("-w", "--wait", action="store_true", help="Wait for startup")
	p_start.add_argument(
		"-V", "--verbose", action="store_true", help="Verbose startup output"
	)
	# Add extended options to start
	daemonctl_CLI_add_process_options(p_start)

	# stop command
	p_stop = subparsers.add_parser("stop", help="Stop running app")
	p_stop.add_argument("app_name", metavar="APP", help="Application name")
	p_stop.add_argument(
		"-f", "--force", action="store_true", help="Force kill if needed"
	)
	p_stop.add_argument("-s", "--signal", metavar="SIG", help="Signal to send")
	p_stop.add_argument(
		"-t", "--timeout", type=int, default=30, metavar="SEC", help="Stop timeout"
	)
	p_stop.add_argument("-w", "--wait", action="store_true", help="Wait for exit")

	# restart command
	p_restart = subparsers.add_parser("restart", help="Restart app")
	p_restart.add_argument("app_name", metavar="APP", help="Application name")
	p_restart.add_argument(
		"-f", "--force", action="store_true", help="Force stop if needed"
	)
	p_restart.add_argument("-w", "--wait", action="store_true", help="Wait for restart")
	p_restart.add_argument(
		"-V", "--verbose", action="store_true", help="Verbose startup output"
	)

	# status command
	p_status = subparsers.add_parser("status", help="Show app status")
	p_status.add_argument("app_name", nargs="?", metavar="APP", help="Application name")
	p_status.add_argument("-a", "--all", action="store_true", help="Show all apps")
	p_status.add_argument("-l", "--long", action="store_true", help="Detailed status")
	p_status.add_argument(
		"-w", "--watch", action="store_true", help="Watch status continuously"
	)
	p_status.add_argument(
		"--refresh", type=int, default=2, metavar="SEC", help="Refresh interval"
	)
	p_status.add_argument(
		"-p", "--processes", action="store_true", help="Show process tree"
	)
	p_status.add_argument(
		"--resources", action="store_true", help="Show resource usage"
	)
	p_status.add_argument(
		"--health", action="store_true", help="Show health check status"
	)

	# list command
	p_list = subparsers.add_parser("list", help="List all apps")

	# logs command
	p_logs = subparsers.add_parser("logs", help="Show app logs")
	p_logs.add_argument("app_name", metavar="APP", help="Application name")
	p_logs.add_argument("-f", "--follow", action="store_true", help="Follow log output")
	p_logs.add_argument(
		"-n", "--lines", type=int, default=50, metavar="N", help="Lines to show"
	)
	p_logs.add_argument("--since", metavar="TIME", help="Show logs since time")
	p_logs.add_argument("--until", metavar="TIME", help="Show logs until time")
	p_logs.add_argument(
		"-t", "--timestamps", action="store_true", help="Show timestamps"
	)
	p_logs.add_argument(
		"--level",
		choices=["debug", "info", "warn", "error"],
		help="Filter by log level",
	)
	p_logs.add_argument(
		"--grep", metavar="PATTERN", help="Filter lines matching pattern"
	)
	p_logs.add_argument(
		"--tail", action="store_true", help="Start from end (default for --follow)"
	)
	p_logs.add_argument("--head", action="store_true", help="Start from beginning")

	# kill command
	p_kill = subparsers.add_parser("kill", help="Send signal to app")
	p_kill.add_argument("app_name", metavar="APP", help="Application name")
	p_kill.add_argument(
		"signal", nargs="?", default="TERM", metavar="SIG", help="Signal name"
	)
	p_kill.add_argument(
		"-a",
		"--all-processes",
		action="store_true",
		help="Send to all processes in group",
	)
	p_kill.add_argument(
		"-p", "--pid-only", action="store_true", help="Send only to main process"
	)
	p_kill.add_argument("-w", "--wait", action="store_true", help="Wait for signal")
	p_kill.add_argument(
		"--timeout", type=int, default=30, metavar="SEC", help="Timeout for wait"
	)

	return parser


# Function: daemonctl_CLI_dispatch ARGS
# Dispatch to appropriate command handler.
def daemonctl_CLI_dispatch(args: argparse.Namespace) -> int:
	"""Dispatch to the appropriate command handler."""
	commands = {
		"run": daemonctl_cmd_run,
		"start": daemonctl_cmd_start,
		"stop": daemonctl_cmd_stop,
		"restart": daemonctl_cmd_restart,
		"status": daemonctl_cmd_status,
		"list": daemonctl_cmd_list,
		"logs": daemonctl_cmd_logs,
		"kill": daemonctl_cmd_kill,
	}

	if not args.command:
		daemonctl_CLI_build_parser().print_help()
		return 0

	# Handle config subcommands
	if args.command == "config":
		config_cmd = getattr(args, "config_command", None)
		if config_cmd == "show":
			return daemonctl_cmd_config_show(args)
		elif config_cmd == "set":
			return daemonctl_cmd_config_set(args)
		else:
			# Print config help
			print("Usage: daemonctl config {show,set} ...")
			return 0

	handler = commands.get(args.command)
	if not handler:
		daemonctl_util_log("error", f"Unknown command: {args.command}")
		return 1

	return handler(args)


# -----------------------------------------------------------------------------
#
# MAIN
#
# -----------------------------------------------------------------------------


# Function: daemonctl_main
# Main entry point.
def daemonctl_main(argv: Optional[list[str]] = None) -> int:
	"""Main entry point."""
	global _verbose, _quiet, _no_color, _dry_run, _op_timeout, _base_path

	parser = daemonctl_CLI_build_parser()
	args = parser.parse_args(argv)

	# Apply global options
	_verbose = args.verbose
	_quiet = args.quiet
	_no_color = args.no_color or DAEMONCTL_NO_COLOR
	_dry_run = args.dry_run
	_op_timeout = args.op_timeout

	if args.path:
		_base_path = Path(args.path)

	return daemonctl_CLI_dispatch(args)


if __name__ == "__main__":
	sys.exit(daemonctl_main())

# EOF
