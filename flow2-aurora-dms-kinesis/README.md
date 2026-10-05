# Flow 2: Aurora PostgreSQL → DMS → Kinesis → Firehose → S3 Tables

## Architecture

```
┌──────────────────────── Shared VPC (private subnets) ────────────────────────┐
│                                                                               │
│   Aurora PostgreSQL                                                           │
│   (public schema: customers)                                                  │
│        │                                                                      │
│        ▼  DMS replication instance                                            │
│           full-load + CDC (logical replication)                               │
│        │                                                                      │
│   ┌──────────────┐                                                            │
│   │   Kinesis    │                                                            │
│   │ Data Streams │  (2 shards)                                                │
│   └──────┬───────┘                                                            │
│          │                                                                    │
│          ▼  Lambda transform (flattens the DMS record wrapper)                │
└──────────┼────────────────────────────────────────────────────────────────┘
           │
           ▼
   Amazon Data Firehose  ──(delivery errors)──▶  shared error S3 bucket
   (Iceberg destination, upsert on customer_id)
           │
           ▼
   S3 Table Bucket (Apache Iceberg)
       └── flow2_aurora namespace
           └── customers table
           │
           ▼
   Query with Amazon Athena
```

Data path: Aurora emits inserts/updates as CDC → DMS writes them to Kinesis → a Lambda unwraps the DMS envelope → Firehose upserts rows into the Iceberg `customers` table. Rows are matched on `customer_id` (the upsert key).

## Prerequisites

- Shared infrastructure deployed (`shared/deploy.sh`)
- Python 3.9+ with boto3 installed
- AWS CLI configured with appropriate permissions

## Deploy

```bash
# Full deployment (Aurora, DMS, Kinesis, data load, schema sync, Firehose, start DMS)
./deploy.sh
```

## What the Deploy Script Does

1. **Deploys CloudFormation stack** — Aurora PostgreSQL, DMS replication instance/endpoints/task, Kinesis Data Streams, IAM roles (~15-20 minutes)
2. **Creates the source table and loads data** — Runs `load-data.py` to create the `customers` table with 2,000 records via Aurora Data API
3. **Syncs Aurora schema → S3 Tables** — Runs `sync-schema.py` to discover table schemas and create matching Iceberg tables
4. **Creates Firehose delivery stream** — Built via CLI (not CloudFormation) because `DestinationTableConfigurationList` is dynamically generated from `schema-mapping.json`
5. **Starts the DMS replication task** — Begins full-load + CDC

**Approximate time/cost:** deploy is ~20 minutes (Aurora + DMS provisioning dominate); data appears within ~2 minutes of the DMS task starting. Aurora (`db.r6g.large`), the DMS instance (`dms.r5.large`), and the 2 Kinesis shards bill continuously while running — run `teardown.sh` when you are done.

### Why Firehose is Created via CLI (Not CloudFormation)

The Firehose `DestinationTableConfigurationList` maps each Aurora table to its S3 Tables target with the correct upsert keys (primary keys). Since these are discovered dynamically by `sync-schema.py`, the Firehose must be created after schema sync completes. This is a deliberate design choice.

### Terraform vs CLI: destination-table-config divergence

In the Terraform path, the flow2 Firehose (`aws_kinesis_firehose_delivery_stream.flow2`) pins a single `destination_table_configuration` for the known `customers` table (keyed on `customer_id`). The CLI path builds `DestinationTableConfigurationList` dynamically from `schema-mapping.json`. This is a deliberate, documented divergence: Terraform describes the demo's known table statically, while the CLI stays schema-driven. If you add tables to Aurora, extend the Terraform resource to match.

## Schema Sync Tool (`sync-schema.py`)

The schema converter automatically mirrors Aurora PostgreSQL table structures into S3 Tables:

```bash
# Sync all tables in the public schema
python3 sync-schema.py

# Sync specific tables only
python3 sync-schema.py --tables customers

# Preview without creating (dry run)
python3 sync-schema.py --dry-run
```

**What it does:**
1. Connects to Aurora PostgreSQL via **RDS Data API** (not psql — Aurora is in a private subnet)
2. Reads `information_schema.columns` to discover table schemas
3. Reads `information_schema.table_constraints` to discover primary keys
4. Maps PostgreSQL types → Iceberg types
5. Creates matching S3 Tables in the `flow2_aurora` namespace
6. Outputs `schema-mapping.json` (used by `deploy.sh` to configure Firehose)

**Type mapping (PostgreSQL → Iceberg):**

| PostgreSQL | Iceberg |
|------------|---------|
| integer, serial | int |
| bigint, bigserial | long |
| real | float |
| double precision, numeric | double |
| boolean | boolean |
| varchar, text, char | string |
| date | date |
| timestamp | timestamp |
| timestamptz | timestamptz |
| bytea | binary |
| json, jsonb, uuid | string |

## How It Works

1. **Aurora PostgreSQL** cluster is created with logical replication enabled (required for DMS CDC).
2. **Aurora Data API** (`EnableHttpEndpoint`) is enabled so `sync-schema.py` and `load-data.py` can connect without direct network access (Aurora is in a private subnet).
3. **DMS Replication Task** performs a full-load of existing data, then captures ongoing changes via PostgreSQL logical replication.
4. DMS writes CDC events as JSON to **Kinesis Data Streams**.
5. **Amazon Data Firehose** reads from Kinesis and writes to S3 Tables using the Iceberg destination with upsert support (keyed on primary keys discovered by `sync-schema.py`).
6. Data lands as **Apache Iceberg tables** in the S3 Table Bucket.

## Validate

```bash
# Check DMS task status
REGION="$(aws configure get region)"   # the region you deployed into
aws dms describe-replication-tasks \
  --filters "Name=replication-task-id,Values=zero-etl-workshop-flow2-task" \
  --region "$REGION" \
  --query 'ReplicationTasks[0].{Status:Status,Progress:ReplicationTaskStats.FullLoadProgressPercent}'

# Check Firehose status
aws firehose describe-delivery-stream \
  --delivery-stream-name zero-etl-workshop-flow2-firehose \
  --region "$REGION" \
  --query 'DeliveryStreamDescription.DeliveryStreamStatus'

# Query data via Athena (S3 Tables catalog)
# Database: flow2_aurora
# Table: customers
```

## Teardown

```bash
./teardown.sh
```

## Key Configuration Details

| Setting | Value |
|---------|-------|
| Aurora Engine | aurora-postgresql 16.6 |
| Aurora Data API | Enabled (`EnableHttpEndpoint`) — required for private subnet access |
| Logical Replication | Enabled via parameter group |
| DMS Migration Type | full-load-and-cdc |
| DMS Target | Kinesis Data Streams (JSON) |
| DMS ParallelLoadThreads | Requires `ParallelLoadBufferSize` (50-1000) |
| Kinesis Shards | 2 (provisioned) |
| Firehose Source | Kinesis Data Streams |
| Firehose Destination | Iceberg (S3 Tables) |
| Firehose Buffer | 60s / 128MB |
| Upsert Keys | Auto-detected from PG primary keys |
| Schema Sync | `sync-schema.py` (PG → Iceberg type mapping) |

## Key Learnings & Gotchas

### Firehose CatalogARN must use the sub-catalog ARN

The Firehose `CatalogConfiguration.CatalogArn` **must** use the S3 Tables sub-catalog ARN format:

```
arn:aws:glue:<region>:<account>:catalog/s3tablescatalog/<bucket-name>
```

Not the top-level catalog ARN (`arn:aws:glue:<region>:<account>:catalog`). Using the wrong ARN will cause Firehose to fail to find the target database/tables.

### Lake Formation permissions needed on the sub-catalog

Lake Formation permissions must be granted on the `s3tablescatalog` sub-catalog for the Firehose role. Without this, Firehose will get access denied when trying to write to S3 Tables.

### cfnresponse module removed from Python 3.12+ Lambda runtimes

If using CloudFormation custom resources with Lambda, the `cfnresponse` module is no longer bundled in Python 3.12+ runtimes. Use `urllib3` (or `urllib.request`) to send responses to the CloudFormation pre-signed URL instead.

### DMS ParallelLoadThreads requires ParallelLoadBufferSize

When configuring DMS `ParallelLoadThreads`, you **must** also set `ParallelLoadBufferSize` (valid range: 50-1000). Omitting it causes DMS task failures.

### Aurora Data API is required for private subnet access

Since Aurora is deployed in private subnets (no public access), the Data API (`EnableHttpEndpoint`) must be enabled. This allows `sync-schema.py` and `load-data.py` to query Aurora via the AWS API without needing a bastion host or VPN.

### DMS control records will fail in Firehose — this is normal

DMS sends control records (`create-table`, `drop-table` metadata) through Kinesis. These records don't match any Iceberg table schema and will land in the Firehose **error bucket** (`flow2-errors/` prefix). This is expected behavior and does not indicate a problem with data replication.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Firehose fails with "database not found" | Wrong CatalogARN format | Use sub-catalog ARN: `arn:aws:glue:region:account:catalog/s3tablescatalog/bucket-name` |
| Firehose access denied on write | Missing Lake Formation permissions | Grant permissions on `s3tablescatalog` sub-catalog for Firehose role |
| DMS task fails on start | `ParallelLoadBufferSize` not set | Add `ParallelLoadBufferSize` (50-1000) alongside `ParallelLoadThreads` |
| `sync-schema.py` can't connect to Aurora | Data API not enabled | Ensure `EnableHttpEndpoint: true` on Aurora cluster |
| cfnresponse import error in Lambda | Python 3.12+ runtime | Replace `cfnresponse` with `urllib3` or `urllib.request` |
| Records in Firehose error bucket | DMS control records (create-table, drop-table) | Normal — these are metadata records, not data failures |
| `schema-mapping.json` not found | `sync-schema.py` not run before Firehose creation | Run `sync-schema.py` first, then create Firehose |
| Firehose not in CloudFormation | By design — dynamic table config | Firehose is created via CLI after schema sync; teardown script handles cleanup |
