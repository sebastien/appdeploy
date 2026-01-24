## Appdeploy Runner

Overview
--------

The Appdeploy Runner is a portable bash script designed to manage long-running processes as daemons on Linux systems using only standard or easily-installable tools. It provides a unified interface for daemon lifecycle management, automatic log rotation, and process monitoring across different Linux distributions.

Design Objectives
-----------------

### Primary Goals

-   **Zero external dependencies**: Work with tools available on standard Linux installations
-   **Cross-distribution compatibility**: Support Ubuntu, Fedora, CentOS, Arch, openSUSE
-   **Graceful degradation**: Automatically select best available tools and fallback appropriately
-   **Process isolation**: Ensure daemons survive terminal/session closure
-   **Log management**: Provide automatic log rotation without cron dependencies
-   **Process identification**: Enable easy discovery and management of running services

### Non-Goals

-   Complex service orchestration (use systemd/docker for that)
-   Network service discovery
-   Resource limiting (rely on systemd for advanced features)
-   Cross-platform support (Linux-only)

Architecture
------------

### Component Hierarchy

Plaintext

`Appdeploy Runner
├── Dependency Detection Layer
│   ├── Package Manager Detection
│   ├── Tool Availability Checking
│   └── Permission Validation
├── Service Management Layer
│   ├── systemd Integration (preferred)
│   └── Manual Daemon Management (fallback)
└── Log Management Layer
    ├── rotatelogs Integration (preferred)
    ├── journald Integration (systemd)
    └── Manual Log Rotation (fallback)`

### Design Decisions

#### 1\. **Dependency Strategy: Tiered Approach**

-   **Tier 1 (Required)**: Basic shell tools (`bash`, `ps`, `kill`, `tee`, etc.)
-   **Tier 2 (Preferred)**: systemd for daemon management
-   **Tier 3 (Optional)**: rotatelogs for advanced log rotation

**Rationale**: Ensures maximum compatibility while providing optimal experience when better tools are available.

#### 2\. **systemd First, Manual Fallback**

-   Prefer systemd user services for non-root users
-   Fall back to `setsid` + PID file management when systemd unavailable

**Rationale**: systemd provides superior process management, automatic restarts, and logging integration, but isn't universal.

#### 3\. **Pipe-Based Log Rotation**

-   Use `rotatelogs` for real-time log rotation via pipes
-   Implement manual rotation as fallback using `tee` + size monitoring

**Rationale**: Eliminates cron dependency and provides immediate rotation without log loss.

#### 4\. **Interactive Dependency Installation**

-   Detect missing optional dependencies
-   Offer to install them with appropriate package manager commands
-   Never fail on missing optional dependencies

**Rationale**: Balances automation with user control, avoiding unwanted system modifications.

API Specification
-----------------

### Command Interface

Bash

`./appdeploy-runner.sh [COMMAND] [OPTIONS]`

#### Core Commands

| Command | Description | Dependencies |
| --- | --- | --- |
| `check` | Validate system dependencies and show capabilities | None |
| `install` | Create and install the service | App script |
| `uninstall` | Stop and remove the service | None |
| `start` | Start the service | Service installed |
| `stop` | Stop the service | Service installed |
| `restart` | Restart the service | Service installed |
| `status` | Show service status and process information | Service installed |
| `logs` | Show recent log entries | Service installed |
| `logs -f` | Follow logs in real-time | Service installed |
| `help` | Display usage information | None |

#### Environment Variables

| Variable | Default | Description | Example |
| --- | --- | --- | --- |
| `APP_NAME` | `myapp` | Service identifier and process group tag | `mywebserver` |
| `APP_SCRIPT` | `./run.sh` | Path to executable script to daemonize | `/opt/myapp/start.sh` |
| `LOG_SIZE` | `10M` | Log rotation size threshold | `50M`, `1G` |
| `LOG_COUNT` | `7` | Number of rotated logs to retain | `14`, `30` |
| `RUN_USER` | `$(whoami)` | User account for service execution | `www-data`, `appuser` |
| `USE_SYSTEMD` | `auto` | systemd usage preference | `true`, `false`, `auto` |

### Return Codes

| Code | Meaning | When Returned |
| --- | --- | --- |
| `0` | Success | Command completed successfully |
| `1` | General error | Invalid command, missing dependencies, permission issues |
| `2` | Service already running | Attempting to start running service |
| `3` | Service not running | Attempting to stop non-running service |

### Process Identification

Services are tagged with environment variables for easy identification:

Bash

`export SERVICE_NAME="$APP_NAME"
export SERVICE_TYPE="main"`

Discovery commands:

Bash

`# Find by service name
pgrep -f "SERVICE_NAME=myapp"

# Find by process pattern
pgrep -f "myapp"

# List all managed services
ps aux | grep "SERVICE_NAME="`

Dependency Management
---------------------

### Detection Matrix

| Tool | Detection Method | Installation Command |
| --- | --- | --- |
| systemd | `systemctl --version` | Pre-installed |
| rotatelogs | `command -v rotatelogs` | `apt install apache2-utils` |
| Package Manager | `command -v apt/dnf/yum` | N/A |

### Fallback Chain

Plaintext

`systemd + rotatelogs (optimal)
    ↓
systemd + journald (good)
    ↓
manual daemon + rotatelogs (functional)
    ↓
manual daemon + manual rotation (basic)`

### Package Manager Support

| Distribution | Package Manager | rotatelogs Package |
| --- | --- | --- |
| Ubuntu/Debian | `apt` | `apache2-utils` |
| Fedora/RHEL | `dnf` | `httpd-tools` |
| CentOS | `yum` | `httpd-tools` |
| Arch Linux | `pacman` | `apache` |
| openSUSE | `zypper` | `apache2-utils` |

Log Management
--------------

### Log Rotation Strategies

#### 1\. **rotatelogs (Preferred)**

Bash

`./app.sh 2>&1 | rotatelogs /var/log/myapp/app.%Y-%m-%d-%H_%M_%S 10M`

-   **Pros**: Real-time rotation, no log loss, timestamp-based filenames
-   **Cons**: Requires apache2-utils package

#### 2\. **Manual Rotation (Fallback)**

Bash

`./app.sh 2>&1 | while read line; do
    echo "$line" | tee -a current.log
    # Size check and rotation logic
done`

-   **Pros**: No dependencies, full control
-   **Cons**: More complex, potential for brief log loss during rotation

#### 3\. **journald (systemd)**

Bash

`# Automatic via systemd service configuration
StandardOutput=journal
StandardError=journal`

-   **Pros**: Integrated with systemd, automatic management
-   **Cons**: Less control over rotation policies

### Log File Structure

Plaintext

`/var/log/$APP_NAME/
├── current.log              # Active log (manual rotation)
├── app_20260124_143022.log  # Rotated log (manual)
├── app.2026-01-24-14_30_22  # Rotated log (rotatelogs)
└── app.2026-01-24-14_35_45  # Rotated log (rotatelogs)`

Usage Patterns
--------------

### Basic Service Setup

Bash

`# Set up environment
export APP_NAME="mywebserver"
export APP_SCRIPT="/opt/myapp/server.sh"
export LOG_SIZE="50M"

# Check system capabilities
./appdeploy-runner.sh check

# Install and start
./appdeploy-runner.sh install
./appdeploy-runner.sh start`

### Development Workflow

Bash

`# Quick setup for development
APP_NAME="devserver" APP_SCRIPT="./dev-server.sh" ./appdeploy-runner.sh install

# Monitor logs during development
./appdeploy-runner.sh logs -f

# Restart after code changes
./appdeploy-runner.sh restart`

### Production Deployment

Bash

`# Install optimal dependencies first
sudo apt-get install apache2-utils  # Ubuntu
sudo dnf install httpd-tools         # Fedora

# Deploy with production settings
export APP_NAME="prodapp"
export APP_SCRIPT="/opt/prodapp/start.sh"
export LOG_SIZE="100M"
export LOG_COUNT="30"
export RUN_USER="appuser"

./appdeploy-runner.sh install`

### Multi-Service Management

Bash

`# Deploy multiple services
for service in api worker scheduler; do
    APP_NAME="myapp-$service"\
    APP_SCRIPT="/opt/myapp/$service.sh"\
    ./appdeploy-runner.sh install
done

# Check all services
for service in api worker scheduler; do
    APP_NAME="myapp-$service" ./appdeploy-runner.sh status
done`

Integration Patterns
--------------------

### CI/CD Integration

Bash

`#!/bin/bash
# deploy.sh
set -e

# Stop existing service
APP_NAME="$SERVICE_NAME" ./appdeploy-runner.sh stop || true

# Deploy new code
rsync -av ./app/ /opt/myapp/

# Start service
APP_NAME="$SERVICE_NAME"\
APP_SCRIPT="/opt/myapp/start.sh"\
./appdeploy-runner.sh install

APP_NAME="$SERVICE_NAME" ./appdeploy-runner.sh start`

### Health Check Integration

Bash

`#!/bin/bash
# health-check.sh
APP_NAME="myapp" ./appdeploy-runner.sh status
if [ $? -ne 0 ]; then
    echo "Service down, restarting..."
    APP_NAME="myapp" ./appdeploy-runner.sh start
fi`

### Log Monitoring Integration

Bash

`# Monitor for errors
APP_NAME="myapp" ./appdeploy-runner.sh logs | grep -i error

# Export logs to external system
APP_NAME="myapp" ./appdeploy-runner.sh logs -f |\
    while read line; do
        curl -X POST -d "$line" http://log-collector/api/logs
    done`

Security Considerations
-----------------------

### File Permissions

-   Service files: `644` (readable by owner and group)
-   Log directories: `755` (writable by service user only)
-   PID files: `644` (readable by all, writable by owner)

### User Isolation

-   Non-root services run under specified user account
-   Log files owned by service user
-   systemd user services for additional isolation

### Log Security

-   Logs may contain sensitive information
-   Automatic rotation prevents disk exhaustion
-   Consider log encryption for sensitive applications

Limitations
-----------

### Known Limitations

1.  **Single-process services only**: No built-in support for multi-process applications
2.  **Linux-only**: No support for other Unix variants
3.  **Basic resource management**: No CPU/memory limits (use systemd for advanced features)
4.  **No service dependencies**: Cannot express dependencies between services
5.  **Limited log filtering**: No built-in log filtering or structured logging

### Workarounds

-   **Multi-process apps**: Use a wrapper script that manages child processes
-   **Resource limits**: Combine with systemd service files for advanced features
-   **Service dependencies**: Use systemd `After=` directives in generated service files
-   **Advanced logging**: Pipe through external log processors

Future Enhancements
-------------------

### Planned Features

-   **Service templates**: Pre-configured setups for common application types
-   **Health check integration**: Built-in health monitoring and restart policies
-   **Log filtering**: Basic log level filtering and structured output
-   **Service discovery**: Simple service registry for multi-service applications

### Compatibility Roadmap

-   **Container integration**: Support for containerized applications
-   **Cloud-init integration**: Automatic service setup in cloud environments
-   **Configuration management**: Integration with Ansible, Puppet, Chef
