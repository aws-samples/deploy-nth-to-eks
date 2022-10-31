#!/bin/bash
set -x

echo "nth_script.sh script "

print_usage(){
  echo "This script deploys a cloudformation stack with resources required to install the AWS Node Termination Handler - Queue Processor on provided cluster"
  echo "More details here: https://github.com/aws/aws-node-termination-handler"  
  echo "Script assumes appropriate IAM OIDC provider exists"  
  echo "Script will create a new service account for use in the Kubernetes cluster."  
  echo "Usage:"
  echo "      -a <AutoScaling Group Name>       Provide an existing Autoscaling group in the same region. For multiple ASGs use ',' to separate. <e.g -a ASG1,ASG2, ... ,ASGN>"
  echo "      -c <Cluster Name>                 Provide the name for the cluster being upgraded"  
  echo "      -g <region>                       Provide the region where EKS Cluster is deployed"     
  echo "      -r <Image Repo Name>  Optional    Name of the ECR repo. Defaults to: public.ecr.aws/aws-ec2/aws-node-termination-handler"     
  echo "      -t <Image Tag>        Optional    Tag for the image. Defaults to 1.16"     
  echo "      -d                                Rolls back all changes from running script"
  echo "      -x                                For Dry run. It will just generate the CFN Template"
}


rollback(){
    echo "Rolling back changes"
    echo
    echo "Deleting stack ..."
    echo    
        aws cloudformation delete-stack --region "${REGION}"  --stack-name $STACKNAME
    echo
    echo "Removing AutoScalingGroup tags ..."
    echo
    CLEANUP_ASGs=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[? Tags[? (Key=='aws-node-termination-handler/managed') && Value=='']]".AutoScalingGroupName --output text)
    read -a resources <<< "$CLEANUP_ASGs"
    for resourceId in "${resources[@]}"; do
        echo $resourceId
        ## Update ASG tags
        aws autoscaling delete-tags --tags ResourceId="${resourceId}",ResourceType=auto-scaling-group,Key=aws-node-termination-handler/managed,Value=''
        echo "Removed tags from $resourceId"
        echo
    done
    echo
    echo "Uninstalling aws-node-termination-handler ..."
    helm uninstall aws-node-termination-handler -n $NAMESPACE
    echo
    echo "Rollback complete"
}

DO_ROLLBACK=false
DRY_RUN=false

while getopts :a:c:g:r:t:d:x flag
do
    case "${flag}" in
        a) AUTOSCALINGGROUPS=("$OPTARG");;
        c) CLUSTER_NAME=${OPTARG};;
        g) REGION=${OPTARG};;
        r) REPO=${OPTARG};;
        t) TAG=${OPTARG};;
        d) DO_ROLLBACK=true; ;;
        x) DRY_RUN=true ;;
        *) print_usage
           exit 1 ;;  
    esac
done

NAMESPACE="kube-system"
OIDC_PROVIDER=$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "${REGION}" --query "cluster.identity.oidc.issuer" --output text | sed -e "s/^https:\/\///")
OIDC_IAM_ARN=$(aws iam list-open-id-connect-providers --region "${REGION}" | jq -r '.[]|.[].Arn' |grep "$OIDC_PROVIDER")
echo "OIDC_PROVIDER is : $OIDC_PROVIDER"
echo "OIDC_IAM_ARN is : $OIDC_IAM_ARN"


SERVICEACCOUNT="sa-pods-${CLUSTER_NAME}"

ASGNotificationRole="asg-nodetermhdlr-${CLUSTER_NAME}"
NodeTerminationHandlerPodsRole="asg-nodetermhdlr-pod-${CLUSTER_NAME}"
STACKNAME="nth-stack-${CLUSTER_NAME}"
SQS_QUEUE_NAME="sqs-${CLUSTER_NAME}"

## Set Optional Params
[ ! -z "$REPO" ] && IMAGEREPO="$REPO"  
[ ! -z "$TAG" ] && IMAGETAG="$TAG"

if "$DO_ROLLBACK"; then
    rollback
    exit 0
fi

if [ $# -eq 0 ]; then
    echo "No arguments supplied"
    echo "This script requires the following parameters: -a [AUTOSCALINGGROUPS] -c [CLUSTER_NAME]"
    exit 1
fi

## Check if ASG Name is supplied
if [ -z "$AUTOSCALINGGROUPS" ]; then
    echo "No AutoScalingGroup argument supplied"
    exit 1
fi

## Check if Cluster Name is supplied
if [ -z "$CLUSTER_NAME" ]; then
    echo "No Cluster name argument supplied"
    exit 1
fi

## Sort out ASGs
## For each ASG, check if it's valid
## Check duplicates
INVALID_ASG=()
VALID_ASG=()
IFS=','
read -a ASGs <<< "$AUTOSCALINGGROUPS"
echo "-------------------------------- Checking ASGs Provided --------------------------------------------"
echo "AutoScaling groups provided: "
printf '%s\n' "${ASGs[@]}"
for asg in "${ASGs[@]}"; do
  VALID=$(aws autoscaling describe-auto-scaling-groups --region "${REGION}" --auto-scaling-group-names $asg |jq -r '.[]|.[].AutoScalingGroupARN')
  # continue Valid check
  if [ -z "$VALID" ]; then
    INVALID_ASG+=("$asg")
  else
    # add a dupe check
    VALID_ASG+=("$asg")
  fi
done
echo
echo "Removing duplicate entries"
echo

## Only store unique names
VALID_ASG=($(printf "%s\n" "${VALID_ASG[@]}"| sort -u | tr '\n' ',' ))
echo
echo "Found these unique AutoScaling groups:"
printf '%s\n' "${VALID_ASG[@]}"
echo "----------------------------------------------------------------------------------------------------"

## Show invalid
if (( ${#INVALID_ASG[@]} )); then
    echo "The following AutoScalingGroups do not exist:"
    printf '%s\n' "${INVALID_ASG[@]}"
    exit 1
fi

## Stack should install 9 resources
## Place in tmp folder??

NTH_STACK=$(cat <<EOF > nth_cfn_template.json
{
    "AWSTemplateFormatVersion": "2010-09-09",
    "Resources": {
        "ASGNotificationRole": {
            "Type": "AWS::IAM::Role",
            "Properties": {
                "AssumeRolePolicyDocument": {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Principal": {
                                "Service": [
                                    "autoscaling.amazonaws.com"
                                ]
                            },
                            "Action": [
                                "sts:AssumeRole"
                            ]
                        }
                    ]
                },
                "Path": "/",
                "ManagedPolicyArns": [
                    "arn:aws:iam::aws:policy/service-role/AutoScalingNotificationAccessRole"
                ],
                "RoleName": "${ASGNotificationRole}"
            }
        },
        "NodeTerminationHandlerPodsRole": {
            "Type": "AWS::IAM::Role",
            "Properties": {
                "AssumeRolePolicyDocument": {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Principal": {
                                "Federated": "${OIDC_IAM_ARN}"
                            },
                            "Action": "sts:AssumeRoleWithWebIdentity",
                            "Condition": {
                                "StringEquals": {
                                    "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
                                    "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICEACCOUNT}"
                                }
                            }
                        }
                    ]
                },
                "Path": "/",
                "Policies": [
                    {
                        "PolicyName": "NTH-QueueProcessor",
                        "PolicyDocument": {
                            "Version": "2012-10-17",
                            "Statement": [
                                {
                                    "Effect": "Allow",
                                    "Action": [
                                        "autoscaling:CompleteLifecycleAction",
                                        "autoscaling:DescribeAutoScalingInstances",
                                        "autoscaling:DescribeTags",
                                        "ec2:DescribeInstances",
                                        "sqs:DeleteMessage",
                                        "sqs:ReceiveMessage"
                                    ],
                                    "Resource": "*"
                                }
                            ]
                        }
                    }
                ],
                "RoleName": "${NodeTerminationHandlerPodsRole}"
            }
        },
        "Queue": {
            "Type": "AWS::SQS::Queue",
            "Properties": {
                "KmsMasterKeyId": "alias/aws/sqs",
                "MessageRetentionPeriod": 300,
                "QueueName": "${SQS_QUEUE_NAME}"
            }
        },
        "QueuePolicy": {
            "Type": "AWS::SQS::QueuePolicy",
            "Properties": {
                "Queues": [
                    {
                        "Ref": "Queue"
                    }
                ],
                "PolicyDocument": {
                    "Version": "2012-10-17",
                    "Id": "NTHQueuePolicy",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Principal": {
                                "Service": [
                                    "events.amazonaws.com",
                                    "sqs.amazonaws.com"
                                ]
                            },
                            "Action": "sqs:SendMessage",
                            "Resource": {
                                "Fn::GetAtt": [
                                    "Queue",
                                    "Arn"
                                ]
                            }
                        }
                    ]
                }
            }
        }
    },
    "Outputs": {
        "QueueURL": {
            "Description": "Queue url for AWS NTH controller",
            "Value": {
                "Ref": "Queue"
            }
        },
        "NodeTerminationHandlerPodsRole": {
            "Description": "Queue url for AWS NTH controller",
            "Value": {
                "Fn::GetAtt": [
                    "NodeTerminationHandlerPodsRole",
                    "Arn"
                ]
            }
        }
    }
}
EOF
)

## Create lifecycle hooks for every ASG
## Construct JSON
for ASG in "${VALID_ASG[@]}"; do
echo "Creating lifecycle hooks from provided Autoscaling group: $ASG"
TERM_HOOK=$(cat << EOF | jq . > hooks.json
    {
        "Type": "AWS::AutoScaling::LifecycleHook",
        "Properties": {
            "AutoScalingGroupName": "${ASG}",
            "LifecycleHookName": "NTH-K8S-TERM-HOOK",
            "LifecycleTransition": "autoscaling:EC2_INSTANCE_TERMINATING",
            "HeartbeatTimeout": 300,
            "DefaultResult": "CONTINUE",
            "NotificationTargetARN": {
                "Fn::GetAtt": [
                    "Queue",
                    "Arn"
                ]
            },
            "RoleARN": {
                "Fn::GetAtt": [
                    "ASGNotificationRole",
                    "Arn"
                ]
            }
        }
    }
EOF
)

HOOKNAME="$(echo "TermHook-$ASG"|sed -r 's/[_-]+//g')"

cat nth_cfn_template.json |jq --arg name "$HOOKNAME" --argjson blob "$(<hooks.json)" '(.Resources|.[$name]) |= .+ $blob' >tmp.json &&
mv tmp.json nth_cfn_template.json
done

echo
echo "Done creating hooks"
echo

cat nth_cfn_template.json


echo "----------------------------------- Deploy Stack --------------------------------------------------"
echo "Creating stack: $STACKNAME"

## Deploy stack

if [ ${DRY_RUN} == "true" ]; then

    echo "Dry Run. So skipping installation"

else
    echo "Deploying stack..."

    aws cloudformation deploy --stack-name "$STACKNAME" --region "${REGION}" --template-file nth_cfn_template.json --capabilities CAPABILITY_NAMED_IAM --no-fail-on-empty-changeset
    STACK_STATUS=$?


    echo
    if [[ ${STACK_STATUS} -ne 0 ]] ; then
        # Waiter encountered a failure state.
        echo "Stack ${STACKNAME} create/update failed. AWS error code is ${STACK_STATUS}."
        exit ${STACK_STATUS}
    fi

    ## Grab stack output
    # QueueURL=$(aws cloudformation describe-stacks --region "${REGION}" --query "Stacks[?StackName=='$STACKNAME'].Outputs[].OutputValue" --output text) 
    QueueURL=$(aws cloudformation describe-stacks --region "${REGION}"  --stack-name "${STACKNAME}" --query 'Stacks[0].Outputs[?OutputKey==`QueueURL`].OutputValue' --output text)
    echo "----------------------------------------------------------------------------------------------------"
    echo "QueueURL is: $QueueURL"

    IAM_PODS_ARN=$(aws cloudformation describe-stacks --region "${REGION}"  --stack-name "${STACKNAME}" --query 'Stacks[0].Outputs[?OutputKey==`NodeTerminationHandlerPodsRole`].OutputValue' --output text)
    echo "----------------------------------------------------------------------------------------------------"
    echo "QueueURL is: $IAM_PODS_ARN"

    echo "--------------------------------- Tag Autoscaling Groups -------------------------------------------"
    echo "The following AutoScalingGroups will be tagged:"
    printf '%s\n' "${VALID_ASG[@]}"

    for resourceId in "${VALID_ASG[@]}"; do
        ## Update ASG tags
        aws autoscaling create-or-update-tags --region "${REGION}" --tags ResourceId=${resourceId},ResourceType=auto-scaling-group,Key=aws-node-termination-handler/managed,Value=,PropagateAtLaunch=true
        echo "Tagged $resourceId."
    done


    echo "------------------- Create and associate IAM Role for Pods -------------------------------"

    echo "------------------- Proceed to install Node Termination Handler -----------------------------------"
    echo 

    # sleep 10
    # echo "Purge SQS Queue"
    # aws sqs purge-queue --queue-url ${QueueURL} --region ${REGION}
    # Add eks-charts before running
    helm repo add eks https://aws.github.io/eks-charts

    helm upgrade --install aws-node-termination-handler \
        --namespace "$NAMESPACE" \
        --set enableSqsTerminationDraining=true \
        --set queueURL="$QueueURL" \
        --set serviceAccount.name="$SERVICEACCOUNT" \
        --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="$IAM_PODS_ARN" \
        eks/aws-node-termination-handler --values ./values.yaml


    HELM_STATUS=$?

    if [[ ${HELM_STATUS} -ne 0 ]] ; then
        # Waiter encountered a failure state.
        echo "Helm install failed with status ${HELM_STATUS}."
        exit ${HELM_STATUS}
    fi	

    kubectl describe sa "$SERVICEACCOUNT" -n $NAMESPACE

    echo "Install completed"
    echo "---------------------------------------------------------------------------------------------------"
    echo

fi
