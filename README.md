```
   _____               ________                .__
  /  _  \ ______ ______\______ \   ____ ______ |  |   ____ ___.__.
 /  /_\  \\____ \\____ \|    |  \_/ __ \\____ \|  |  /  _ <   |  |
/    |    \  |_> >  |_> >    `   \  ___/|  |_> >  |_(  <_> )___  |
\____|__  /   __/|   __/_______  /\___  >   __/|____/\____// ____|
        \/|__|   |__|          \/     \/|__|               \/
```

AppDeploy is a collection of tools designed to make application deployment
and management on a homelab server easy. It consists of a collection of core
tools that support the following:

- **Deployment**: `appdeploy` packages your application and uploads it to the
  target server. It installs `daemonctl`, `daemonrun`, and `teelog` if they
  are missing.
- **Configuration**: When you start an app, `appdeploy` calls
  `daemonctl` on the remote machine.
- **Execution**: `daemonctl` reads the
  app's config and launches `daemonrun` with the correct parameters.
- **Runtime**: `daemonrun` spawns the application process, managing its
  lifecycle and resource usage.
- **Logging**: `daemonrun` pipes the
  application's output to `teelog`, which handles writing to log files with
  rotation policies.

Here's an overview of the tools:

- `appdeploy`, high-level tool to package, upload, install and run your
  applications on a server.
- `daemonctl`, high-level tool to run processes as daemons (or not) on machine.
   This is used by `appdeploy` to control applications.
- `daemonrun`, low-level tool to run a process as a daemon, or not.
   This is used by `daemonctl` to manage the running of processes.
- `teelog`, is a logging wrapper that supports automatic rotation

You'll need a Linux system (we use `/proc`), a recent `python` (3.11+) and
`bash`.

## Quickstart

Clone the repository, and install the symlinks to `~/.local/bin`:

```bash
git clone https://github.com/yourusername/appdeploy.git
cd appdeploy
make install-symlinks
```

You can try deploying the `example/helloworld` application:

- Pick a target, which is your localhost:/opt/apps or like `USER@HOST[:PATH]`
- Set the target to `APPDEPLOY_TARGET`, make sure the directory exists and has rights
- Run an upgrade (install, activate, start): `appdeploy upgrade example/helloworld`
- Verify it's running: `appdeploy status helloworld`
- View logs: Tail the application logs: `appdeploy logs helloworld --follow` (Press Ctrl+C to exit)
- Cleanup: `appdeploy stop helloworld` and `appdeploy uninstall helloworld --all`

## Application Packaging

Appdeploy expects files in your directory structure to be deployable:

```
[conf.toml]             # Optional package and daemon configuration
[env.sh]                # Optional environment script (sourced by run.sh, not automatically)
run[.sh]                # Required: runs the application in foreground
[check[.sh]]            # Optional health check script
[on-start[.sh]]         # Script run when application starts successfully
[on-stop[.sh]]          # Script run when application stops
[VERSION]               # Optional version file (single line)
```

When deployed, applications will live in the target like so:

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
            ${NAME}.err         # Stderr log (via teelog)
            ${NAME}.run         # Operations/event log
        run/                    # Active runtime directory
            .pid                # PID file
            .version            # Active version string
            logs -> ../logs     # Symlink to logs
            ...                 # Symlinks created from layers (see below)
```
