#!/bin/bash
# Serverless Image Processing with S3 + Lambda
# Prerequisites: AWS CLI, zip, IAM permissions

set -e

# Variables
PROJECT_NAME="image-processing"
REGION="us-east-1"
SOURCE_BUCKET="${PROJECT_NAME}-source-$(date +%s)"
DEST_BUCKET="${PROJECT_NAME}-processed-$(date +%s)"
ROLE_NAME="${PROJECT_NAME}-lambda-role"
POLICY_NAME="${PROJECT_NAME}-lambda-policy"
LAMBDA_NAME="${PROJECT_NAME}-function"

# 1. Create S3 buckets
echo "Creating S3 buckets..."
aws s3 mb s3://$SOURCE_BUCKET --region $REGION
aws s3 mb s3://$DEST_BUCKET --region $REGION

# 2. Create IAM Role for Lambda
echo "Creating IAM Role..."
cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document file://trust-policy.json

# Attach AWSLambdaBasicExecutionRole
aws iam attach-role-policy \
  --role-name $ROLE_NAME \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

# Allow S3 access
cat > s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject"],
      "Resource": [
        "arn:aws:s3:::$SOURCE_BUCKET/*",
        "arn:aws:s3:::$DEST_BUCKET/*"
      ]
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name $ROLE_NAME \
  --policy-name $POLICY_NAME \
  --policy-document file://s3-policy.json

# 3. Create Lambda function (Python example)
echo "Creating Lambda function..."
mkdir lambda_code
cat > lambda_code/lambda_function.py <<'EOF'
import boto3
from PIL import Image
import os

s3 = boto3.client('s3')

def lambda_handler(event, context):
    # Get bucket and object key
    bucket = event['Records'][0]['s3']['bucket']['name']
    key = event['Records'][0]['s3']['object']['key']
    
    download_path = f"/tmp/{os.path.basename(key)}"
    upload_path = f"/tmp/resized-{os.path.basename(key)}"

    # Download image
    s3.download_file(bucket, key, download_path)

    # Process image (resize)
    with Image.open(download_path) as img:
        img = img.resize((200, 200))
        img.save(upload_path)

    # Upload to destination bucket
    dest_bucket = os.environ['DEST_BUCKET']
    s3.upload_file(upload_path, dest_bucket, f"resized-{os.path.basename(key)}")

    return {"status": "success", "file": f"resized-{key}"}
EOF

# Zip function
cd lambda_code
zip function.zip lambda_function.py
cd ..

# Get role ARN
ROLE_ARN=$(aws iam get-role --role-name $ROLE_NAME --query 'Role.Arn' --output text)

aws lambda create-function \
  --function-name $LAMBDA_NAME \
  --runtime python3.9 \
  --role $ROLE_ARN \
  --handler lambda_function.lambda_handler \
  --zip-file fileb://lambda_code/function.zip \
  --region $REGION \
  --environment Variables="{DEST_BUCKET=$DEST_BUCKET}"

# 4. Add S3 trigger to Lambda
echo "Adding S3 event trigger..."
aws s3api put-bucket-notification-configuration \
  --bucket $SOURCE_BUCKET \
  --notification-configuration '{
    "LambdaFunctionConfigurations": [
      {
        "LambdaFunctionArn": "'$(aws lambda get-function --function-name $LAMBDA_NAME --query 'Configuration.FunctionArn' --output text)'",
        "Events": ["s3:ObjectCreated:*"]
      }
    ]
  }'

# Grant permission for S3 to invoke Lambda
aws lambda add-permission \
  --function-name $LAMBDA_NAME \
  --principal s3.amazonaws.com \
  --statement-id s3invoke \
  --action "lambda:InvokeFunction" \
  --source-arn arn:aws:s3:::$SOURCE_BUCKET

echo "✅ Setup complete!"
echo "Upload images to s3://$SOURCE_BUCKET and check processed images in s3://$DEST_BUCKET"
