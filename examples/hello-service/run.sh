#!/usr/bin/env bash
# Will be run within a shell that sources `env.sh` first.
echo ">>> START"
watch -n1 echo "$HELLO_MESSAGE It is now:" '$(date)'
echo "<<<END"
# EOF
