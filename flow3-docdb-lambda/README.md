# Flow 3: DocumentDB → Change Streams → Lambda → Firehose → S3 Tables

## Architecture

```
┌──────────────────── Shared VPC (private subnets) ────────────────────┐
│                                                                       │
│   DocumentDB cluster                                                  │
│   (workshop.products collection, change streams enabled)             │
│        │                                                              │
│        ▼  Change stream                                               │
│           consumed by Lambda Event Source Mapping (ESM)              │
│        │                                                              │
│   ┌──────────────────────────┐                                       │
│   │  Lambda change processor  │                                       │
│   └────────────┬─────────────┘                                       │
└────────────────┼────────────────────────────────────────────────────┘
                 │  PutRecordBatch (Direct PUT)
                 ▼
   Amazon Data Firehose  ──(delivery errors)──▶  shared error S3 bucket
   (Direct PUT → Iceberg)
                 │
                 ▼
   S3 Table Bucket (Apache Iceberg)
       └── flow3_docdb namespace
           └── products table
                 │
                 ▼
   Query with Amazon Athena
```

Data path: a write to the `products` collection appears on the DocumentDB change stream → the Lambda ESM invokes the processor → the processor pushes batches to Firehose via `PutRecordBatch` → Firehose writes them into the Iceberg `products` table. Because the ESM uses `StartingPosition: LATEST`, only changes made **after** the ESM is active are captured (see the note below).

## Prerequisites

- Shared infrastructure deployed (`shared/deploy.sh`)
- Python 3.9+ with boto3 installed
- AWS CLI configured with appropriate permissions

## Deploy

```bash
# 1. Deploy infrastructure and create Firehose
./deploy.sh

# 2. Load sample data (2,000 products) via temporary Lambda
python3 load-data.py
```

**Approximate time/cost:** deploy is ~15 minutes (DocumentDB provisioning dominates). The DocumentDB cluster (`db.r6g.large`) and the shared NAT gateway bill continuously while running — run `teardown.sh` when you are done.

**Important:** The Event Source Mapping (ESM) is configured with `StartingPosition: LATEST`. This means it only processes changes that occur **after** the ESM becomes active. You must insert new data after deployment to see records flow through to S3 Tables.

## What the Deploy Script Does

1. **Creates S3 Tables namespace and table** — `flow3_docdb.products` with the Iceberg schema
2. **Deploys CloudFormation stack** — DocumentDB cluster, Lambda processor, Lambda ESM, IAM roles (~10-15 minutes)
3. **Creates Firehose delivery stream** — Direct PUT mode (Lambda pushes via `PutRecordBatch`), created via CLI with Iceberg destination

## How It Works

1. **DocumentDB** cluster is created with change streams enabled (via parameter group `change_stream_log_retention_duration`).
2. **Change streams must be explicitly enabled** on the database via the `modifyChangeStreams` admin command (the parameter group only sets retention duration).
3. **Lambda Event Source Mapping** connects to the DocumentDB cluster's change stream for the `workshop.products` collection.
4. When documents are inserted/updated/deleted, DocumentDB emits change events.
5. **Lambda** receives batches of change events, extracts the full document, cleans BSON types, and sends records to **Firehose** via `PutRecordBatch` (Direct PUT — not Kinesis).
6. **Firehose** writes to S3 Tables using the Iceberg destination with upsert on `product_id`.
7. Data lands as **Apache Iceberg tables** in the S3 Table Bucket.

## Data Loading

The `load-data.py` script creates a **temporary Lambda function** in the VPC to load data into DocumentDB:

- Installs `pymongo` at runtime via `pip install pymongo -t /tmp/pip` (not bundled in a layer)
- Connects to DocumentDB using credentials from Secrets Manager
- Downloads the RDS CA bundle for TLS connections
- Inserts 2,000 product documents in batches of 500
- Cleans up the temporary Lambda after completion

## Validate

```bash
# Check Lambda event source mapping status
REGION="$(aws configure get region)"   # the region you deployed into
aws lambda list-event-source-mappings \
  --function-name zero-etl-workshop-flow3-processor \
  --region "$REGION" \
  --query 'EventSourceMappings[0].{State:State,LastProcessingResult:LastProcessingResult}'

# Check Firehose status
aws firehose describe-delivery-stream \
  --delivery-stream-name zero-etl-workshop-flow3-firehose \
  --region "$REGION" \
  --query 'DeliveryStreamDescription.DeliveryStreamStatus'

# Query data via Athena (S3 Tables catalog)
# Database: flow3_docdb
# Table: products
```

**To test CDC after deployment**, insert new documents — the ESM starts from LATEST:
```bash
# Use load-data.py or invoke the loader Lambda manually with new product IDs
python3 load-data.py
```

## Teardown

```bash
./teardown.sh
```

## Key Configuration Details

| Setting | Value |
|---------|-------|
| DocumentDB Engine | docdb 5.0 |
| Change Streams | Enabled (10800s retention) — must also run `modifyChangeStreams` admin command |
| Lambda Trigger | EventSourceMapping with DocumentDB (`StartingPosition: LATEST`) |
| Lambda Runtime | Python 3.12 |
| Firehose Source | **Direct PUT** (Lambda pushes via `PutRecordBatch`) |
| Firehose Destination | Iceberg (S3 Tables) |
| Firehose Buffer | 60s / 128MB |
| Upsert Key | product_id |
| Firehose CatalogARN | S3 Tables sub-catalog: `arn:aws:glue:region:account:catalog/s3tablescatalog/<bucket>` |
| Loader Lambda | Uses `pymongo` installed at runtime via pip to `/tmp` |

## Key Learnings & Gotchas

### DocumentDB change streams must be explicitly enabled

The CloudFormation parameter group sets `change_stream_log_retention_duration`, but change streams must also be **explicitly enabled** on the database using the `modifyChangeStreams` admin command:

```javascript
// Run in mongosh connected to DocumentDB
db.adminCommand({ modifyChangeStreams: 1, database: "workshop", collection: "products", enable: true });
```

Without this, the Lambda ESM will not receive any change events.

### Lambda ESM requires additional IAM permissions

The Lambda execution role for the DocumentDB ESM needs these permissions beyond the basics:

- `ec2:DescribeSecurityGroups`
- `rds:DescribeDBClusters`
- `rds:DescribeDBClusterParameters`
- `rds:DescribeDBSubnetGroups`

These are required by the ESM service to discover the DocumentDB cluster's VPC configuration and connect to the change stream.

### Firehose is Direct PUT (not Kinesis-sourced)

Unlike Flow 2, this Firehose uses **Direct PUT** mode. The Lambda processor calls `firehose:PutRecordBatch` directly to push records. There is no Kinesis Data Stream in this flow.

### Loader Lambda installs pymongo at runtime

The loader Lambda doesn't use a Lambda layer. Instead, it runs `pip install pymongo -t /tmp/pip` at invocation time and adds `/tmp/pip` to `sys.path`. This avoids the need to build and manage a Lambda layer for the workshop.

### ESM set to LATEST — need new inserts to test

The Event Source Mapping uses `StartingPosition: LATEST`, meaning it only processes changes that occur **after** the ESM is active. Pre-existing documents in DocumentDB won't trigger events. To test the full pipeline, insert new documents after the ESM shows `State: Enabled`.

### Firehose CatalogARN uses sub-catalog format

Same as Flow 2 — the Firehose `CatalogConfiguration.CatalogARN` must use:
```
arn:aws:glue:<region>:<account>:catalog/s3tablescatalog/<bucket-name>
```

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| ESM state is `Enabled` but no records flow | Change streams not enabled on the database | Run `modifyChangeStreams` admin command on DocumentDB |
| ESM state is `Enabled` but no records flow | Data was loaded before ESM was active | Insert new documents — ESM starts from LATEST |
| ESM fails to create with access denied | Missing IAM permissions | Add `ec2:DescribeSecurityGroups`, `rds:DescribeDBClusters`, `rds:DescribeDBClusterParameters`, `rds:DescribeDBSubnetGroups` to Lambda role |
| Loader Lambda fails with `pymongo` import error | pip install failed (network/timeout) | Ensure Lambda has internet access via NAT gateway in VPC |
| Firehose fails with "database not found" | Wrong CatalogARN format | Use sub-catalog ARN: `arn:aws:glue:region:account:catalog/s3tablescatalog/bucket-name` |
| No data in Athena | Firehose buffering delay | Wait 60+ seconds (buffer interval); check Firehose CloudWatch logs |
| Loader Lambda timeout | DocumentDB connection issues | Check security group allows Lambda → DocumentDB on port 27017 |
