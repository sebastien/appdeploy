export APPDEPLOY_TARGET=agent@stage:/apps
source appdeploy.sh
appdeploy_check $APPDEPLOY_TARGET
# appdeploy_install $APPDEPLOY_TARGET myapp-1.0.0.tar.gz
appdeploy_package examples/hello-service hello-service-1.0.0.tar.gz
