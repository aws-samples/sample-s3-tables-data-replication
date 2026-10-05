# S3 Table Buckets Data Replication Workshop

Three sample flows demonstrating different ways to replicate data into Amazon S3 Table Buckets (Apache Iceberg).

## Flows

| Flow | Source | Pipeline | Target |
|------|--------|----------|--------|
| **1** | DynamoDB | AWS Glue Zero-ETL | S3 Tables |
| **2** | Aurora PostgreSQL | DMS → Kinesis Data Streams → Lambda Transform → Amazon Data Firehose | S3 Tables |
| **3** | Amazon DocumentDB | Change Streams → Lambda → Amazon Data Firehose | S3 Tables |

## Architecture

All three flows run inside one shared VPC and land in one shared S3 Table Bucket (Apache Iceberg), each in its own namespace. Flow 1 is a managed Glue integration (no VPC data path); flows 2 and 3 stream change data out of VPC-resident databases.

```
   Shared infrastructure: one VPC (2 public + 2 private subnets, NAT gateway),
   one S3 Table Bucket, one error S3 bucket. All three flows deploy into it.

   FLOW 1  (managed Glue Zero-ETL — no VPC data path)
   ┌─────────────┐   PITR-based export
   │  DynamoDB   │ ─────────────────────────────┐
   │  (orders)   │                               │
   └─────────────┘                               │
                                                 ▼
   FLOW 2  (in VPC)                      ┌────────────────────────────────┐
   ┌─────────────┐  DMS    ┌──────────┐  │   S3 Table Bucket (Iceberg)    │
   │   Aurora    │ full +  │ Kinesis  │  │                                │
   │ PostgreSQL  │──CDC──▶ │  Data    │  │  zetl_<id>        (flow1)      │
   │ (customers) │         │ Streams  │  │  flow2_aurora.customers        │
   └─────────────┘         └────┬─────┘  │  flow3_docdb.products          │
                                │        └────────────────────────────────┘
                       Lambda transform             ▲        │
                       (flatten DMS record)         │        │
                                │                   │        ▼
                                └──▶ Firehose ──────┘  Query via Amazon Athena
                                                       (Glue Data Catalog +
   FLOW 3  (in VPC)                                     Lake Formation grant)
   ┌─────────────┐  change  ┌───────────┐
   │ DocumentDB  │ stream   │  Lambda   │
   │ (products)  │─(ESM)──▶ │ processor │──▶ Firehose (Direct PUT) ──▶ S3 Tables
   └─────────────┘          └───────────┘

   Firehose delivery errors (flows 2 & 3) ──▶ shared error S3 bucket
```

Legend: `λ xform` = Lambda transform that flattens the DMS record wrapper (flow 2 only). `ESM` = Lambda Event Source Mapping reading DocumentDB change streams. Each flow writes to its own namespace in the single shared table bucket, so the three can be deployed and torn down independently.

## Prerequisites

- AWS CLI v2 configured with credentials.
- **Region: pick one supported region and set it before deploying.** All three flows write to Amazon S3 Tables and Flow 1 uses AWS Glue zero-ETL-to-S3-Tables, so you must deploy to a region where **both** features are available — for example `us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`, `ap-northeast-1`, among others (confirm current availability: [S3 Tables regions](https://aws.amazon.com/s3/features/tables/) and [Glue zero-ETL supported regions](https://docs.aws.amazon.com/glue/latest/dg/zero-etl-supported-regions.html)). The whole stack deploys into a single region. Set it once and everything follows it:
  - **CLI / CloudFormation path:** `aws configure set region <region>` (or `export AWS_REGION=<region>`). The deploy/teardown scripts read your configured region and **fail with a clear message if none is set** — they no longer silently assume `us-east-1`.
  - **Terraform path:** pass `-var region=<region>` or set `TF_VAR_region=<region>` (the `region` variable has no default, so the choice is deliberate). Make sure your AWS CLI points at the same region, since the `local-exec` steps shell out to `aws`.
- Python 3.9+ installed.
- **IAM permissions (least-privilege, not Admin).** The deployer needs permission to create and manage, in this account/region, the resources below. Prefer a scoped role over `AdministratorAccess`:
  - CloudFormation: create/update/delete stacks.
  - IAM: create/update/delete the roles and policies the templates define (DMS, Firehose, Lambda, Glue target roles) and pass them to services (`iam:PassRole`).
  - Glue: Zero-ETL integrations, resource policy, catalog operations (`glue:*Integration*`, `glue:PutResourcePolicy`, `glue:GetTable`).
  - DMS: replication instance, endpoints, task, start/stop.
  - Amazon Data Firehose: create/describe/delete delivery streams.
  - Lambda: create/update/delete functions, event source mappings.
  - RDS / Aurora: create/manage the Aurora PostgreSQL cluster + RDS Data API.
  - Amazon DocumentDB: create/manage the cluster and parameter group.
  - S3 and S3 Tables: table bucket + error bucket, `s3tables:*Table*`/`*Namespace*` on the workshop bucket.
  - Lake Formation: data-lake admin (to grant the Firehose/Glue roles) — see the setup.sh warning below.
  - Athena: run queries to verify data.
  - Secrets Manager: create/read the DB credential secrets.
  - EC2 / VPC: VPC, subnets, NAT gateway, security groups.
- **Flow 1 only**: Account must allow `dynamodb:PutResourcePolicy` (some SCPs block this).
- **`setup.sh` makes account-wide changes.** It configures Lake Formation and creates account-level IAM roles (`dms-vpc-role`, `S3TablesRoleForLakeFormation`) and the `s3tablescatalog` federated catalog. These affect the whole account, not just this workshop. `setup.sh` now **appends** your caller role to the Lake Formation data-lake-admin list (read-modify-write) rather than overwriting it, so it will not clobber existing admins — but review it before running in a shared account.
- **Database password (required, no default)**: Flow 2 (Aurora) and Flow 3 (DocumentDB) need a master password. No password ships in the templates. You must supply one:
  - CloudFormation: `export DB_PASSWORD='<your-strong-password>'` before running `flow2-.../deploy.sh` and `flow3-.../deploy.sh`. The scripts pass it to CloudFormation and fail fast if it is unset. Minimum length is 8 characters.
  - Terraform: `export TF_VAR_db_password='<your-strong-password>'` (or pass `-var db_password=...`) before `terraform plan/apply`.
  - The value is only used to create the clusters and their Secrets Manager secrets; loaders read the secret by ARN. Never commit a real password.

## Quick Start (Full Deployment)

```bash
# 1. One-time account setup (DMS role, Lake Formation, S3 Tables catalog, Python venv)
./setup.sh

# 2. Deploy shared infrastructure (VPC, S3 Table Bucket, error bucket)
./shared/deploy.sh

# 3. Deploy each flow
source .venv/bin/activate

# Flows 2 and 3 require a DB master password (no default is shipped).
# Set it once in your shell; deploy.sh fails fast if it is missing.
export DB_PASSWORD='<your-strong-password>'  # min 8 chars; do not commit

# Flow 1: DynamoDB → Glue Zero-ETL (~5 min deploy, ~15 min for initial export)
./flow1-dynamodb-glue/deploy.sh

# Flow 2: Aurora PG → DMS → Kinesis → Firehose (~20 min deploy)
./flow2-aurora-dms-kinesis/deploy.sh

# Flow 3: DocumentDB → Lambda → Firehose (~15 min deploy)
./flow3-docdb-lambda/deploy.sh
```

## Step-by-Step Manual Deployment

### Step 0: Pre-Flight Setup (once per account)

```bash
./setup.sh
```

This creates:
- `dms-vpc-role` IAM role (required by DMS)
- Lake Formation admin configuration
- `S3TablesRoleForLakeFormation` IAM role with hybrid access enabled
- `s3tablescatalog` federated catalog in AWS Glue
- Python virtual environment with boto3

### Step 1: Shared Infrastructure

```bash
./shared/deploy.sh
```

Creates: VPC (2 public + 2 private subnets, NAT Gateway), S3 Table Bucket, error S3 bucket for Firehose.

### Step 2: Flow 1 — DynamoDB → Glue Zero-ETL → S3 Tables

```bash
source .venv/bin/activate

# Deploy DynamoDB table + IAM role, configure Glue integration
./flow1-dynamodb-glue/deploy.sh

# Load 2,000 sample orders
python3 flow1-dynamodb-glue/load-data.py
```

**What deploy.sh does:**
1. Deploys CFN stack (DynamoDB table with PITR, Glue target IAM role)
2. Sets Glue catalog resource policy with `--enable-hybrid TRUE`
3. Sets `IntegrationResourceProperty` on the S3 Tables **catalog** ARN (not a database)
4. Sets `IntegrationTableProperties` for the DynamoDB table
5. Creates the Glue Zero-ETL integration targeting the catalog

**Wait ~15-20 minutes** for the initial DynamoDB PITR export to complete. Glue auto-creates a `zetl_<integration-id>` namespace with the replicated table.

### Step 3: Flow 2 — Aurora PostgreSQL → DMS → Kinesis → Firehose → S3 Tables

```bash
source .venv/bin/activate

# Deploy Aurora, DMS, Kinesis, load data, sync schema, create Firehose, start DMS
./flow2-aurora-dms-kinesis/deploy.sh
```

**What deploy.sh does:**
1. Deploys CFN stack (Aurora PG with Data API + logical replication, DMS, Kinesis, Firehose IAM role, Lambda transform, Lake Formation grant custom resource)
2. Loads 2,000 sample customers via RDS Data API
3. Runs `sync-schema.py` to read Aurora schema and create matching S3 Tables
4. Creates Firehose delivery stream via CLI with:
   - `CatalogARN` pointing to the S3 Tables sub-catalog
   - `ProcessingConfiguration` with Lambda transform (flattens DMS record wrapper)
   - `DestinationTableConfigurationList` built from schema mapping
5. Starts DMS replication task

**If Firehose creation fails** with `glue:GetTable` error: Lake Formation permissions may not have propagated. Wait 30 seconds and re-run the deploy script (it's idempotent — skips already-created resources).

### Step 4: Flow 3 — DocumentDB → Lambda → Firehose → S3 Tables

```bash
source .venv/bin/activate

# Deploy DocumentDB, Lambda, create Firehose
./flow3-docdb-lambda/deploy.sh

# Load 2,000 sample products (uses temporary Lambda in VPC)
python3 flow3-docdb-lambda/load-data.py
```

**What deploy.sh does:**
1. Creates S3 Tables namespace and products table
2. Deploys CFN stack (DocumentDB with change streams parameter, Lambda processor in VPC, `EnableChangeStreams` custom resource, Lake Formation grant custom resource)
3. Creates Firehose delivery stream (Direct PUT) via CLI

**Note:** Data loaded before the ESM is active won't trigger change streams. The `load-data.py` script loads initial data. To see data flow through to S3 Tables, insert additional records after the ESM shows `State: Enabled`.

### Step 5: Verify Data

```bash
# Set these once to match the region you deployed into.
REGION="$(aws configure get region)"   # or: REGION=us-west-2
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CATALOG="s3tablescatalog/zero-etl-workshop-tables-${ACCOUNT_ID}"
OUTPUT="s3://zero-etl-workshop-errors-${ACCOUNT_ID}/athena-results/"

# Check Flow 1 integration status
aws glue describe-integrations --region "$REGION" \
  --query "Integrations[?contains(IntegrationName,'flow1')].{Name:IntegrationName,Status:Status}" --output table

# Flow 1 (find the zetl_ namespace first)
aws s3tables list-namespaces \
  --table-bucket-arn "arn:aws:s3tables:${REGION}:${ACCOUNT_ID}:bucket/zero-etl-workshop-tables-${ACCOUNT_ID}" \
  --region "$REGION" --query "namespaces[?starts_with(namespace[0],'zetl_')].namespace[0]" --output text

# Flow 2
aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM customers" \
  --query-execution-context "{\"Database\":\"flow2_aurora\",\"Catalog\":\"${CATALOG}\"}" \
  --result-configuration "{\"OutputLocation\":\"${OUTPUT}\"}" --region "$REGION"

# Flow 3
aws athena start-query-execution \
  --query-string "SELECT COUNT(*) FROM products" \
  --query-execution-context "{\"Database\":\"flow3_docdb\",\"Catalog\":\"${CATALOG}\"}" \
  --result-configuration "{\"OutputLocation\":\"${OUTPUT}\"}" --region "$REGION"
```

**Note — Athena needs an explicit Lake Formation table grant.** Being a Lake Formation *admin* (which `setup.sh` makes you) does **not** by itself allow `SELECT` on a table; LF requires an explicit grant to the querying principal. If an Athena query fails with `Insufficient permissions ... does not have any privilege on specified resource`, grant your user/role read access on the namespace, then re-run:

```bash
CATALOG_ID="${ACCOUNT_ID}:s3tablescatalog/zero-etl-workshop-tables-${ACCOUNT_ID}"
MY_PRINCIPAL=$(aws sts get-caller-identity --query Arn --output text | sed 's|assumed-role/\(.*\)/.*|role/\1|; s|:sts:|:iam:|')
for NS in flow2_aurora flow3_docdb; do
  aws lakeformation grant-permissions \
    --principal "DataLakePrincipalIdentifier=${MY_PRINCIPAL}" \
    --resource "{\"Table\":{\"CatalogId\":\"${CATALOG_ID}\",\"DatabaseName\":\"${NS}\",\"TableWildcard\":{}}}" \
    --permissions SELECT DESCRIBE --region "$REGION"
done
```
(For a `zetl_*` flow1 namespace, substitute its discovered name.)

## Terraform (alternative IaC path)

> **Two equivalent IaC paths.** This workshop ships both **CloudFormation** (`*/template.yaml` + bash `deploy.sh`/`teardown.sh`) and **Terraform** (`terraform/`). They provision the same architecture and are kept in parity. Both have been exercised in a test account; pick whichever your team prefers. The Terraform path was verified end-to-end (deploy + load + teardown) in a non-`us-east-1` region to confirm region portability. Whichever path you choose, **run `setup.sh` first** (see the required-first-step box below).

> ⚠️ **REQUIRED FIRST STEP — run `setup.sh` once per account/region before `terraform apply`.** The Terraform does **not** create the account-level prerequisites and will **fail partway** without them (Aurora/DMS/DocDB come up, then the Firehose streams fail with `Role ... is not authorized to perform: glue:GetTable` / `Database not found`). `setup.sh` creates these one-time, account-global resources that both IaC paths depend on:
> - **`dms-vpc-role`** — the account role AWS DMS requires to manage replication-instance networking. Without it, the DMS subnet group fails with `dms-vpc-role is not configured properly`.
> - **Lake Formation data-lake admin** — adds your caller as an LF admin (additive) so LF grants are allowed.
> - **`S3TablesRoleForLakeFormation` + S3 Tables ↔ Lake Formation federation registration** (`register-resource --with-federation`). This is what makes the S3 Tables namespaces (`flow2_aurora`, `flow3_docdb`) resolvable as Lake Formation databases. Without it, the Firehose roles' LF grants fail with `Database not found`, and Firehose creation then fails the `glue:GetTable` check.
>
> ```bash
> aws configure set region <your-region>   # or export AWS_REGION
> ./setup.sh                                 # idempotent; safe to re-run
> ```
>
> These are account-global singletons (fixed names, one per account/region) and are intentionally **not** managed by Terraform so repeated or parallel deployments don't fight over ownership. Run `setup.sh` first; then `terraform apply`.

The Terraform is a **single composed root module** at `terraform/`. The shared infrastructure and the three flows are child modules under one state, so you run **one** `init`/`plan`/`apply` for everything and the shared outputs (VPC, subnets, table bucket, error bucket) are wired into the flow modules automatically — you do not deploy modules one at a time.

```bash
cd terraform

# project_name must be UNIQUE per deployment (resource names derive from it;
# a random suffix is appended internally so repeated applies stay stable).
# db_password is REQUIRED — there is no default anywhere.
export TF_VAR_db_password='<your-strong-password>'   # min 8 chars; do not commit

terraform init
terraform plan  -var 'project_name=zero-etl-ev-<unique>'
terraform apply -var 'project_name=zero-etl-ev-<unique>'
```

See `terraform/example.tfvars` for a starting point (contains a non-secret placeholder; supply `db_password` via `TF_VAR_db_password` or `-var`, never a committed literal).

What the Terraform now covers (parity with the CloudFormation path):

- **flow2 and flow3 Firehose delivery streams** are created in Terraform (`aws_kinesis_firehose_delivery_stream`) with the Iceberg destination — previously these existed only in the CLI deploy scripts.
- The **flow1 Glue Zero-ETL integration** is created from Terraform via a documented `null_resource` with a `local-exec` provisioner that wraps the same `aws glue` calls as `flow1/deploy.sh` (there is no GA native resource for the DynamoDB → S3 Tables integration).
- The **flow2/flow3 S3 Tables namespaces** the Firehose streams target are managed natively in Terraform (`aws_s3tables_namespace`: `flow2_aurora`, `flow3_docdb`). The **tables** themselves (`customers`, `products`) are created via a documented `null_resource`/`local-exec` — see the known limitation below.
- `project_name`, `db_password`, and `region` are **required root variables with no default** — set `region` to a supported region (see Prerequisites) via `-var region=<region>` or `TF_VAR_region`.

A commented `backend "s3"` example is included in `terraform/main.tf`. If you prefer per-flow state over the composed root, you could instead split the modules and wire shared outputs with `terraform_remote_state` — the composed root module is the chosen and documented approach.

#### Known limitation — S3 Tables table schema is created via the AWS CLI, not the native resource

The Iceberg **table** resources (`flow2_aurora.customers`, `flow3_docdb.products`) are **not** created with the native `aws_s3tables_table` resource. In the pinned `hashicorp/aws` provider (5.x), that resource accepts only `name`, `namespace`, `table_bucket_arn`, and `format` — it has **no argument for the Iceberg column schema** (field names/types). Column-schema support ("schemaV2") is slated for a later provider release ([terraform-provider-aws#47601](https://github.com/hashicorp/terraform-provider-aws/issues/47601)). Because flow2/flow3 need an explicit schema so the Firehose Iceberg sink and the Athena queries match the documented columns, each flow module creates its table with a `null_resource` + `local-exec` that calls `aws s3tables create-table --metadata '{...}'`. This is **behavior-identical to the tested CloudFormation/CLI path** (`flow3/deploy.sh`) and reuses the same `null_resource` pattern as the flow1 Glue integration.

Implications for the person verifying/applying:
- The AWS CLI must be installed and authenticated to the **same region you pass as `-var region=`** on whatever host runs `terraform apply` (the `local-exec` shells out to `aws` and passes `--region ${var.region}`).
- `terraform plan` will show the table as a `null_resource`, **not** as a managed `aws_s3tables_table` — the table only truly exists after `apply` runs the provisioner. Verify the table end-to-end via Athena.
- To change a table's schema, edit the `--metadata` JSON in the module and bump the `schema_version` trigger so the resource is recreated.
- **Revisit** once the provider ships schema support and the project pins that version — the `null_resource` can then be replaced with the native resource.

Verify (Terraform `fmt`/`init -backend=false`/`validate` have been run and pass; `plan`/`apply` must be run in a disposable test account, in a supported region):

```bash
cd terraform
terraform fmt -recursive
terraform init -backend=false
terraform validate
```

## Costs & Cleanup

This workshop provisions several **always-on, billable** resources. They bill for as long as they exist, independent of whether data is flowing:

| Resource | Flow | Notes |
|----------|------|-------|
| Aurora PostgreSQL `db.r6g.large` | 2 | Running cluster; the largest line item |
| DMS replication instance `dms.r5.large` | 2 | Billed while the instance exists |
| Kinesis Data Streams — 2 provisioned shards | 2 | Per-shard-hour billing |
| Amazon DocumentDB `db.r6g.large` | 3 | Running cluster |
| NAT gateway (+ Elastic IP) | shared | Per-hour + data processing |
| S3 Table Bucket + error bucket | all | Storage + request costs (small) |
| Firehose delivery streams | 2, 3 | Per-GB ingested (small for 2,000 records) |

As a rough order of magnitude, the Aurora + DMS + DocumentDB + NAT combination can run on the order of **tens of US dollars per day** if left running (varies by region). Treat this as workshop-only and **tear everything down when finished.**

### Teardown

Tear down in reverse order (CloudFormation path):

```bash
./flow3-docdb-lambda/teardown.sh    # ~10 min (DocumentDB deletion)
./flow2-aurora-dms-kinesis/teardown.sh  # ~15 min (Aurora + DMS deletion)
./flow1-dynamodb-glue/teardown.sh   # ~2 min
./shared/teardown.sh                # ~2 min
```

For the Terraform path, a single `cd terraform && terraform destroy -var 'project_name=<the-one-you-applied>'` (with `TF_VAR_db_password` set) removes everything in the composed root; the flow1 Glue integration is best-effort deleted by the `null_resource` destroy provisioner.

### Verify nothing remains

After teardown, confirm these are gone (leftovers keep billing):

```bash
REGION="$(aws configure get region)"   # the region you deployed into
aws rds describe-db-clusters --region "$REGION" --query "DBClusters[].DBClusterIdentifier"
aws dms describe-replication-instances --region "$REGION" --query "ReplicationInstances[].ReplicationInstanceIdentifier"
aws dms describe-replication-tasks --region "$REGION" --query "ReplicationTasks[].ReplicationTaskIdentifier"
aws docdb describe-db-clusters --region "$REGION" --query "DBClusters[].DBClusterIdentifier"
aws kinesis list-streams --region "$REGION"
aws ec2 describe-nat-gateways --region "$REGION" --filter "Name=state,Values=available" --query "NatGateways[].NatGatewayId"
aws ec2 describe-addresses --region "$REGION" --query "Addresses[].AllocationId"
aws firehose list-delivery-streams --region "$REGION"
aws s3 ls | grep zero-etl
aws iam list-roles --query "Roles[?contains(RoleName,'zero-etl')].RoleName"
aws glue describe-integrations --region "$REGION" --query "Integrations[?contains(IntegrationName,'flow1')].IntegrationName"
```

Also review Lake Formation grants (`aws lakeformation list-permissions --region "$REGION"`) and remove any workshop grants left behind. The account-wide roles created by `setup.sh` (`dms-vpc-role`, `S3TablesRoleForLakeFormation`) and the `s3tablescatalog` catalog are **not** removed by the per-flow teardown scripts — delete them manually if you no longer need them.

> **Teardown ordering note.** Run the flow teardowns before `shared/teardown.sh`. The shared stack delete can fail once with `DELETE_FAILED` on `TableBucket` ("bucket not empty") or `PrivateSubnet` ("has dependencies") if the flow teardowns' S3 Tables namespace cleanup and the DMS/Lambda/DocDB ENI releases haven't fully propagated yet (a few seconds–minutes). This is a timing race, not a stuck resource — simply **re-run the delete** once the namespaces are gone and the ENIs released:
> ```bash
> aws cloudformation delete-stack --stack-name zero-etl-workshop-shared --region "$REGION"
> aws cloudformation wait stack-delete-complete --stack-name zero-etl-workshop-shared --region "$REGION"
> ```

## Security Notes

- **Database password is supplied at deploy time — there is no default.** No credential ships in any template, script, or `.tfvars`. CloudFormation reads it from `DB_PASSWORD` (deploy scripts fail fast if unset); Terraform reads it from `TF_VAR_db_password` (or `-var db_password=...`). The value only populates the Aurora/DocumentDB clusters and their Secrets Manager secrets; the loaders and schema tools read the secret by ARN. This is a **workshop-only** credential — use a throwaway strong password and never commit a real value.
- **Two IaC paths, kept in parity:** CloudFormation (`template.yaml` + bash scripts) and Terraform (`terraform/`) provision the same architecture. Both have been exercised in a test account. Use whichever your team prefers — do not run both in the same account/region at once (they share account-global `setup.sh` resources and would collide on names/Lake Formation state).
- **`setup.sh` touches account-wide Lake Formation and IAM.** It appends your caller to the LF data-lake-admin list (additive read-modify-write) and creates account-level roles/catalog. Review before running in a shared account.

## Project Structure

```
zero-etl/
├── README.md                       # This file
├── WORKSHOP_PROMPT.md              # Original workshop requirements
├── setup.sh                        # One-time account setup
├── shared/                         # VPC, S3 Table Bucket, error bucket
│   ├── template.yaml
│   ├── deploy.sh
│   └── teardown.sh
├── flow1-dynamodb-glue/            # DynamoDB → Glue Zero-ETL → S3 Tables
│   ├── template.yaml
│   ├── deploy.sh
│   ├── teardown.sh
│   ├── load-data.py
│   └── README.md
├── flow2-aurora-dms-kinesis/       # Aurora PG → DMS → Kinesis → Firehose → S3 Tables
│   ├── template.yaml
│   ├── deploy.sh
│   ├── teardown.sh
│   ├── load-data.py
│   ├── sync-schema.py              # Auto-discovers Aurora schema → creates S3 Tables
│   └── README.md
├── flow3-docdb-lambda/             # DocumentDB → Change Streams → Lambda → Firehose → S3 Tables
│   ├── template.yaml
│   ├── deploy.sh
│   ├── teardown.sh
│   ├── load-data.py
│   └── README.md
└── terraform/                      # Alternative IaC path (composed root module, one state)
    ├── main.tf                     # Root: provider, modules shared/flow1/flow2/flow3
    ├── variables.tf                # region, project_name (required), db_password (required)
    ├── outputs.tf
    ├── example.tfvars              # Non-secret placeholders
    ├── shared/                     # Child module: VPC, S3 Table Bucket, error bucket
    ├── flow1-dynamodb-glue/        # Child module: DynamoDB + Glue Zero-ETL (null_resource)
    ├── flow2-aurora-dms-kinesis/   # Child module: Aurora/DMS/Kinesis/Firehose
    └── flow3-docdb-lambda/         # Child module: DocumentDB/Lambda/Firehose
```

## Known Issues & Workarounds

| Issue | Workaround |
|-------|-----------|
| SCP blocks `dynamodb:PutResourcePolicy` | Flow 1 requires this. Ask account admin to allow it, or skip Flow 1. |
| Firehose `glue:GetTable` error on creation | Lake Formation permission propagation delay. Wait 30s and retry `deploy.sh`. |
| Flow 1 table not visible immediately | Glue Zero-ETL initial export takes 15-20 minutes. Check with `aws glue describe-integrations`. |
| Flow 3 shows 0 rows after deploy | ESM set to LATEST — only new inserts after ESM is active are captured. Insert more data. |
| Athena query `Insufficient permissions` | LF admin ≠ table SELECT. Grant your querying principal `SELECT`/`DESCRIBE` on the namespace (see the Verify section's grant snippet). |
| Firehose records land in the error bucket with `Lakeformation.AccessDenied` | The LF grant to the Firehose role had not propagated when those records arrived. On a clean `setup.sh`-first deploy the grant lands before data flows. Records that already errored are not retried; re-insert, or re-drive the source after the grant is confirmed. |
| Records loaded into the source don't appear in `flow2_aurora.customers` | DMS full-load pushes to Kinesis; from there Kinesis → Lambda transform → Firehose → Iceberg each buffer (Firehose ~60s). Allow a few minutes. If still absent, check the flow2 transform Lambda's CloudWatch logs and the Firehose `IncomingRecords`/error-bucket for the specific failure. |

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for information on reporting a potential security issue. Do not create a public GitHub issue for security findings.

## License

This library is licensed under the Apache-2.0 License. See the [LICENSE](LICENSE) file.
