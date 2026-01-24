# Task: daemonctl Full Implementation (Phase 2)

## Overview

Complete the full `daemonctl` implementation beyond MVP, adding all remaining features from the spec.

## Prerequisites

- [x] task-daemonctl-001-implement.md completed (MVP)

## Remaining Commands

### Config Commands
```
daemonctl config show [APP]     # Show current configuration
daemonctl config set KEY=VALUE  # Set configuration option
```

**Options for config:**
```
-a, --all               # Show all app configs
-g, --global            # Show global config only
--format FORMAT         # Output format: toml,json,yaml
--resolved              # Show resolved config (after overrides)
--path PATH             # Show specific config path
```

## Remaining Options

### Run/Start Options

**Process Management:**
```
-u, --user USER         # Run as specific user
-G, --run-group GROUP   # Run as specific group
-C, --chdir DIR         # Change working directory
--umask MASK            # Set file creation mask
--nice PRIORITY         # Set process niceness (-20 to 19)
```

**Signal Handling:**
```
-A, --forward-all-signals   # Forward all signals (default)
--no-signal-forward         # Disable signal forwarding
-S, --signal SIG            # Forward specific signal
--preserve-signals LIST     # Don't forward these signals
-k, --kill-timeout SEC      # Timeout for SIGKILL (default: 30)
--stop-signal SIGNAL        # Signal for graceful stop (default: TERM)
--reload-signal SIGNAL      # Signal for reload (default: HUP)
```

**Logging:**
```
-l, --log FILE          # Log file location
--log-level LEVEL       # Log level: debug,info,warn,error
--stdout FILE           # Redirect stdout to file
--stderr FILE           # Redirect stderr to file
--syslog                # Log to syslog
```

**Resource Limits:**
```
--memory-limit SIZE     # Memory limit (e.g., 512M, 1G)
--cpu-limit PERCENT     # CPU limit (1-100)
--file-limit COUNT      # Max open files
--proc-limit COUNT      # Max processes/threads
--core-limit SIZE       # Core dump size limit
--stack-limit SIZE      # Stack size limit
--timeout SECONDS       # Kill after timeout
```

**Sandboxing:**
```
--sandbox TYPE          # Enable sandbox: none,firejail,unshare
--sandbox-profile FILE  # Custom sandbox profile
--private-tmp           # Use private /tmp
--private-dev           # Use private /dev
--no-network            # Disable network access
--readonly-paths PATHS  # Colon-separated read-only paths
--caps-drop CAPS        # Drop capabilities
--caps-keep CAPS        # Keep only these capabilities
--seccomp               # Enable seccomp filtering
--seccomp-profile FILE  # Custom seccomp profile
```

**Environment:**
```
--env KEY=VALUE         # Set environment variable
--env-file FILE         # Load environment from file
--clear-env             # Clear inherited environment
--config-override K=V   # Override config value from CLI
--no-config             # Ignore config files
```

### Status Options
```
-w, --watch             # Watch status continuously
--refresh SECONDS       # Refresh interval (default: 2)
-p, --processes         # Show process tree
--resources             # Show resource usage
--health                # Show health check status
```

### Logs Options
```
--since TIME            # Show logs since time
--until TIME            # Show logs until time
-t, --timestamps        # Show timestamps
--level LEVEL           # Filter by log level
--grep PATTERN          # Filter lines matching pattern
--tail                  # Start from end (default for --follow)
--head                  # Start from beginning
```

### Kill Options
```
-a, --all-processes     # Send to all processes in group
-p, --pid-only          # Send only to main process
-w, --wait              # Wait for signal to be processed
--timeout SECONDS       # Timeout for wait
```

## Health Monitoring (daemonctl-only)

Implement persistent supervisor with health checks:

```python
@dataclass
class MonitoringConfig:
    enabled: bool = False
    check_interval: int = 30        # seconds
    check_command: str = ""         # or use check[.sh] script
    check_timeout: int = 10         # seconds
    failure_threshold: int = 3      # failures before restart
    success_threshold: int = 1      # successes to mark healthy
    startup_delay: int = 60         # delay before first check
```

### Supervisor Mode

When `daemonctl run` is used (not `start`), implement:

1. Start the app via daemonrun
2. Run health checks at configured intervals
3. Track consecutive failures
4. Auto-restart on failure threshold
5. Run on-start/on-stop hooks appropriately
6. Handle signals for clean shutdown

```python
def daemonctl_supervisor_run(app_name: str, config: AppConfig) -> int:
    """Run as persistent supervisor with health monitoring."""
    # Start app
    # Enter monitoring loop
    # Handle restarts on failures
    # Clean shutdown on signals
```

## Additional Config Sections

### Full Type Definitions

```python
@dataclass
class SecurityConfig:
    user: str = ""
    group: str = ""
    capabilities_drop: list[str] = field(default_factory=list)
    capabilities_keep: list[str] = field(default_factory=list)

@dataclass
class SandboxConfig:
    type: str = "none"              # none, firejail, unshare
    profile: str = ""
    private_tmp: bool = False
    private_dev: bool = False
    readonly_paths: list[str] = field(default_factory=list)
    no_network: bool = False
    seccomp: bool = False
    seccomp_profile: str = ""

@dataclass
class LimitsConfig:
    memory_limit: str = ""          # e.g., "512M"
    cpu_limit: int = 0              # 1-100
    file_limit: int = 0
    process_limit: int = 0
    core_limit: str = ""
    stack_limit: str = ""
    timeout: int = 0

@dataclass
class MonitoringConfig:
    enabled: bool = False
    check_interval: int = 30
    check_command: str = ""
    check_timeout: int = 10
    failure_threshold: int = 3
    success_threshold: int = 1
    startup_delay: int = 60
```

## teelog Integration

For log rotation, integrate with `teelog.sh`:

```python
def daemonctl_app_start_with_teelog(app_name: str, config: AppConfig) -> int:
    """Start app with teelog for log rotation."""
    teelog_args = []
    if config.logging.max_size:
        teelog_args.extend(["--max-size", config.logging.max_size])
    if config.logging.max_age:
        teelog_args.extend(["--max-age", config.logging.max_age])
    if config.logging.max_count:
        teelog_args.extend(["--max-count", str(config.logging.max_count)])
    
    # Build command: teelog [opts] out.log err.log -- daemonrun [opts] -- ./run
```

## Environment Variable Support

Per-app environment overrides:

```python
def daemonctl_config_from_env(app_name: str) -> dict:
    """Load config overrides from DAEMONCTL_{APP}_{KEY} env vars."""
    prefix = f"DAEMONCTL_{app_name.upper()}_"
    overrides = {}
    for key, value in os.environ.items():
        if key.startswith(prefix):
            config_key = key[len(prefix):].lower()
            overrides[config_key] = value
    return overrides
```

## Watch Mode for Status

```python
def daemonctl_cmd_status_watch(args: argparse.Namespace) -> int:
    """Continuously display status with refresh."""
    import curses
    # Or simple terminal clear + reprint
    while True:
        os.system('clear')
        daemonctl_cmd_status(args)
        time.sleep(args.refresh)
```

## Process Tree Display

```python
def daemonctl_process_tree(PID: int) -> list[dict]:
    """Get process tree starting from PID."""
    # Read /proc/{pid}/task for threads
    # Read /proc to find children (ppid == pid)
    # Build tree structure
```

## Acceptance Criteria

- [x] All config options implemented
- [x] All CLI options implemented
- [x] Config commands (show, set) work
- [x] Health monitoring with auto-restart works
- [x] Supervisor mode (`run`) vs background mode (`start`) work correctly
- [x] teelog integration for log rotation
- [x] Watch mode for status
- [x] Process tree display
- [x] Resource limit enforcement
- [x] Sandbox options passed to daemonrun
- [x] Environment variable overrides work
- [ ] Full test coverage
