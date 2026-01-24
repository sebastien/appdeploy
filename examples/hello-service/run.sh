#!/usr/bin/env bash
# Will be run within a shell that sources `env.sh` first.
echo ">>> START run.sh"
# Debug: Check if environment is available
{
	echo "DEBUG: HELLO_MESSAGE is set to: ${HELLO_MESSAGE:-NOT_SET}"
	echo "RUN_SH_EXECUTED=1"
	echo "HELLO_MESSAGE=$HELLO_MESSAGE"
} >>/tmp/appdeploy_test_run.log
# Simple loop instead of watch for easier testing
for _ in {1..10}; do
	echo "$HELLO_MESSAGE It is now: $(date)"
	sleep 1
done
echo "<<<END run.sh"
# EOF
