#!/bin/bash
# --
# on-stop hook - runs after the daemon stops

if [ -f /tmp/with-hooks-prestart.txt ]; then
    rm /tmp/with-hooks-prestart.txt
fi

if [ -f /tmp/with-hooks-status.txt ]; then
    rm /tmp/with-hooks-status.txt
fi

exit 0
