#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="zero-etl-workshop-flow2"
SHARED_STACK="zero-etl-workshop-shared"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
if [ -z "$REGION" ]; then
  echo "ERROR: No AWS region set. Run 'aws configure set region <region>' or export AWS_REGION." >&2
  exit 1
fi
PROJECT_NAME="zero-etl-workshop"
NAMESPACE="flow2_aurora"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TABLE_BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$SHARED_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`TableBucketName`].OutputValue' --output text 2>/dev/null || true)

echo "=== Step 1: Delete Firehose delivery stream ==="
FIREHOSE_NAME="${PROJECT_NAME}-flow2-firehose"
aws firehose delete-delivery-stream \
  --delivery-stream-name "$FIREHOSE_NAME" \
  --region "$REGION" 2>/dev/null || echo "  No Firehose to delete"

echo "=== Step 2: Stop DMS replication task ==="
DMS_TASK_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`DMSReplicationTaskArn`].OutputValue' --output text 2>/dev/null || true)

if [ -n "$DMS_TASK_ARN" ] && [ "$DMS_TASK_ARN" != "None" ]; then
  TASK_STATUS=$(aws dms describe-replication-tasks \
    --filters "Name=replication-task-arn,Values=${DMS_TASK_ARN}" \
    --region "$REGION" \
    --query 'ReplicationTasks[0].Status' --output text 2>/dev/null || true)
  if [ "$TASK_STATUS" = "running" ]; then
    aws dms stop-replication-task --replication-task-arn "$DMS_TASK_ARN" --region "$REGION" 2>/dev/null || true
    echo "  Stopping DMS task..."
    sleep 30
  fi
fi

echo "=== Step 3: Revoke Lake Formation permissions ==="
FIREHOSE_ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`FirehoseRoleArn`].OutputValue' --output text 2>/dev/null || true)

if [ -n "$FIREHOSE_ROLE_ARN" ] && [ "$FIREHOSE_ROLE_ARN" != "None" ] && [ -n "$TABLE_BUCKET_NAME" ]; then
  CATALOG_ID="${ACCOUNT_ID}:s3tablescatalog/${TABLE_BUCKET_NAME}"
  aws lakeformation revoke-permissions \
    --principal "{\"DataLakePrincipal\": {\"DataLakePrincipalIdentifier\": \"${FIREHOSE_ROLE_ARN}\"}}" \
    --resource "{\"Table\": {\"CatalogId\": \"${CATALOG_ID}\", \"DatabaseName\": \"${NAMESPACE}\", \"TableWildcard\": {}}}" \
    --permissions "ALL" \
    --permissions-with-grant-option "ALL" \
    --region "$REGION" 2>/dev/null || true
fi

echo "=== Step 4: Delete CloudFormation stack ==="
aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION"
echo "  Waiting for stack deletion (this may take 10-15 minutes for Aurora)..."
aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"

echo "=== Step 5: Clean up S3 Tables resources ==="
if [ -n "$TABLE_BUCKET_NAME" ] && [ "$TABLE_BUCKET_NAME" != "None" ]; then
  TABLE_BUCKET_ARN="arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/${TABLE_BUCKET_NAME}"
  CATALOG_ID="${ACCOUNT_ID}:s3tablescatalog/${TABLE_BUCKET_NAME}"

  # Delete tables
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

  # Delete namespace
  aws s3tables delete-namespace \
    --table-bucket-arn "$TABLE_BUCKET_ARN" \
    --namespace "$NAMESPACE" \
    --region "$REGION" 2>/dev/null || true

  # Delete Glue database
  aws glue delete-database \
    --catalog-id "$CATALOG_ID" \
    --name "$NAMESPACE" \
    --region "$REGION" 2>/dev/null || true
  echo "  Deleted namespace and Glue database: $NAMESPACE"
fi

echo "=== Flow 2 teardown complete ==="
