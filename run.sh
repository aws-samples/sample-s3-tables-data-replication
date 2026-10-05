#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "============================================"
echo "  S3 Table Buckets Workshop - Full Deploy"
echo "============================================"
echo ""

# Step 0: Pre-flight setup
echo ">>> Step 0: Pre-flight setup"
bash setup.sh
echo ""

# Step 1: Shared infrastructure
echo ">>> Step 1: Shared infrastructure (VPC, S3 Table Bucket)"
bash shared/deploy.sh
echo ""

# Activate venv for Python scripts
source .venv/bin/activate

# Step 2: Flow 1 — DynamoDB → Glue Zero-ETL → S3 Tables
echo ">>> Step 2: Flow 1 — DynamoDB → Glue Zero-ETL"
bash flow1-dynamodb-glue/deploy.sh
echo ""

# Step 3: Flow 2 — Aurora PG → DMS → Kinesis → Firehose → S3 Tables
echo ">>> Step 3: Flow 2 — Aurora PG → DMS → Kinesis → Firehose"
bash flow2-aurora-dms-kinesis/deploy.sh
echo ""

# Step 4: Flow 3 — DocumentDB → Lambda → Firehose → S3 Tables
echo ">>> Step 4: Flow 3 — DocumentDB → Lambda → Firehose"
bash flow3-docdb-lambda/deploy.sh
echo ""

# Summary
REGION="${AWS_REGION:-$(aws configure get region 2>/dev/null)}"
if [ -z "$REGION" ]; then
  echo "ERROR: No AWS region set. Run 'aws configure set region <region>' or export AWS_REGION." >&2
  exit 1
fi
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "============================================"
echo "  Deployment Complete"
echo "============================================"
echo ""
echo "Account:  $ACCOUNT_ID"
echo "Region:   $REGION"
echo ""
echo "Flow 1:   DynamoDB → Glue Zero-ETL → S3 Tables"
echo "          Initial export takes ~15-20 min. Check:"
echo "          aws glue describe-integrations --region $REGION"
echo ""
echo "Flow 2:   Aurora PG → DMS → Kinesis → Firehose → S3 Tables"
echo "          Data should appear within ~2 min of DMS start."
echo ""
echo "Flow 3:   DocumentDB → Lambda → Firehose → S3 Tables"
echo "          Insert new records to trigger change streams."
echo ""
echo "Verify with Athena:"
echo "  CATALOG=\"s3tablescatalog/zero-etl-workshop-tables-${ACCOUNT_ID}\""
echo "  SELECT COUNT(*) FROM flow2_aurora.customers;"
echo "  SELECT COUNT(*) FROM flow3_docdb.products;"
echo ""
echo "Teardown: bash teardown.sh"
