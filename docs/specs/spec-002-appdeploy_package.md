# Appdeploy package

`appdeloy package PATH [VERSION|OUTPUT]` creates an appdeloy package for the
distribution at `PATH`. If `OUTPUT` is specified, it must match the `PACKAGE_ARCHIVE`
format (`{name}-{version}.tar.[bz2,gz,xz]`) or otherwise the package name will
be inferred from the basename of `PATH`, the optional `VERSION` or defaulting to
the git or jj commit version, or if not the current timestamp as `YYYYMMDDHHmMSS`.

The command must:
- Ensure PATH has `env.sh` and `run.sh`, if not, fail
- Get/compute the output archive name
- If it exists, stops unless the `-f/--force` flag is set
- Proceeds to package the PATH, making sure that all files and dirs are readonly in the archive (but preserving +x flags)

