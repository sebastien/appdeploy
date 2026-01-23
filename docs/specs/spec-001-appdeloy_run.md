# Appdeploy Run

The `appdeploy run [-c--config CONF_ARCHIVE] [-r|--run RUN_PATH] PACKAGE_ARCHIVE [OVERLAY_PATH]` can run an
appdeploy package locally. What it will do is:

- Create a temporary run directory `appdeploy.run.XXXX` in the current path (or `RUN_PATH` if specified)
- Unpack the archive
- Unpack the configuration (if provided)
- Create symlinks for all OVERLAY_PATH
- Check the installed package (should be `env.sh` and `run.sh`)
- Start a subprocess in the run directory, source `env.sh` and exec `run.sh` logging to stdout and stderr as expected
- On exit, log the exit status, runtime, and cleanup the run directory, making sure to unlink symlinks first.
