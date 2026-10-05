#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "============================================"
echo "  S3 Table Buckets Workshop - Full Teardown"
echo "============================================"
echo ""

echo ">>> Flow 3: DocumentDB → Lambda → Firehose"
bash flow3-docdb-lambda/teardown.sh
echo ""

echo ">>> Flow 2: Aurora PG → DMS → Kinesis → Firehose"
bash flow2-aurora-dms-kinesis/teardown.sh
echo ""

echo ">>> Flow 1: DynamoDB → Glue Zero-ETL"
bash flow1-dynamodb-glue/teardown.sh
echo ""

echo ">>> Shared infrastructure"
bash shared/teardown.sh
echo ""

echo "============================================"
echo "  Teardown Complete"
echo "============================================"
