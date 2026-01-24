# Task: Daemonrun Options Alignment

## Status

**COMPLETE** - All proposed options have been implemented in daemonrun.sh

### Verification Summary
- Signal handling options: Implemented (lines 314-368)
- User/Group options: Implemented (lines 391-398)  
- Logging options: Implemented (lines 417-461)
- Daemonization options: Implemented (lines 407-414)
- Resource limit options: Implemented (lines 500-523)
- Sandboxing options: Implemented (lines 570-589)
- Validation logic: Implemented (lines 682-756)
- Help/usage text: Updated (lines 818-894)

Completed: 2026-01-25

---

## Objective

Align `daemonrun` CLI options with `daemonctl` configuration, ensuring daemonrun
has all necessary runtime options and daemonctl only contains options that either:
1. Map directly to daemonrun options
2. Are specific to daemon control (restart policies, health checks, delays)

## Summary of Changes Made

### Options Added to daemonrun

**Signal Handling:**
```
-A, --forward-all-signals    Forward all signals to process group (default: true)
--stop-signal SIG            Signal for graceful stop (default: TERM)
--reload-signal SIG          Signal for reload (default: HUP)
```

**User/Group:**
```
-G, --run-group GROUP        Run as specific group (requires root)
```

**Logging:**
```
--log-level LEVEL            Log level: debug,info,warn,error (default: info)
--stdout FILE                Redirect stdout to file
--stderr FILE                Redirect stderr to file
--syslog                     Log to syslog instead of file
```

**Daemonization:**
```
--umask OCTAL                Set file creation mask (default: 022)
```

**Resource Limits:**
```
--core-limit SIZE            Core dump size limit (e.g., 0, unlimited)
--stack-limit SIZE           Stack size limit (e.g., 8M)
--nice PRIORITY              Process niceness (-20 to 19, default: 0)
```

**Sandboxing:**
```
--caps-keep LIST             Keep only these capabilities (comma-separated)
--seccomp-profile FILE       Custom seccomp profile file
```

## Complete daemonrun CLI Reference

```
daemonrun [OPTIONS] [--] COMMAND [ARGS...]

Process management:
-g, --group NAME             Set process group name (default: command basename)
-s, --setsid                 Create new session with setsid() (default: true)
-f, --foreground             Keep process in foreground (no daemonization)

Signal handling:
-A, --forward-all-signals    Forward all signals to process group (default: true)
--no-signal-forward          Disable automatic signal forwarding
-S, --signal SIG             Forward specific signal (can be repeated)
--preserve-signals LIST      Don't forward these signals (comma-separated)
-k, --kill-timeout SEC       Timeout for SIGKILL after SIGTERM (default: 30)
--stop-signal SIG            Signal for graceful stop (default: TERM)
--reload-signal SIG          Signal for reload (default: HUP)

Daemonization:
-d, --daemon                 Double-fork to create true daemon
-p, --pidfile FILE           Write PID to file (default: /tmp/GROUPNAME.pid)
-u, --user USER              Run as specific user (requires root)
-G, --run-group GROUP        Run as specific group (requires root)
-C, --chdir DIR              Change working directory (default: /)
--umask OCTAL                Set file creation mask (default: 022)

Logging:
-l, --log FILE               Log events to file (default: stderr)
--log-level LEVEL            Log level: debug,info,warn,error (default: info)
--stdout FILE                Redirect stdout to file
--stderr FILE                Redirect stderr to file
--syslog                     Log to syslog instead of file
-q, --quiet                  Suppress all output except errors
-v, --verbose                Enable verbose logging

Resource Limits:
--memory-limit SIZE          Set memory limit (e.g., 512M, 1G)
--cpu-limit PERCENT          Set CPU usage limit (1-100)
--file-limit COUNT           Set maximum open files
--proc-limit COUNT           Set maximum processes/threads
--core-limit SIZE            Core dump size limit (e.g., 0, unlimited)
--stack-limit SIZE           Stack size limit (e.g., 8M)
--timeout SECONDS            Kill process after timeout
--nice PRIORITY              Process niceness (-20 to 19, default: 0)

Sandboxing:
--sandbox TYPE               Enable sandboxing: none,firejail,unshare (default: none)
--sandbox-profile FILE       Use custom sandbox profile
--private-tmp                Use private /tmp directory
--private-dev                Use private /dev directory
--no-network                 Disable network access
--caps-drop LIST             Drop capabilities (comma-separated)
--caps-keep LIST             Keep only these capabilities (comma-separated)
--seccomp                    Enable seccomp filtering
--seccomp-profile FILE       Custom seccomp profile
--readonly-paths LIST        Make paths read-only (colon-separated)
```

## Mapping Table: daemonctl config → daemonrun option

| daemonctl config | daemonrun option |
|------------------|------------------|
| daemon.name | --group |
| daemon.foreground | --foreground |
| daemon.double_fork | --daemon |
| daemon.setsid | --setsid |
| daemon.working_directory | --chdir |
| daemon.umask | --umask |
| process.command | COMMAND |
| process.args | ARGS... |
| process.priority | --nice |
| process.clear_env | --clear-env |
| security.user | --user |
| security.group | --run-group |
| security.capabilities_drop | --caps-drop |
| security.capabilities_keep | --caps-keep |
| logging.file | --log |
| logging.level | --log-level |
| logging.stdout_file | --stdout |
| logging.stderr_file | --stderr |
| logging.syslog | --syslog |
| logging.quiet | --quiet |
| logging.verbose | --verbose |
| pidfile.enabled | (--pidfile or omit) |
| pidfile.path | --pidfile |
| signals.forward_all | --forward-all-signals / --no-signal-forward |
| signals.forward_list | --signal (repeated) |
| signals.preserve_signals | --preserve-signals |
| signals.kill_timeout | --kill-timeout |
| signals.stop_signal | --stop-signal |
| signals.reload_signal | --reload-signal |
| sandbox.type | --sandbox |
| sandbox.profile | --sandbox-profile |
| sandbox.private_tmp | --private-tmp |
| sandbox.private_dev | --private-dev |
| sandbox.readonly_paths | --readonly-paths |
| sandbox.no_network | --no-network |
| sandbox.seccomp | --seccomp |
| sandbox.seccomp_profile | --seccomp-profile |
| limits.memory_limit | --memory-limit |
| limits.cpu_limit | --cpu-limit |
| limits.file_limit | --file-limit |
| limits.process_limit | --proc-limit |
| limits.core_limit | --core-limit |
| limits.stack_limit | --stack-limit |
| limits.timeout | --timeout |

## daemonctl-only Options (not passed to daemonrun)

These options are managed by daemonctl itself, not forwarded to daemonrun:

**Daemon metadata:**
- `daemon.description` - Human-readable description
- `daemon.enabled` - Whether to auto-start on boot

**Process lifecycle:**
- `process.environment` - Environment variables (set before calling daemonrun)
- `process.environment_file` - Environment file (sourced before daemonrun)
- `process.oom_score_adj` - OOM killer adjustment (set by daemonctl)
- `process.restart` - Restart policy
- `process.restart_delay` - Delay between restarts
- `process.restart_max_attempts` - Maximum restart attempts
- `process.start_timeout` - Timeout for process startup
- `process.stop_timeout` - Timeout for graceful shutdown

**Monitoring:**
- All `monitoring.*` options - Health checks managed by daemonctl

## daemonctl CLI Alignment

The daemonctl CLI options must align with daemonrun. Key changes:

| Old CLI | New CLI | Reason |
|---------|---------|--------|
| `-g, --group GROUP` | `-G, --run-group GROUP` | Align with daemonrun |
| `--priority NICE` | `--nice PRIORITY` | Align with daemonrun |
| `-t, --timeout` (global) | `-T, --op-timeout` | Disambiguate from limits.timeout |

## Implementation Notes

1. daemonctl constructs daemonrun command line from its configuration
2. Options not mappable to daemonrun are handled by daemonctl directly
3. Environment variables are set by daemonctl before invoking daemonrun
4. Log rotation should be handled externally (logrotate) not by daemonrun
5. When `--syslog` is used, daemonrun pipes output to `logger` command
