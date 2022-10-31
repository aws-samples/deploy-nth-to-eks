#!/bin/bash
set -x

echo "starting nth install script"
helm status aws-node-termination-handler -n kube-system>/dev/null 2>&1
if [ $? -ne 0 ]; then 
  echo "aws-node-termination-handler helm installation NOT found. Continuing..."
  ./nth_script.sh -a ${ASG_GROUPS} -c ${EKS_CLUSTERNAME} -g "${REGION}"
else
  echo "aws-node-termination-handler helm installation found. Skipping..."
fi
