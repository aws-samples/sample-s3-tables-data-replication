#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="zero-etl-workshop-flow2"
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
NAMESPACE="flow2_aurora"
FIREHOSE_NAME="${PROJECT_NAME}-flow2-firehose"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Get shared stack outputs
get_output() {
  aws cloudformation describe-stacks --stack-name "$1" --region "$REGION" \
    --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text
}

VPC_ID=$(get_output "$SHARED_STACK" VpcId)
PRIVATE_SUBNET_1=$(get_output "$SHARED_STACK" PrivateSubnet1Id)
PRIVATE_SUBNET_2=$(get_output "$SHARED_STACK" PrivateSubnet2Id)
TABLE_BUCKET_NAME=$(get_output "$SHARED_STACK" TableBucketName)
ERROR_BUCKET_ARN=$(get_output "$SHARED_STACK" ErrorBucketArn)
ERROR_BUCKET_NAME=$(get_output "$SHARED_STACK" ErrorBucketName)

echo "=== Step 1: Deploy CloudFormation stack ==="
echo "  (Aurora, DMS, Kinesis, IAM roles — takes ~15-20 minutes)"
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

echo "=== Step 2: Create source tables and load data ==="
python3 "${SCRIPT_DIR}/load-data.py"

echo "=== Step 3: Sync Aurora schema → S3 Tables ==="
python3 "${SCRIPT_DIR}/sync-schema.py"

echo "=== Step 4: Create Firehose delivery stream ==="
FIREHOSE_ROLE_ARN=$(get_output "$STACK_NAME" FirehoseRoleArn)
KINESIS_ARN=$(get_output "$STACK_NAME" KinesisStreamArn)
LOG_GROUP=$(get_output "$STACK_NAME" FirehoseLogGroupName)
LOG_STREAM=$(get_output "$STACK_NAME" FirehoseLogStreamName)
TRANSFORM_ARN=$(get_output "$STACK_NAME" TransformLambdaArn)
CATALOG_ARN="arn:aws:glue:${REGION}:${ACCOUNT_ID}:catalog/s3tablescatalog/${TABLE_BUCKET_NAME}"
CATALOG_ID="${ACCOUNT_ID}:s3tablescatalog/${TABLE_BUCKET_NAME}"

# Ensure Lake Formation permissions (CFN custom resource may not have propagated yet)
aws lakeformation grant-permissions \
  --principal "DataLakePrincipalIdentifier=${FIREHOSE_ROLE_ARN}" \
  --resource "{\"Table\":{\"CatalogId\":\"${CATALOG_ID}\",\"DatabaseName\":\"${NAMESPACE}\",\"TableWildcard\":{}}}" \
  --permissions "SELECT" "INSERT" "ALTER" "DESCRIBE" \
  --region "$REGION" 2>/dev/null || true

# Check if Firehose already exists
if aws firehose describe-delivery-stream --delivery-stream-name "$FIREHOSE_NAME" --region "$REGION" 2>/dev/null; then
  echo "  Firehose already exists"
else
  # Build DestinationTableConfigurationList from schema-mapping.json
  MAPPING_FILE="${SCRIPT_DIR}/schema-mapping.json"
  if [ ! -f "$MAPPING_FILE" ]; then
    echo "ERROR: schema-mapping.json not found. Run sync-schema.py first." >&2
    exit 1
  fi

  # Generate destination table configs from the mapping
  DEST_TABLES=$(python3 -c "
import json, sys
with open('${MAPPING_FILE}') as f:
    tables = json.load(f)
configs = []
for t in tables:
    cfg = {
        'DestinationDatabaseName': '${NAMESPACE}',
        'DestinationTableName': t['table']
    }
    if t.get('primary_keys'):
        cfg['UniqueKeys'] = t['primary_keys']
    configs.append(cfg)
print(json.dumps(configs))
")

  FIREHOSE_CREATED=false
  for ATTEMPT in $(seq 1 5); do
    if aws firehose create-delivery-stream \
      --delivery-stream-name "$FIREHOSE_NAME" \
      --delivery-stream-type KinesisStreamAsSource \
      --kinesis-stream-source-configuration "{
        \"KinesisStreamARN\": \"${KINESIS_ARN}\",
        \"RoleARN\": \"${FIREHOSE_ROLE_ARN}\"
      }" \
      --iceberg-destination-configuration "{
        \"RoleARN\": \"${FIREHOSE_ROLE_ARN}\",
        \"CatalogConfiguration\": {\"CatalogARN\": \"${CATALOG_ARN}\"},
        \"S3Configuration\": {
          \"BucketARN\": \"${ERROR_BUCKET_ARN}\",
          \"RoleARN\": \"${FIREHOSE_ROLE_ARN}\",
          \"Prefix\": \"flow2-errors/\",
          \"ErrorOutputPrefix\": \"flow2-error-output/\",
          \"CloudWatchLoggingOptions\": {
            \"Enabled\": true,
            \"LogGroupName\": \"${LOG_GROUP}\",
            \"LogStreamName\": \"${LOG_STREAM}\"
          }
        },
        \"BufferingHints\": {\"IntervalInSeconds\": 60, \"SizeInMBs\": 128},
        \"ProcessingConfiguration\": {
          \"Enabled\": true,
          \"Processors\": [{
            \"Type\": \"Lambda\",
            \"Parameters\": [
              {\"ParameterName\": \"LambdaArn\", \"ParameterValue\": \"${TRANSFORM_ARN}\"},
              {\"ParameterName\": \"BufferSizeInMBs\", \"ParameterValue\": \"1\"},
              {\"ParameterName\": \"BufferIntervalInSeconds\", \"ParameterValue\": \"60\"}
            ]
          }]
        },
        \"CloudWatchLoggingOptions\": {
          \"Enabled\": true,
          \"LogGroupName\": \"${LOG_GROUP}\",
          \"LogStreamName\": \"${LOG_STREAM}\"
        },
        \"DestinationTableConfigurationList\": ${DEST_TABLES}
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
    if [ "$STATUS" = "ACTIVE" ]; then
      echo "  Firehose is ACTIVE"
      break
    fi
    sleep 5
  done
fi

echo "=== Step 5: Start DMS replication task ==="
DMS_TASK_ARN=$(get_output "$STACK_NAME" DMSReplicationTaskArn)

TASK_STATUS=$(aws dms describe-replication-tasks \
  --filters "Name=replication-task-arn,Values=${DMS_TASK_ARN}" \
  --region "$REGION" \
  --query 'ReplicationTasks[0].Status' --output text)

if [ "$TASK_STATUS" = "ready" ]; then
  aws dms start-replication-task \
    --replication-task-arn "$DMS_TASK_ARN" \
    --start-replication-task-type start-replication \
    --region "$REGION" > /dev/null
  echo "  DMS task started"
elif [ "$TASK_STATUS" = "running" ]; then
  echo "  DMS task already running"
else
  echo "  DMS task status: $TASK_STATUS (may need manual start)"
fi

AURORA_ENDPOINT=$(get_output "$STACK_NAME" AuroraEndpoint)

echo ""
echo "=== Flow 2 deployed ==="
echo "Aurora Endpoint: $AURORA_ENDPOINT"
echo "Kinesis Stream: ${PROJECT_NAME}-flow2-cdc"
echo "Firehose: $FIREHOSE_NAME"
echo "DMS Task: $DMS_TASK_ARN"
echo ""
echo "CDC data will flow: Aurora → DMS → Kinesis → Firehose → S3 Tables"
