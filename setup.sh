#!/bin/bash

export AWS_REGION=$(jq -r ".region" config/config.json)
export ACCOUNTID=$(aws sts get-caller-identity | jq -r ".Account")
echo "Current Account : $ACCOUNTID, Region: $AWS_REGION"

cdk bootstrap aws://${ACCOUNTID}/${AWS_REGION}

cluster_role_name=$(cat config/config.json|jq -r .eksClusterRole)
cluster_name=$(cat config/config.json|jq -r .eksClusterName)

if [ $(cat config/config.json|jq -r .create_cluster_role) = "yes" ]; then
  echo "Creating cluster role"
  ./create_cluster_role.sh ${cluster_role_name} ${cluster_name}
else 
  echo "cluster role create is set to false. Make sure cluster role ${cluster_role_name} exist and proper RBAC access"
fi

OIDC_PROVIDER=$(aws eks describe-cluster --name "$cluster_name" --region "${AWS_REGION}" --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
OIDC_IAM_ARN=$(aws iam list-open-id-connect-providers --region "${AWS_REGION}" | jq -r '.[]|.[].Arn' |grep "$OIDC_PROVIDER")

if [ -z ${OIDC_IAM_ARN} ]; then
  echo "IAM OIDC provider not found"
  if [ $(cat config/config.json|jq -r .create_iam_oidc_provider) = "yes" ]; then
    echo "create_iam_oidc_provider flag is set to yes. Creatig it"
    eksctl utils associate-iam-oidc-provider --cluster "$cluster_name" --region "${AWS_REGION}" --approve
  else
    echo "create_iam_oidc_provider flag is set to no. Exiting..."
    exit 1
  fi
else
  echo "IAM OIDC provider Found"
fi
if [ $(cat config/config.json|jq -r .install_cdk) = "yes" ]; then
  echo "Installing CDK version 2.27.0"
  sudo npm install -g cdk@2.27.0
fi
cd cdk
npm install
aws configure set region $AWS_REGION

cdk deploy -c source=../../config/config.json --require-approval never 

