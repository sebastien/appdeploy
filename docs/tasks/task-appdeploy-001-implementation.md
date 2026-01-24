# Task: Implement appdeploy.py

## Overview

Implement `appdeploy.py` - a tool that packages, deploys, and runs applications on local or remote machines using `daemonctl`, `daemonrun`, and `teelog`.

**Source Spec:** `spec-appdeploy.md`

---

## Clarifications Resolved

1. **TOML Parsing**: Use `tomllib` (Python 3.11+ stdlib)
2. **Bundled Tool Location**: Look for `appdeploy.daemonctl`, `appdeploy.daemonrun`, `appdeploy.teelog` in the same directory as `appdeploy.py` (resolve symlinks)
3. **Target Tool Names**: Install as `daemonctl`, `daemonrun`, `teelog` in `${TARGET}/bin/`
4. **Remote File Reads**: Use SSH subprocess (`ssh host 'cat file'`)

---

## Implementation Phases

### Phase 1: Core Infrastructure (~150 lines)

#### 1.1 File Structure and Imports
```python
#!/usr/bin/env python3
import argparse, dataclasses, hashlib, os, shutil, subprocess
import sys, tarfile, tempfile, tomllib
from pathlib import Path
from typing import Optional, Any
```

#### 1.2 Constants and Globals
```python
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
```

#### 1.3 Data Types
```python
@dataclass
class Target:
    host: str | None      # None for local
    user: str | None
    path: Path
    is_remote: bool

@dataclass
class Package:
    name: str
    version: str
    path: Path            # Directory or archive path
    is_archive: bool
    config: dict[str, Any]  # Parsed conf.toml

@dataclass
class InstalledVersion:
    name: str
    version: str
    status: str           # "active", "inactive"
    installed: str        # ISO timestamp
    size: int             # bytes
```

#### 1.4 Utility Functions
- `appdeploy_util_confirm(message, yes=False) -> bool`
- `appdeploy_util_output(message, quiet=False)`
- `appdeploy_util_error(message)`
- `appdeploy_util_color(text, color) -> str`
- `appdeploy_util_parse_time(time_str) -> datetime` (for --since/--until)
- `appdeploy_util_format_size(bytes) -> str`

---

### Phase 2: Target Resolution and Execution (~200 lines)

#### 2.1 Target Parsing
```python
def appdeploy_target_parse(target_str: str, force_local=False, force_remote=False) -> Target:
    """Parse TARGET string into Target dataclass.
    
    Resolution rules:
    1. Contains '@' -> remote
    2. Contains ':' (not position 2 on Windows) -> remote
    3. Starts with '/', './', '../', '~' -> local
    4. Exists as local directory -> local
    5. 'localhost' or '127.0.0.1' -> local
    6. Otherwise -> remote
    """
```

#### 2.2 Execution Helpers
```python
def appdeploy_exec_run(target: Target, command: str, 
                       timeout: int = 30) -> subprocess.CompletedProcess:
    """Execute command on target (SSH for remote, direct for local)."""

def appdeploy_exec_copy(target: Target, local_path: Path, 
                        remote_path: str) -> None:
    """Copy file to target (scp for remote, shutil.copy for local)."""

def appdeploy_exec_read(target: Target, remote_path: str) -> str:
    """Read file from target (ssh cat for remote, Path.read_text for local)."""

def appdeploy_exec_exists(target: Target, path: str) -> bool:
    """Check if path exists on target."""

def appdeploy_exec_mkdir(target: Target, path: str) -> None:
    """Create directory on target (mkdir -p)."""
```

---

### Phase 3: Package Operations (~250 lines)

#### 3.1 Name/Version Resolution
```python
def appdeploy_package_resolve_name(path: Path, config: dict, 
                                   cli_name: str | None) -> str:
    """Resolve package name: CLI -> conf.toml -> directory basename -> archive prefix."""

def appdeploy_package_resolve_version(path: Path, config: dict,
                                      cli_version: str | None) -> str:
    """Resolve version: CLI -> conf.toml -> VERSION file -> git hash -> error."""

def appdeploy_package_parse_archive(filename: str) -> tuple[str, str]:
    """Parse name and version from archive filename.
    Split on first '-' followed by digit."""
```

#### 3.2 Package Loading
```python
def appdeploy_package_load(path: Path, cli_name: str | None = None,
                           cli_version: str | None = None) -> Package:
    """Load package from directory or archive path."""
```

#### 3.3 Package Validation
```python
def appdeploy_package_validate(pkg: Package, strict: bool = False) -> list[str]:
    """Validate package structure. Returns list of errors/warnings.
    
    Checks:
    - run or run.sh exists and is executable
    - conf.toml is valid TOML (if present)
    - env.sh has valid shell syntax (if present)
    - No forbidden paths (.git/, __pycache__/, *.pyc, .env)
    """
```

#### 3.4 Package Creation
```python
def appdeploy_package_create(pkg: Package, output: Path | None = None,
                             compression: str = "gz",
                             exclude: list[str] | None = None) -> Path:
    """Create archive from package directory."""
```

---

### Phase 4: Target Operations (~400 lines)

#### 4.1 Bootstrap
```python
def appdeploy_target_bootstrap(target: Target, force: bool = False,
                               check_only: bool = False,
                               upgrade: bool = False,
                               tools_path: Path | None = None) -> bool:
    """Install/upgrade tools on target.
    
    Installs daemonctl, daemonrun, teelog to ${TARGET}/bin/
    Returns True if tools are up-to-date."""
```

#### 4.2 Install/Uninstall
```python
def appdeploy_target_install(target: Target, pkg: Package,
                             activate: bool = False,
                             keep: int = 5) -> None:
    """Upload and unpack archive to target."""

def appdeploy_target_uninstall(target: Target, name: str, version: str | None,
                               all_versions: bool = False,
                               keep_data: bool = False,
                               keep_logs: bool = False) -> None:
    """Remove installed version(s)."""
```

#### 4.3 Activate/Deactivate
```python
def appdeploy_target_activate(target: Target, name: str, 
                              version: str | None = None,
                              no_restart: bool = False) -> None:
    """Set active version (atomic symlink creation)."""

def appdeploy_target_deactivate(target: Target, name: str) -> None:
    """Remove active symlinks."""
```

#### 4.4 Layer Population
```python
def appdeploy_target_populate_run(target: Target, name: str, 
                                  version: str) -> None:
    """Populate run/ directory with layer symlinks.
    
    Layer order (last wins): dist/ -> data/ -> conf/ -> logs symlink
    Uses atomic rename: run.new/ -> run/"""
```

#### 4.5 List/Clean
```python
def appdeploy_target_list(target: Target, name: str | None = None,
                          long_format: bool = False,
                          active_only: bool = False,
                          json_format: bool = False) -> list[InstalledVersion]:
    """List installed packages/versions."""

def appdeploy_target_clean(target: Target, name: str, 
                           keep: int = 5) -> list[str]:
    """Remove old inactive versions. Returns list of removed versions."""
```

---

### Phase 5: Daemon Operations (~200 lines)

```python
def appdeploy_daemon_start(target: Target, name: str,
                           attach: bool = False,
                           wait: bool = False,
                           timeout: int = 60) -> None:
    """Start daemon via daemonctl."""

def appdeploy_daemon_stop(target: Target, name: str,
                          signal: str = "TERM",
                          force: bool = False,
                          timeout: int = 30,
                          wait: bool = False) -> None:
    """Stop daemon via daemonctl."""

def appdeploy_daemon_restart(target: Target, name: str, ...) -> None:
    """Restart daemon via daemonctl."""

def appdeploy_daemon_status(target: Target, name: str | None = None,
                            long_format: bool = False,
                            json_format: bool = False) -> dict:
    """Get daemon status via daemonctl."""

def appdeploy_daemon_logs(target: Target, name: str,
                          follow: bool = False,
                          lines: int = 50,
                          stream: str = "all",  # stdout/stderr/ops/all
                          since: str | None = None,
                          until: str | None = None,
                          grep: str | None = None) -> None:
    """Show logs (streams output)."""

def appdeploy_daemon_kill(target: Target, name: str, signal: str = "TERM",
                          all_processes: bool = False,
                          wait: bool = False,
                          timeout: int = 30) -> None:
    """Send signal to daemon."""
```

---

### Phase 6: High-Level Commands (~300 lines)

#### 6.1 Upgrade with Rollback
```python
def appdeploy_cmd_upgrade(target: Target, pkg: Package,
                          keep: int = 5,
                          rollback_on_fail: bool = True,
                          health_timeout: int = 60,
                          startup_grace: int = 5) -> bool:
    """Atomic upgrade with health check and rollback.
    
    1. Install new version
    2. Record current active version (for rollback)
    3. Stop current (if running)
    4. Activate new version
    5. Start new version
    6. Health check
    7. On failure: rollback to previous"""
```

#### 6.2 Health Check
```python
def appdeploy_health_check(target: Target, name: str,
                           timeout: int = 60,
                           grace: int = 5) -> bool:
    """Run health check.
    
    If check.sh exists: poll every 2s until exit 0 or timeout
    Otherwise: verify process still running after grace period"""
```

#### 6.3 Rollback
```python
def appdeploy_cmd_rollback(target: Target, name: str,
                           to_version: str | None = None,
                           no_restart: bool = False) -> None:
    """Rollback to previous (or specified) version."""
```

#### 6.4 Local Run
```python
def appdeploy_cmd_run(pkg: Package,
                      keep_temp: bool = False,
                      timeout: int = 0,
                      env: dict[str, str] | None = None,
                      chdir: Path | None = None,
                      no_layers: bool = False,
                      data_dir: Path | None = None,
                      conf_dir: Path | None = None) -> int:
    """Run package in simulated deployment environment."""
```

---

### Phase 7: CLI Implementation (~400 lines)

#### 7.1 Argument Parser Structure
```python
def appdeploy_build_parser() -> argparse.ArgumentParser:
    """Build argument parser with all subcommands."""
    
    parser = argparse.ArgumentParser(prog="appdeploy", ...)
    
    # Global options
    parser.add_argument("-t", "--target", ...)
    parser.add_argument("-v", "--verbose", ...)
    # ... etc
    
    subparsers = parser.add_subparsers(dest="command")
    
    # Package commands
    subparsers.add_parser("check", ...)
    subparsers.add_parser("package", ...)
    subparsers.add_parser("run", ...)
    
    # Deployment commands
    subparsers.add_parser("install", ...)
    subparsers.add_parser("uninstall", ...)
    subparsers.add_parser("activate", ...)
    subparsers.add_parser("deactivate", ...)
    subparsers.add_parser("list", ...)
    subparsers.add_parser("upgrade", ...)
    subparsers.add_parser("rollback", ...)
    subparsers.add_parser("clean", ...)
    subparsers.add_parser("bootstrap", ...)
    
    # Runtime commands
    subparsers.add_parser("start", ...)
    subparsers.add_parser("stop", ...)
    subparsers.add_parser("restart", ...)
    subparsers.add_parser("status", ...)
    subparsers.add_parser("logs", ...)
    subparsers.add_parser("show", ...)
    subparsers.add_parser("kill", ...)
```

#### 7.2 Command Handlers
Each command gets a handler function:
```python
def appdeploy_cmd_check(args: argparse.Namespace) -> int: ...
def appdeploy_cmd_package(args: argparse.Namespace) -> int: ...
def appdeploy_cmd_install(args: argparse.Namespace) -> int: ...
# ... etc
```

#### 7.3 Main Entry Point
```python
def appdeploy_main() -> int:
    """Main entry point."""
    parser = appdeploy_build_parser()
    args = parser.parse_args()
    
    # Set up globals from args
    # Handle --version, --tool-versions
    # Dispatch to command handler
    # Return appropriate exit code
```

---

## Estimated Size

| Phase | Lines |
|-------|-------|
| 1. Core Infrastructure | ~150 |
| 2. Target/Execution | ~200 |
| 3. Package Operations | ~250 |
| 4. Target Operations | ~400 |
| 5. Daemon Operations | ~200 |
| 6. High-Level Commands | ~300 |
| 7. CLI Implementation | ~400 |
| **Total** | **~1900** |

---

## Dependencies

**Required files to exist alongside appdeploy.py:**
- `appdeploy.daemonctl` (copy/symlink of daemonctl.py)
- `appdeploy.daemonrun` (copy/symlink of daemonrun.sh)
- `appdeploy.teelog` (copy/symlink of teelog.sh)

---

## Implementation Order

Recommended order for incremental development:

1. **Skeleton** - File structure, imports, argument parser, main()
2. **Data types** - Target, Package, etc.
3. **Target parsing** - `appdeploy_target_parse()`
4. **Package commands** - check, package (local-only, no target needed)
5. **Local execution** - `appdeploy_exec_*` for local targets
6. **Bootstrap** - Install tools to target
7. **Install/Activate** - Core deployment operations
8. **Daemon proxy** - start, stop, status, logs
9. **Upgrade/Rollback** - High-level commands with health checks
10. **SSH operations** - Remote target support
11. **Polish** - Error handling, edge cases, colors, dry-run

---

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error |
| 2 | Partial success / warnings |
| 3 | User cancelled (declined confirmation) |
| 130 | Interrupted (Ctrl+C / SIGINT) |

---

## Checklist

- [ ] Phase 1: Core Infrastructure
  - [ ] File structure and imports
  - [ ] Data types (Package, Target, InstalledVersion)
  - [ ] Utility functions
- [ ] Phase 2: Target Resolution and Execution
  - [ ] Target parsing and resolution
  - [ ] SSH operations
  - [ ] Local operations
- [ ] Phase 3: Package Operations
  - [ ] Name/version resolution
  - [ ] Package validation
  - [ ] Package creation
- [ ] Phase 4: Target Operations
  - [ ] Bootstrap
  - [ ] Install/Uninstall
  - [ ] Activate/Deactivate
  - [ ] List/Clean
- [ ] Phase 5: Daemon Operations
  - [ ] Start/Stop/Restart
  - [ ] Status
  - [ ] Logs
  - [ ] Kill
- [ ] Phase 6: High-Level Commands
  - [ ] Upgrade with rollback
  - [ ] Rollback
  - [ ] Run (local testing)
  - [ ] Show
- [ ] Phase 7: CLI Implementation
  - [ ] Argument parser
  - [ ] Command dispatch
  - [ ] Signal handling
