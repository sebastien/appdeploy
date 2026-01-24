# Appdeploy Control

## Overview

Service management commands control running application instances on targets.
The runner script (`appdeploy.runner.sh`) is automatically deployed to 
`$TARGET_PATH/appdeploy.runner.sh` (shared by all packages on that target).

## Runner Deployment

- **Source**: Sibling file to `appdeploy.sh` (resolved via realpath)
- **Target**: `$TARGET_PATH/appdeploy.runner.sh`
- **Trigger**: Auto-deployed on first `activate` or `start` command
- **Backends**: systemd (preferred) or manual PID-based daemon

## Commands

### appdeploy list [PACKAGE[:VERSION]] [TARGET]

Shows all packages on target that match PACKAGE and VERSION.
Globs supported. Shows status: uploaded, installed, or active.

### appdeploy status PACKAGE[:VERSION] [TARGET]

Shows service status for each matching package:
- **running** (bold green): Service is active and running
- **stopped**: Package is activated but service not running
- **inactive**: Package exists but not activated

### appdeploy start PACKAGE[:VERSION] [TARGET]

Starts the service daemon for the specified package.

**Version resolution** (when VERSION not specified):
1. Currently active version (if any)
2. Last active version (from `.last-active` marker)
3. Latest installed/uploaded version

**Auto-activation**: If package is installed but not activated, automatically
activates it before starting. If only uploaded, installs then activates.

**Fails if**: Package not found on target.

### appdeploy stop PACKAGE[:VERSION] [TARGET]

Stops the service daemon gracefully:
1. Sends SIGTERM
2. Waits for graceful shutdown (configurable timeout)
3. Sends SIGKILL if still running

Does **not** deactivate the package (symlinks remain in `run/`).

### appdeploy restart PACKAGE[:VERSION] [TARGET]

Equivalent to `stop` followed by `start`.

### appdeploy logs PACKAGE[:VERSION] [TARGET] [-f]

Shows recent log output from `$TARGET_PATH/$PACKAGE/var/logs/`.

Options:
- `-f`: Follow logs in real-time (like `tail -f`)

### appdeploy remove PACKAGE[:VERSION] [TARGET]

Removes a package completely:
1. Stops the service if running
2. Deactivates the package
3. Removes installed files and archive

## Target Structure

```
$TARGET_PATH/
    appdeploy.runner.sh     # Shared runner script
    myapp/
        packages/           # Uploaded archives
        dist/               # Installed versions
        var/
            logs/           # Log files
        run/                # Active symlinks (env.sh, run.sh, etc.)
        .active             # Current active version
        .last-active        # Previous active version (for restart)
        .pid                # PID file (manual daemon mode)
```

## Service Backends

### systemd (preferred)

- Creates user service: `appdeploy-$PACKAGE.service`
- Located in `~/.config/systemd/user/` (user) or `/etc/systemd/system/` (root)
- Logs via journald: `journalctl --user -u appdeploy-$PACKAGE`

### Manual Daemon (fallback)

- PID file: `$TARGET_PATH/$PACKAGE/.pid`
- Process managed via signals (SIGTERM/SIGKILL)
- Logs to `$TARGET_PATH/$PACKAGE/var/logs/`

## Log Rotation

| Method | Files | Trigger |
|--------|-------|---------|
| rotatelogs | `app.YYYY-MM-DD-HH_MM_SS` | Size-based |
| Manual fallback | `current.log` -> `app_TIMESTAMP.log.gz` | Size-based |

Configuration via environment:
- `LOG_SIZE`: Rotation threshold (default: `10M`)
- `LOG_COUNT`: Files to retain (default: `7`)

## Environment Variables

Passed to runner at invocation:

| Variable | Value | Description |
|----------|-------|-------------|
| `APP_NAME` | Package name | Service identifier |
| `APP_SCRIPT` | `$TARGET_PATH/$PKG/run/run.sh` | Script to execute |
| `LOG_DIR` | `$TARGET_PATH/$PKG/var/logs` | Log directory |
| `PID_FILE` | `$TARGET_PATH/$PKG/.pid` | PID file location |
| `RUN_USER` | Target user | User to run service as |
| `USE_SYSTEMD` | `auto` | `auto`/`true`/`false` |
