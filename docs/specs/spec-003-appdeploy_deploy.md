# Appdeloy Deploy

`appdeloy deploy [-p|--package NAME[-VERSION]] PACKAGE_PATH|PACKAGE_ARCHIVE [CONF_ARCHIVE] [TARGET]` deploys the given
package, given as a package dir or a package archive, inferring the name from the package path or
archive (default name is basename, default version is `TIMESTAMP-GIT_SHORTREV` when directory, otherwise
parsed from archive name). And does the following:

- Local: Validate the package (env.sh, run.sh, bot executable)
- Local: Package the archive if not already an archive
- Target: Terraforms target so that it's in the right configuration
- Target: Uploads package
- Target: Installs package
- Target: Deactivates current if any
- Target: Activate uploaded package
- Target: Add configuration if given
- Target: Start the package
