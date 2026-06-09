#!/bin/bash

# =============================================================================
# simulate-github-actions.sh
# =============================================================================
# Simulates the GitHub Actions deploy.yml workflow locally.
# Mimics exactly what the customer's CD pipeline does:
#   1. Assume the Github_worker role
#   2. Package the app
#   3. Upload to S3
#   4. Create application version
#   5. Update environment (triggers S3 Access Denied)
#   6. Poll for completion and show the failure
#
# This is the equivalent of the GitHub Actions workflow running.
# =============================================================================

set -euo pipefail

STACK_NAME="innoslate-repro-stack"
APP_NAME="innoslate-repro"
ENV_NAME="InnoslateTest-repro"
REGION="eu-north-1"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Simulating GitHub Actions Deploy Workflow                      ║"
echo "║  (Replicating: .github/workflows/deploy.yml)                   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Step: Configure AWS credentials (simulates OIDC) ─────────────────────────
echo "┌─ Step: Configure AWS credentials ──────────────────────────────┐"
echo "│  In GitHub Actions, this uses OIDC to assume the role.         │"
echo "│  Locally, we assume the role directly via STS.                 │"
echo "└────────────────────────────────────────────────────────────────┘"
echo ""

DEPLOYER_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`DeployerRoleArn`].OutputValue' \
  --output text \
  --region $REGION)

echo "Assuming role: $DEPLOYER_ROLE_ARN"

CREDS=$(aws sts assume-role \
  --role-arn "$DEPLOYER_ROLE_ARN" \
  --role-session-name "github-actions-simulation" \
  --region $REGION \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SessionToken'])")

echo "✓ Assumed role successfully"
echo "  Identity: $(aws sts get-caller-identity --query 'Arn' --output text)"
echo ""

# ── Step: Verify AWS identity ─────────────────────────────────────────────────
echo "┌─ Step: Verify AWS identity ────────────────────────────────────┐"
aws sts get-caller-identity --output table
echo "└────────────────────────────────────────────────────────────────┘"
echo ""

# ── Step: Package application ─────────────────────────────────────────────────
echo "┌─ Step: Package application ────────────────────────────────────┐"
zip -r app.zip application.py requirements.txt
echo "  Artifact: app.zip ($(du -h app.zip | cut -f1))"
echo "  SHA256: $(shasum -a 256 app.zip | cut -d' ' -f1)"
echo "└────────────────────────────────────────────────────────────────┘"
echo ""

# ── Step: Upload to S3 ───────────────────────────────────────────────────────
echo "┌─ Step: Upload to S3 ───────────────────────────────────────────┐"

BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SourceBucketName`].OutputValue' \
  --output text \
  --region $REGION 2>/dev/null || true)

# If we can't read the stack with the assumed role, use the known bucket
if [ -z "$BUCKET_NAME" ] || [ "$BUCKET_NAME" = "None" ]; then
  # Unset temp creds to read stack, then re-assume
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  BUCKET_NAME=$(aws cloudformation describe-stacks \
    --stack-name $STACK_NAME \
    --query 'Stacks[0].Outputs[?OutputKey==`SourceBucketName`].OutputValue' \
    --output text \
    --region $REGION)
  # Re-assume role
  CREDS=$(aws sts assume-role \
    --role-arn "$DEPLOYER_ROLE_ARN" \
    --role-session-name "github-actions-simulation" \
    --region $REGION \
    --output json)
  export AWS_ACCESS_KEY_ID=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
  export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
  export AWS_SESSION_TOKEN=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SessionToken'])")
fi

echo "  Uploading to: s3://$BUCKET_NAME/$APP_NAME/app.zip"
aws s3 cp app.zip s3://$BUCKET_NAME/$APP_NAME/app.zip --region $REGION
echo "  ✓ Upload successful"
echo ""
echo "  Verifying upload..."
aws s3 ls s3://$BUCKET_NAME/$APP_NAME/app.zip --region $REGION
echo "└────────────────────────────────────────────────────────────────┘"
echo ""

# ── Step: Create application version ─────────────────────────────────────────
VERSION_LABEL="v4.14.1.0-$(git rev-parse --short HEAD 2>/dev/null || echo 'f166bb1')-$(date +%Y%m%d-%H%M%S)"
echo "┌─ Step: Create application version ─────────────────────────────┐"
echo "  Version: $VERSION_LABEL"
aws elasticbeanstalk create-application-version \
  --application-name $APP_NAME \
  --version-label "$VERSION_LABEL" \
  --source-bundle S3Bucket=$BUCKET_NAME,S3Key=$APP_NAME/app.zip \
  --region $REGION > /dev/null
echo "  ✓ Version created"
echo "└────────────────────────────────────────────────────────────────┘"
echo ""

# ── Step: Deploy to environment ──────────────────────────────────────────────
echo "┌─ Step: Deploy to environment ──────────────────────────────────┐"
echo "  Updating: $ENV_NAME → $VERSION_LABEL"
aws elasticbeanstalk update-environment \
  --application-name $APP_NAME \
  --environment-name $ENV_NAME \
  --version-label "$VERSION_LABEL" \
  --region $REGION > /dev/null
echo "  ✓ Deployment triggered"
echo "└────────────────────────────────────────────────────────────────┘"
echo ""

# ── Step: Wait for deployment ─────────────────────────────────────────────────
echo "┌─ Step: Wait for deployment (polling every 15s, max 5min) ──────┐"
MAX_WAIT=300
ELAPSED=0

# Unset assumed role creds to poll with main creds
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

while [ $ELAPSED -lt $MAX_WAIT ]; do
  STATUS=$(aws elasticbeanstalk describe-environments \
    --environment-names $ENV_NAME \
    --region $REGION \
    --query 'Environments[0].Status' \
    --output text)

  HEALTH=$(aws elasticbeanstalk describe-environments \
    --environment-names $ENV_NAME \
    --region $REGION \
    --query 'Environments[0].Health' \
    --output text)

  CURRENT_VER=$(aws elasticbeanstalk describe-environments \
    --environment-names $ENV_NAME \
    --region $REGION \
    --query 'Environments[0].VersionLabel' \
    --output text)

  echo "  [$(date +%H:%M:%S)] Status=$STATUS Health=$HEALTH Version=$CURRENT_VER (${ELAPSED}s)"

  if [ "$STATUS" = "Ready" ]; then
    break
  fi

  sleep 15
  ELAPSED=$((ELAPSED + 15))
done
echo "└────────────────────────────────────────────────────────────────┘"
echo ""

# ── Step: Verify deployment ──────────────────────────────────────────────────
echo "┌─ Step: Verify deployment ──────────────────────────────────────┐"
FINAL_VERSION=$(aws elasticbeanstalk describe-environments \
  --environment-names $ENV_NAME \
  --region $REGION \
  --query 'Environments[0].VersionLabel' \
  --output text)

echo "  Expected: $VERSION_LABEL"
echo "  Actual:   $FINAL_VERSION"
echo ""

if [ "$FINAL_VERSION" != "$VERSION_LABEL" ]; then
  echo "  ❌ DEPLOYMENT FAILED"
  echo ""
  echo "  Error events:"
  aws elasticbeanstalk describe-events \
    --environment-name $ENV_NAME \
    --region $REGION \
    --max-records 10 \
    --query 'Events[?Severity==`ERROR`].{Time:EventDate,Message:Message}' \
    --output table
  echo ""
  echo "  ┌─────────────────────────────────────────────────────────────┐"
  echo "  │ This replicates the customer error:                          │"
  echo "  │                                                              │"
  echo "  │ Service:AmazonCloudFormation, Message:S3 error: Access Denied│"
  echo "  │                                                              │"
  echo "  │ The app version v4.14.1.0-f166bb1-... was created but failed │"
  echo "  │ to deploy. No 403 in S3 logs. No CloudTrail denied events.   │"
  echo "  └─────────────────────────────────────────────────────────────┘"
  echo ""
  echo "  Run ./diagnose.sh to investigate"
  echo "  Run ./deploy-fixed.sh to resolve"
else
  echo "  ✓ Deployment successful (this means the fix was applied)"
fi
echo "└────────────────────────────────────────────────────────────────┘"
