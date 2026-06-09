#!/bin/bash

# =============================================================================
# diagnose.sh - Diagnostic script for the S3 Access Denied issue
# =============================================================================
# Run this after deploy-broken.sh to investigate the failure,
# similar to what the customer would do when troubleshooting.
# =============================================================================

STACK_NAME="innoslate-repro-stack"
APP_NAME="innoslate-repro"
ENV_NAME="InnoslateTest-repro"
REGION="eu-north-1"

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Diagnosis: S3 Access Denied during EB Deployment               ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

# ── Check environment health and events ──────────────────────────────────────
echo "═══ 1. Environment Events (last 20) ═══"
echo ""
aws elasticbeanstalk describe-events \
  --environment-name $ENV_NAME \
  --region $REGION \
  --max-records 20 \
  --query 'Events[].{Time:EventDate,Severity:Severity,Message:Message}' \
  --output table
echo ""

# ── Check environment status ─────────────────────────────────────────────────
echo "═══ 2. Environment Status ═══"
echo ""
aws elasticbeanstalk describe-environments \
  --environment-names $ENV_NAME \
  --region $REGION \
  --query 'Environments[0].{Status:Status,Health:Health,HealthStatus:HealthStatus,VersionLabel:VersionLabel}' \
  --output table
echo ""

# ── Check application versions ───────────────────────────────────────────────
echo "═══ 3. Application Versions (showing versions exist but fail to deploy) ═══"
echo ""
aws elasticbeanstalk describe-application-versions \
  --application-name $APP_NAME \
  --region $REGION \
  --query 'ApplicationVersions[*].{Version:VersionLabel,Status:Status,Created:DateCreated}' \
  --output table
echo ""

# ── Check the S3 object exists ───────────────────────────────────────────────
echo "═══ 4. S3 Artifact Check (proving the file IS there) ═══"
echo ""
BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name $STACK_NAME \
  --query 'Stacks[0].Outputs[?OutputKey==`SourceBucketName`].OutputValue' \
  --output text \
  --region $REGION)

echo "Bucket: $BUCKET_NAME"
aws s3 ls s3://$BUCKET_NAME/$APP_NAME/ --region $REGION
echo ""

# ── Check bucket policy ──────────────────────────────────────────────────────
echo "═══ 5. Bucket Policy (look for Deny statements) ═══"
echo ""
aws s3api get-bucket-policy --bucket $BUCKET_NAME --region $REGION --output text 2>&1 | python3 -m json.tool 2>/dev/null || echo "No bucket policy or error retrieving it"
echo ""

# ── Check EB service role permissions ────────────────────────────────────────
echo "═══ 6. EB Service Role Policies ═══"
echo ""
SERVICE_ROLE_NAME="${APP_NAME}-eb-service-broken"
echo "Role: $SERVICE_ROLE_NAME"
echo ""
echo "Attached policies:"
aws iam list-attached-role-policies --role-name $SERVICE_ROLE_NAME --output table 2>/dev/null || echo "Could not list policies"
echo ""
echo "Inline policies:"
aws iam list-role-policies --role-name $SERVICE_ROLE_NAME --output table 2>/dev/null || echo "No inline policies"
echo ""

# ── Check CloudTrail for denied events ───────────────────────────────────────
echo "═══ 7. CloudTrail - S3 Access Denied (last 24h) ═══"
echo ""
echo "Searching for denied S3 events..."
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=GetObject \
  --start-time $(date -u -v-1d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '1 day ago' '+%Y-%m-%dT%H:%M:%SZ') \
  --region $REGION \
  --query 'Events[?contains(CloudTrailEvent, `AccessDenied`)].{Time:EventTime,Event:EventName}' \
  --output table 2>/dev/null || echo "(No denied events found in CloudTrail - this is expected)"
echo ""
echo "NOTE: CloudTrail often does NOT log S3 denials from service roles."
echo "      This is why the customer saw no 403s or CloudTrail denied events."
echo ""

# ── Simulate the HeadBucket confusion ────────────────────────────────────────
echo "═══ 8. HeadBucket Action Confusion ═══"
echo ""
echo "Customer tried adding s3:HeadBucket to their policy..."
echo "  ❌ 'The action s3:HeadBucket does not exist'"
echo ""
echo "This is correct. HeadBucket is an S3 API call, but the IAM action"
echo "that authorizes it is s3:ListBucket. See:"
echo "  https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazons3.html"
echo ""

# ── Summary ──────────────────────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  DIAGNOSIS SUMMARY                                              ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║                                                                 ║"
echo "║  Problem: EB Service Role cannot read S3 source bundle          ║"
echo "║                                                                 ║"
echo "║  Evidence:                                                      ║"
echo "║  • App version exists (create-application-version succeeded)    ║"
echo "║  • S3 object exists (uploader role has access)                  ║"
echo "║  • EB events show: 'S3 error: Access Denied'                   ║"
echo "║  • No 403 in access logs (IAM-level denial)                    ║"
echo "║  • No CloudTrail denied events (service-to-service call)        ║"
echo "║                                                                 ║"
echo "║  Root Cause: Explicit Deny in bucket policy blocks EB service   ║"
echo "║  role from s3:GetObject. IAM Deny always wins over Allow.       ║"
echo "║                                                                 ║"
echo "║  Fix: Remove Deny statement from bucket policy.                 ║"
echo "║       Run: ./deploy-fixed.sh                                    ║"
echo "║                                                                 ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
