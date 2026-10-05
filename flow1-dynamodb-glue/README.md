# Flow 1: DynamoDB → Glue Zero-ETL → S3 Tables

## Architecture

Flow 1 is a fully managed AWS Glue Zero-ETL integration — there is no VPC, no streaming service, and no Lambda in the data path. Glue performs a point-in-time (PITR) export of the DynamoDB table into the S3 Table Bucket and keeps it refreshed.

```
   ┌─────────────────────┐
   │   DynamoDB table     │
   │     (orders)         │   PITR enabled
   │   on-demand + PITR    │
   └──────────┬──────────┘
              │
              │  AWS Glue Zero-ETL integration
              │  (PITR-based export; initial export ~15-20 min)
              ▼
   ┌─────────────────────────────────────────────┐
   │            S3 Table Bucket (Iceberg)          │
   │                                               │
   │   zetl_<integration-id>   ← namespace auto-   │
   │        └── <source-table>    created by Glue  │
   └──────────────────────┬──────────────────────┘
                          │
                          ▼
                 Query with Amazon Athena
                 (Glue Data Catalog + Lake Formation grant)
```

Note: the `zetl_<integration-id>` namespace name is assigned by Glue — it is **not** a fixed name you choose. Discover it after the export completes (see "Validate" below).

## Prerequisites

- Shared infrastructure deployed (`shared/deploy.sh`)
- Python 3.9+ with boto3 installed
- AWS CLI configured with appropriate permissions

## Deploy

```bash
# 1. Deploy infrastructure and create the Zero-ETL integration
./deploy.sh

# 2. Load sample data (2,000 orders)
python3 load-data.py
```

**Approximate time/cost:** deploy is ~5 minutes; the initial PITR export takes ~15-20 minutes before data appears. DynamoDB (PITR + on-demand) and the Glue Zero-ETL integration bill while they exist — run `teardown.sh` when you are done.

## What the Deploy Script Does

1. **Deploys CloudFormation** — DynamoDB table with PITR enabled and a resource-based policy granting Glue access.
2. **Sets Glue catalog resource policy** with `--enable-hybrid TRUE` — required for S3 Tables catalog integration.
3. **Sets IntegrationResourceProperty** — configures the IAM role on the S3 Tables **catalog** (`--target-processing-properties '{"RoleArn":...}'`), not on a database.
4. **Sets IntegrationTableProperties** — passes `--target-table-config ''` (empty) for the DynamoDB source table.
5. **Creates the Glue Zero-ETL integration** — connects the DynamoDB source to the S3 Tables catalog target.

The script does **not** run `create-database`; Glue auto-creates a `zetl_<integration-id>` namespace for the replicated table.

## How It Works

1. **DynamoDB Table** is created with Point-in-Time Recovery (PITR) enabled and a resource-based policy granting AWS Glue access.
2. **Glue Zero-ETL Integration** connects the DynamoDB table to the S3 Tables catalog.
3. Glue performs a **full export** using DynamoDB's ExportTableToPointInTime (PITR) API. This takes **15-20 minutes**.
4. The integration is **PITR export-based** — refreshes are driven by Glue re-exporting from PITR, not by DynamoDB Streams. DynamoDB Streams is not enabled in this workshop, so there is no stream-based incremental CDC.
5. Data lands as **Apache Iceberg tables** in the S3 Table Bucket, under a Glue-managed `zetl_<integration-id>` namespace.

## Validate

After the integration reaches ACTIVE status and initial sync completes (~15-20 minutes):

```bash
# Set REGION to the region you deployed into (these commands are region-agnostic).
REGION="$(aws configure get region)"

# Check integration status (note: the CLI command is describe-integrations, NOT list-integrations)
aws glue describe-integrations --region "$REGION" \
  --query "Integrations[?contains(IntegrationName,'flow1')].{Name:IntegrationName,Status:Status}" \
  --output table

# Discover the Glue-created namespace. Glue auto-creates a zetl_<integration-id>
# namespace — it is NOT a fixed name you choose.
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws s3tables list-namespaces \
  --table-bucket-arn "arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/zero-etl-workshop-tables-${ACCOUNT_ID}" \
  --region "$REGION" \
  --query "namespaces[?starts_with(namespace[0],'zetl_')].namespace[0]" --output text
```

Then query the discovered namespace via Amazon Athena (substitute the real `zetl_<integration-id>` namespace and the replicated table name):
```sql
SELECT * FROM "zetl_<integration-id>"."<source-table>" LIMIT 10;
```

## Teardown

```bash
./teardown.sh
```

## Key Configuration Details

| Setting | Value |
|---------|-------|
| DynamoDB PITR | Required for the Zero-ETL export |
| DynamoDB Resource Policy | Grants `glue.amazonaws.com` export access |
| Target Table Config | `--target-table-config ''` (empty) passed to `create-integration-table-properties` |
| Refresh Model | PITR export-based (no DynamoDB Streams / stream CDC) |
| Initial Export Time | 15-20 minutes |
| Target Catalog | `s3tablescatalog/<table-bucket-name>` |
| Target Namespace | Glue-created `zetl_<integration-id>` (not a fixed name) |

## Key Learnings & Gotchas

### Target database must exist in the DEFAULT Glue catalog

The Glue Zero-ETL integration target ARN uses the **short format** that references the default catalog:

```
arn:aws:glue:<region>:<account>:database/<dbName>
```

Not the S3 Tables catalog-qualified format. The database is created under the S3 Tables catalog (`CATALOG_ID="${ACCOUNT_ID}:s3tablescatalog/${TABLE_BUCKET_NAME}"`), but the target ARN for `create-integration` uses the short form.

### Glue resource policy needs `--enable-hybrid TRUE`

When setting the Glue catalog resource policy via `put-resource-policy`, you **must** include the `--enable-hybrid TRUE` flag. Without it, the policy won't work with S3 Tables catalog resources:

```bash
aws glue put-resource-policy \
  --policy-in-json "$POLICY" \
  --enable-hybrid TRUE \
  --region "$REGION"
```

### CLI command is `describe-integrations` (not `list-integrations`)

To check integration status, use:
```bash
aws glue describe-integrations --region "$REGION"
```

There is no `list-integrations` command in the Glue CLI.

### Initial export takes 15-20 minutes

The first sync is a full PITR export from DynamoDB. Be patient — the integration will show as `ACTIVE` but data won't appear in S3 Tables until the export completes. You can monitor progress in the Glue console under Zero-ETL integrations.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `create-integration` fails with access denied | Resource policy missing or `--enable-hybrid TRUE` not set | Re-run `put-resource-policy` with `--enable-hybrid TRUE` |
| Integration stuck in CREATING | Initial PITR export in progress | Wait 15-20 minutes; check Glue console for progress |
| No data in Athena after 20+ minutes | Integration may have failed | Check `describe-integrations` for error details |
| `list-integrations` command not found | Wrong CLI command | Use `describe-integrations` instead |
| Target ARN validation error | Using long-form catalog ARN | Use short format: `arn:aws:glue:region:account:database/dbName` |
| Integration target not found | Wrong catalog on `create-integration` | Target the S3 Tables sub-catalog ARN; deploy.sh does not pre-create a database — Glue creates the `zetl_<integration-id>` namespace itself |
