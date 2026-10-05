terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.80, < 6.0" }
  }
}

variable "region" { default = "us-east-1" }
variable "project_name" { default = "zero-etl-workshop" }
variable "vpc_id" {}
variable "private_subnet_1_id" {}
variable "private_subnet_2_id" {}
variable "vpc_cidr" { default = "10.0.0.0/16" }
variable "table_bucket_name" {}
variable "table_bucket_arn" {}
variable "error_bucket_arn" {}
variable "error_bucket_name" {}
variable "db_password" {
  description = "Master DB password. Provide via -var or TF_VAR_db_password; no default is shipped."
  type        = string
  sensitive   = true
}

data "aws_caller_identity" "current" {}
locals { account_id = data.aws_caller_identity.current.account_id }

# ============ Security Groups ============
# Aurora SG: ingress on 5432 is scoped to the DMS SG (the only client), not the whole
# VPC CIDR. Egress is explicit all-traffic, matching the CFN SG default (CFN SGs allow all
# egress unless SecurityGroupEgress is specified; this block makes that explicit for TF).
resource "aws_security_group" "aurora" {
  name_prefix = "${var.project_name}-flow2-aurora-"
  vpc_id      = var.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.dms.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# DMS SG: egress all (matches CFN DMSSecurityGroup SecurityGroupEgress -1/0.0.0.0/0).
resource "aws_security_group" "dms" {
  name_prefix = "${var.project_name}-flow2-dms-"
  vpc_id      = var.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============ Aurora PostgreSQL ============
resource "aws_db_subnet_group" "aurora" {
  name       = "${var.project_name}-flow2"
  subnet_ids = [var.private_subnet_1_id, var.private_subnet_2_id]
}

resource "aws_rds_cluster_parameter_group" "aurora" {
  family = "aurora-postgresql16"
  name   = "${var.project_name}-flow2-pg"
  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }
}

resource "aws_rds_cluster" "aurora" {
  cluster_identifier = "${var.project_name}-flow2-aurora"
  engine             = "aurora-postgresql"
  # Major-version only (not a pinned patch like "16.6"): AWS resolves it to a supported 16.x
  # minor in whatever region you deploy to. A pinned patch version is region-fragile — e.g.
  # 16.6 does not exist in us-west-2. The parameter group family below stays "aurora-postgresql16".
  engine_version                  = "16"
  master_username                 = "postgres"
  master_password                 = var.db_password
  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora.name
  enable_http_endpoint            = true
  storage_encrypted               = true
  deletion_protection             = false
  skip_final_snapshot             = true
}

resource "aws_rds_cluster_instance" "aurora" {
  identifier         = "${var.project_name}-flow2-aurora-1"
  cluster_identifier = aws_rds_cluster.aurora.id
  instance_class     = "db.r6g.large"
  engine             = aws_rds_cluster.aurora.engine
}

resource "aws_secretsmanager_secret" "aurora" {
  name = "${var.project_name}-flow2-db-secret"
}

resource "aws_secretsmanager_secret_version" "aurora" {
  secret_id     = aws_secretsmanager_secret.aurora.id
  secret_string = jsonencode({ username = "postgres", password = var.db_password })
}

# ============ Kinesis Data Stream ============
resource "aws_kinesis_stream" "cdc" {
  name        = "${var.project_name}-flow2-cdc"
  shard_count = 2
}

# ============ DMS ============
resource "aws_dms_replication_subnet_group" "main" {
  replication_subnet_group_id          = "${var.project_name}-flow2-dms"
  replication_subnet_group_description = "Flow 2 DMS"
  subnet_ids                           = [var.private_subnet_1_id, var.private_subnet_2_id]
}

resource "aws_dms_replication_instance" "main" {
  replication_instance_id     = "${var.project_name}-flow2-dms"
  replication_instance_class  = "dms.r5.large"
  allocated_storage           = 50
  vpc_security_group_ids      = [aws_security_group.dms.id, aws_security_group.aurora.id]
  replication_subnet_group_id = aws_dms_replication_subnet_group.main.id
  publicly_accessible         = false
}

resource "aws_iam_role" "dms_kinesis" {
  name = "${var.project_name}-flow2-dms-kinesis"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "dms.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "dms_kinesis" {
  name = "KinesisAccess"
  role = aws_iam_role.dms_kinesis.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["kinesis:PutRecord", "kinesis:PutRecords", "kinesis:DescribeStream"], Resource = aws_kinesis_stream.cdc.arn }]
  })
}

resource "aws_dms_endpoint" "source" {
  endpoint_id   = "${var.project_name}-flow2-source"
  endpoint_type = "source"
  engine_name   = "aurora-postgresql"
  server_name   = aws_rds_cluster.aurora.endpoint
  port          = 5432
  database_name = "postgres"
  username      = "postgres"
  password      = var.db_password
  depends_on    = [aws_rds_cluster_instance.aurora]
}

resource "aws_dms_endpoint" "target" {
  endpoint_id   = "${var.project_name}-flow2-target"
  endpoint_type = "target"
  engine_name   = "kinesis"
  kinesis_settings {
    stream_arn                  = aws_kinesis_stream.cdc.arn
    service_access_role_arn     = aws_iam_role.dms_kinesis.arn
    message_format              = "json"
    include_transaction_details = true
  }
}

resource "aws_dms_replication_task" "main" {
  replication_task_id       = "${var.project_name}-flow2-task"
  replication_instance_arn  = aws_dms_replication_instance.main.replication_instance_arn
  source_endpoint_arn       = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn       = aws_dms_endpoint.target.endpoint_arn
  migration_type            = "full-load-and-cdc"
  table_mappings            = jsonencode({ rules = [{ "rule-type" = "selection", "rule-id" = "1", "rule-name" = "all-public", "object-locator" = { "schema-name" = "public", "table-name" = "%" }, "rule-action" = "include" }] })
  replication_task_settings = jsonencode({ TargetMetadata = { ParallelLoadThreads = 4, ParallelLoadBufferSize = 50 }, Logging = { EnableLogging = true } })
}

# ============ S3 Tables Namespace + Table ============
# Mirrors flow2/schema-mapping.json (generated by sync-schema.py at deploy time).
# The Firehose iceberg destination targets this namespace/table.
resource "aws_s3tables_namespace" "flow2" {
  namespace        = "flow2_aurora"
  table_bucket_arn = var.table_bucket_arn
}

# The S3 Tables table is created via the AWS CLI (null_resource/local-exec) rather than the
# native aws_s3tables_table resource. REASON: the hashicorp/aws provider pinned here (5.x)
# exposes aws_s3tables_table WITHOUT an Iceberg column-schema argument -- it accepts only
# name/namespace/table_bucket_arn/format (schema support, "schemaV2", lands in a later
# provider release, see hashicorp/terraform-provider-aws#47601). The 'customers' schema below
# mirrors schema-mapping.json (generated by sync-schema.py). Creating the table via
# `aws s3tables create-table --metadata` is behavior-identical to the tested CloudFormation
# path and uses the same null_resource/local-exec pattern as the flow1 Glue integration.
# NOTE: unlike the CFN deploy.sh (which builds DestinationTableConfigurationList dynamically
# from schema-mapping.json for every synced table), this Terraform path pins the single known
# 'customers' table. If the Aurora schema grows, add matching tables here and a matching
# destination_table_configuration block on the Firehose stream below. Revisit (switch back to
# the native resource) once the provider gains schema support. See the "S3 Tables table
# creation" note in the root README and flow2-aurora-dms-kinesis/README.md.
resource "null_resource" "s3tables_table" {
  triggers = {
    bucket_arn     = var.table_bucket_arn
    namespace      = aws_s3tables_namespace.flow2.namespace
    table          = "customers"
    region         = var.region
    schema_version = "v1"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws s3tables create-table \
        --table-bucket-arn "${var.table_bucket_arn}" \
        --namespace "${aws_s3tables_namespace.flow2.namespace}" \
        --name "customers" \
        --format ICEBERG \
        --metadata '{
          "iceberg": {
            "schema": {
              "fields": [
                {"name": "customer_id", "type": "int", "required": true},
                {"name": "first_name", "type": "string"},
                {"name": "last_name", "type": "string"},
                {"name": "email", "type": "string"},
                {"name": "city", "type": "string"},
                {"name": "signup_date", "type": "date"},
                {"name": "total_orders", "type": "int"},
                {"name": "total_spent", "type": "double"}
              ]
            }
          }
        }' \
        --region "${var.region}" 2>/dev/null || echo "  Table already exists (skipping)"
    EOT
  }

  # Destroy-time cleanup: the table was created out-of-band via CLI, so Terraform doesn't
  # manage it and won't delete it on destroy — which then makes the native namespace delete
  # fail with "namespace is not empty". This deletes the table first. Uses self.triggers
  # (the only values available to a destroy-time provisioner); best-effort so a missing table
  # doesn't block teardown.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      aws s3tables delete-table \
        --table-bucket-arn "${self.triggers.bucket_arn}" \
        --namespace "${self.triggers.namespace}" \
        --name "${self.triggers.table}" \
        --region "${self.triggers.region}" 2>/dev/null || echo "  Table already gone (skipping)"
    EOT
  }

  depends_on = [aws_s3tables_namespace.flow2]
}

# ============ Firehose Role ============
resource "aws_iam_role" "firehose" {
  name = "${var.project_name}-flow2-firehose"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "firehose.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  name = "FirehosePolicy"
  role = aws_iam_role.firehose.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Kinesis", Effect = "Allow", Action = ["kinesis:DescribeStream", "kinesis:GetShardIterator", "kinesis:GetRecords", "kinesis:ListShards"], Resource = aws_kinesis_stream.cdc.arn },
      { Sid = "Glue", Effect = "Allow", Action = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:UpdateTable"], Resource = ["arn:aws:glue:${var.region}:${local.account_id}:catalog", "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog", "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog/*", "arn:aws:glue:${var.region}:${local.account_id}:database/*", "arn:aws:glue:${var.region}:${local.account_id}:table/*/*"] },
      { Sid = "S3Tables", Effect = "Allow", Action = ["s3tables:GetTable", "s3tables:GetTableData", "s3tables:GetTableMetadataLocation", "s3tables:UpdateTableMetadataLocation", "s3tables:PutTableData", "s3tables:GetTableBucket"], Resource = ["arn:aws:s3tables:${var.region}:${local.account_id}:bucket/${var.table_bucket_name}", "arn:aws:s3tables:${var.region}:${local.account_id}:bucket/${var.table_bucket_name}/*"] },
      { Sid = "LakeFormation", Effect = "Allow", Action = ["lakeformation:GetDataAccess"], Resource = "*" },
      { Sid = "ErrorBucket", Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"], Resource = [var.error_bucket_arn, "${var.error_bucket_arn}/*"] },
      { Sid = "Logs", Effect = "Allow", Action = ["logs:PutLogEvents", "logs:CreateLogGroup", "logs:CreateLogStream"], Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/firehose/${var.project_name}-flow2:*" },
      { Sid = "Lambda", Effect = "Allow", Action = ["lambda:InvokeFunction", "lambda:GetFunctionConfiguration"], Resource = aws_lambda_function.transform.arn },
    ]
  })
}

# ============ Lambda Transform ============
resource "aws_iam_role" "transform_lambda" {
  name = "${var.project_name}-flow2-transform-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

# managed_policy_arns on aws_iam_role is deprecated; attach via a separate resource instead.
resource "aws_iam_role_policy_attachment" "transform_lambda_basic" {
  role       = aws_iam_role.transform_lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "archive_file" "transform" {
  type        = "zip"
  output_path = "${path.module}/transform.zip"
  source {
    content  = <<-EOF
      import base64, json
      def handler(event, context):
        output = []
        for record in event['records']:
          payload = json.loads(base64.b64decode(record['data']).decode('utf-8'))
          if 'data' in payload and payload.get('metadata', {}).get('record-type') == 'data':
            flat = payload['data']
            output.append({'recordId': record['recordId'], 'result': 'Ok', 'data': base64.b64encode((json.dumps(flat) + '\n').encode()).decode()})
          else:
            output.append({'recordId': record['recordId'], 'result': 'Dropped', 'data': record['data']})
        return {'records': output}
    EOF
    filename = "index.py"
  }
}

resource "aws_lambda_function" "transform" {
  function_name    = "${var.project_name}-flow2-transform"
  role             = aws_iam_role.transform_lambda.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 60
  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256
}

# ============ CloudWatch Logs ============
resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/firehose/${var.project_name}-flow2"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "DestinationDelivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

# ============ Lake Formation Grant ============
# Granted via the AWS CLI (null_resource/local-exec) rather than the native
# aws_lakeformation_permissions resource. REASON: that resource validates table.catalog_id as
# a bare 12-digit account ID and REJECTS the S3 Tables federated sub-catalog form
# "<account>:s3tablescatalog/<bucket>" that this grant requires. The raw lakeformation
# grant-permissions API (used here and by flow2/deploy.sh) accepts it. Scoped to the minimum
# the Firehose principal needs: SELECT, INSERT, ALTER, DESCRIBE (no grant-option). Depends on
# the table existing (null_resource.s3tables_table) since the grant targets it.
resource "null_resource" "lf_grant" {
  triggers = {
    role_arn   = aws_iam_role.firehose.arn
    catalog_id = "${local.account_id}:s3tablescatalog/${var.table_bucket_name}"
    namespace  = "flow2_aurora"
    region     = var.region
  }

  # Retry with backoff for transient propagation: right after the namespace/table are created,
  # Lake Formation's federated catalog view of the S3 Tables database can lag a few seconds
  # ("Database not found"). We retry for ~2 minutes. If it STILL cannot grant, we FAIL LOUDLY
  # (non-zero exit) rather than swallowing it — a persistent failure means a real prerequisite
  # is missing (almost always: setup.sh was not run, so the S3 Tables <-> Lake Formation
  # federation is not registered). Failing here gives a clear, actionable error and leaves this
  # resource not-created so the next `terraform apply` retries it, instead of limping on to a
  # confusing Firehose `glue:GetTable` error downstream.
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -uo pipefail
      for i in $(seq 1 12); do
        if aws lakeformation grant-permissions \
          --principal "DataLakePrincipalIdentifier=${aws_iam_role.firehose.arn}" \
          --resource '{"Table":{"CatalogId":"${local.account_id}:s3tablescatalog/${var.table_bucket_name}","DatabaseName":"flow2_aurora","TableWildcard":{}}}' \
          --permissions SELECT INSERT ALTER DESCRIBE \
          --region "${var.region}" 2>/tmp/lf_grant_flow2.err; then
          echo "LF grant succeeded (attempt $i)"
          exit 0
        fi
        echo "LF grant attempt $i failed ($(cat /tmp/lf_grant_flow2.err)); retrying in 10s..."
        sleep 10
      done
      echo "ERROR: Lake Formation grant for flow2_aurora failed after all retries." >&2
      echo "Most likely cause: setup.sh was not run in this account/region, so the S3 Tables" >&2
      echo "federation with Lake Formation is not registered (see the Terraform prerequisites" >&2
      echo "in README.md). Run ./setup.sh, then re-run terraform apply. Last error:" >&2
      cat /tmp/lf_grant_flow2.err >&2
      exit 1
    EOT
  }

  depends_on = [null_resource.s3tables_table]
}

# ============ Firehose Delivery Stream (Iceberg) ============
# Mirrors flow2/deploy.sh step 4 (aws firehose create-delivery-stream --iceberg-destination-configuration).
# KinesisStreamAsSource: reads CDC records off the Kinesis stream, runs the transform
# Lambda processor, then writes to the Iceberg table.
#
# DIVERGENCE (deliberate, documented): the CLI path in deploy.sh builds
# DestinationTableConfigurationList dynamically from schema-mapping.json (one entry per
# synced table). This Terraform path pins the single known 'customers' table instead. If
# the Aurora schema grows additional tables, add matching aws_s3tables_table resources and
# destination_table_configuration blocks here (or regenerate from schema-mapping.json).
resource "aws_kinesis_firehose_delivery_stream" "flow2" {
  name        = "${var.project_name}-flow2-firehose"
  destination = "iceberg"

  kinesis_source_configuration {
    kinesis_stream_arn = aws_kinesis_stream.cdc.arn
    role_arn           = aws_iam_role.firehose.arn
  }

  iceberg_configuration {
    role_arn           = aws_iam_role.firehose.arn
    catalog_arn        = "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog/${var.table_bucket_name}"
    buffering_interval = 60
    buffering_size     = 128

    s3_configuration {
      role_arn            = aws_iam_role.firehose.arn
      bucket_arn          = var.error_bucket_arn
      prefix              = "flow2-errors/"
      error_output_prefix = "flow2-error-output/"

      cloudwatch_logging_options {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose.name
        log_stream_name = aws_cloudwatch_log_stream.firehose.name
      }
    }

    processing_configuration {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = aws_lambda_function.transform.arn
        }
        parameters {
          parameter_name  = "BufferSizeInMBs"
          parameter_value = "1"
        }
        parameters {
          parameter_name  = "BufferIntervalInSeconds"
          parameter_value = "60"
        }
      }
    }

    destination_table_configuration {
      database_name = "flow2_aurora"
      table_name    = "customers"
      unique_keys   = ["customer_id"]
    }

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = aws_cloudwatch_log_stream.firehose.name
    }
  }

  depends_on = [
    null_resource.lf_grant,
    null_resource.s3tables_table,
  ]
}

# ============ Outputs ============
output "aurora_endpoint" { value = aws_rds_cluster.aurora.endpoint }
output "aurora_cluster_arn" { value = aws_rds_cluster.aurora.arn }
output "aurora_secret_arn" { value = aws_secretsmanager_secret.aurora.arn }
output "kinesis_stream_arn" { value = aws_kinesis_stream.cdc.arn }
output "dms_task_arn" { value = aws_dms_replication_task.main.replication_task_arn }
output "firehose_role_arn" { value = aws_iam_role.firehose.arn }
output "transform_lambda_arn" { value = aws_lambda_function.transform.arn }
output "log_group_name" { value = aws_cloudwatch_log_group.firehose.name }
output "log_stream_name" { value = aws_cloudwatch_log_stream.firehose.name }
output "firehose_stream_name" { value = aws_kinesis_firehose_delivery_stream.flow2.name }
