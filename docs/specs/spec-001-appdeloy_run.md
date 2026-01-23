# Appdeploy Run

The `appdeploy run [-c--config CONF_ARCHIVE] [-r|--run RUN_PATH] PACKAGE_ARCHIVE|PACKAG_PATH [OVERLAY_PATH]` can run an
appdeploy package locally from a packaged archive, or a package distribution path.

What it will do is:

- Create a temporary run directory `appdeploy.run.XXXX` in the current path (or `RUN_PATH` if specified)
- Unpack the archive (if an archive) in `RUN_PATH`, or symlink all of `PACKAGE_PATH` to the `RUN_PATH`
- Check the installed package (there should be `env.sh` and `run.sh`, both should be executable)
- Unpack the configuration (if provided) in `RUN_PATH`
- Create symlinks for all `OVERLAY_PATH` in `RUN_PATH`, overriding any existing file (careful as they may be readonly)
- Start a subprocess in the run directory, source `env.sh` and exec `run.sh` logging to stdout and stderr as expected
- On exit, log the exit status, runtime, and cleanup the run directory, making sure to unlink symlinks first.
