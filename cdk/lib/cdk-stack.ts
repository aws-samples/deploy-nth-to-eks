import { Stack, StackProps } from 'aws-cdk-lib';
import { Construct } from 'constructs';
import { Artifact, Pipeline } from 'aws-cdk-lib/aws-codepipeline';
import path = require("path");
import { Repository, Code } from 'aws-cdk-lib/aws-codecommit';
import { CodeBuildAction, CodeCommitSourceAction } from 'aws-cdk-lib/aws-codepipeline-actions';
import { BuildSpec, LinuxBuildImage, PipelineProject } from 'aws-cdk-lib/aws-codebuild';
import {Role, ServicePrincipal, PolicyStatement, Policy} from 'aws-cdk-lib/aws-iam';
import YAML = require('yaml');
import { readFileSync } from 'fs';
import { env } from 'process';
import { AutoScalingGroup } from 'aws-cdk-lib/aws-autoscaling';


export interface CdkStackProps extends StackProps {
  pipelineName: string;
  repositoryName: string;
  branch: string;
  cfn_scan_script: string;
  cfn_deploy_script: string;
  eksClusterName: string;
  eksClusterRole: string;
  AsgGroupName:string;
  region: string;
}

export class CdkStack extends Stack {
  private readonly props: CdkStackProps
  constructor(scope: Construct, id: string, props: CdkStackProps) {
    super(scope, id, props);
    this.props = props
    const { pipelineName, repositoryName, branch, cfn_scan_script, cfn_deploy_script } = props;
    const repository = this.createCodeCommit(repositoryName);
    this.createPipeline(pipelineName, repository, branch, cfn_scan_script, cfn_deploy_script)

  }

  private createCodeCommit(repositoryName: string) {
    return new Repository(this, "codeCommit", {
      repositoryName,
      code: Code.fromDirectory(path.join(__dirname, "../../nth"), "master")
    })
  }


  private createScanBuildServiceRole(){
    const {eksClusterName}=this.props
    const role= new Role(this,"scanRole",{
      assumedBy:new ServicePrincipal("codebuild.amazonaws.com"),

    })
    role.addToPolicy(new PolicyStatement({
      resources: ['*'],
      actions: ["iam:ListOpenIDConnectProviders","autoscaling:DescribeAutoScalingGroups"],
    }));
    role.addToPolicy(new PolicyStatement({
      resources: [`arn:aws:eks:${this.region}:${this.account}:cluster/${eksClusterName}`],
      actions: ["eks:DescribeCluster"],
    }));
    role.addToPolicy(new PolicyStatement({
      resources: [`arn:aws:eks:${this.region}:${this.account}:cluster/*`],
      actions: ["eks:ListClusters"],
    }));
    return role;
  }
  private createDeployBuildServiceRole(){
    const {eksClusterName,AsgGroupName,eksClusterRole}=this.props

    const role= new Role(this,"deployRole",{
      assumedBy:new ServicePrincipal("codebuild.amazonaws.com"),

    })
    role.addToPolicy(new PolicyStatement({
      resources: ['*'],
      actions: ["iam:ListOpenIDConnectProviders","autoscaling:DescribeAutoScalingGroups"],
    }));
    role.addToPolicy(new PolicyStatement({
      resources: [`arn:aws:eks:${this.region}:${this.account}:cluster/${eksClusterName}`],
      actions: ["eks:DescribeCluster"],
    }));
    role.addToPolicy(new PolicyStatement({
      resources: [`arn:aws:eks:${this.region}:${this.account}:cluster/*`],
      actions: ["eks:ListClusters"],
    }));
    let asgList=AsgGroupName.split(',')
    let asgArns=asgList.map((asg=>{
      return AutoScalingGroup.fromAutoScalingGroupName(this,asg,asg).autoScalingGroupArn
    }))
    const policy=new Policy(this,"deployRolePolicy",{
      statements:[ new PolicyStatement(
        {
          resources:asgArns,
          actions:["autoscaling:PutLifecycleHook",
          "autoscaling:DeleteLifecycleHook",
          "autoscaling:DescribeLifecycleHooks",
          "autoscaling:CreateOrUpdateTags"]
        },
      ),new PolicyStatement({ 
        resources:[`arn:aws:cloudformation:${this.region}:${this.account}:stack/*/*`],
        actions:[  "cloudformation:CreateStack",
        "cloudformation:DeleteStack",
        "cloudformation:DescribeChangeSetHooks",
        "cloudformation:UpdateStack",
        "cloudformation:CreateChangeSet",
        "cloudformation:DescribeChangeSet",
        "cloudformation:ExecuteChangeSet",
        "cloudformation:DeleteChangeSet",
        "cloudformation:ListChangeSets",
        "cloudformation:DescribeStacks",
        "cloudformation:GetTemplateSummary"]
      }),new PolicyStatement({ 
        resources:[`arn:aws:iam::${this.account}:role/*${eksClusterName}*`,`arn:aws:iam::${this.account}:role/${eksClusterRole}`],
        actions:["iam:GetRole",
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:PassRole",
        "sts:AssumeRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:PutRolePolicy",
        "iam:getRolePolicy"]
      }),new PolicyStatement({ 
        resources:["*"],
        actions:["sqs:ListQueues", "autoscaling:DescribeLifecycleHooks"]
      }),new PolicyStatement({ 
        resources:[`arn:aws:sqs:${this.region}:${this.account}:*${eksClusterName}*`],
        actions:["sqs:*"]
      })

      ]
    })
    policy.attachToRole(role)
    return role;

  }

  private createPipeline(pipelineName: string, repository: Repository, branch: string, cfn_scan_script: string, cfn_deploy_script: string) {
    const sourceArtifact = new Artifact("Source");
    const scanArtifact = new Artifact("Scan");
    return new Pipeline(this, "pipeline", {
      pipelineName,
      stages: [{
        stageName: "Source",
        actions: [new CodeCommitSourceAction({
          actionName: "Source",
          repository,
          branch,
          output: sourceArtifact
        }
        )]

      }, {
        stageName: "Cfn-Scan",
        actions: [new CodeBuildAction({
          actionName: "Cfn-Scan",
          input: sourceArtifact,
          outputs: [scanArtifact],
          project: this.createCodeBuild("cfn-Scan", cfn_scan_script, "buildSpec-scan.yaml",this.createScanBuildServiceRole())

        }
        )]

      },
      {
        stageName: "Nth-Deploy",
        actions: [new CodeBuildAction(
          {
            actionName: "Nth-Deploy",
            input: sourceArtifact,
            project: this.createCodeBuild("Nth-Deploy", cfn_deploy_script, "buildSpec-application.yaml",this.createDeployBuildServiceRole())

          }
        )]
      }


      ]


    })
  }

  private createCodeBuild(projectName: string, executablePath: string, buildSpecPath: string, role:Role) {

    const { eksClusterName, eksClusterRole, region,AsgGroupName } = this.props;
    const buildspecContent = YAML.parse(readFileSync(`${__dirname}/buildSpec/${buildSpecPath}`, "utf8"));
    const project = new PipelineProject(this, projectName, {
      projectName,
      environment: { buildImage: LinuxBuildImage.STANDARD_5_0 },
      buildSpec: BuildSpec.fromObjectToYaml(buildspecContent),
      role,
      environmentVariables: {
        EXECUTABLENAME: { value: executablePath },
        EKS_CLUSTERNAME: { value: eksClusterName },
        EKS_CLUSTERROLE_ARN: { value: `arn:aws:iam::${this.account}:role/${eksClusterRole}` },
        ASG_GROUPS: { value: AsgGroupName },
        REGION: { value: region }
      }

    })
    return project
  }


}
