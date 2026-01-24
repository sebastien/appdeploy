# Appdeploy Control

The following commands control an appdeploy instance:

- `appdeploy list [PACKAGE[:VERSION]] [TARGET]` shows all packages on target that match PACKAGE and VERSION (globs supported, all by default)

- `appdeploy status [PACKAGE[:VERSION]] [TARGET]` for each package, shows the active version (if any, bold green if running), if no active or running, show as inactive. When PACKAGE and VERSION, filter using both, glob supported.

- `appdeploy start PACKAGE[:VERSION] [TARGET]` ensures that the given package is started and running on the target. Will install and activate the package version if found.

- `appdeploy stop PACKAGE[:VERSION] [TARGET]` ensures that the given package is stopped and not running on the target. Will deactivate the package version if found.

- `appdeploy remove PACKAGE[:VERSION] [TARGET]` ensures that the given package is removed from the target.
