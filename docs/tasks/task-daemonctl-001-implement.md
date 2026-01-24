# Task: daemonctl MVP Implementation

## Overview

Implement `daemonctl.py` - a daemon management wrapper around `daemonrun.sh` and `teelog.sh`.

## Target

- Python 3.11+ (stdlib only, use `tomllib`)
- Subprocess integration with existing shell scripts
- Persistent supervisor mode for health monitoring
- Compact implementation (~800 lines)

## MVP Commands

| Command | Description |
|---------|-------------|
| `daemonctl run APP` | Run as daemon with supervisor (attach mode) |
| `daemonctl start APP` | Start daemon in background |
| `daemonctl stop APP` | Stop daemon gracefully |
| `daemonctl status [APP]` | Show status of daemon(s) |
| `daemonctl list` | List all managed daemons |
| `daemonctl logs APP` | Show/follow daemon logs |
| `daemonctl restart APP` | Stop + start |
| `daemonctl kill APP [SIG]` | Send signal to daemon |

## MVP Options

### Global Options
```
-c, --config FILE       # Use specific config file
-p, --path DIR          # Set DAEMONCTL_PATH
-e, --env FILE          # Additional environment file
-v, --verbose           # Verbose output
-q, --quiet             # Suppress non-error output
--no-color              # Disable colored output
-n, --dry-run           # Show what would be done
-f, --force             # Force operation
-T, --op-timeout SEC    # Operation timeout (default: 30)
--help                  # Show help
--version               # Show version
```

### Command-Specific Options

**run/start:**
```
-d, --daemon            # Daemonize (default for start)
-F, --foreground        # Keep in foreground
-a, --attach            # Attach to output after starting
-w, --wait              # Wait for startup to complete
```

**stop:**
```
-f, --force             # Force kill if graceful stop fails
-t, --timeout SEC       # Timeout before SIGKILL (default: 30)
-w, --wait              # Wait for process to exit
```

**status:**
```
-a, --all               # Show all apps
-l, --long              # Detailed status
```

**logs:**
```
-f, --follow            # Follow log output
-n, --lines COUNT       # Number of lines (default: 50)
```

## File Structure

```python
#!/usr/bin/env python
# --
# File: daemonctl.py

import ...

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
# VERSION, DAEMONCTL_PATH, tool paths, global state

# -----------------------------------------------------------------------------
# TYPES
# -----------------------------------------------------------------------------
# @dataclass: DaemonConfig, ProcessConfig, LoggingConfig, PIDFileConfig,
#             SignalsConfig, AppConfig

# -----------------------------------------------------------------------------
# UTILITIES
# -----------------------------------------------------------------------------
# daemonctl_util_log, daemonctl_util_color, daemonctl_util_run,
# daemonctl_util_parse_duration, daemonctl_util_parse_size

# -----------------------------------------------------------------------------
# CONFIG
# -----------------------------------------------------------------------------
# daemonctl_config_load, daemonctl_config_to_daemonrun_args,
# daemonctl_config_from_env

# -----------------------------------------------------------------------------
# PROCESS
# -----------------------------------------------------------------------------
# daemonctl_process_PID_path, daemonctl_process_PID_read,
# daemonctl_process_PID_write, daemonctl_process_PID_remove,
# daemonctl_process_is_running, daemonctl_process_info,
# daemonctl_process_signal, daemonctl_process_wait

# -----------------------------------------------------------------------------
# APP
# -----------------------------------------------------------------------------
# daemonctl_app_path, daemonctl_app_exists, daemonctl_app_list,
# daemonctl_app_status, daemonctl_app_source_env, daemonctl_app_run_hook,
# daemonctl_app_get_run_cmd

# -----------------------------------------------------------------------------
# COMMANDS
# -----------------------------------------------------------------------------
# daemonctl_cmd_run, daemonctl_cmd_start, daemonctl_cmd_stop,
# daemonctl_cmd_restart, daemonctl_cmd_status, daemonctl_cmd_list,
# daemonctl_cmd_logs, daemonctl_cmd_kill

# -----------------------------------------------------------------------------
# CLI
# -----------------------------------------------------------------------------
# daemonctl_CLI_build_parser, daemonctl_CLI_parse, daemonctl_CLI_dispatch

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------
# daemonctl_main

if __name__ == "__main__":
    sys.exit(daemonctl_main())
```

## App Directory Convention

```
${DAEMONCTL_PATH}/${APP_NAME}/
  run/
    [conf.toml]         # Optional configuration
    [env.sh]            # Optional environment script
    run[.sh]            # Runs the application (required)
    [check[.sh]]        # Health check
    [on-start[.sh]]     # Hook: after start
    [on-stop[.sh]]      # Hook: after stop
```

## Config to daemonrun Mapping

| Config Key | daemonrun Option |
|------------|------------------|
| `daemon.name` | `--group` |
| `daemon.foreground` | `--foreground` |
| `daemon.double_fork` | `--daemon` |
| `daemon.setsid` | `--setsid` / `--no-setsid` |
| `daemon.working_directory` | `--chdir` |
| `daemon.umask` | `--umask` |
| `process.priority` | `--nice` |
| `process.clear_env` | `--clear-env` |
| `security.user` | `--user` |
| `security.group` | `--run-group` |
| `logging.file` | `--log` |
| `logging.level` | `--log-level` |
| `logging.stdout_file` | `--stdout` |
| `logging.stderr_file` | `--stderr` |
| `logging.syslog` | `--syslog` |
| `pidfile.path` | `--pidfile` |
| `signals.kill_timeout` | `--kill-timeout` |
| `signals.stop_signal` | `--stop-signal` |

## List Output Format

```
# NAME       STATUS   PID    MEMORY  CPU   PATH
  myapp      running  12345  128M    2.1%  /apps/myapp/run
  webapp     stopped  -      -       -     /apps/webapp/run
```

## Naming Conventions

- Functions: `daemonctl_{section}_{operation}`
- Acronyms: UPPERCASE (`PID`, `CPU`, `CLI`, `TOML`)
- Types: PascalCase with UPPERCASE acronyms (`PIDFileConfig`)

## Acceptance Criteria

- [ ] All MVP commands implemented and functional
- [ ] Global options work across all commands
- [ ] Config loading from `conf.toml` works
- [ ] Environment sourcing from `env.sh` works
- [ ] PID file management works correctly
- [ ] Process status reads from `/proc`
- [ ] Hooks (`on-start`, `on-stop`) are executed
- [ ] `daemonrun.sh` integration via subprocess works
- [ ] List/status output is properly formatted
- [ ] Dry-run mode shows commands without executing
- [ ] Error handling with clear messages
- [ ] Works as both CLI and importable library
