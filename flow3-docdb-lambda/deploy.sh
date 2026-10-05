#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="zero-etl-workshop-flow3"
SHARED_STACK="zero-etl-workshop-shared"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
if [ -z "$REGION" ]; then
  echo "ERROR: No AWS region set. Run 'aws configure set region <region>' or export AWS_REGION." >&2
  echo "       Pick a region where both S3 Tables and Glue zero-ETL-to-S3-Tables are available (e.g. us-east-1, us-east-2, us-west-2)." >&2
  exit 1
fi
TEMPLATE="$(dirname "$0")/template.yaml"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_NAME="zero-etl-workshop"
NAMESPACE="flow3_docdb"
FIREHOSE_NAME="${PROJECT_NAME}-flow3-firehose"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

get_output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

VPC_ID=$(get_output "$SHARED_STACK" VpcId)
PRIVATE_SUBNET_1=$(get_output "$SHARED_STACK" PrivateSubnet1Id)
PRIVATE_SUBNET_2=$(get_output "$SHARED_STACK" PrivateSubnet2Id)
TABLE_BUCKET_NAME=$(get_output "$SHARED_STACK" TableBucketName)
TABLE_BUCKET_ARN="arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/${TABLE_BUCKET_NAME}"
ERROR_BUCKET_ARN=$(get_output "$SHARED_STACK" ErrorBucketArn)
ERROR_BUCKET_NAME=$(get_output "$SHARED_STACK" ErrorBucketName)
CATALOG_ID="${ACCOUNT_ID}:s3tablescatalog/${TABLE_BUCKET_NAME}"
CATALOG_ARN="arn:aws:glue:${REGION}:${ACCOUNT_ID}:catalog/s3tablescatalog/${TABLE_BUCKET_NAME}"

echo "=== Step 1: Create S3 Tables namespace and table ==="
aws s3tables create-namespace \
  --table-bucket-arn "$TABLE_BUCKET_ARN" \
  --namespace "$NAMESPACE" \
  --region "$REGION" 2>/dev/null || echo "  Namespace already exists"

aws s3tables create-table \
  --table-bucket-arn "$TABLE_BUCKET_ARN" \
  --namespace "$NAMESPACE" \
  --name "products" \
  --format ICEBERG \
  --metadata '{
    "iceberg": {
      "schema": {
        "fields": [
          {"name": "product_id", "type": "string", "required": true},
          {"name": "name", "type": "string"},
          {"name": "category", "type": "string"},
          {"name": "price", "type": "double"},
          {"name": "stock", "type": "int"},
          {"name": "rating", "type": "double"},
          {"name": "updated_at", "type": "string"}
        ]
      }
    }
  }' \
  --region "$REGION" 2>/dev/null || echo "  Table already exists"

echo "=== Step 2: Deploy CloudFormation stack ==="
echo "  (DocumentDB, Lambda, IAM roles — takes ~10-15 minutes)"
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    VpcId="$VPC_ID" \
    PrivateSubnet1Id="$PRIVATE_SUBNET_1" \
    PrivateSubnet2Id="$PRIVATE_SUBNET_2" \
    TableBucketName="$TABLE_BUCKET_NAME" \
    ErrorBucketArn="$ERROR_BUCKET_ARN" \
    ErrorBucketName="$ERROR_BUCKET_NAME" \
    DBMasterPassword="${DB_PASSWORD:?set DB_PASSWORD before deploying (no default is shipped)}"

FIREHOSE_ROLE_ARN=$(get_output "$STACK_NAME" FirehoseRoleArn)
LOG_GROUP=$(get_output "$STACK_NAME" FirehoseLogGroupName)
LOG_STREAM=$(get_output "$STACK_NAME" FirehoseLogStreamName)

echo "=== Step 3: Create Firehose delivery stream ==="
if aws firehose describe-delivery-stream --delivery-stream-name "$FIREHOSE_NAME" --region "$REGION" 2>/dev/null; then
  echo "  Firehose already exists"
else
  # Ensure Lake Formation permissions (CFN custom resource may not have propagated yet)
  aws lakeformation grant-permissions \
    --principal "DataLakePrincipalIdentifier=${FIREHOSE_ROLE_ARN}" \
    --resource "{\"Table\":{\"CatalogId\":\"${CATALOG_ID}\",\"DatabaseName\":\"${NAMESPACE}\",\"TableWildcard\":{}}}" \
    --permissions "SELECT" "INSERT" "ALTER" "DESCRIBE" \
    --region "$REGION" 2>/dev/null || true

  FIREHOSE_CREATED=false
  for ATTEMPT in $(seq 1 5); do
    if aws firehose create-delivery-stream \
      --delivery-stream-name "$FIREHOSE_NAME" \
      --delivery-stream-type DirectPut \
      --iceberg-destination-configuration "{
        \"RoleARN\":\"${FIREHOSE_ROLE_ARN}\",
        \"CatalogConfiguration\":{\"CatalogARN\":\"${CATALOG_ARN}\"},
        \"S3Configuration\":{\"BucketARN\":\"${ERROR_BUCKET_ARN}\",\"RoleARN\":\"${FIREHOSE_ROLE_ARN}\",\"Prefix\":\"flow3-errors/\",\"ErrorOutputPrefix\":\"flow3-error-output/\"},
        \"BufferingHints\":{\"IntervalInSeconds\":60,\"SizeInMBs\":128},
        \"CloudWatchLoggingOptions\":{\"Enabled\":true,\"LogGroupName\":\"${LOG_GROUP}\",\"LogStreamName\":\"${LOG_STREAM}\"},
        \"DestinationTableConfigurationList\":[{\"DestinationDatabaseName\":\"${NAMESPACE}\",\"DestinationTableName\":\"products\",\"UniqueKeys\":[\"product_id\"]}]
      }" \
      --region "$REGION" > /dev/null 2>&1; then
      FIREHOSE_CREATED=true
      break
    else
      echo "  Attempt $ATTEMPT failed (Lake Formation permissions may still be propagating). Retrying in 30s..."
      sleep 30
    fi
  done

  if [ "$FIREHOSE_CREATED" = false ]; then
    echo "ERROR: Failed to create Firehose after 5 attempts. Check Lake Formation permissions." >&2
    exit 1
  fi
  echo "  Created Firehose: $FIREHOSE_NAME"

  echo "  Waiting for Firehose to become ACTIVE..."
  for i in $(seq 1 30); do
    STATUS=$(aws firehose describe-delivery-stream \
      --delivery-stream-name "$FIREHOSE_NAME" --region "$REGION" \
      --query 'DeliveryStreamDescription.DeliveryStreamStatus' --output text)
    [ "$STATUS" = "ACTIVE" ] && echo "  Firehose is ACTIVE" && break
    sleep 5
  done
fi

echo ""
echo "=== Flow 3 deployed ==="
echo "DocumentDB: $(get_output "$STACK_NAME" DocDBClusterEndpoint)"
echo "Lambda: $(get_output "$STACK_NAME" LambdaFunctionName)"
echo "Firehose: $FIREHOSE_NAME"
echo ""
echo "Loading sample data into DocumentDB..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/.venv/bin/activate" 2>/dev/null || true
python3 "${SCRIPT_DIR}/load-data.py"
echo ""
echo "Data loaded. New inserts after the ESM is active will flow through to S3 Tables."
