# AppDeploy CLI Reference

## Global Options

- `-h|--help`
- `-v|--version`
- `--debug`

## Commands

```
# Run a package archive locally (setup + execute env.sh/run.sh)
appdeploy run PACKAGE_ARCHIVE [-c|--config FILE] [-r|--run PATH] [-d|--dry] [OVERLAY_PATHS...]

# Create a package archive from a directory
appdeploy package PATH [VERSION|OUTPUT] [-f|--force]

# Prepare target: create structure if needed, list installed packages
appdeploy prepare [TARGET]

# Verify target directory exists
appdeploy check [TARGET]

# Full deployment lifecycle: terraform, upload, install, deactivate old, activate new, deploy config
appdeploy deploy [-p|--package NAME[-VERSION]] PACKAGE_PATH [CONF_ARCHIVE] [TARGET]

# Upload a package archive to target
appdeploy upload PACKAGE [NAME] [VERSION] [TARGET]

# Install (unpack) an uploaded package on target
appdeploy install PACKAGE[:VERSION] [TARGET]

# Activate a package (create symlinks in run/ from dist/ and var/)
appdeploy activate PACKAGE[:VERSION] [TARGET]

# Deactivate a package (remove symlinks from run/)
appdeploy deactivate PACKAGE[:VERSION] [TARGET]

# Uninstall a package (remove dist/, keep archive)
appdeploy uninstall PACKAGE[:VERSION] [TARGET]

# Remove a package completely (uninstall + delete archive)
appdeploy remove PACKAGE[:VERSION] [TARGET]

# List packages on target with status (uploaded/installed/active)
# Note: with 1 arg, treated as TARGET (not PACKAGE)
appdeploy list [PACKAGE[:VERSION]] [TARGET]

# Deploy configuration archive to package var/ directory
appdeploy configure PACKAGE[:VERSION] CONF_ARCHIVE [TARGET]

# Service Management (runner auto-deployed on activate/start)
appdeploy start PACKAGE[:VERSION] [TARGET]      # Start service (auto-activates if needed)
appdeploy stop PACKAGE[:VERSION] [TARGET]       # Stop service daemon
appdeploy restart PACKAGE[:VERSION] [TARGET]    # Restart service (stop + start)
appdeploy status PACKAGE[:VERSION] [TARGET]     # Show service status (running/stopped)
appdeploy logs PACKAGE[:VERSION] [TARGET] [-f]  # Show logs (-f to follow)
```

## Formats

- `PACKAGE`: `${NAME}-${VERSION}` (`NAME` can contain `-`)
- `PACKAGE_ARCHIVE`: `${NAME}-${VERSION}.tar.[gz,bz2,xz]`
- `PACKAGE[:VERSION]`: `myapp` or `myapp:1.0.0`
- `TARGET`: `[USER@]HOST[:PATH]` - contains `@` or `/` to disambiguate from PACKAGE

## Environment Variables

- `APPDEPLOY_TARGET` (default: `/opt/apps`)
- `APPDEPLOY_DEFAULT_TARGET` (default: `/opt/apps`)
- `APPDEPLOY_DEFAULT_PATH` (default: `/opt/apps`)
- `DEBUG`
- `NOCOLOR`
