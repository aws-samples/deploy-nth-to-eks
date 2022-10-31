#!/bin/bash
set -x

echo "starting nth scan script"
helm status aws-node-termination-handler -n kube-system>/dev/null 2>&1

if [ $? -ne 0 ]; then 
  echo "aws-node-termination-handler helm installation NOT found. Continuing..."
  echo "Executing Dry Run"
  ./nth_script.sh -a ${ASG_GROUPS} -c ${EKS_CLUSTERNAME} -g "${REGION}" -x
  echo "Executing cfn nag"
  cfn_nag_scan --input-path nth_cfn_template.json
else
  echo "aws-node-termination-handler helm installation found. Skipping"
fi