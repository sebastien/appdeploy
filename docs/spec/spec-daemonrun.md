# Daemonrun

`daemonrun` is a CLI tool and library to run processes with the following
features:

- Named process groups with `setsid()`
- Proper signal forwarding to all processes within process group
- Graceful termination
- Optional logging of events
- Optional daemonisation through double-fork
- Optional sandboxing


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

Basic usage:

```
# Simple process group with logging
daemonrun --group myapp --log /var/log/myapp.log ./myapp

# Daemonize with PID file
daemonrun --daemon --pidfile /var/run/myapp.pid --group myapp ./myapp

# Foreground with signal forwarding
daemonrun --foreground --group webserver nginx -g "daemon off;"
```

Advanced usage:

```
# Firejail sandbox with network isolation
daemonrun --sandbox firejail --no-network --private-tmp \
          --group isolated-app ./untrusted-app

# Custom unshare sandbox
daemonrun --sandbox unshare --private-dev --readonly-paths /etc:/usr \
          --group secure-service ./service

# Resource-limited execution
daemonrun --memory-limit 512M --cpu-limit 50 --timeout 3600 \
          --group batch-job ./batch-processor

```

Integration

```
# Systemd-style service
daemonrun --daemon --user myapp --run-group myapp \
          --pidfile /var/run/myapp.pid --log /var/log/myapp.log \
          --chdir /opt/myapp ./myapp-server

# Development with auto-restart (using external wrapper)
while true; do
    daemonrun --foreground --group dev-server --log-level debug ./dev-server
    sleep 1
done

# Container-like isolation
daemonrun --sandbox unshare --private-tmp --private-dev \
          --no-network --caps-drop all --seccomp \
          --memory-limit 256M --proc-limit 10 \
          --group isolated ./isolated-task

# Separate stdout/stderr logging
daemonrun --daemon --group myapp \
          --stdout /var/log/myapp/stdout.log \
          --stderr /var/log/myapp/stderr.log \
          ./myapp

# Syslog integration
daemonrun --daemon --group myapp --syslog ./myapp
```

## Implementation

Should be implemented in bash in `daemonrun.sh`, following this template

```
#!/usr/bin/env bash
# --
# File: Daemonrun
#
# `daemonrun` is…

set -euo pipefail

# CONFIGURATION
DAEMONRUN_...=...

# DEFAULTS
DAEMONRUN_...=...

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
daemonrun_function() {
  …
}

# -----------------------------------------------------------------------------
#
# MAIN
#
# -----------------------------------------------------------------------------

# Function: dameonrun_main
# Main cli
dameonrun_main() {
  …
}

# Can be used as a library or executable
if [[ "${BASH_SOURCE[0]}" == "$0" ]] || [[ "$(basename "$0")" =~ ^daemonrun(\.sh)?$ ]]; then
	daemonrun_main "$@"
fi

# EOF
```


Rules:
- Name functions like `daemonrun_{group}_operation`, like `daemonrun_pidfile_write` instead of `daemonrun_write_pidfile`
