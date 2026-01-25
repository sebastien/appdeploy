```
   _____               ________                .__
  /  _  \ ______ ______\______ \   ____ ______ |  |   ____ ___.__.
 /  /_\  \\____ \\____ \|    |  \_/ __ \\____ \|  |  /  _ <   |  |
/    |    \  |_> >  |_> >    `   \  ___/|  |_> >  |_(  <_> )___  |
\____|__  /   __/|   __/_______  /\___  >   __/|____/\____// ____|
        \/|__|   |__|          \/     \/|__|               \/

```

AppDeploy is a comprehensive toolkit designed to package, deploy, and manage applications on local or remote servers. It provides a robust alternative to complex container orchestration for simpler deployment needs, offering atomic upgrades, rollbacks, and process management.

## Tools Overview

The project consists of four integrated tools, each serving a specific layer of the deployment stack:

### 1. `appdeploy`
**The Deployment Manager**
The high-level CLI tool that orchestrates the entire deployment lifecycle.
- **Offers:** Packaging, uploading, version management (install/upgrade/rollback), and remote execution via SSH.
- **Role:** It acts as the control plane, interacting with the target machine to set up the environment and invoke the other tools.

### 2. `daemonctl`
**The Service Manager**
A wrapper around `daemonrun` that serves as the interface between the deployed application structure and the process runner.
- **Offers:** Configuration management (TOML), environment handling, health monitoring, and simplified commands for process control (start/stop/restart/status).
- **Role:** It interprets the application's configuration and translates high-level intents into specific `daemonrun` commands.

### 3. `daemonrun`
**The Process Runner**
The core execution engine responsible for running the application processes reliably.
- **Offers:** Daemonization (double-fork), signal forwarding, process groups, resource limits, and sandboxing (namespaces/capabilities).
- **Role:** It ensures the application runs correctly, handles signals gracefully, and stays within defined resource boundaries.

### 4. `teelog`
**The Logger**
A specialized logging utility that manages application output.
- **Offers:** Log rotation (by size/age/count), stdout/stderr separation, and atomic line writing.
- **Role:** It captures the output from `daemonrun` and ensures logs are safely written and rotated without losing data or corrupting lines.

## How They Work Together

1.  **Deployment**: `appdeploy` packages your application and uploads it to the target server. It installs `daemonctl`, `daemonrun`, and `teelog` if they are missing.
2.  **Configuration**: When you start an app, `appdeploy` calls `daemonctl` on the remote machine.
3.  **Execution**: `daemonctl` reads the app's config and launches `daemonrun` with the correct parameters.
4.  **Runtime**: `daemonrun` spawns the application process, managing its lifecycle and resource usage.
5.  **Logging**: `daemonrun` pipes the application's output to `teelog`, which handles writing to log files with rotation policies.

This layered approach allows for a clean separation of concerns: `appdeploy` handles *how it gets there*, `daemonctl` handles *how it's configured*, `daemonrun` handles *how it runs*, and `teelog` handles *what it says*.
