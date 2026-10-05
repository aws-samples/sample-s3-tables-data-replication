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
# DocumentDB SG: ingress on 27017 is scoped to the Lambda SG (the only client), not the
# whole VPC CIDR. Egress is explicit all-traffic, matching the CFN SG default (CFN SGs
# allow all egress unless SecurityGroupEgress is specified; this makes it explicit for TF).
resource "aws_security_group" "docdb" {
  name_prefix = "${var.project_name}-flow3-docdb-"
  vpc_id      = var.vpc_id
  ingress {
    from_port       = 27017
    to_port         = 27017
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Lambda SG: egress all (matches CFN LambdaSecurityGroup SecurityGroupEgress -1/0.0.0.0/0).
resource "aws_security_group" "lambda" {
  name_prefix = "${var.project_name}-flow3-lambda-"
  vpc_id      = var.vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ============ DocumentDB ============
resource "aws_docdb_subnet_group" "main" {
  name       = "${var.project_name}-flow3"
  subnet_ids = [var.private_subnet_1_id, var.private_subnet_2_id]
}

resource "aws_docdb_cluster_parameter_group" "main" {
  family = "docdb5.0"
  name   = "${var.project_name}-flow3"
  parameter {
    name  = "change_stream_log_retention_duration"
    value = "10800"
  }
}

resource "aws_secretsmanager_secret" "docdb" {
  name = "${var.project_name}-flow3-docdb-secret"
}

resource "aws_secretsmanager_secret_version" "docdb" {
  secret_id     = aws_secretsmanager_secret.docdb.id
  secret_string = jsonencode({ username = "docdbadmin", password = var.db_password })
}

resource "aws_docdb_cluster" "main" {
  cluster_identifier              = "${var.project_name}-flow3-docdb"
  master_username                 = "docdbadmin"
  master_password                 = var.db_password
  db_subnet_group_name            = aws_docdb_subnet_group.main.name
  vpc_security_group_ids          = [aws_security_group.docdb.id]
  db_cluster_parameter_group_name = aws_docdb_cluster_parameter_group.main.name
  storage_encrypted               = true
  deletion_protection             = false
  skip_final_snapshot             = true
}

resource "aws_docdb_cluster_instance" "main" {
  identifier         = "${var.project_name}-flow3-docdb-1"
  cluster_identifier = aws_docdb_cluster.main.id
  instance_class     = "db.r6g.large"
}

# ============ S3 Tables Namespace + Table ============
# Mirrors flow3/deploy.sh step 1 (aws s3tables create-namespace / create-table).
# The Firehose iceberg destination targets this namespace/table.
resource "aws_s3tables_namespace" "flow3" {
  namespace        = "flow3_docdb"
  table_bucket_arn = var.table_bucket_arn
}

# The S3 Tables table is created via the AWS CLI (null_resource/local-exec) rather than the
# native aws_s3tables_table resource. REASON: the hashicorp/aws provider pinned here (5.x)
# exposes aws_s3tables_table WITHOUT an Iceberg column-schema argument -- it accepts only
# name/namespace/table_bucket_arn/format (schema support, "schemaV2", lands in a later
# provider release, see hashicorp/terraform-provider-aws#47601). flow3 REQUIRES an explicit
# 7-field schema (product_id..updated_at) so the Firehose iceberg sink and the Athena
# queries match the documented columns. Creating the table via `aws s3tables create-table
# --metadata` is behavior-identical to flow3/deploy.sh step 1 (the tested CloudFormation
# path), and uses the same null_resource/local-exec pattern already used for the flow1 Glue
# integration. Revisit (switch back to the native resource) once the provider gains schema
# support and the project pins that version. See the "S3 Tables table creation" note in
# the root README and flow3-docdb-lambda/README.md.
resource "null_resource" "s3tables_table" {
  triggers = {
    bucket_arn = var.table_bucket_arn
    namespace  = aws_s3tables_namespace.flow3.namespace
    table      = "products"
    region     = var.region
    # Bump this when the schema below changes so the table is recreated.
    schema_version = "v1"
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      aws s3tables create-table \
        --table-bucket-arn "${var.table_bucket_arn}" \
        --namespace "${aws_s3tables_namespace.flow3.namespace}" \
        --name "products" \
        --format ICEBERG \
        --metadata '{
          "iceberg": {
            "schema": {
              "fields": [
                {"name": "product_id", "type": "string", "required": true},
                {"name": "name", "type": "string"},
                {"name": "category", "type": "string"},
                {"name": "price", "type": "double"},
                {"name": "stock", "type": "int"},
                {"name": "rating", "type": "double"},
                {"name": "updated_at", "type": "string"}
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

  depends_on = [aws_s3tables_namespace.flow3]
}

# ============ Firehose Role ============
resource "aws_iam_role" "firehose" {
  name = "${var.project_name}-flow3-firehose"
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
      { Sid = "Glue", Effect = "Allow", Action = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:UpdateTable"], Resource = ["arn:aws:glue:${var.region}:${local.account_id}:catalog", "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog", "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog/*", "arn:aws:glue:${var.region}:${local.account_id}:database/*", "arn:aws:glue:${var.region}:${local.account_id}:table/*/*"] },
      { Sid = "S3Tables", Effect = "Allow", Action = ["s3tables:GetTable", "s3tables:GetTableData", "s3tables:GetTableMetadataLocation", "s3tables:UpdateTableMetadataLocation", "s3tables:PutTableData", "s3tables:GetTableBucket"], Resource = ["arn:aws:s3tables:${var.region}:${local.account_id}:bucket/${var.table_bucket_name}", "arn:aws:s3tables:${var.region}:${local.account_id}:bucket/${var.table_bucket_name}/*"] },
      { Sid = "LakeFormation", Effect = "Allow", Action = ["lakeformation:GetDataAccess"], Resource = "*" },
      { Sid = "ErrorBucket", Effect = "Allow", Action = ["s3:PutObject", "s3:GetObject", "s3:ListBucket", "s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"], Resource = [var.error_bucket_arn, "${var.error_bucket_arn}/*"] },
      { Sid = "Logs", Effect = "Allow", Action = ["logs:PutLogEvents", "logs:CreateLogGroup", "logs:CreateLogStream"], Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/firehose/${var.project_name}-flow3:*" },
    ]
  })
}

# ============ Lambda Processor Role ============
resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-flow3-lambda"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "lambda.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

# managed_policy_arns on aws_iam_role is deprecated; attach via a separate resource instead.
resource "aws_iam_role_policy_attachment" "lambda_vpc_access" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda" {
  name = "LambdaPolicy"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "Firehose", Effect = "Allow", Action = ["firehose:PutRecord", "firehose:PutRecordBatch"], Resource = "arn:aws:firehose:${var.region}:${local.account_id}:deliverystream/${var.project_name}-flow3-firehose" },
      { Sid = "Secrets", Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.docdb.arn },
      { Sid = "DocDBDescribe", Effect = "Allow", Action = ["rds:DescribeDBClusters", "rds:DescribeDBClusterParameters", "rds:DescribeDBSubnetGroups", "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeVpcs"], Resource = "*" },
      { Sid = "Logs", Effect = "Allow", Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"], Resource = "arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws/lambda/${var.project_name}-flow3-processor:*" },
    ]
  })
}

# ============ Lambda Processor ============
data "archive_file" "processor" {
  type        = "zip"
  output_path = "${path.module}/processor.zip"
  source {
    content  = <<-EOF
      import json, boto3, os
      firehose = boto3.client('firehose')
      STREAM = os.environ['FIREHOSE_STREAM_NAME']
      def handler(event, context):
        records = []
        for record in event.get('events', []):
          doc = record.get('event', {})
          full_doc = doc.get('fullDocument', {})
          cleaned = {}
          for k, v in full_doc.items():
            if isinstance(v, dict): cleaned[k] = str(v)
            else: cleaned[k] = v
          cleaned.pop('_id', None)
          if cleaned:
            records.append({'Data': json.dumps(cleaned) + '\n'})
        if records:
          for i in range(0, len(records), 500):
            firehose.put_record_batch(DeliveryStreamName=STREAM, Records=records[i:i+500])
          print(f'Sent {len(records)} records to Firehose')
        return {'statusCode': 200}
    EOF
    filename = "index.py"
  }
}

resource "aws_lambda_function" "processor" {
  function_name    = "${var.project_name}-flow3-processor"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 300
  memory_size      = 256
  filename         = data.archive_file.processor.output_path
  source_code_hash = data.archive_file.processor.output_base64sha256

  vpc_config {
    subnet_ids         = [var.private_subnet_1_id, var.private_subnet_2_id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = { FIREHOSE_STREAM_NAME = "${var.project_name}-flow3-firehose" }
  }
}

# ============ Enable Change Streams (via null_resource + Lambda) ============
data "archive_file" "enable_cs" {
  type        = "zip"
  output_path = "${path.module}/enable_cs.zip"
  source {
    content  = <<-EOF
      import json, os, urllib.request, subprocess, sys
      def handler(event, context):
        subprocess.check_call([sys.executable, '-m', 'pip', 'install', 'pymongo', '-t', '/tmp/pip', '-q'])
        sys.path.insert(0, '/tmp/pip')
        import pymongo, boto3
        sm = boto3.client('secretsmanager')
        secret = json.loads(sm.get_secret_value(SecretId=os.environ['SECRET_ARN'])['SecretString'])
        urllib.request.urlretrieve('https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem', '/tmp/ca.pem')
        client = pymongo.MongoClient(f"mongodb://{secret['username']}:{secret['password']}@{os.environ['DOCDB_ENDPOINT']}:27017/?tls=true&tlsCAFile=/tmp/ca.pem&replicaSet=rs0&readPreference=secondaryPreferred&retryWrites=false")
        client.admin.command({'modifyChangeStreams': 1, 'database': 'workshop', 'collection': '', 'enable': True})
        return {'status': 'enabled'}
    EOF
    filename = "index.py"
  }
}

resource "aws_lambda_function" "enable_cs" {
  function_name    = "${var.project_name}-flow3-enable-cs"
  role             = aws_iam_role.lambda.arn
  handler          = "index.handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 256
  filename         = data.archive_file.enable_cs.output_path
  source_code_hash = data.archive_file.enable_cs.output_base64sha256

  vpc_config {
    subnet_ids         = [var.private_subnet_1_id, var.private_subnet_2_id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      SECRET_ARN     = aws_secretsmanager_secret.docdb.arn
      DOCDB_ENDPOINT = aws_docdb_cluster.main.endpoint
    }
  }

  depends_on = [aws_docdb_cluster_instance.main]
}

# Invoke the enable-change-streams Lambda after DocumentDB is ready
resource "aws_lambda_invocation" "enable_cs" {
  function_name = aws_lambda_function.enable_cs.function_name
  input         = jsonencode({})
  depends_on    = [aws_docdb_cluster_instance.main]
}

# ============ Event Source Mapping ============
resource "aws_lambda_event_source_mapping" "docdb" {
  event_source_arn  = aws_docdb_cluster.main.arn
  function_name     = aws_lambda_function.processor.arn
  starting_position = "LATEST"
  batch_size        = 100
  enabled           = true

  document_db_event_source_config {
    database_name   = "workshop"
    collection_name = "products"
    full_document   = "UpdateLookup"
  }

  source_access_configuration {
    type = "BASIC_AUTH"
    uri  = aws_secretsmanager_secret.docdb.arn
  }

  depends_on = [aws_lambda_invocation.enable_cs]
}

# ============ Lake Formation Grant ============
# Granted via the AWS CLI (null_resource/local-exec) rather than the native
# aws_lakeformation_permissions resource. REASON: that resource validates table.catalog_id as
# a bare 12-digit account ID and REJECTS the S3 Tables federated sub-catalog form
# "<account>:s3tablescatalog/<bucket>" that this grant requires. The raw lakeformation
# grant-permissions API (used here and by flow3/deploy.sh) accepts it. Scoped to the minimum
# the Firehose principal needs: SELECT, INSERT, ALTER, DESCRIBE (no grant-option). Depends on
# the table existing (null_resource.s3tables_table) since the grant targets it.
resource "null_resource" "lf_grant" {
  triggers = {
    role_arn   = aws_iam_role.firehose.arn
    catalog_id = "${local.account_id}:s3tablescatalog/${var.table_bucket_name}"
    namespace  = "flow3_docdb"
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
          --resource '{"Table":{"CatalogId":"${local.account_id}:s3tablescatalog/${var.table_bucket_name}","DatabaseName":"flow3_docdb","TableWildcard":{}}}' \
          --permissions SELECT INSERT ALTER DESCRIBE \
          --region "${var.region}" 2>/tmp/lf_grant_flow3.err; then
          echo "LF grant succeeded (attempt $i)"
          exit 0
        fi
        echo "LF grant attempt $i failed ($(cat /tmp/lf_grant_flow3.err)); retrying in 10s..."
        sleep 10
      done
      echo "ERROR: Lake Formation grant for flow3_docdb failed after all retries." >&2
      echo "Most likely cause: setup.sh was not run in this account/region, so the S3 Tables" >&2
      echo "federation with Lake Formation is not registered (see the Terraform prerequisites" >&2
      echo "in README.md). Run ./setup.sh, then re-run terraform apply. Last error:" >&2
      cat /tmp/lf_grant_flow3.err >&2
      exit 1
    EOT
  }

  depends_on = [null_resource.s3tables_table]
}

# ============ CloudWatch Logs ============
resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/firehose/${var.project_name}-flow3"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_stream" "firehose" {
  name           = "DestinationDelivery"
  log_group_name = aws_cloudwatch_log_group.firehose.name
}

# ============ Firehose Delivery Stream (Iceberg) ============
# Mirrors flow3/deploy.sh step 3 (aws firehose create-delivery-stream --iceberg-destination-configuration).
# DirectPut source: the processor Lambda calls firehose.put_record_batch into this stream.
# The stream name MUST stay "${var.project_name}-flow3-firehose": the processor Lambda env
# FIREHOSE_STREAM_NAME and the Lambda IAM policy ARN already reference this exact literal.
resource "aws_kinesis_firehose_delivery_stream" "flow3" {
  name        = "${var.project_name}-flow3-firehose"
  destination = "iceberg"

  iceberg_configuration {
    role_arn           = aws_iam_role.firehose.arn
    catalog_arn        = "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog/${var.table_bucket_name}"
    buffering_interval = 60
    buffering_size     = 128

    s3_configuration {
      role_arn            = aws_iam_role.firehose.arn
      bucket_arn          = var.error_bucket_arn
      prefix              = "flow3-errors/"
      error_output_prefix = "flow3-error-output/"

      cloudwatch_logging_options {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose.name
        log_stream_name = aws_cloudwatch_log_stream.firehose.name
      }
    }

    destination_table_configuration {
      database_name = "flow3_docdb"
      table_name    = "products"
      unique_keys   = ["product_id"]
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
output "docdb_endpoint" { value = aws_docdb_cluster.main.endpoint }
output "docdb_secret_arn" { value = aws_secretsmanager_secret.docdb.arn }
output "firehose_role_arn" { value = aws_iam_role.firehose.arn }
output "processor_function_name" { value = aws_lambda_function.processor.function_name }
output "log_group_name" { value = aws_cloudwatch_log_group.firehose.name }
output "log_stream_name" { value = aws_cloudwatch_log_stream.firehose.name }
output "firehose_stream_name" { value = aws_kinesis_firehose_delivery_stream.flow3.name }
