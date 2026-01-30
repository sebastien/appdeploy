#!/bin/bash
# --
# on-start hook - runs before the daemon starts

if [ -f /tmp/with-hooks-prestart.txt ]; then
    rm /tmp/with-hooks-prestart.txt
fi

echo "pre-start-complete" > /tmp/with-hooks-prestart.txt
exit 0
