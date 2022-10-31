#!/bin/bash
export AWS_REGION=$(jq -r ".region" config/config.json)
export ACCOUNTID=$(aws sts get-caller-identity | jq -r ".Account")
export cdk_stack_name=$(jq -r ".stackName" config/config.json) 
aws configure set region $AWS_REGION

echo "checking if helm release aws-node-termination-handler is installed"
helm status aws-node-termination-handler -n kube-system>/dev/null 2>&1
if [ $? -ne 0 ]; then 
  echo "aws-node-termination-handler helm installation NOT found. Continuing..."
else
  echo "aws-node-termination-handler helm installation found. Uninstalling..."
  helm uninstall -n kube-system aws-node-termination-handler
fi
CLUSTER_NAME=$(cat config/config.json|jq -r .eksClusterName)
nthStack="nth-stack-${CLUSTER_NAME}"
echo "Deleting Stack ${nthStack}"
aws cloudformation delete-stack --stack-name $nthStack
echo "${nthStack} Deleted"
cd cdk
echo "Deleting Stack ${cdk_stack_name}"
cdk destroy -c source=../../config/config.json --require-approval never 
echo "${cdk_stack_name} Deleted"
