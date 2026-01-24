# Teelog

Teelog is a tool that works like `tee`, except that it:

- Supports stdout & stderr logging
- Supports log rotation by size
- Supports rotated log cleanup by count or age
- Never cuts a log in the middle of a line.

```
# teelog -s|--max-size SIZE -a|--max-age AGE -c|--max-count COUNT OUT [ERR]
# Like tee:
./my-service | teelog --max-size 10Mb --max-age=7d --max-count=100 myservice.log
# Easily capture stdout/err
teelog --max-size 10Mb --max-age=7d --max-count=100 myservice.log -- my-service
```

## Implementation

Should be implemented in bash in `teelog.sh`, following this template

```
#!/usr/bin/env bash
# --
# File: Teelog
#
# `teelog` is…

set -euo pipefail

# DEFAULTS
TEELOG_MAX_SIZE=${TEELOG_MAX_SIZE:-}
TEELOG_MAX_AGE=${TEELOG_MAX_AGE:-}

# -----------------------------------------------------------------------------
#
# SECTION
#
# -----------------------------------------------------------------------------

# =============================================================================
# GROUP
# =============================================================================

# Function: teelog_parse_size SIZE
# Parses the given `SIZE`, returns bytes
teelog_parse_size() {
  …
}

# -----------------------------------------------------------------------------
#
# MAIN
#
# -----------------------------------------------------------------------------

# Function: teelog_main ARGS
# Main cli
teelog_main() {
  …
}

# Can be used as a library or executable
case "$(basename "$0")" in
  teelog.sh|teelog)
    exec teelog_main()
    ;;
esac


# EOF
```

Rules:
- Never cut in the middle of a line
- Log archives are suffixed with date, like `YYYY-MM-DD-HHmmSS`
- Same-second rotation: we use sequence numbers `2026-01-25-143022`, `2026-01-25-143022.1`
- Directory creation: Auto-create parent directories
- Exit code: Return command's exit code; print `EOK` or `EFAIL $STATUS` on completion


