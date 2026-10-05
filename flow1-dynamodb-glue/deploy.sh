#!/usr/bin/env bash
set -euo pipefail

STACK_NAME="zero-etl-workshop-flow1"
SHARED_STACK="zero-etl-workshop-shared"
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
if [ -z "$REGION" ]; then
  echo "ERROR: No AWS region set. Run 'aws configure set region <region>' or export AWS_REGION." >&2
  echo "       Pick a region where both S3 Tables and Glue zero-ETL-to-S3-Tables are available (e.g. us-east-1, us-east-2, us-west-2)." >&2
  exit 1
fi
TEMPLATE="$(dirname "$0")/template.yaml"
PROJECT_NAME="zero-etl-workshop"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
TABLE_BUCKET_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$SHARED_STACK" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`TableBucketName`].OutputValue' --output text)

# The target for Glue Zero-ETL is the S3 Tables CATALOG (not a database).
# Glue automatically creates a namespace (zetl_<integration-id>) and table.
TARGET_CATALOG_ARN="arn:aws:glue:${REGION}:${ACCOUNT_ID}:catalog/s3tablescatalog/${TABLE_BUCKET_NAME}"

echo "=== Step 1: Deploy CloudFormation stack ==="
aws cloudformation deploy \
  --stack-name "$STACK_NAME" \
  --template-file "$TEMPLATE" \
  --region "$REGION" \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-fail-on-empty-changeset \
  --parameter-overrides \
    TableBucketName="$TABLE_BUCKET_NAME"

DDB_TABLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`DynamoDBTableArn`].OutputValue' --output text)
DDB_TABLE_NAME=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`DynamoDBTableName`].OutputValue' --output text)
ROLE_ARN=$(aws cloudformation describe-stacks \
  --stack-name "$STACK_NAME" --region "$REGION" \
  --query 'Stacks[0].Outputs[?OutputKey==`GlueTargetRoleArn`].OutputValue' --output text)

echo "=== Step 2: Set Glue catalog resource policy ==="
CATALOG_ARN="arn:aws:glue:${REGION}:${ACCOUNT_ID}:catalog"

POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowGlueZeroETLInbound",
      "Effect": "Allow",
      "Principal": {"Service": "glue.amazonaws.com"},
      "Action": "glue:AuthorizeInboundIntegration",
      "Resource": ["${CATALOG_ARN}", "${TARGET_CATALOG_ARN}"]
    },
    {
      "Sid": "AllowAccountCreateInbound",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::${ACCOUNT_ID}:root"},
      "Action": "glue:CreateInboundIntegration",
      "Resource": ["${CATALOG_ARN}", "${TARGET_CATALOG_ARN}"]
    }
  ]
}
EOF
)
aws glue put-resource-policy \
  --policy-in-json "$POLICY" \
  --enable-hybrid TRUE \
  --region "$REGION"
echo "  Resource policy set"

echo "=== Step 3: Set IntegrationResourceProperty on catalog ==="
aws glue create-integration-resource-property \
  --resource-arn "$TARGET_CATALOG_ARN" \
  --target-processing-properties "{\"RoleArn\": \"${ROLE_ARN}\"}" \
  --region "$REGION" 2>/dev/null || \
aws glue update-integration-resource-property \
  --resource-arn "$TARGET_CATALOG_ARN" \
  --target-processing-properties "{\"RoleArn\": \"${ROLE_ARN}\"}" \
  --region "$REGION"
echo "  Resource property set"

echo "=== Step 4: Set IntegrationTableProperties ==="
aws glue create-integration-table-properties \
  --resource-arn "$TARGET_CATALOG_ARN" \
  --table-name "$DDB_TABLE_NAME" \
  --target-table-config '' \
  --region "$REGION" 2>/dev/null || echo "  Table properties already set"

echo "=== Step 5: Create Glue Zero-ETL Integration ==="
INTEGRATION_NAME="${PROJECT_NAME}-flow1-ddb-to-s3tables"

EXISTING=$(aws glue describe-integrations --region "$REGION" \
  --query "Integrations[?IntegrationName=='${INTEGRATION_NAME}'].IntegrationArn" \
  --output text 2>/dev/null || true)

if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ] && [ "$EXISTING" != "" ]; then
  echo "  Integration already exists: $EXISTING"
  INTEGRATION_ARN="$EXISTING"
else
  INTEGRATION_ARN=$(aws glue create-integration \
    --integration-name "$INTEGRATION_NAME" \
    --source-arn "$DDB_TABLE_ARN" \
    --target-arn "$TARGET_CATALOG_ARN" \
    --description "Flow 1: DynamoDB to S3 Tables via Glue Zero-ETL" \
    --region "$REGION" \
    --query 'IntegrationArn' --output text)
  echo "  Created integration: $INTEGRATION_ARN"
fi

echo ""
echo "=== Flow 1 deployed ==="
echo "DynamoDB Table: $DDB_TABLE_NAME"
echo "Target: S3 Tables catalog (${TABLE_BUCKET_NAME})"
echo "Integration: $INTEGRATION_ARN"
echo ""
echo "Loading sample data..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$(dirname "$SCRIPT_DIR")/.venv/bin/activate" 2>/dev/null || true
python3 "${SCRIPT_DIR}/load-data.py"
echo ""
echo "Glue Zero-ETL will automatically create a namespace (zetl_<integration-id>)"
echo "and replicate the DynamoDB table as an Iceberg table within it."
echo "Initial export takes ~15-20 minutes."
