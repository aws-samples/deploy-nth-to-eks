#! /bin/bash
cluster_role_name=$1
cluster_name=$2
Trus_policy_doc="Role-Trust-Policy.json"
echo "Cluster Name is set to: ${cluster_name}"
echo "Cluster role to be created: ${cluster_role_name}"
Account_ID=$(aws sts get-caller-identity --query "Account" --output text)
sed  's/ACCOUNTID/'"$Account_ID"'/g' ${Trus_policy_doc} > updated_${Trus_policy_doc}
aws iam get-role --role-name ${cluster_role_name} >/dev/null  2>&1
if [ $? -eq 0 ]; then
  echo "Role ${cluster_role_name} already exists"
else
  aws iam create-role --role-name ${cluster_role_name} --assume-role-policy-document file://updated_${Trus_policy_doc}
  eksctl create iamidentitymapping --cluster ${cluster_name} --arn arn:aws:iam::${Account_ID}:role/${cluster_role_name} --group system:masters --username clusteradminnth
fi
