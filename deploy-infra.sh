#!/bin/bash

# Deploy shared infrastructure (application, S3 bucket, IAM roles, both environments)

STACK_NAME="sample-eb-stack"
APP_NAME="sample-eb-app"
REGION="eu-north-1"

echo "Deploying CloudFormation stack..."
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name $STACK_NAME \
  --parameter-overrides ApplicationName=$APP_NAME \
  --capabilities CAPABILITY_IAM \
  --region $REGION

if [ $? -ne 0 ]; then
  echo "CloudFormation deployment failed!"
  exit 1
fi

echo "Infrastructure deployed successfully."
echo ""
echo "Next steps:"
echo "  ./deploy-basic.sh     - Deploy app to basic monitoring environment"
echo "  ./deploy-enhanced.sh  - Deploy app to enhanced monitoring environment"
