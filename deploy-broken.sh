#!/bin/bash

# =============================================================================
# deploy-broken.sh - Replicates the customer S3 Access Denied issue
# =============================================================================
#
# This script simulates the customer's CD pipeline (Github Actions) deploying
# to Elastic Beanstalk. The deployment will:
#   1. Successfully upload the artifact to S3 ✓
#   2. Successfully create an application version ✓  
#   3. FAIL when EB/CloudFormation tries to read the artifact during deploy ✗
#
# The error will be:
#   "Service:AmazonCloudFormation, Message:S3 error: Access Denied"
#
# Root cause: The EB service role has an explicit Deny on s3:GetObject via
# the bucket policy, mimicking misconfigured cross-service permissions.
# =============================================================================

set -e

STACK_NAME="innoslate-repro-stack"
APP_NAME="innoslate-repro"
ENV_NAME="InnoslateTest-repro"
REGION="eu-north-1"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  S3 Access Denied Repro - Deploying Broken Environment         ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Deploy infrastructure ────────────────────────────────────────────
echo "[1/5] Deploying CloudFormation stack (infra + broken IAM)..."
aws cloudformation deploy \
  --template-file template-broken.yaml \
  --stack-name $STACK_NAME \
  --parameter-overrides ApplicationName=$APP_NAME EnvironmentName=$ENV_NAME \
  --capabilities CAPABILITY_NAMED_IAM \
  --region $REGION

echo "       ✓ Stack deployed"
echo ""

# ── Step 2: Get outputs ──────────────────────────────────────────────────────
echo "[2/5] Retrieving stack outputs..."
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SourceBucketName`].OutputValue' \
  --output text \
  --region $REGION)

DEPLOYER_ROLE=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`DeployerRoleArn`].OutputValue' \
  --output text \
  --region $REGION)

SERVICE_ROLE=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`ServiceRoleArn`].OutputValue' \
  --output text \
  --region $REGION)

echo "       Bucket:       $BUCKET_NAME"
echo "       Deployer Role: $DEPLOYER_ROLE"
echo "       Service Role:  $SERVICE_ROLE"
echo ""

# ── Step 3: Package and upload (this succeeds - mimics Github Actions upload)
echo "[3/5] Packaging and uploading artifact to S3..."
zip -r app.zip application.py requirements.txt
aws s3 cp app.zip s3://$BUCKET_NAME/$APP_NAME/app.zip --region $REGION
echo "       ✓ Artifact uploaded to s3://$BUCKET_NAME/$APP_NAME/app.zip"
echo ""

# ── Step 4: Create application version (this also succeeds) ──────────────────
VERSION_LABEL="v4.14.1.0-$(git rev-parse --short HEAD 2>/dev/null || echo 'f166bb1')-$(date +%Y%m%d-%H%M%S)"
echo "[4/5] Creating application version: $VERSION_LABEL"
aws elasticbeanstalk create-application-version \
  --application-name $APP_NAME \
  --version-label "$VERSION_LABEL" \
  --source-bundle S3Bucket=$BUCKET_NAME,S3Key=$APP_NAME/app.zip \
  --region $REGION > /dev/null

echo "       ✓ Version created (visible in EB console)"
echo ""

# ── Step 5: Trigger deployment (THIS WILL FAIL with S3 Access Denied) ────────
echo "[5/5] Updating environment (this will trigger the S3 Access Denied error)..."
echo ""
echo "       ⚠ Expecting failure: Service:AmazonCloudFormation, Message:S3 error: Access Denied"
echo ""
aws elasticbeanstalk update-environment \
  --application-name $APP_NAME \
  --environment-name $ENV_NAME \
  --version-label "$VERSION_LABEL" \
  --region $REGION

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Deployment triggered. Monitor for the Access Denied error:     ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "Watch environment events:"
echo "  aws elasticbeanstalk describe-events \\"
echo "    --environment-name $ENV_NAME \\"
echo "    --region $REGION \\"
echo "    --max-records 20"
echo ""
echo "Expected error in events:"
echo "  ERROR: Service:AmazonCloudFormation, Message:S3 error: Access Denied"
echo "  ERROR: Failed to deploy application."
echo ""
echo "Why this happens:"
echo "  1. Github_worker role CAN upload to S3 (so artifact is there)"
echo "  2. Application version is created successfully"  
echo "  3. But the EB Service Role has an explicit DENY on s3:GetObject"
echo "  4. When CloudFormation/EB tries to download the bundle → Access Denied"
echo "  5. No 403 in S3 access logs because the deny is at IAM/bucket-policy level"
echo ""
echo "To fix: Remove the Deny statement from the bucket policy, or"
echo "        give the EB service role explicit s3:GetObject on the bucket."
echo "        Run: ./deploy-fixed.sh"
