#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="zero-etl-workshop-flow1"
SHARED_STACK="zero-etl-workshop-shared"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
if [ -z "$REGION" ]; then
  echo "ERROR: No AWS region set. Run 'aws configure set region <region>' or export AWS_REGION." >&2
  exit 1
fi
PROJECT_NAME="zero-etl-workshop"
INTEGRATION_NAME="${PROJECT_NAME}-flow1-ddb-to-s3tables"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TABLE_BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$SHARED_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`TableBucketName`].OutputValue' --output text 2>/dev/null || true)

TARGET_CATALOG_ARN="arn:aws:glue:${REGION}:${ACCOUNT_ID}:catalog/s3tablescatalog/${TABLE_BUCKET_NAME}"

echo "=== Step 1: Delete Glue Zero-ETL Integration ==="
INTEGRATION_ARN=$(aws glue describe-integrations --region "$REGION" \
  --query "Integrations[?IntegrationName=='${INTEGRATION_NAME}'].IntegrationArn" \
  --output text 2>/dev/null || true)

if [ -n "$INTEGRATION_ARN" ] && [ "$INTEGRATION_ARN" != "None" ] && [ "$INTEGRATION_ARN" != "" ]; then
  aws glue delete-integration --integration-identifier "$INTEGRATION_ARN" --region "$REGION" 2>/dev/null || true
  echo "  Deleted integration: $INTEGRATION_ARN"
  echo "  Waiting for deletion..."
  sleep 30
fi

echo "=== Step 2: Clean up integration resources on catalog ==="
aws glue delete-integration-table-properties \
  --resource-arn "$TARGET_CATALOG_ARN" \
  --table-name "${PROJECT_NAME}-orders" \
  --region "$REGION" 2>/dev/null || true
aws glue delete-integration-resource-property \
  --resource-arn "$TARGET_CATALOG_ARN" \
  --region "$REGION" 2>/dev/null || true

echo "=== Step 3: Clean up auto-created zetl_* namespaces ==="
if [ -n "$TABLE_BUCKET_NAME" ] && [ "$TABLE_BUCKET_NAME" != "None" ]; then
  CATALOG_ID="${ACCOUNT_ID}:s3tablescatalog/${TABLE_BUCKET_NAME}"
  TABLE_BUCKET_ARN="arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/${TABLE_BUCKET_NAME}"

  # Find zetl_ namespaces
  NAMESPACES=$(aws s3tables list-namespaces \
    --table-bucket-arn "$TABLE_BUCKET_ARN" --region "$REGION" \
    --query "namespaces[?starts_with(namespace[0],'zetl_')].namespace[0]" --output text 2>/dev/null || true)

  for NS in $NAMESPACES; do
    TABLES=$(aws s3tables list-tables \
      --table-bucket-arn "$TABLE_BUCKET_ARN" --namespace "$NS" \
      --region "$REGION" --query 'tables[].name' --output text 2>/dev/null || true)
    for TBL in $TABLES; do
      aws s3tables delete-table \
        --table-bucket-arn "$TABLE_BUCKET_ARN" --namespace "$NS" --name "$TBL" \
        --region "$REGION" 2>/dev/null || true
      echo "  Deleted table: $NS.$TBL"
    done
    aws s3tables delete-namespace \
      --table-bucket-arn "$TABLE_BUCKET_ARN" --namespace "$NS" \
      --region "$REGION" 2>/dev/null || true
    echo "  Deleted namespace: $NS"
  done
fi

echo "=== Step 4: Remove Glue catalog resource policy ==="
aws glue delete-resource-policy --region "$REGION" 2>/dev/null || true

echo "=== Step 5: Delete CloudFormation stack ==="
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"

echo "=== Flow 1 teardown complete ==="
