# Security Findings — Accepted Items

This document records the static-analysis findings that are **knowingly accepted** in this
repository, each with the scanner, the rule ID, and a specific justification. Findings that were
remediated in code (synthetic-data domains, Kinesis/DynamoDB encryption, S3 versioning, private
subnet public-IP, flow3 Firehose S3 Tables ARN scoping, SQL value parameterization) are **not**
listed here — they were fixed, not accepted.

## Preamble — why these items are accepted

As stated at the top of the [README](README.md):

> **Sample code — not for production.** This repository is AWS sample code intended to demonstrate
> data-replication patterns into Amazon S3 Table Buckets. It is provided for educational purposes
> and must be reviewed, hardened, and tested before any production use.

The accepted findings below share a common theme that follows directly from that disclaimer:

- This is an **educational sample**, explicitly **non-production**, intended to be deployed into a
  **disposable test account** and **torn down after use** (every flow ships a `teardown.sh`).
- Where a hardening control adds operational cost or account-specific key/log management that would
  obscure the pattern being taught, the sample chooses **AWS service default encryption** and
  **simplified logging/retention** to stay **portable and readable** across accounts and regions.
- **Production users should not accept these defaults.** Before any production use, enable
  **customer-managed KMS keys (CMKs)**, **full logging with long retention**, and
  **least-privilege** IAM in place of the simplifications documented here.

Each item below states why it is acceptable *for this sample specifically*, not as a blanket waiver.

---

## 1. Encryption at rest — AWS-managed / default keys instead of customer-managed KMS CMKs

Every resource in this group **is encrypted at rest**; the finding is only that the key is an
AWS-managed or AWS-owned/default key rather than a customer-managed CMK. For a disposable
educational sample this avoids the key-policy, grant, and cross-service CMK management that would
distract from the replication pattern, while still keeping data encrypted at rest.

| Scanner | Rule ID | Resource(s) in this repo | Specific justification |
|---------|---------|--------------------------|------------------------|
| Checkov | **CKV_AWS_149** | flow2 `AuroraSecret` (CFN) / `aws_secretsmanager_secret.aurora` (TF); flow3 `DocDBSecret` (CFN) / `aws_secretsmanager_secret.docdb` (TF) | The Secrets Manager secrets holding the Aurora and DocumentDB credentials use the **AWS-managed Secrets Manager key** (`aws/secretsmanager`). Accepted to avoid provisioning and managing a CMK solely to hold short-lived workshop credentials; the secret is still encrypted. |
| Checkov | **CKV_AWS_327** | flow2 Aurora cluster (`StorageEncrypted: true`) | Aurora `StorageEncrypted` is enabled but uses the **default RDS KMS key** rather than a CMK. Accepted: storage is encrypted; a CMK adds no educational value for a throwaway cluster. |
| Checkov | **CKV_AWS_212** | flow2 DMS replication instance | The DMS replication instance relies on **default DMS encryption** (AWS-managed key) rather than a CMK. Accepted: the instance is ephemeral and torn down with the stack; data is still encrypted. |
| Checkov | **CKV_AWS_296** | flow2 DMS endpoint(s) | DMS endpoint uses **default endpoint encryption** rather than a CMK. Accepted for the same ephemeral, non-production reason as the replication instance. |
| Checkov | **CKV_AWS_182** | flow3 DocumentDB cluster | DocumentDB cluster uses **default storage encryption** (AWS-managed key) rather than a CMK. Accepted: storage is encrypted; CMK management is out of scope for the sample. |
| Checkov | **CKV_AWS_240** | flow2/flow3 Amazon Data Firehose delivery stream SSE | Firehose server-side encryption uses the **AWS-owned/default key**. Accepted to keep the delivery stream portable without a CMK; records are still encrypted in transit to the destination. |
| Checkov | **CKV_AWS_241** | flow2/flow3 Amazon Data Firehose delivery stream SSE (key type) | Companion to CKV_AWS_240: the Firehose SSE **key type is AWS-owned/default**, not a CMK. Accepted for the same reason — avoids CMK management while keeping SSE on. |

**Production guidance:** replace each of the above with a customer-managed KMS CMK and scope the key
policy to the consuming roles.

---

## 2. Logging and retention — simplified for a short-lived workshop

| Scanner | Rule ID | Resource(s) in this repo | Specific justification |
|---------|---------|--------------------------|------------------------|
| Checkov | **CKV_AWS_338** | flow2/flow3 Firehose CloudWatch Logs log groups (`RetentionInDays: 7` / `retention_in_days = 7`) | Log retention is deliberately set to **7 days**, not the 1-year minimum the rule expects. Seven days is sufficient to debug a workshop that is deployed, exercised, and **torn down within days**; a 1-year retention would outlive the disposable account and add storage cost for no educational benefit. |
| Checkov | **CKV_AWS_85** | flow3 DocumentDB cluster | DocumentDB **audit/profiler logging is not enabled**. Accepted: audit logging exists for long-running compliance monitoring, which does not apply to a transient sample cluster; enabling it would add noise and cost without demonstrating anything about the replication flow. |
| Checkov | **CKV_AWS_353** | flow2 Aurora cluster | Aurora **Performance Insights is not enabled**. Accepted: Performance Insights supports ongoing production performance tuning, which is out of scope for a short-lived demonstration cluster. |
| Checkov | **CKV_AWS_18** | shared error/S3 buckets | **S3 server access logging is intentionally omitted** to avoid introducing a *second* log-target bucket (plus its own policy, encryption, and lifecycle) purely to satisfy the control, which would complicate the sample. The error bucket already enforces SSE (AES256), a public-access block, a TLS-only bucket policy, and a 30-day lifecycle. |

**Production guidance:** set retention to your compliance minimum (e.g. ≥ 365 days), enable
DocumentDB audit logging and Aurora Performance Insights, and configure S3 access logging to a
dedicated, locked-down log bucket.

---

## 3. RDS IAM database authentication

| Scanner | Rule ID | Resource(s) in this repo | Specific justification |
|---------|---------|--------------------------|------------------------|
| Checkov | **CKV_AWS_162** | flow2 Aurora cluster | IAM database authentication is **not enabled**. The sample deliberately uses a **deploy-time master password stored in Secrets Manager** because the whole point of flow2 is to demonstrate the **Secrets Manager credential flow end-to-end** (DMS reads the secret to connect). Switching to IAM database auth would remove the exact mechanism the sample is teaching. |

**Production guidance:** enable IAM database authentication and issue short-lived DB auth tokens
instead of a static master password.

---

## 4. Residual IAM wildcards (not narrowed by the hardening pass — and why they cannot be)

The IAM policies in this repo are predominantly ARN-scoped. The hardening pass scoped every wildcard
that *could* be scoped (notably the flow3 Firehose S3 Tables ARNs, raised to the named bucket to
match Terraform). The wildcards below remain because the actions involved **do not support
resource-level permissions**, or the `*` already denotes the single intended resource.

| Scanner / source | Where | Residual | Specific justification |
|------------------|-------|----------|------------------------|
| IAM policy review | flow2 Firehose role, flow3 Firehose role, flow1 Glue role (CFN `template.yaml` and matching `terraform/.../main.tf`) | `lakeformation:GetDataAccess` with `Resource: "*"` | `lakeformation:GetDataAccess` **has no resource-level scoping** — Lake Formation authorizes the underlying data via its own permission model, so the IAM resource must be `*`. Cannot be narrowed. |
| IAM policy review | flow2 `LFGrantLambdaRole`, flow3 `LFGrantLambdaRole` (CFN) and matching TF | `lakeformation:GrantPermissions` / `lakeformation:RevokePermissions` with `Resource: "*"` | These Grant/Revoke calls administer Lake Formation permissions on the **federated `s3tablescatalog` sub-catalog** (the roles' `CatalogId` is `${AWS::AccountId}:s3tablescatalog/${TableBucketName}`). The Lake Formation grant/revoke actions **do not take an IAM resource ARN**; scoping is enforced by Lake Formation on the sub-catalog, not by the IAM `Resource` element. Cannot be narrowed. |
| IAM policy review | flow3 Lambda policy — `LambdaPolicy` (CFN) / `DocDBDescribe` statement (TF) | `rds:Describe*` and `ec2:Describe*` (`rds:DescribeDBClusters`, `rds:DescribeDBClusterParameters`, `rds:DescribeDBSubnetGroups`, `ec2:DescribeSecurityGroups`, `ec2:DescribeSubnets`, `ec2:DescribeVpcs`) with `Resource: "*"` | These **`Describe` actions have no resource-level permissions** in IAM; they must be granted on `*`. Required so the Lambda event-source mapping can discover the DocumentDB cluster's networking. Cannot be narrowed. |
| IAM policy review | flow1 DynamoDB `OrdersTable` resource-based policy (CFN) / matching TF | `Resource: "*"` in the table's own resource policy | Inside a **DynamoDB resource-based policy** `Resource: "*"` means **"this table"** (the policy is already attached to the single table). It is further constrained by `Condition` keys **`aws:SourceAccount`** (this account) and **`aws:SourceArn`** (`arn:aws:glue:...:integration:*`), so the Glue Zero-ETL service principal can only act from this account's integrations. Effectively already least-privilege. |

**Production guidance:** keep these as-is where the action genuinely lacks resource-level support;
otherwise tighten `aws:SourceArn` to the specific integration ARN once it is known.

---

## 5. Bandit B608 — SQL built with string construction (`sync-schema.py`)

| Scanner | Rule ID | File | Specific justification |
|---------|---------|------|------------------------|
| Bandit | **B608** | `flow2-aurora-dms-kinesis/sync-schema.py` (information_schema discovery queries, ~lines 93/112/120) | Accepted. The queries that drive S3 Tables schema discovery read `information_schema` filtered by schema and table name. Those filter values come **only from the script's own trusted sources** — the `--schema` CLI argument (default `public`) and table names the script itself discovered from `information_schema` moments earlier — **never from external or end-user input**. The literal filter values are bound as **RDS Data API named parameters** (`:schema`, `:table`) rather than concatenated, so no row/value data is interpolated into SQL. Any remaining query text is fixed SQL plus these trusted, parameterized identifiers; the Bandit string-construction pattern is a false positive in this trusted-input, non-production context. |

**Production guidance:** if these queries are ever fed values from an untrusted caller, validate the
identifiers against an allowlist derived from `information_schema` before use.
