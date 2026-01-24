# Daemonrun Implementation Plan

## Overview

`daemonrun` is a CLI tool and library to run processes with:
- Named process groups with `setsid()`
- Proper signal forwarding to all processes within process group
- Graceful termination with configurable timeout
- Optional logging of events
- Optional daemonization through double-fork
- Optional sandboxing (firejail, unshare)
- Optional resource limits

## API

```bash
daemonrun [OPTIONS] [--] COMMAND [ARGS...]
```

### Options

| Category | Option | Description | Default |
|----------|--------|-------------|---------|
| **Process** | `-g, --group NAME` | Process group name | command basename |
| | `-s, --setsid` | Create new session | true |
| | `-f, --foreground` | Keep in foreground | false |
| **Signal** | `-k, --kill-timeout SEC` | Graceful termination timeout | 30 |
| | `-S, --signal SIG` | Forward specific signals (overrides default) | TERM,INT,HUP,USR1,USR2,QUIT |
| | `--no-signal-forward` | Disable signal forwarding | - |
| | `--preserve-signals LIST` | Don't forward these signals | - |
| **Daemon** | `-d, --daemon` | Double-fork daemonization | false |
| | `-p, --pidfile FILE` | PID file path | /tmp/GROUP.pid |
| | `-u, --user USER` | Run as user (requires root) | - |
| | `-C, --chdir DIR` | Working directory | / (daemon) or unchanged |
| **Logging** | `-l, --log FILE` | Log file | stderr |
| | `-q, --quiet` | Suppress non-error output | false |
| | `-v, --verbose` | Enable debug logging | false |
| **Limits** | `--memory-limit SIZE` | Memory limit (512M, 1G) | - |
| | `--cpu-limit PERCENT` | CPU limit (requires cpulimit) | - |
| | `--file-limit COUNT` | Max open files | - |
| | `--proc-limit COUNT` | Max processes | - |
| | `--timeout SECONDS` | Kill after timeout | - |
| **Sandbox** | `--sandbox TYPE` | none, firejail, unshare | none |
| | `--sandbox-profile FILE` | Custom sandbox profile | - |
| | `--private-tmp` | Private /tmp | false |
| | `--private-dev` | Private /dev | false |
| | `--no-network` | Disable network | false |
| | `--caps-drop LIST` | Drop capabilities | - |
| | `--seccomp` | Enable seccomp (firejail only) | false |
| | `--readonly-paths LIST` | Read-only paths (firejail only) | - |

## Naming Convention

All functions follow `daemonrun_{group}_{operation}` pattern:

| Group | Purpose |
|-------|---------|
| `log_` | Logging (write, debug, info, warn, error) |
| `parse_` | Argument parsing (size, list, args, validate, usage) |
| `signal_` | Signal handling (setup, handler, terminate, cleanup) |
| `pidfile_` | PID file management (path, check, write, read, remove) |
| `process_` | Process management (session_create, privileges_drop, chdir, command_check) |
| `limit_` | Resource limits (apply, memory, files, procs, cpu, timeout_setup, timeout_cancel) |
| `sandbox_` | Sandboxing (available, validate, build_command, firejail_args, unshare_args) |
| `run_` | Execution (foreground, daemon, exec) |

## Design Decisions

| Decision | Resolution |
|----------|------------|
| CPU limiting | Use `cpulimit` if present, warn if not available |
| Seccomp with unshare | Skip silently (not supported) |
| Readonly paths with unshare | Error: only supported with firejail |
| Signal forwarding | Enabled by default, `--signal` overrides default set |
| Log format | `YYYY-MM-DD HH:MM:SS [LEVEL] [GROUP:PID] MESSAGE` |

## Edge Cases

### Argument Validation

| Edge Case | Handling |
|-----------|----------|
| `--daemon` + `--foreground` | Error: mutually exclusive options |
| Empty command (no COMMAND given) | Error with usage message |
| Invalid signal name | Error with list of valid signals |
| Invalid size format (e.g., "10X") | Error with format examples |
| Negative timeout | Error: must be positive integer |
| CPU limit > 100 or < 1 | Error: must be 1-100 |

### PID File

| Edge Case | Handling |
|-----------|----------|
| PID file exists, process running | Error: "already running (PID X)" |
| PID file exists, process dead | Warn about stale file, remove it, continue |
| PID file directory not writable | Error before forking with clear message |
| PID file path is relative | Convert to absolute path |
| Cannot write PID file after fork | Log error, continue (non-fatal) |

### Process Management

| Edge Case | Handling |
|-----------|----------|
| Command not found | Error before forking: "command not found: X" |
| Command not executable | Error: "permission denied: X" |
| User doesn't exist (--user) | Error: "user not found: X" |
| Not root but --user specified | Error: "must be root to change user" |
| Chdir path doesn't exist | Error before forking: "directory not found: X" |
| Chdir path not a directory | Error: "not a directory: X" |
| setsid not available | Warn, continue without session creation |

### Signal Handling

| Edge Case | Handling |
|-----------|----------|
| SIGKILL received during graceful shutdown | Accept immediately, exit |
| Child exits before signal setup complete | Detect via wait, report exit code |
| Kill timeout = 0 | Skip SIGTERM, send SIGKILL immediately |
| Signal received after child exits | Ignore gracefully |
| Multiple rapid signals | Process first, ignore duplicates during handling |

### Resource Limits

| Edge Case | Handling |
|-----------|----------|
| Permission denied for ulimit | Warn, continue (soft failure) |
| cpulimit not installed | Warn: "cpulimit not found, CPU limit skipped" |
| Invalid memory size | Error with valid format examples |
| Limit exceeds system maximum | Warn, apply system maximum |

### Sandboxing

| Edge Case | Handling |
|-----------|----------|
| firejail not installed | Error: "firejail not found, install with: ..." |
| unshare not installed | Error: "unshare not found" |
| `--readonly-paths` with unshare | Error: "readonly-paths only supported with firejail" |
| `--seccomp` with unshare | Debug log: "seccomp not supported with unshare, skipped" |
| `--sandbox-profile` file not found | Error: "sandbox profile not found: X" |
| Sandbox + user change | Apply user change inside sandbox |

### Daemonization

| Edge Case | Handling |
|-----------|----------|
| Fork fails | Error with errno message |
| Cannot redirect to /dev/null | Error: "cannot redirect file descriptors" |
| Parent exits before child writes PID | Use pipe for synchronization |
| Log file not writable in daemon mode | Error before forking |

### Timeout

| Edge Case | Handling |
|-----------|----------|
| Process exits before timeout | Cancel timeout watchdog |
| Timeout fires during graceful shutdown | Let graceful shutdown complete |
| Timeout = 0 | Disable timeout (run indefinitely) |

## Execution Flow

```
daemonrun_main
    |
    +-- daemonrun_parse_args
    +-- daemonrun_parse_validate
    |       +-- Check daemon/foreground conflict
    |       +-- daemonrun_process_command_check
    |       +-- Validate user exists (if --user)
    |       +-- Validate chdir exists (if --chdir)
    |       +-- daemonrun_sandbox_validate
    |
    +-- daemonrun_pidfile_check
    |       +-- Error if already running
    |       +-- Remove stale PID file
    |
    +-- Dispatch
            |
            +-- [foreground] daemonrun_run_foreground
            |       +-- daemonrun_signal_setup
            |       +-- daemonrun_process_chdir
            |       +-- daemonrun_process_privileges_drop
            |       +-- Fork child
            |       |       +-- daemonrun_limit_apply
            |       |       +-- daemonrun_sandbox_build_command
            |       |       +-- exec (with setsid if enabled)
            |       +-- daemonrun_pidfile_write (child PID)
            |       +-- daemonrun_limit_cpu (background cpulimit)
            |       +-- daemonrun_limit_timeout_setup
            |       +-- Wait for child
            |       +-- daemonrun_signal_cleanup
            |       +-- Return exit code
            |
            +-- [daemon] daemonrun_run_daemon
                    +-- First fork (parent exits)
                    +-- setsid (new session)
                    +-- Second fork (session leader exits)
                    +-- Close stdin/stdout/stderr
                    +-- Redirect to /dev/null (or log file)
                    +-- daemonrun_process_chdir
                    +-- daemonrun_process_privileges_drop
                    +-- daemonrun_pidfile_write (final PID)
                    +-- daemonrun_limit_apply
                    +-- daemonrun_sandbox_build_command
                    +-- exec command
```

## Function Specifications

### Logging

```bash
# Function: daemonrun_log_write LEVEL MESSAGE...
# Core logging function.
#
# Parameters:
#   LEVEL   - Numeric level (0=DEBUG, 1=INFO, 2=WARN, 3=ERROR)
#   MESSAGE - Message parts
#
# Output format: YYYY-MM-DD HH:MM:SS [LEVEL] [GROUP:PID] MESSAGE

# Function: daemonrun_log_debug MESSAGE...
# Function: daemonrun_log_info MESSAGE...
# Function: daemonrun_log_warn MESSAGE...
# Function: daemonrun_log_error MESSAGE...
```

### Signal Handling

```bash
# Function: daemonrun_signal_setup
# Install handlers for configured signals.
# Traps: EXIT (cleanup), configured forward signals

# Function: daemonrun_signal_handler SIGNAL
# Forward signal to process group (-$PGID)

# Function: daemonrun_signal_terminate
# Graceful shutdown sequence:
# 1. Send SIGTERM to process group
# 2. Wait up to kill_timeout seconds
# 3. Send SIGKILL if still running

# Function: daemonrun_signal_cleanup
# EXIT handler: remove PID file, cancel timeout
```

### Sandboxing

```bash
# Function: daemonrun_sandbox_build_command
# Returns complete command with sandbox wrapper:
#
# none:     command args...
# firejail: firejail [options] -- command args...
# unshare:  unshare [options] -- command args...
```

## Testing Scenarios

1. **Basic foreground:** `daemonrun --foreground -- sleep 10`
2. **Signal forwarding:** Send SIGTERM, verify child receives it
3. **Graceful timeout:** Child ignores SIGTERM, verify SIGKILL after timeout
4. **Daemon mode:** Verify double-fork, PID file, detached process
5. **Resource limits:** Verify ulimit applied
6. **Sandbox firejail:** Verify isolated execution
7. **Already running:** Verify error when PID file exists with live process
8. **Stale PID file:** Verify cleanup and restart
