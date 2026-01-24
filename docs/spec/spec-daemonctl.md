# Daemonctl

`daemonctl` is a wrapper around `daemonrun`. `daemonctl` relies on the following
conventions, in `DAEMONCTL_PATH`:

```
${APP_NAME}/
  run/
    [conf.toml]             # Optional configuration
    [env.sh]                # Optional environment script, sourced before running any other
    run[.sh]                # Runs the application in the foreground
    [check[.sh]]            # Health check to run
    [on-start[.sh]]         # Script run when the application is working and started
    [on-stop[.sh]]          # Script run when the application is stopped
```


`daemonctl` offers the following commands:

```
# Process management
daemonctl run [OPTIONS] APP_NAME     # Runs as a daemon
daemonctl start [OPTIONS] APP_NAME   # Start new daemon
daemonctl stop APP_NAME              # Stop daemon by group name
daemonctl restart APP_NAME           # Restart daemon
daemonctl status [APP_NAME]          # Show status of daemon(s)
daemonctl list                       # List all managed daemons
daemonctl logs APP_NAME              # Show logs for daemon
daemonctl kill APP_NAME [SIGNAL]     # Send signal to daemon

# Configuration
daemonctl config show                # Show current configuration
daemonctl config set KEY=VALUE       # Set configuration option
```

## Options

Global options

```
# Configuration and Path Options
-c, --config FILE            # Use specific config file (default: ./conf.toml)
-p, --path DIR               # Set DAEMONCTL_PATH (default: current directory)
-e, --env FILE               # Additional environment file to source
--config-override KEY=VALUE  # Override any config value from CLI
--no-config                  # Ignore config files, use defaults only

# Output and Logging
-v, --verbose                # Verbose output
-q, --quiet                  # Suppress non-error output
--no-color                   # Disable colored output

# Global Behavior
-n, --dry-run                # Show what would be done without executing
-f, --force                  # Force operation, ignore warnings
-T, --op-timeout SECONDS     # Global timeout for operations (default: 30)
--help                       # Show help
--version                    # Show version
```


### Command: `daemonctl run [OPTIONS] APP_NAME`

Run application as daemon (combines start + attach):

#### Daemon Behavior
```
-d, --daemon                 # Double-fork to create true daemon (default: true)
-F, --foreground             # Keep in foreground, don't daemonize
-a, --attach                 # Attach to output after starting
--no-setsid                  # Don't create new session
```

### Process Management

```
-u, --user USER              # Run as specific user
-G, --run-group GROUP        # Run as specific group
-C, --chdir DIR              # Change working directory
--umask MASK                 # Set file creation mask (octal)
--nice PRIORITY              # Set process niceness (-20 to 19)
```

### Signal Handling

```
-A, --forward-all-signals    # Forward all signals (default: true)
--no-signal-forward          # Disable automatic signal forwarding
-S, --signal SIG             # Forward specific signal (repeatable)
--preserve-signals LIST      # Don't forward these signals (comma-separated)
-k, --kill-timeout SECONDS   # Timeout for SIGKILL after SIGTERM (default: 30)
--stop-signal SIGNAL         # Signal for graceful stop (default: TERM)
--reload-signal SIGNAL       # Signal for reload (default: HUP)
```

### Logging

```
-l, --log FILE               # Log file location
--log-level LEVEL            # Log level: debug,info,warn,error (default: info)
--stdout FILE                # Redirect stdout to file
--stderr FILE                # Redirect stderr to file
--syslog                     # Log to syslog instead
```

### Resource Limits

```
--memory-limit SIZE          # Memory limit (e.g., 512M, 1G)
--cpu-limit PERCENT          # CPU limit (1-100)
--file-limit COUNT           # Max open files
--proc-limit COUNT           # Max processes/threads
--core-limit SIZE            # Core dump size limit
--stack-limit SIZE           # Stack size limit
--timeout SECONDS            # Kill after timeout
```

### Sandboxing
```
--sandbox TYPE               # Enable sandbox: none,firejail,unshare
--sandbox-profile FILE       # Custom sandbox profile
--private-tmp                # Use private /tmp
--private-dev                # Use private /dev
--no-network                 # Disable network access
--readonly-paths PATHS       # Colon-separated read-only paths
--caps-drop CAPS             # Drop capabilities (comma-separated)
--caps-keep CAPS             # Keep only these capabilities (comma-separated)
--seccomp                    # Enable seccomp filtering
--seccomp-profile FILE       # Custom seccomp profile
```

### Environment

```
--env KEY=VALUE              # Set environment variable (repeatable)
--env-file FILE              # Load environment from file
--clear-env                  # Clear inherited environment
```

## Command: `daemonctl start [OPTIONS] APP_NAME`

Start daemon in background:

```
# Same options as 'run' but with different defaults:
-d, --daemon                 # Always true for start
-a, --attach                 # Attach after starting (default: false)
-w, --wait                   # Wait for startup to complete
--start-timeout SECONDS      # Timeout for startup (default: 60)
```

## Command: `daemonctl stop [OPTIONS] APP_NAME`

Stop running daemon:

```
-f, --force                  # Force kill if graceful stop fails
-s, --signal SIGNAL          # Signal to send (default: TERM)
-t, --timeout SECONDS        # Timeout before SIGKILL (default: 30)
-w, --wait                   # Wait for process to exit
--remove-pidfile             # Remove PID file after stop
```

## Command: `daemonctl restart [OPTIONS] APP_NAME`

Restart daemon:

```
# Combines stop + start options
-f, --force                  # Force stop if needed
-w, --wait                   # Wait for stop before start
--stop-timeout SECONDS       # Timeout for stop phase
--start-timeout SECONDS      # Timeout for start phase
--delay SECONDS              # Delay between stop and start
# Plus all options from 'start' command for restart behavior
```

## Command: `daemonctl status [OPTIONS] [APP_NAME]`

Show daemon status:

```
-a, --all                    # Show all apps (default if no APP_NAME)
-l, --long                   # Show detailed status
-w, --watch                  # Watch status continuously
--refresh SECONDS            # Refresh interval for watch (default: 2)
-p, --processes              # Show process tree
--resources                  # Show resource usage
--health                     # Show health check status
--json                       # Output as JSON
```

## Command `daemonctl list [OPTIONS]`

List all managed daemons, shows:

- name
- status
- pid
- memory
- cpu
- path
- stdout log path
- stderr log path

```
-l, --long                   # Show detailed info
--json                       # Output as JSON
```

Formatted as a tabulated grid with headers as `# HEADER HEADER` first line.

## Command: `daemonctl logs [OPTIONS] APP_NAME`

Show daemon logs:

```
-f, --follow                 # Follow log output (like tail -f)
-n, --lines COUNT            # Number of lines to show (default: 50)
--since TIME                 # Show logs since time (e.g., "2h", "2023-01-01")
--until TIME                 # Show logs until time
-t, --timestamps             # Show timestamps
--level LEVEL                # Filter by log level
--grep PATTERN               # Filter lines matching pattern
--tail                       # Start from end of log (default for --follow)
--head                       # Start from beginning of log
```

## Command: `daemonctl kill [OPTIONS] APP_NAME [SIGNAL]`

Send signal to daemon:

```
-a, --all-processes          # Send to all processes in group
-p, --pid-only               # Send only to main process
-w, --wait                   # Wait for signal to be processed
--timeout SECONDS            # Timeout for wait
```

## Command: `daemonctl config [OPTIONS] [APP_NAME]`

Configuration management:
```
-a, --all                    # Show all app configs
-g, --global                 # Show global config only
--format FORMAT              # Output format: toml,json,yaml
--resolved                   # Show resolved config (after overrides)
--path PATH                  # Show specific config path
```

### Environment Variable Support

```
# Global environment variables
DAEMONCTL_PATH=/path/to/apps          # Default app directory
DAEMONCTL_CONFIG=/path/to/config      # Global config file
DAEMONCTL_LOG_LEVEL=info              # Default log level
DAEMONCTL_OP_TIMEOUT=30               # Default operation timeout
DAEMONCTL_NO_COLOR=1                  # Disable colors

# Per-app environment variables
DAEMONCTL_MYAPP_USER=appuser          # Override user for 'myapp'
DAEMONCTL_MYAPP_MEMORY_LIMIT=512M     # Override memory limit
```

## Configuration

All configuration options map directly to `daemonrun` CLI options unless marked
as "daemonctl-only" (these are managed by daemonctl, not passed to daemonrun).

### Daemon Settings

```
daemon.name=string              # Process group name (default: command basename)
                                # Maps to: --group
daemon.description=string       # Human-readable description (daemonctl-only)
daemon.enabled=boolean          # Auto-start on boot (default: true, daemonctl-only)
daemon.foreground=boolean       # Keep in foreground (default: false)
                                # Maps to: --foreground
daemon.double_fork=boolean      # True daemonization (default: true)
                                # Maps to: --daemon
daemon.setsid=boolean           # Create new session (default: true)
                                # Maps to: --setsid
daemon.working_directory=path   # Working directory (default: /)
                                # Maps to: --chdir
daemon.umask=octal              # File creation mask (default: 022)
                                # Maps to: --umask
```

### Process Management

```
process.command=string                  # Command to execute (required)
process.args=array[string]              # Command arguments
process.environment=map[string]         # Environment variables (daemonctl-only)
process.environment_file=path           # Environment file (daemonctl-only)
process.clear_env=boolean               # Clear inherited environment (default: false)
                                        # Maps to: --clear-env
process.priority=integer                # Process niceness (-20 to 19, default: 0)
                                        # Maps to: --nice
process.oom_score_adj=integer           # OOM killer adjustment (-1000 to 1000, daemonctl-only)
process.restart=boolean                 # Restart on exit (default: false, daemonctl-only)
process.restart_delay=duration          # Delay between restarts (default: 5s, daemonctl-only)
process.restart_max_attempts=integer    # Max restart attempts (default: 3, daemonctl-only)
process.start_timeout=duration          # Startup timeout (default: 60s, daemonctl-only)
process.stop_timeout=duration           # Shutdown timeout (default: 30s, daemonctl-only)
```

### User and Group Settings

```
security.user=string                    # Run as specific user
                                        # Maps to: --user
security.group=string                   # Run as specific group
                                        # Maps to: --run-group
security.capabilities_drop=array[string] # Capabilities to drop
                                        # Maps to: --caps-drop
security.capabilities_keep=array[string] # Capabilities to keep
                                        # Maps to: --caps-keep
```

### Logging Configuration

```
logging.file=path               # Log file path (default: stderr)
                                # Maps to: --log
logging.level=enum              # Log level: debug,info,warn,error (default: info)
                                # Maps to: --log-level
logging.stdout_file=path        # Redirect stdout to file
                                # Maps to: --stdout
logging.stderr_file=path        # Redirect stderr to file
                                # Maps to: --stderr
logging.syslog=boolean          # Log to syslog (default: false)
                                # Maps to: --syslog
logging.quiet=boolean           # Suppress output except errors (default: false)
                                # Maps to: --quiet
logging.verbose=boolean         # Enable verbose logging (default: false)
                                # Maps to: --verbose
```

### PID File Management

```
pidfile.enabled=boolean         # Create PID file (default: true)
pidfile.path=path               # PID file location (default: /tmp/{name}.pid)
                                # Maps to: --pidfile
```

### Signal Handling

```
signals.forward_all=boolean             # Forward all signals (default: true)
                                        # Maps to: --forward-all-signals / --no-signal-forward
signals.forward_list=array[string]      # Specific signals to forward
                                        # Maps to: --signal (repeated)
signals.preserve_signals=array[string]  # Don't forward these signals
                                        # Maps to: --preserve-signals
signals.kill_timeout=duration           # SIGKILL timeout after SIGTERM (default: 30s)
                                        # Maps to: --kill-timeout
signals.stop_signal=string              # Signal for graceful stop (default: TERM)
                                        # Maps to: --stop-signal
signals.reload_signal=string            # Signal for reload (default: HUP)
                                        # Maps to: --reload-signal
```

### Sandboxing Options

```
sandbox.type=enum               # Sandbox type: none,firejail,unshare (default: none)
                                # Maps to: --sandbox
sandbox.profile=path            # Custom sandbox profile file
                                # Maps to: --sandbox-profile
sandbox.private_tmp=boolean     # Use private /tmp (default: false)
                                # Maps to: --private-tmp
sandbox.private_dev=boolean     # Use private /dev (default: false)
                                # Maps to: --private-dev
sandbox.readonly_paths=array[path] # Paths to make read-only
                                # Maps to: --readonly-paths
sandbox.no_network=boolean      # Disable network access (default: false)
                                # Maps to: --no-network
sandbox.seccomp=boolean         # Enable seccomp filtering (default: false)
                                # Maps to: --seccomp
sandbox.seccomp_profile=path    # Custom seccomp profile
                                # Maps to: --seccomp-profile
```

### Resource Limits

```
limits.memory_limit=size        # Maximum memory (e.g., 512M, 1G)
                                # Maps to: --memory-limit
limits.cpu_limit=percentage     # CPU usage limit (1-100)
                                # Maps to: --cpu-limit
limits.file_limit=integer       # Maximum open files
                                # Maps to: --file-limit
limits.process_limit=integer    # Maximum processes/threads
                                # Maps to: --proc-limit
limits.core_limit=size          # Core dump size limit
                                # Maps to: --core-limit
limits.stack_limit=size         # Stack size limit
                                # Maps to: --stack-limit
limits.timeout=duration         # Kill process after timeout
                                # Maps to: --timeout
```

### Monitoring and Health Checks

All monitoring options are daemonctl-only (daemonrun does not handle health checks).

```
monitoring.enabled=boolean              # Enable health monitoring (default: false)
monitoring.check_interval=duration      # Health check interval (default: 30s)
monitoring.check_command=string         # Command to run for health check
monitoring.check_timeout=duration       # Health check timeout (default: 10s)
monitoring.failure_threshold=integer    # Failures before restart (default: 3)
monitoring.success_threshold=integer    # Successes to mark healthy (default: 1)
monitoring.startup_delay=duration       # Delay before first check (default: 60s)
```

## Implementation

Implement `daemonctl.py` using typed python 3.4, no external dependency, stlib only,
following this structure:

```
#!/usr/bin/env python
# --
# File: Daemonctl
#
# `daemonctl` is…

import …

# -----------------------------------------------------------------------------
#
# SECTION
#
# -----------------------------------------------------------------------------

# =============================================================================
# GROUP
# =============================================================================

# Function: daemonrun_function ARGS
# Documentation in NaturalDocs
def daemonctl_function():
  …

# -----------------------------------------------------------------------------
#
# MAIN
#
# -----------------------------------------------------------------------------

# Function: dameonrun_main
# Main cli
def daemonctl_main():
  …

# Can be used as a library or executable
if __name__ == "__main__":
  daemonctl_main()

# EOF
```

When organising the file, follow this order

- Globals, environment configuration first
- Types
- Common utilities
- Groups of functions
- High-level API
- CLI wrappers
- Main

When naming functions follow `daemonctl_{group}_{operation}` and focus on consistency and clarity.

Implementation style is compact, we want a small file, not too many lines.

Rules:
- Uses `daemonrun` for underlying operations
- Uses `teelog` for managing log outputs
