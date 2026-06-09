#!/bin/bash

# =============================================================================
# deploy-fixed.sh - Fixes the S3 Access Denied issue
# =============================================================================
#
# This script removes the Deny statement from the bucket policy and redeploys,
# demonstrating the resolution to the customer's issue.
# =============================================================================

STACK_NAME="innoslate-repro-stack"
APP_NAME="innoslate-repro"
ENV_NAME="InnoslateTest-repro"
REGION="eu-north-1"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  S3 Access Denied FIX - Removing Deny + Redeploying            ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Get bucket name ──────────────────────────────────────────────────
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SourceBucketName`].OutputValue' \
  --output text \
  --region $REGION)

if [ -z "$BUCKET_NAME" ] || [ "$BUCKET_NAME" = "None" ]; then
  echo "ERROR: Stack not found. Run ./deploy-broken.sh first."
  exit 1
fi

echo "[1/4] Found bucket: $BUCKET_NAME"
echo ""

# ── Step 2: Remove the restrictive bucket policy ─────────────────────────────
echo "[2/4] Removing Deny bucket policy..."
aws s3api delete-bucket-policy --bucket $BUCKET_NAME --region $REGION
echo "       ✓ Bucket policy removed (EB service role can now read objects)"
echo ""

# ── Step 3: Re-upload and create a new version ───────────────────────────────
echo "[3/4] Creating new application version..."
zip -r app.zip application.py requirements.txt
aws s3 cp app.zip s3://$BUCKET_NAME/$APP_NAME/app.zip --region $REGION

VERSION_LABEL="v4.14.1.0-fixed-$(date +%Y%m%d-%H%M%S)"
aws elasticbeanstalk create-application-version \
  --application-name $APP_NAME \
  --version-label "$VERSION_LABEL" \
  --source-bundle S3Bucket=$BUCKET_NAME,S3Key=$APP_NAME/app.zip \
  --region $REGION > /dev/null
echo "       ✓ Version: $VERSION_LABEL"
echo ""

# ── Step 4: Deploy (should succeed now) ──────────────────────────────────────
echo "[4/4] Deploying (should succeed this time)..."
aws elasticbeanstalk update-environment \
  --application-name $APP_NAME \
  --environment-name $ENV_NAME \
  --version-label "$VERSION_LABEL" \
  --region $REGION

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Fix deployed! Monitor with:                                    ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
echo "  aws elasticbeanstalk describe-events \\"
echo "    --environment-name $ENV_NAME \\"
echo "    --region $REGION --max-records 10"
echo ""
echo "Expected: Environment update completed successfully."
echo ""
echo "Root cause summary:"
echo "  The bucket policy had an explicit Deny on s3:GetObject for the"
echo "  EB service role. Even though the managed policies (Enhanced Health,"
echo "  ManagedUpdates) include some S3 permissions, an explicit Deny"
echo "  always overrides Allow in IAM policy evaluation."
echo ""
echo "  Customer confusion points:"
echo "  - s3:HeadBucket is NOT a valid IAM action (maps to s3:ListBucket)"
echo "  - No 403 in S3 access logs because denial happens at IAM layer"
echo "  - App version IS created successfully (just can't be read by EB)"
echo "  - CloudTrail may not show the deny if the caller is the EB service"
