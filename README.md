# Deploy NTH to EKS

Automate Deployment of Node Termination Handler in Self Managed Worker Node in EKS Cluster using CICD Pipeline

# Summary 

AWS Node Termination Handler ensures that the Kubernetes control plane responds appropriately to events that can cause your EC2 instance to become unavailable, such as EC2 maintenance events, EC2 Spot interruptions, ASG Scale-In, ASG AZ Rebalance, and EC2 Instance Termination via the API or Console. If not handled, your application code may not stop gracefully, take longer to recover full availability, or accidentally schedule work to nodes that are going down.The aws-node-termination-handler (NTH) can operate in two different modes: Instance Metadata Service (IMDS) or the Queue Processor.

The aws-node-termination-handler Instance Metadata Service Monitor will run a small pod on each host to perform monitoring of IMDS paths like /spot or /events and react accordingly to drain and/or cordon the corresponding node.
The aws-node-termination-handler Queue Processor will monitor an SQS queue of events from Amazon EventBridge for ASG lifecycle events, EC2 status change events, Spot Interruption Termination Notice events, and Spot Rebalance Recommendation events. When NTH detects an instance is going down, we use the Kubernetes API to cordon the node to ensure no new work is scheduled there, then drain it, removing any existing work. The termination handler Queue Processor requires AWS IAM permissions to monitor and manage the SQS queue and to query the EC2 API. 
This pattern will automate the deployment of Node Termination Handler using Queue Processor through CICD Pipeline


# Prerequisites 
- An active AWS account
- A web browser that is supported for use with the AWS Management Console. (See the list of supported browsers)
- npm with latest version
- cdk version >= 2.27.0
- kubectl - Kubernetes command line tool. Refer to this doc on how to install.   
- eksctl - CLI for Amazon EKS. Refer to this doc on how to install.
- Running EKS Cluster with version 1.20 or above
- Self managed NodeGroup attached to the EKS Cluster
- IAM OIDC Provider for your cluster. Reference document

# Limitations 
- AWS region must support the AWS EKS service


# Product versions
- Kubernetes v1.20 or higher


# Target technology stack  
- VPC
- EKS Cluster
- SQS
- IAM 
- Kubernetes

# High Level Workflow
The workflow illustrated in the diagram consists of these high-level steps:

- Autoscale EC2 terminate event is sent to SQS Queue
- NTH Pod will monitor for new messages in SQS Queue
- NTH Pod will receive the new message and do the following
  - Cordon the Node so that new POD does not run on the Node
  - Drain the Node, so that existing POD gets evacuated
  - Send LifeCycle Hook signal to ASG so that Node can be terminated


## Code 

**nth** folder - Contains helm chart, values files, scripts to scan and deploy AWS CloudFormation template for node terminator handler

**config/config.json**  - Configuration parameter file for the application . This file contains all the parameter needed for CDK deploy.

**cdk** - CDK source code

**setup.sh** -  Script, used to deploy CDK application to create the required CI/CD Pipeline and other required resources. 

**uninstall.sh** - Script, used to clean up the resources.

## Setup your environment
To pull down the repo via ssh, run 
``` 
git clone git@github.com:aws-samples/deploy-nth-to-eks.git
```
or via HTTPS
```
git clone https://github.com/aws-samples/deploy-nth-to-eks.git
```
This creates a folder named deploy-nth-to-eks. Navigate to the folder
```
cd deploy-nth-to-eks 
```
## Setup Parameters

Setup the following required parameter in config/config.json file.

- **pipelineName** : The name of the CI/CD Pipeline to be created by CDK application. For example, "deploy-nth-to-eks-pipeline" .This implementation will create the AWS CodePipeline with this name.

- **repositoryName**: The AWS CodeCommit Repo to be created. CDK application will create this repo with the content of **nth** folder and will set as source for the CICD Pipeline. For example, "deploy-nth-to-eks-repo". **Note** This solution will create this AWS CodeCommit Repo and the branch( provided in **branch** parameter below). This does not have to exist in advance. 

- **branch**: The branch name of the above Repository. Commit to this branch will trigger the CICD Pipeline. For example, "main"

- **cfn_scan_script**: The path of the script that will be used to scan the AWS CloudFormation Template for NTH. For example, scan.sh. This script exists in **nth** folder that will be part of AWS CodeCommit Repo

- **cfn_deploy_script**: The path of the script that will be used to deploy the AWS CloudFormation Template for NTH. For example, installApp.sh. This script exists in **nth** folder that will be part of AWS CodeCommit Repo

- **stackName**: The Cloud Formation Stack Name to be deployed. This solution will deploy a AWS CloudFormation Stack with this name.

- **eksClusterName**: Existing EKS Cluster Name. This needs to exists.

- **eksClusterRole**: IAM Role that will be used to access EKS Cluster for all k8s API call. Usually, this role is added in aws-auth configmap . For example, clusteradmin

- **create_cluster_role**: Select yes, if you want to create the above cluster role.  Select "no" if you provide an existing cluster role in eksClusterRole parameter.

- **create_iam_oidc_provider**: Select "yes" to create IAM OIDC provider for your cluster. If IAM OIDC provider already exists, select no. For more information, refer this [link](https://docs.aws.amazon.com/eks/latest/userguide/enable-iam-roles-for-service-accounts.html)

- **AsgGroupName**: Comma separated list of Auto Scaling Group (ASG) Name that are part of the EKSCluster. For example, "ASG_Group_1,ASG_Group_2". These ASG groups must exists.

- **region**: AWS region Name where the cluster is running. For example, "us-east-2"

- **install_cdk**: Selct "yes" if cdk is not currenty installed in the machine. Check with ```cdk --version``` command if the installed CDK version is >= 2.27.0. In that case, select "no" . If selected "yes" , setup.sh script will execute ```sudo npm install -g cdk@2.27.0``` command to install CDK in the machine. It needs sudo permission, hence provide the password to proceed when asked.


## Set kubeconfig

Set your AWS credentials in your terminal and ensure you have rights to assume the cluster role. 

Example:

```
aws eks update-kubeconfig --name <Cluster_Name> --region <region> --role-arn <Role_ARN>
```

## Deploy CICD Pipeline
Execute the following script to deploy the CICD Pipeline
```
./setup.sh
```
The script will deploy the CDK application that will create AWS code commit repository with sample code and AWS Code Pipeline and few other resources based on the user input parameter in config/config.json file
This script will ask for the password as it installs npm packages with sudo command. 

## Review the CICD Pipeline
Navigate to  AWS Console and review the following resources created by the Stack

- AWS CodeCommit Repo with the content of "nth" folder

- AWS CodeBuild Project cfn-Scan that will be used to scan the AWS CloudFormation Template before deploying NTH through the pipeline

- AWS CodeBuild Project Nth-Deploy that will be used to deploy the AWS CloudFormation Template to NTH through the pipeline

- AWS CodePipeline to deploy NTH 

On successful Pipeline Execution, helm release **aws-node-termination-handler** will be installed in the EKS cluster. Also a POD ( named aws-node-termination-handler* ) will be running in kube-system namespace in the cluster. Refer to the target architector to know more about this NTH POD and its function.

## Test 

To simulate Auto Scaling Scale in event - 

1. Navigate to EC2 Console --> Auto Scaling Groups.
2. Select and Edit ASG Name ( the one provided in the config/config.json file) 
3. Decrease Desired and Minimum Capacity by 1.
4. Update the Settings

With the above scale in event, the NTH POD will cordon and drain the corresponding worker node ( EC2 instance that will be terminated as part of the scale in event) . To check the logs -

1. Find the NTH POD Name, for example

```
kubectl get pods -n kube-system |grep aws-node-termination-handler
aws-node-termination-handler-65445555-kbqc7   1/1     Running   0          26m
kubectl get pods -n kube-system |grep aws-node-termination-handler
aws-node-termination-handler-65445555-kbqc7   1/1     Running   0          26m
```

Check logs (A sample log looks like below. It shows the Node has been cordoned and drained before sending the ASG Lifecycle hook completion signal)

```
kubectl -n kube-system logs aws-node-termination-handler-65445555-kbqc7
022/07/17 20:20:43 INF Adding new event to the event store event={"AutoScalingGroupName":"eksctl-my-cluster-target-nodegroup-ng-10d99c89-NodeGroup-ZME36IGAP7O1","Description":"ASG Lifecycle Termination event received. Instance will be interrupted at 2022-07-17 20:20:42.702 +0000 UTC \n","EndTime":"0001-01-01T00:00:00Z","EventID":"asg-lifecycle-term-33383831316538382d353564362d343332362d613931352d383430666165636334333564","InProgress":false,"InstanceID":"i-0409f2a9d3085b80e","IsManaged":true,"Kind":"SQS_TERMINATE","NodeLabels":null,"NodeName":"ip-192-168-75-60.us-east-2.compute.internal","NodeProcessed":false,"Pods":null,"ProviderID":"aws:///us-east-2c/i-0409f2a9d3085b80e","StartTime":"2022-07-17T20:20:42.702Z","State":""}
2022/07/17 20:20:44 INF Requesting instance drain event-id=asg-lifecycle-term-33383831316538382d353564362d343332362d613931352d383430666165636334333564 instance-id=i-0409f2a9d3085b80e kind=SQS_TERMINATE node-name=ip-192-168-75-60.us-east-2.compute.internal provider-id=aws:///us-east-2c/i-0409f2a9d3085b80e
2022/07/17 20:20:44 INF Pods on node node_name=ip-192-168-75-60.us-east-2.compute.internal pod_names=["aws-node-qchsw","aws-node-termination-handler-65445555-kbqc7","kube-proxy-mz5x5"]
2022/07/17 20:20:44 INF Draining the node
2022/07/17 20:20:44 ??? WARNING: ignoring DaemonSet-managed Pods: kube-system/aws-node-qchsw, kube-system/kube-proxy-mz5x5
2022/07/17 20:20:44 INF Node successfully cordoned and drained node_name=ip-192-168-75-60.us-east-2.compute.internal reason="ASG Lifecycle Termination event received. Instance will be interrupted at 2022-07-17 20:20:42.702 +0000 UTC \n"
2022/07/17 20:20:44 INF Completed ASG Lifecycle Hook (NTH-K8S-TERM-HOOK) for instance i-0409f2a9d3085b80e
```

## Cleanup

To clean up the resources created by this pattern, execute the following command

```
./uninstall.sh
```
This will clean up all the resources created in this pattern by deleting AWS CloudFormation stack.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This library is licensed under the MIT-0 License. See the LICENSE file.