# S3 Table Buckets Data Replication Workshop — Build Prompt

## Goal

Create three isolated, deployable sample data replication flows into a shared Amazon S3 Table Bucket for a customer workshop. Each flow demonstrates a different source database replicating data into S3 Tables (Apache Iceberg). The deliverables must be ready for **live deployment** during the workshop.

## Region

Any region where **both** Amazon S3 Tables and AWS Glue zero-ETL-to-S3-Tables are available (e.g. `us-east-1`, `us-east-2`, `us-west-2`, `eu-west-1`, `ap-northeast-1`). The stack deploys into a single region of the operator's choice — set it via `aws configure set region <region>` / `AWS_REGION` (CLI path) or `-var region=<region>` / `TF_VAR_region` (Terraform path). (Originally built and tested in `us-east-1`.)

## Flows

### Flow 1: DynamoDB → S3 Tables (Glue Zero-ETL)

- Use **AWS Glue Zero-ETL integration** to replicate DynamoDB data into S3 Table Buckets.
- Create the source DynamoDB table and populate it with **thousands of sample records**.

### Flow 2: Aurora PostgreSQL → S3 Tables (DMS + Kinesis + Firehose)

- Use **AWS DMS** to capture CDC from Aurora PostgreSQL.
- Stream CDC events through **Amazon Kinesis Data Streams**.
- Deliver via **Amazon Data Firehose** into S3 Table Buckets.
- Create the source Aurora PostgreSQL cluster/database with sample tables and **thousands of records**.

### Flow 3: DocumentDB → S3 Tables (Change Streams + Lambda + Firehose)

- Use **DocumentDB Change Streams** with **AWS Lambda** to capture change events.
- Lambda pushes events into **Amazon Data Firehose**, which writes to S3 Table Buckets.
- Create the source DocumentDB cluster/collection and populate with **thousands of sample records**.

## Infrastructure & Tooling

- **IaC:** AWS CloudFormation (chosen for easiest conversion to Terraform via tools like `cf2tf`).
- **S3 Table Bucket:** One shared bucket with separate table namespaces per flow.
- **VPC:** Create a new dedicated VPC (Aurora PostgreSQL and DocumentDB require VPC placement).
- **Iceberg:** Use sensible defaults for partitioning and schema design.
- Follow **AWS best practices** throughout (IAM least privilege, encryption, tagging, etc.).

## Sample Data

- **Theme:** Generic (users, orders, products, etc.).
- **Volume:** Thousands of records per source to demonstrate CDC in action.
- Each flow includes a data loader script to populate the source database.

## Deliverables Per Flow

Each flow lives in its own isolated directory and includes:

1. **CloudFormation template(s)** — all resources for the flow.
2. **Deploy script** — one-command deployment.
3. **Teardown script** — one-command cleanup of all resources.
4. **Data loader script** — populates the source database with sample data.
5. **README** — step-by-step instructions for live deployment, validation, and teardown.

## Development Process

- **Iteratively deploy and test** each flow in the currently authenticated AWS account.
- **Validate** each flow works end-to-end (data appears correctly in S3 Tables).
- **Clean up** all AWS resources after each successful test.
- Final deliverable is **code ready to deploy live** (not pre-deployed).

## Deployment Learnings (from live testing)

Key gotchas discovered during actual deployment — see each flow's README for full details.

### Cross-cutting
- **Firehose CatalogARN** must use the sub-catalog ARN format: `arn:aws:glue:<region>:<account>:catalog/s3tablescatalog/<bucket-name>` (not the top-level catalog ARN)
- **cfnresponse module** was removed from Python 3.12+ Lambda runtimes — use `urllib3` or `urllib.request` for CloudFormation custom resource responses
- **Lake Formation permissions** are needed on the `s3tablescatalog` sub-catalog for roles that write to S3 Tables

### Flow 1 (DynamoDB → Glue Zero-ETL)
- Target database ARN uses short format: `arn:aws:glue:region:account:database/dbName`
- Glue resource policy requires `--enable-hybrid TRUE` flag
- CLI command is `describe-integrations` (not `list-integrations`)
- Initial DynamoDB PITR export takes 15-20 minutes

### Flow 2 (Aurora PG → DMS → Kinesis → Firehose)
- DMS `ParallelLoadThreads` requires `ParallelLoadBufferSize` (50-1000)
- Aurora Data API (`EnableHttpEndpoint`) needed since Aurora is in a private subnet
- Firehose is created via CLI after schema sync (not in CFN) because `DestinationTableConfigurationList` is built dynamically
- DMS control records (create-table, drop-table) will fail in Firehose error bucket — this is normal

### Flow 3 (DocumentDB → Lambda → Firehose)
- DocumentDB change streams must be explicitly enabled via `modifyChangeStreams` admin command
- Lambda ESM for DocumentDB needs `ec2:DescribeSecurityGroups` and `rds:Describe*` permissions
- Firehose is Direct PUT (Lambda pushes via `PutRecordBatch`)
- Loader Lambda installs `pymongo` at runtime via pip to `/tmp`
- ESM set to LATEST — need new inserts after ESM is active to test

## Project Structure

```
zero-etl/
├── WORKSHOP_PROMPT.md          # This file
├── shared/                     # Shared resources (S3 Table Bucket, VPC)
│   ├── template.yaml
│   ├── deploy.sh
│   └── teardown.sh
├── flow1-dynamodb-glue/        # DynamoDB → Glue Zero-ETL → S3 Tables
│   ├── template.yaml
│   ├── deploy.sh
│   ├── teardown.sh
│   ├── load-data.py
│   └── README.md
├── flow2-aurora-dms-kinesis/   # Aurora PG → DMS → Kinesis → Firehose → S3 Tables
│   ├── template.yaml
│   ├── deploy.sh
│   ├── teardown.sh
│   ├── load-data.py
│   └── README.md
└── flow3-docdb-lambda/         # DocumentDB → Change Streams → Lambda → Firehose → S3 Tables
    ├── template.yaml
    ├── deploy.sh
    ├── teardown.sh
    ├── load-data.py
    └── README.md
```
