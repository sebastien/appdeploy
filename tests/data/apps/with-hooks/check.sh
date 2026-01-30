#!/bin/bash
# --
# Health check script - returns 0 if healthy, non-zero if unhealthy

if [ -f /tmp/with-hooks-status.txt ]; then
    STATUS=$(cat /tmp/with-hooks-status.txt)
    if [ "$STATUS" = "running" ]; then
        exit 0
    else
        echo "Health check: FAILED - status is $STATUS"
        exit 1
    fi
else
    echo "Health check: FAILED - status file not found"
    exit 1
fi
