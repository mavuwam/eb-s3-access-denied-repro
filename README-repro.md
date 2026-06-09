# S3 Access Denied Repro — Elastic Beanstalk + GitHub Actions

## Customer Issue

Elastic Beanstalk deployment fails with:
```
Service:AmazonCloudFormation, Message:S3 error: Access Denied
```

Key symptoms:
- Application versions are created successfully (visible in EB console)
- Deployment fails when EB/CloudFormation tries to read the S3 source bundle
- No 403 errors in S3 access logs
- No denied events in CloudTrail
- `s3:HeadBucket` does not exist as an IAM action (maps to `s3:ListBucket`)

## Architecture

```
GitHub Actions (Github_worker role via OIDC)
    │
    ├── 1. zip + upload to S3          ✓ (deployer has s3:PutObject)
    ├── 2. create-application-version  ✓ (deployer has EB permissions)
    └── 3. update-environment          ✓ (triggers async deployment)
                │
                ▼
    EB Service Role tries to read S3 bundle
                │
                ▼
    Bucket Policy: DENY s3:GetObject for EB service role
                │
                ▼
    ❌ "S3 error: Access Denied"
```

## Files

| File | Purpose |
|------|---------|
| `template-broken.yaml` | CFN template with broken bucket policy |
| `template-github-oidc.yaml` | Full template with GitHub OIDC provider |
| `.github/workflows/deploy.yml` | GitHub Actions workflow |
| `deploy-broken.sh` | Deploy the broken environment |
| `simulate-github-actions.sh` | Run the GH Actions workflow locally |
| `diagnose.sh` | Investigate the failure |
| `deploy-fixed.sh` | Apply the fix |

## Quick Start

```bash
# 1. Deploy the broken infrastructure
./deploy-broken.sh

# 2. Simulate the GitHub Actions pipeline (will fail)
./simulate-github-actions.sh

# 3. Diagnose the issue
./diagnose.sh

# 4. Apply the fix
./deploy-fixed.sh

# 5. Re-run the pipeline (will succeed)
./simulate-github-actions.sh
```

## Deploying with Actual GitHub Actions

1. Create a GitHub repo and push this code
2. Deploy the OIDC template:
   ```bash
   aws cloudformation deploy \
     --template-file template-github-oidc.yaml \
     --stack-name innoslate-repro-stack \
     --parameter-overrides GitHubOrg=YOUR_ORG GitHubRepo=YOUR_REPO \
     --capabilities CAPABILITY_NAMED_IAM \
     --region eu-north-1
   ```
3. Set the GitHub secret `AWS_DEPLOY_ROLE_ARN` to the deployer role ARN from stack outputs
4. Push to main or trigger the workflow manually
5. Watch it fail with the S3 Access Denied error

## Root Cause

The bucket policy has an explicit **Deny** on `s3:GetObject` for the EB service role.
In IAM policy evaluation, an explicit Deny **always** overrides any Allow —
even if the managed policies (`AWSElasticBeanstalkEnhancedHealth`, etc.) grant S3 access.

## Why No 403 in Logs

- S3 access logging only records requests that reach S3
- IAM/bucket policy denials happen at the authorization layer before the request is processed
- CloudTrail doesn't log service-to-service calls made by EB/CloudFormation internally
- This makes it extremely difficult to diagnose without checking the bucket policy directly

## Fix

Remove the Deny statement from the bucket policy, OR ensure the EB service role
has an explicit Allow that isn't blocked by a Deny.
