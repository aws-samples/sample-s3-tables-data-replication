#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="zero-etl-workshop-flow3"
SHARED_STACK="zero-etl-workshop-shared"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
if [ -z "$REGION" ]; then
  echo "ERROR: No AWS region set. Run 'aws configure set region <region>' or export AWS_REGION." >&2
  exit 1
fi
PROJECT_NAME="zero-etl-workshop"
NAMESPACE="flow3_docdb"
FIREHOSE_NAME="${PROJECT_NAME}-flow3-firehose"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TABLE_BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$SHARED_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`TableBucketName`].OutputValue' --output text 2>/dev/null || true)

echo "=== Step 1: Delete Firehose ==="
aws firehose delete-delivery-stream \
  --delivery-stream-name "$FIREHOSE_NAME" \
  --region "$REGION" 2>/dev/null || echo "  No Firehose to delete"

echo "=== Step 2: Delete loader Lambda if exists ==="
aws lambda delete-function --function-name "${PROJECT_NAME}-flow3-loader" --region "$REGION" 2>/dev/null || true

echo "=== Step 3: Delete CloudFormation stack ==="
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
echo "  Waiting for stack deletion (DocumentDB takes ~10 minutes)..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"

echo "=== Step 4: Clean up S3 Tables resources ==="
if [ -n "$TABLE_BUCKET_NAME" ] && [ "$TABLE_BUCKET_NAME" != "None" ]; then
  TABLE_BUCKET_ARN="arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/${TABLE_BUCKET_NAME}"

  TABLES=$(aws s3tables list-tables \
    --table-bucket-arn "$TABLE_BUCKET_ARN" \
    --namespace "$NAMESPACE" \
    --region "$REGION" \
    --query 'tables[].name' --output text 2>/dev/null || true)
  for TBL in $TABLES; do
    aws s3tables delete-table \
      --table-bucket-arn "$TABLE_BUCKET_ARN" \
      --namespace "$NAMESPACE" \
      --name "$TBL" \
      --region "$REGION" 2>/dev/null || true
    echo "  Deleted S3 table: $TBL"
  done

  aws s3tables delete-namespace \
    --table-bucket-arn "$TABLE_BUCKET_ARN" \
    --namespace "$NAMESPACE" \
    --region "$REGION" 2>/dev/null || true
  echo "  Deleted namespace: $NAMESPACE"
fi

echo "=== Flow 3 teardown complete ==="
