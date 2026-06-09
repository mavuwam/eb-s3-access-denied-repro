#!/bin/bash

# Deploy application to the ENHANCED monitoring environment

STACK_NAME="sample-eb-stack"
APP_NAME="sample-eb-app"
ENV_NAME="sample-eb-enhanced"
REGION="eu-north-1"

echo "=== Deploying to ENHANCED environment ==="

echo "Packaging application..."
zip -r app.zip application.py requirements.txt

BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SourceBucketName`].OutputValue' \
  --output text \
  --region $REGION)

if [ -z "$BUCKET_NAME" ] || [ "$BUCKET_NAME" = "None" ]; then
  echo "Could not find S3 bucket. Run ./deploy-infra.sh first."
  exit 1
fi

echo "Uploading to S3..."
aws s3 cp app.zip s3://$BUCKET_NAME/$APP_NAME/app-enhanced.zip --region $REGION

VERSION_LABEL="enhanced-$(date +%s)"
echo "Creating application version: $VERSION_LABEL"
aws elasticbeanstalk create-application-version \
  --application-name $APP_NAME \
  --version-label $VERSION_LABEL \
  --source-bundle S3Bucket=$BUCKET_NAME,S3Key=$APP_NAME/app-enhanced.zip \
  --region $REGION

echo "Updating enhanced environment..."
aws elasticbeanstalk update-environment \
  --application-name $APP_NAME \
  --environment-name $ENV_NAME \
  --version-label $VERSION_LABEL \
  --region $REGION

APP_URL=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`EnhancedEnvironmentURL`].OutputValue' \
  --output text \
  --region $REGION)

echo ""
echo "========================================="
echo "Enhanced environment deployment started!"
echo "URL: http://$APP_URL"
echo "========================================="
echo "Check status: aws elasticbeanstalk describe-environments --environment-names $ENV_NAME --region $REGION"
