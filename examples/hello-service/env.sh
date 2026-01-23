#!/usr/bin/env bash
# Define environment variables, you can run commands as well.
echo ">>> START env.sh"
HELLO_MESSAGE="Hello, world! This started at $(date)."
# Export the variable so it's available to child processes
export HELLO_MESSAGE
echo "ENV_SH_SOURCED=1" >>/tmp/appdeploy_test_env.log
echo "HELLO_MESSAGE=$HELLO_MESSAGE" >>/tmp/appdeploy_test_env.log
echo "<<< END env.sh"
# EOF
