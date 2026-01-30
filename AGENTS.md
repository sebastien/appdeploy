# AppDeploy Agent Guidelines

AppDeploy is a collection of tools for application deployment and management on Linux servers. Uses LittleSDK build system, Python 3.11+, and Bash.

## Build Commands

- `make` - Default build (runs BUILD_ALL)
- `make build` - Builds all outputs
- `make prep` - Installs dependencies & prepares environment
- `make check` / `make lint` - Runs all checks
- `make fix` / `make fmt` - Runs all fixes/formatters
- `make test` - Runs all tests
- `make run` - Runs the project
- `make dist` - Creates distributions
- `make clean` - Removes build artifacts
- `make help` - Shows available rules

## Test Commands

Tests use a custom bash testing framework defined in `tests/lib-testing.sh`:

- `make test` - Run all tests
- Run a single test file: `./tests/daemonrun.test.sh`
- Run root tests (requires sudo): `sudo ./tests/daemonrun.root.test.sh`

### Test Framework

Source the library and use these primitives:

```bash
source "tests/lib-testing.sh"
test-init "Test Name"
test-step "Description"
test-ok          # Mark test passed
test-fail "msg"  # Mark test failed
test-expect-success cmd
test-expect-failure cmd
test-end
```

## Project Structure

- `src/py/` - Python sources (appdeploy, daemonctl)
- `src/sh/` - Shell scripts (daemonrun.sh, teelog.sh)
- `src/systemd/` - Systemd service files
- `tests/` - Bash-based test suite
- `example/` - Example applications
- `bin/` - Symlinks to installed tools
- `build/` - Build artifacts (created by make)
- `run/` - Runtime files (created by make run)
- `dist/` - Distribution artifacts

## Code Style

### Python

- **Naming**: Functions use `snake_case` with `appdeploy_` prefix for public APIs
- **Types**: Use type hints (e.g., `-> Optional[str]`, `dict[str, Any]`)
- **Docstrings**: Short docstrings for functions explaining purpose and params
- **Imports**: Standard library only, minimize third-party dependencies
- **Structure**: Group code by functionality (UTILITIES, TARGET OPERATIONS, etc.)
- **Globals**: Module-level globals use leading underscore for internal state
- **Error handling**: Raise specific exceptions with helpful messages
- **Be concise**: Write compact, functional code

Example:

```python
def appdeploy_util_color(text: str, color: str) -> str:
    """Colorize text if colors are enabled."""
    if _no_color:
        return text
    return f"{colors.get(color, '')}{text}{colors.get('reset', '')}"
```

### Bash

- **Naming**: Functions use `snake_case` with tool prefix (e.g., `teelog_`, `daemonrun_`)
- **Headers**: File headers with `#!/usr/bin/env bash` and description comment block
- **Strict mode**: `set -euo pipefail` at start of scripts
- **Docstrings**: Document all functions with `# Function: name PARAMS` format
- **Comments**: Use `# --` and `# ##` for section headers
- **Globals**: Private globals use leading underscore (e.g., `_TEELOG_OUT_FILE`)
- **Error handling**: Use `|| true` to suppress expected failures
- **No trailing spaces**: Keep lines clean

Example:

```bash
# Function: teelog_parse_size SIZE
# Parses a human-readable size string and outputs bytes.
telog_parse_size() {
    local input="$1"
    [[ "$input" =~ ^([0-9]+)([KkMmGg][Bb]?)?$ ]]
    # ...
}
```

### LittleSDK Conventions

- Variables: `UPPER_CASE` for globals, `VARNAME?=DEFAULT` for env vars
- Functions: `snake_case` callable via `$(call function_name,…)`
- Tasks: `kebab-case`, suffix `--` for params, `@` for env

## Tools Overview

- `appdeploy` (Python) - High-level deployment tool
- `daemonctl` (Python) - Process control for daemons
- `daemonrun` (Bash) - Low-level process execution
- `teelog` (Bash) - Log rotation and tee utility

## Configuration Files

- `biome.jsonc` - Linting/formatting config (symlinked from SDK)
- `.editorconfig` - Editor configuration (symlinked from SDK)
- `.prettierrc` - Prettier configuration (symlinked from SDK)
- `opencode.jsonc` - opencode configuration (symlinked from SDK)

## Development Workflow

1. Make changes in `src/py/` or `src/sh/`
2. Run tests: `make test` or individual test files
3. Check code: `make check`
4. Build: `make build`
5. Install symlinks: `make install-symlinks`

## Environment Variables

- `APPDEPLOY_TARGET` - Default deployment target path
- `APPDEPLOY_SSH_OPTIONS` - SSH options for remote deployment
- `APPDEPLOY_KEEP_VERSIONS` - Number of versions to keep
- `APPDEPLOY_OP_TIMEOUT` - Operation timeout in seconds
- `APPDEPLOY_NO_COLOR` - Disable colored output

## Rules

- Use the lattice-mcp rule, uses Matryoshka/Lattice (MCP) to query files & documents
