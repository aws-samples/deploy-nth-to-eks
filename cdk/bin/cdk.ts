#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { CdkStack } from '../lib/cdk-stack';
import { resolve } from 'path';
import { readFileSync } from 'fs';


const app = new cdk.App();
const sourcePath =app.node.tryGetContext("source")
const configLoc = resolve(__dirname, sourcePath);
const config = JSON.parse(readFileSync(configLoc, 'utf-8'));

new CdkStack(app, config.stackName, {
  pipelineName:config.pipelineName,
  repositoryName:config.repositoryName,
  branch: config.branch,
  cfn_scan_script:config.cfn_scan_script,
  cfn_deploy_script:config.cfn_deploy_script,
  eksClusterName:config.eksClusterName,
  eksClusterRole: config.eksClusterRole,
  region:config.region,
  AsgGroupName:config.AsgGroupName
  /* If you don't specify 'env', this stack will be environment-agnostic.
   * Account/Region-dependent features and context lookups will not work,
   * but a single synthesized template can be deployed anywhere. */

  /* Uncomment the next line to specialize this stack for the AWS Account
   * and Region that are implied by the current CLI configuration. */
  // env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },

  /* Uncomment the next line if you know exactly what Account and Region you
   * want to deploy the stack to. */
  //env: {  region: config.region },

  /* For more information, see https://docs.aws.amazon.com/cdk/latest/guide/environments.html */
});