# Appdeploy

`appdeploy` is a tool that packages, deploys, and runs applications on local or
remote machines. It uses `daemonctl`, `daemonrun`, and `teelog` to manage the
packaged applications.

## Overview

`appdeploy` works by:

- Packaging a directory into an archive
- Uploading an archive to a local or remote target via SSH
- Installing `daemonctl`, `daemonrun`, and `teelog` to the target (auto-bootstrap)
- Running `daemonctl` on the target on behalf of the user

## Package Structure

An application package directory contains:

```
[conf.toml]             # Optional package and daemon configuration
[env.sh]                # Optional environment script, sourced before any other
run[.sh]                # Required: runs the application in foreground
[check[.sh]]            # Optional health check script
[on-start[.sh]]         # Script run when application starts successfully
[on-stop[.sh]]          # Script run when application stops
[VERSION]               # Optional version file (single line)
```

### Package `conf.toml` Schema

```toml
[package]
name = "myapp"              # Package name (inferred from directory if omitted)
version = "1.0.0"           # Package version (see resolution order below)

[daemon]
# Optional: passed through to daemonctl (see daemonctl spec for full options)
user = "appuser"
memory_limit = "512M"
# ... any daemonctl configuration key
```

### Version Resolution Order

Version is determined by (first match wins):

1. Explicit `--release` CLI flag
2. `conf.toml` `[package] version`
3. `VERSION` file in package root (single line, trimmed)
4. Git short hash if in git repo (`git rev-parse --short HEAD`)
5. Error: version required

### Name Resolution Order

Name is determined by (first match wins):

1. Explicit `--name` CLI flag
2. `conf.toml` `[package] name`
3. Directory basename (for `PACKAGE_PATH`)
4. Archive filename prefix (everything before `-${VERSION}`)

### Archive Format

Package archives follow: `${NAME}-${VERSION}.tar.{gz,bz2,xz}`

**Naming rules:**
- Name: letters, numbers, `_`, `-` (cannot end with `-` followed by digit)
- Version: must start with a digit; may contain letters, numbers, `.`, `-`

**Parsing rule:** Split filename on the first `-` followed by a digit.

**Examples:**
```
myapp-1.0.tar.gz           # name=myapp, version=1.0
myapp-1.0-beta.tar.gz      # name=myapp, version=1.0-beta
my-app-2.0.tar.gz          # name=my-app, version=2.0
my-app-2.0-rc1.tar.gz      # name=my-app, version=2.0-rc1
```

**Invalid:**
```
myapp-beta.tar.gz          # Error: version must start with digit
-1.0.tar.gz                # Error: name required
```

## Target Layout

Target path structure (default: `/opt/apps`):

```
${TARGET_PATH}/
    bin/                        # Tools installation directory
        daemonctl
        daemonrun
        teelog
    ${NAME}/
        packages/               # Uploaded archives
            ${NAME}-${VERSION}.tar.gz
        dist/                   # Unpacked versions
            ${VERSION}/         # Contents of unpacked archive
        conf/                   # Configuration overlay (user-managed)
            ...                 # Symlinked to run/, overrides data/
        data/                   # Data overlay (persistent storage)
            ...                 # Symlinked to run/, overrides dist/
        logs/                   # Log files
            ${NAME}.log         # Stdout log (via teelog)
            ${NAME}.err.log     # Stderr log (via teelog)
            ${NAME}.run.log     # Operations/event log
        run/                    # Active runtime directory
            .pid                # PID file
            .version            # Active version string
            logs -> ../logs     # Symlink to logs
            ...                 # Symlinks created from layers (see below)
```

### Runtime Directory Population

The `run/` directory is populated with symlinks and copies in layer order (last wins):

1. `dist/${VERSION}/*` - Base layer (symlinks to package contents)
2. `data/*` - Data layer (copied, not symlinked - supports write operations)
3. `conf/*` - Config layer (symlinks to user overrides, highest priority)
4. `logs` -> `../logs` - Always present

**Population rules:**
- Only top-level entries are processed (no recursive descent)
- For directories: create symlink to entire directory
- `dist/` and `conf/` entries are symlinked (read-mostly)
- `data/` entries are hard-linked if same filesystem, otherwise copied (write support)

**Conflict resolution**: If the same filename exists in multiple layers, the
highest-priority layer wins. The lower-priority symlink is removed before
creating the higher-priority one.

**Example:**
```
dist/1.0/
    run.sh
    config.yaml
    templates/         # Directory
data/
    app.db            # Will be hard-linked/copied, not symlinked
    cache/            # Directory
conf/
    config.yaml       # Overrides dist/1.0/config.yaml

run/
    run.sh -> ../dist/1.0/run.sh
    config.yaml -> ../conf/config.yaml    # conf wins over dist
    templates/ -> ../dist/1.0/templates/
    app.db                                 # Hard-link or copy from data/
    cache/ -> ../data/cache/              # data/ directories are symlinked
    logs -> ../logs
```

**Note:** Applications that need to write to files should place them in `data/`.
The `data/` directory is never included in packages and persists across versions.

## Remote Execution

`appdeploy` connects to targets via SSH using standard SSH config (`~/.ssh/config`).

### Target Format

```
TARGET = [USER@]HOST[:PATH] | PATH
```

- `HOST` - Remote hostname or IP
- `USER` - SSH username (default: current user)
- `PATH` - Base path on target (default: `/opt/apps`)

### Target Resolution

Targets are classified as local or remote:

1. Contains `@`: **remote** (e.g., `user@host`, `user@host:/path`)
2. Contains `:` not at position 2 (Windows drive): **remote** (e.g., `host:/path`)
3. Starts with `/`, `./`, `../`, or `~`: **local path**
4. Exists as local directory: **local path**
5. Equals `localhost` or `127.0.0.1`: **local** with default path
6. Otherwise: **remote hostname** with default path

**Override resolution:**
```
--local                      # Force local interpretation
--remote                     # Force remote interpretation (SSH)
```

**Examples:**
```
/opt/apps                    # Local: absolute path
./deploy                     # Local: relative path
prod-server                  # Remote: hostname
user@prod:/opt/apps          # Remote: explicit user and path
localhost                    # Local: special case
192.168.1.10                 # Remote: IP address
host.local:/data             # Remote: hostname with path
```

### Remote Operations

For remote targets:
- Commands: `ssh [USER@]HOST 'command'`
- File transfer: `scp` for archives (or `rsync` if available)
- First operation auto-bootstraps tools to `${PATH}/bin/`

For local targets:
- Commands executed directly
- No SSH involved

### Environment Variables

```
APPDEPLOY_TARGET              # Default target (default: /opt/apps)
APPDEPLOY_SSH_OPTIONS         # Additional SSH options (e.g., "-i ~/.ssh/key")
APPDEPLOY_KEEP_VERSIONS       # Default --keep value (default: 5)
APPDEPLOY_OP_TIMEOUT          # Default operation timeout (default: 30)
APPDEPLOY_NO_COLOR            # Disable colors (set to 1)
```

## Signal Handling

### Stop Sequence

When stopping an application:

1. Send `SIGTERM` to the process group
2. Wait up to `--timeout` seconds (default: 30) for graceful exit
3. If process exits: success
4. If still running and `--force`: send `SIGKILL`, wait 5 seconds
5. If still running: fail with error

### Run Script Requirements

The `run` script should:
- Run the application in the foreground (not daemonize)
- Forward `SIGTERM` to child processes for graceful shutdown
- Exit when the application terminates

### Signals Reference

| Signal   | Meaning                              |
|----------|--------------------------------------|
| SIGTERM  | Graceful shutdown request            |
| SIGKILL  | Forced termination (after timeout)   |
| SIGINT   | Interrupt (Ctrl+C) - treated as SIGTERM |

## File Permissions

### Archive Permissions

Archives preserve Unix permission bits (mode). On creation:
- File modes are stored as-is
- Ownership (uid/gid) is not stored (tar default behavior)

### Extraction Permissions

On extraction to target:
- Permission bits are restored from archive
- Files are owned by the user running appdeploy
- If `[daemon] user` is set in conf.toml: ownership changed after extraction
- Directories are created with mode 0755 (modified by umask)

### Required Permissions

| File | Required Mode | Notes |
|------|---------------|-------|
| `run` / `run.sh` | executable (0755) | Validated by `check` |
| `check.sh` | executable (0755) | If present |
| `env.sh` | readable (0644+) | Sourced, not executed |
| `on-start.sh` | executable (0755) | If present |
| `on-stop.sh` | executable (0755) | If present |

## CLI Reference

### Terminology

- `PACKAGE` - Either `PACKAGE_PATH` (directory) or `PACKAGE_ARCHIVE` (tarball)
- `PACKAGE_PATH` - Directory conforming to package structure
- `PACKAGE_ARCHIVE` - Tarball matching `${NAME}-${VERSION}.tar.{gz,bz2,xz}`
- `TARGET` - `[USER@]HOST[:PATH]` or local `PATH`
- `NAME` - Package name, supports wildcards for matching
- `VERSION` - Package version, supports wildcards for matching

### PACKAGE Argument Handling

Commands accepting `PACKAGE` handle both directories and archives:

| Input Type | Detection | Behavior |
|------------|-----------|----------|
| Directory | Path exists and is a directory | Auto-package, then proceed |
| Archive | Filename matches `*.tar.{gz,bz2,xz}` | Use directly |

**Auto-packaging** uses default options. For custom packaging options,
run `appdeploy package` explicitly first.

**Examples:**
```bash
appdeploy -t server install ./myapp          # Packages ./myapp, then installs
appdeploy install myapp-1.0.tar.gz           # Installs archive to default target
appdeploy -t server upgrade ./myapp          # Packages, installs, activates, health-checks
```

### Global Options

```
-t, --target TARGET          # Target specification (default: $APPDEPLOY_TARGET or /opt/apps)
-v, --verbose                # Verbose output
-q, --quiet                  # Suppress non-error output
-n, --dry-run                # Show what would be done without executing
-y, --yes                    # Skip confirmation prompts for destructive operations
-f, --force                  # Force operation, ignore warnings
-T, --op-timeout SECONDS     # Global timeout for operations (default: 30)
--local                      # Force target to be treated as local path
--remote                     # Force target to be treated as remote host
--no-color                   # Disable colored output
--help                       # Show help
--version                    # Show appdeploy version
--tool-versions              # Show bundled tool versions
```

### Exit Codes

- `0` - Success
- `1` - Error
- `2` - Partial success / warnings
- `3` - User cancelled (declined confirmation)
- `130` - Interrupted (Ctrl+C)

### CLI Output Format

Operation messages follow a consistent format with bracketed prefixes:

```
[TARGET] [TIME] MESSAGE [version=VERSION]
```

**Components:**

| Component | When Shown | Format |
|-----------|------------|--------|
| `TARGET` | Always | Full target string (e.g., `user@host:/path` or `/path` for local) |
| `TIME` | First operation only | ISO 8601 time portion (e.g., `14:30:22`) |
| `VERSION` | App lifecycle operations | `version=X.Y.Z` suffix |

**App lifecycle operations** (show version):
- `start`, `stop`, `restart` - process lifecycle
- `activate`, `deactivate` - version switching
- `upgrade`, `rollback` - deployment operations
- `kill` - signal operations

**Other operations** (target + time only, no version suffix):
- `install`, `uninstall` - package management (version appears in message body)
- `bootstrap` - tool management
- `list`, `status`, `logs`, `show` - query operations
- `check`, `package`, `run` - local operations
- `clean` - cleanup

**Examples:**

```
[/opt/apps] [14:30:22] Starting myapp version=1.0.0
[/opt/apps] Stopping myapp version=1.0.0
[user@prod:/opt/apps] [09:15:00] Upgrading myapp to 2.0.0
[user@prod:/opt/apps] Installing myapp-2.0.0.tar.gz
[user@prod:/opt/apps] Activating myapp version=2.0.0
[user@prod:/opt/apps] Health check passed
```

**Output modes:**

| Mode | Behavior |
|------|----------|
| Normal | Standard output with prefixes |
| `--verbose` | Additional `[verbose]` prefixed debug messages |
| `--quiet` | Suppress all output except errors |
| `--dry-run` | Prefix actions with `[dry-run]` |

---

## Package Commands

### `appdeploy check [OPTIONS] PACKAGE`

Validates package structure and requirements.

```
--strict                     # Fail on warnings (e.g., missing optional files)
```

**Validations performed**:
- `run` or `run.sh` exists and is executable
- `conf.toml` is valid TOML (if present)
- `env.sh` has valid shell syntax (if present)
- Name and version can be determined
- No forbidden paths (`.git/`, `__pycache__/`, `*.pyc`, `.env`)

**Exit codes**: 0=valid, 1=invalid, 2=valid with warnings (--strict treats as failure)

---

### `appdeploy package [OPTIONS] PACKAGE_PATH [OUTPUT]`

Creates archive from package directory.

```
-n, --name NAME              # Override package name
-r, --release VERSION        # Override package version
-o, --output FILE            # Output path (default: ./${NAME}-${VERSION}.tar.gz)
-c, --compression TYPE       # Compression: gz (default), bz2, xz
--exclude PATTERN            # Exclude glob pattern (repeatable)
--no-check                   # Skip validation before packaging
```

**Default output**: `./${NAME}-${VERSION}.tar.gz`

---

### `appdeploy run [OPTIONS] PACKAGE`

Runs package locally in a simulated deployment environment.

```
-k, --keep                   # Keep temp directory after exit
--timeout SECONDS            # Kill after timeout (0=unlimited, default: 0)
-e, --env KEY=VALUE          # Set environment variable (repeatable)
--env-file FILE              # Load environment from file
-C, --chdir DIR              # Use specific directory instead of temp
--no-layers                  # Run directly without simulating layers
--data DIR                   # Use DIR as data layer (default: empty temp)
--conf DIR                   # Use DIR as conf layer (default: empty temp)
```

**Behavior:**

By default, simulates the deployment layer structure:
1. Create temp directory with `dist/`, `data/`, `conf/`, `run/`, `logs/`
2. Unpack/copy package to `dist/current/`
3. Copy `--data` contents to `data/` (if provided)
4. Copy `--conf` contents to `conf/` (if provided)
5. Populate `run/` using layer precedence rules
6. Execute `run/run` (or `run/run.sh`)
7. Clean up temp directory on exit (unless `--keep`)

Use `--no-layers` for quick testing without layer simulation.

**Exit code**: Propagates the `run` script's exit code.

---

## Deployment Commands

### `appdeploy install [OPTIONS] PACKAGE`

Uploads and unpacks archive to target. Does not activate by default.

```
-y, --yes                    # Skip confirmation (for overwriting existing version)
--activate                   # Activate after install (implies restart if running)
--keep COUNT                 # Keep only N most recent versions (0=unlimited, default: 5)
--checksum FILE              # Verify archive against checksum file (sha256)
```

**Behavior**:
1. If PACKAGE is a directory: package it first (implicit `appdeploy package`)
2. Bootstrap tools if not present on target
3. Upload archive to `${TARGET}/${NAME}/packages/`
4. Unpack to `${TARGET}/${NAME}/dist/${VERSION}/`
5. If `--activate`: activate the installed version (see `activate` command)

**Note:** To install and immediately run, use `upgrade` instead, which provides
atomic deployment with health checks and automatic rollback.

---

### `appdeploy uninstall [OPTIONS] PACKAGE[:VERSION]`

Removes installed version from target.

**Destructive**: Requires `-y` or interactive confirmation.
**Fails if**: Target version is currently active (must `deactivate` first).

```
-y, --yes                    # Skip confirmation
--all                        # Remove all versions (requires --yes)
--keep-data                  # Preserve conf/ and data/ directories
--keep-logs                  # Preserve logs/ directory
```

---

### `appdeploy activate [OPTIONS] PACKAGE[:VERSION]`

Sets active version by creating symlinks in `run/`.

```
--no-restart                 # Don't restart if already running
```

**Version resolution** (when VERSION omitted): Most recently installed
(by mtime of `dist/${VERSION}/`).

**Behavior**:
1. If another version active, deactivate it first
2. Create symlinks in `run/` following layer precedence
3. Write version string to `run/.version`
4. Unless `--no-restart`: restart if app was running

**Atomicity guarantee:**

Activation is performed atomically to prevent inconsistent states:

1. Create `run.new/` with all symlinks and copies
2. If `run/` exists: rename to `run.old/`
3. Rename `run.new/` to `run/` (atomic on POSIX filesystems)
4. Remove `run.old/` on success
5. On any failure: restore `run.old/` to `run/` if it exists

This ensures `run/` is never in a partial state. If activation is interrupted,
either the old version remains active or the new version is fully active.

---

### `appdeploy deactivate [OPTIONS] PACKAGE`

Removes active symlinks from `run/`.

**Destructive**: Requires `-y` or interactive confirmation.
**Fails if**: App is currently running (must `stop` first).

```
-y, --yes                    # Skip confirmation
```

---

### `appdeploy list [OPTIONS] [PACKAGE]`

Lists installed packages and versions.

```
-l, --long                   # Show detailed info (size, install date)
--active-only                # Show only active versions
--json                       # Output as JSON
```

**Output format**:
```
# NAME          VERSION     STATUS      INSTALLED
myapp           1.2.0       active      2026-01-20 14:30
myapp           1.1.0       inactive    2026-01-15 10:00
otherapp        2.0.0       active      2026-01-18 09:15
```

---

### `appdeploy upgrade [OPTIONS] PACKAGE`

Atomic install + activate + restart with rollback support.

**Destructive**: Requires `-y` or interactive confirmation.
**Default**: `--rollback-on-fail` is ON.

```
-y, --yes                    # Skip confirmation
--no-restart                 # Don't restart after activate
--keep COUNT                 # Keep only N versions (default: 5)
--no-rollback-on-fail        # Disable automatic rollback on health check failure
--health-timeout SECONDS     # Time to wait for healthy status (default: 60)
--startup-grace SECONDS      # Grace period when no check.sh (default: 5)
```

**Behavior**:
1. Install new version
2. Stop current (if running)
3. Activate new version
4. Start new version
5. Health verification (within `--health-timeout`):
   - If `check.sh` exists: poll every 2 seconds until it exits 0
   - If no `check.sh`: verify process is still running after `--startup-grace` seconds
6. On health failure (unless `--no-rollback-on-fail`): rollback to previous version

**Health check details:**
- `--health-timeout` is the maximum time to wait for health check to pass
- `check.sh` is invoked with working directory set to `run/`
- `check.sh` should exit 0 for healthy, non-zero for unhealthy
- If `check.sh` is slow, it's polled every 2 seconds (not run continuously)
- Without `check.sh`, the process must simply remain running for `--startup-grace` seconds

---

### `appdeploy rollback [OPTIONS] PACKAGE`

Activates previous version.

**Destructive**: Requires `-y` or interactive confirmation.

```
-y, --yes                    # Skip confirmation
--to VERSION                 # Rollback to specific version (default: previous)
--no-restart                 # Don't restart after rollback
```

**Previous version**: Second most recently installed (by mtime).

---

### `appdeploy clean [OPTIONS] PACKAGE`

Removes old inactive versions.

**Destructive**: Requires `-y` or interactive confirmation.

```
-y, --yes                    # Skip confirmation
--keep COUNT                 # Keep N most recent versions (default: 5)
```

**Behavior**: Always keeps the active version regardless of `--keep` count.

---

### `appdeploy bootstrap [OPTIONS]`

Installs or updates tools on target.

```
--force                      # Reinstall even if already present and compatible
--check                      # Check tool status without installing (exit 0=ok, 1=missing/outdated)
--upgrade                    # Upgrade tools if newer versions available
--tools-path PATH            # Use tools from PATH instead of bundled
```

Installs `daemonctl`, `daemonrun`, `teelog` to `${TARGET}/bin/`.

**Tool sources (in order):**
1. `--tools-path PATH` - Use user-provided tools
2. Bundled tools - appdeploy includes compatible tool versions

**Version compatibility:**
- Tools are checked via `${tool} --version`
- If tools are missing: install
- If tools are older than minimum required: prompt to upgrade (or use `--upgrade`)
- If tools are compatible: skip (unless `--force`)

---

## Runtime Commands

These commands proxy to `daemonctl` on the target.

### `appdeploy start [OPTIONS] PACKAGE`

Starts the active version.

**Fails if**: No version is active.

```
-a, --attach                 # Attach to output after starting
-w, --wait                   # Wait for startup to complete
--start-timeout SECONDS      # Startup timeout (default: 60)
```

---

### `appdeploy stop [OPTIONS] PACKAGE`

Stops running application.

**Destructive**: Requires `-y` or interactive confirmation.

```
-y, --yes                    # Skip confirmation
-s, --signal SIGNAL          # Signal to send (default: TERM)
-f, --force                  # Force kill if graceful stop fails
-t, --timeout SECONDS        # Timeout before SIGKILL (default: 30)
-w, --wait                   # Wait for process to fully exit
```

---

### `appdeploy restart [OPTIONS] PACKAGE`

Restarts running application.

**Destructive**: Requires `-y` or interactive confirmation.

```
-y, --yes                    # Skip confirmation
-f, --force                  # Force stop if needed
-w, --wait                   # Wait for stop before starting
--stop-timeout SECONDS       # Timeout for stop phase (default: 30)
--start-timeout SECONDS      # Timeout for start phase (default: 60)
--delay SECONDS              # Delay between stop and start (default: 0)
```

---

### `appdeploy status [OPTIONS] [PACKAGE]`

Shows application status.

```
-l, --long                   # Detailed status (includes resources)
-w, --watch                  # Watch continuously
--refresh SECONDS            # Refresh interval for watch (default: 2)
-p, --processes              # Show process tree
--health                     # Show health check status
--json                       # Output as JSON
```

---

### `appdeploy logs [OPTIONS] PACKAGE`

Shows logs for the application.

```
-f, --follow                 # Follow log output (like tail -f)
-n, --lines COUNT            # Number of lines to show (default: 50)
--stdout                     # Show stdout log only (${NAME}.log)
--stderr                     # Show stderr log only (${NAME}.err.log)
--ops                        # Show operations log only (${NAME}.run.log)
--all                        # Show all logs interleaved (default)
--since TIME                 # Logs since time (e.g., "2h", "2026-01-01")
--until TIME                 # Logs until time
--level LEVEL                # Filter by log level
--grep PATTERN               # Filter lines matching pattern
-T, --no-timestamps          # Hide timestamps (shown by default in interleaved mode)
--tail                       # Start from end of log (default for --follow)
--head                       # Start from beginning of log
```

**Time format for `--since` and `--until`:**

Relative times (from now):
```
Ns    # N seconds ago
Nm    # N minutes ago
Nh    # N hours ago
Nd    # N days ago
Nw    # N weeks ago
```

Absolute times:
```
YYYY-MM-DD                   # Midnight UTC on date
YYYY-MM-DDTHH:MM:SS          # UTC timestamp
YYYY-MM-DDTHH:MM:SS±HH:MM    # Timestamp with timezone offset
```

**Examples:**
```bash
appdeploy logs myapp --since 2h              # Last 2 hours
appdeploy logs myapp --since 30m             # Last 30 minutes
appdeploy logs myapp --since 2026-01-20      # Since Jan 20 midnight
appdeploy logs myapp --until 2026-01-20T14:30:00  # Until 2:30 PM UTC
appdeploy logs myapp --since 1d --until 12h  # Between 24h ago and 12h ago
```

**Interleaved format** (default/`--all`):
```
2026-01-25T14:30:22 out: Starting application...
2026-01-25T14:30:22 out: Listening on port 8080
2026-01-25T14:30:25 event: Health check passed
2026-01-25T14:31:00 err: Warning: connection pool exhausted
```

Prefixes: `out:` (stdout), `err:` (stderr), `event:` (operations)

---

### `appdeploy show [OPTIONS] PACKAGE[:VERSION]`

Shows package contents and configuration.

```
--files                      # List all files in version
--config                     # Show resolved conf.toml
--env                        # Show env.sh contents
--run                        # Show run script contents
--tree                       # Show directory tree
```

---

### `appdeploy kill [OPTIONS] PACKAGE [SIGNAL]`

Send signal to running application.

```
-a, --all-processes          # Send to all processes in group
-w, --wait                   # Wait for signal to be processed
--timeout SECONDS            # Timeout for wait (default: 30)
```

Default SIGNAL: TERM

Signals can be specified by name (TERM, HUP, USR1) or number (15, 1, 10).

**Examples:**
```bash
appdeploy kill myapp                         # Send SIGTERM
appdeploy kill myapp HUP                     # Send SIGHUP (reload)
appdeploy -t prod-server kill myapp USR1     # Send SIGUSR1 to remote
appdeploy kill myapp 9                       # Send SIGKILL (not recommended)
```

---

## Implementation

Implement `appdeploy.py` using typed Python 3.14+, stdlib only (no external dependencies).

### Bundled Tools

`appdeploy` includes bundled copies of its dependencies for easy deployment:

```
appdeploy.py             # Main script, available locally
# Bundles commands, installed in $TARGET_PATH/bin
daemonctl                # Bundled daemonctl binary or script
daemonrun                # Bundled daemonrun binary or script
teelog                   # Bundled teelog binary or script
```

When installed, appdeloy also installs `appdeploy.{daemonctl,daemonrun.teelog}`
scripts/commands that can then be installed on the TARGET.

Bundled tool versions are selected for compatibility and tested together.
Use `appdeploy --tool-versions` to display bundled versions.

### File Structure

```python
#!/usr/bin/env python3
# --
# File: appdeploy.py
#
# `appdeploy` packages, deploys, and manages applications on local/remote targets.

import argparse
import dataclasses
import hashlib
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from typing import ...

# -----------------------------------------------------------------------------
#
# GLOBALS AND CONFIGURATION
#
# -----------------------------------------------------------------------------

APPDEPLOY_VERSION = "1.0.0"
APPDEPLOY_TARGET = os.environ.get("APPDEPLOY_TARGET", "/opt/apps")
APPDEPLOY_SSH_OPTIONS = os.environ.get("APPDEPLOY_SSH_OPTIONS", "")

# -----------------------------------------------------------------------------
#
# TYPES
#
# -----------------------------------------------------------------------------

@dataclasses.dataclass
class Package:
    ...

@dataclasses.dataclass
class Target:
    ...

# -----------------------------------------------------------------------------
#
# UTILITIES
#
# -----------------------------------------------------------------------------

def appdeploy_util_confirm(message: str, yes: bool = False) -> bool:
    ...

# -----------------------------------------------------------------------------
#
# SSH AND EXECUTION
#
# -----------------------------------------------------------------------------

def appdeploy_ssh_run(target: Target, command: str) -> subprocess.CompletedProcess:
    ...

def appdeploy_ssh_copy(target: Target, local: Path, remote: str) -> None:
    ...

# -----------------------------------------------------------------------------
#
# PACKAGE OPERATIONS
#
# -----------------------------------------------------------------------------

def appdeploy_package_validate(path: Path, strict: bool = False) -> list[str]:
    ...

def appdeploy_package_create(path: Path, output: Path, ...) -> Path:
    ...

# -----------------------------------------------------------------------------
#
# TARGET OPERATIONS
#
# -----------------------------------------------------------------------------

def appdeploy_target_bootstrap(target: Target, force: bool = False) -> None:
    ...

def appdeploy_target_install(target: Target, archive: Path, ...) -> None:
    ...

# -----------------------------------------------------------------------------
#
# CLI COMMANDS
#
# -----------------------------------------------------------------------------

def appdeploy_cmd_check(args: argparse.Namespace) -> int:
    ...

def appdeploy_cmd_package(args: argparse.Namespace) -> int:
    ...

# -----------------------------------------------------------------------------
#
# MAIN
#
# -----------------------------------------------------------------------------

def appdeploy_main() -> int:
    parser = argparse.ArgumentParser(...)
    ...
    return 0

if __name__ == "__main__":
    sys.exit(appdeploy_main())

# EOF
```

### Naming Conventions

Functions follow `appdeploy_{group}_{operation}`:
- `appdeploy_package_validate`, `appdeploy_package_create`
- `appdeploy_target_bootstrap`, `appdeploy_target_install`
- `appdeploy_ssh_run`, `appdeploy_ssh_copy`
- `appdeploy_cmd_check`, `appdeploy_cmd_start`

### Rules

- All destructive operations require `-y/--yes` or interactive confirmation
- Global `-f/--force` ignores warnings; per-command `-f` forces stop/kill operations
- Logs are rotated for each start (handled by teelog)
- Remote commands use SSH; local commands execute directly
- Bootstrap tools automatically on first remote operation
- Exit codes: 0=success, 1=error, 2=warnings, 3=cancelled, 130=interrupted
- `uninstall` fails if version is active (no force override)
- `deactivate` fails if app is running (no force override)
- `upgrade --rollback-on-fail` is default ON
- Health check: use `check.sh` if present, else process survival for `--startup-grace`
- `install` does not activate by default (use `--activate` or `upgrade` command)
- Default `--keep 5` for version retention across all commands
- Default `--op-timeout 30` for operation timeouts

# EOF
