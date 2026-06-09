# Elastic Beanstalk Sample Application

A simple Python Flask application deployed to AWS Elastic Beanstalk using CloudFormation.

## Prerequisites

- AWS CLI configured with credentials
- Appropriate IAM permissions for CloudFormation, Elastic Beanstalk, S3, and IAM

## Deployment

1. Make the deploy script executable:
```bash
chmod +x deploy.sh
```

2. Run the deployment:
```bash
./deploy.sh
```

The script will:
- Package the application
- Deploy the CloudFormation stack
- Upload the application to S3
- Display the application URL

## Manual Deployment

If you prefer manual steps:

1. Create the application package:
```bash
zip -r app.zip application.py requirements.txt
```

2. Deploy the CloudFormation stack:
```bash
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name sample-eb-stack \
  --capabilities CAPABILITY_IAM \
  --region us-east-1
```

3. Upload the application to the S3 bucket created by CloudFormation

4. Update the Elastic Beanstalk environment to use the new version

## Cleanup

To delete all resources:
```bash
aws cloudformation delete-stack --stack-name sample-eb-stack --region us-east-1
```

## Configuration

Edit `template.yaml` to customize:
- Instance type
- Environment type (SingleInstance vs LoadBalanced)
- Python version
- Region
