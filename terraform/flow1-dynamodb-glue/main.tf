terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.80, < 6.0" }
  }
}

variable "region" { default = "us-east-1" }
variable "project_name" { default = "zero-etl-workshop" }
variable "table_bucket_name" { description = "S3 Table Bucket name from shared stack" }

data "aws_caller_identity" "current" {}
locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ============ DynamoDB Source Table ============
resource "aws_dynamodb_table" "orders" {
  name         = "${var.project_name}-orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }

  point_in_time_recovery { enabled = true }

  server_side_encryption { enabled = true }

  tags = { Project = var.project_name }
}

# DynamoDB resource policy for Glue Zero-ETL access
resource "aws_dynamodb_resource_policy" "glue_access" {
  resource_arn = aws_dynamodb_table.orders.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowGlueZeroETL"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
      Action    = ["dynamodb:ExportTableToPointInTime", "dynamodb:DescribeTable", "dynamodb:DescribeExport"]
      Resource  = "*"
      Condition = {
        StringEquals = { "aws:SourceAccount" = local.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:glue:${var.region}:${local.account_id}:integration:*" }
      }
    }]
  })
}

# ============ Glue Target IAM Role ============
resource "aws_iam_role" "glue_target" {
  name = "${var.project_name}-flow1-glue-target"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "glue.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "glue_target" {
  name = "GlueTargetPolicy"
  role = aws_iam_role.glue_target.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "GlueCatalog"
        Effect = "Allow"
        Action = ["glue:GetDatabase", "glue:GetDatabases", "glue:GetTable", "glue:GetTables", "glue:CreateTable", "glue:UpdateTable", "glue:DeleteTable", "glue:CreateDatabase"]
        Resource = [
          "arn:aws:glue:${var.region}:${local.account_id}:catalog",
          "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog",
          "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog/${var.table_bucket_name}",
          "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog/${var.table_bucket_name}/database/zetl_*",
          "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog/${var.table_bucket_name}/table/zetl_*/*",
          "arn:aws:glue:${var.region}:${local.account_id}:database/zetl_*",
          "arn:aws:glue:${var.region}:${local.account_id}:table/zetl_*/*",
        ]
      },
      {
        Sid    = "S3Tables"
        Effect = "Allow"
        # Glue Zero-ETL writes NEW tables into the target namespace, so (unlike the Firehose
        # roles that only write to a pre-created table) this role additionally needs namespace
        # read + table/namespace create actions. Omitting s3tables:GetNamespace causes the
        # integration to go NEEDS_ATTENTION with TARGET_NAMESPACE_ACCESS_DENIED.
        Action   = ["s3tables:GetTable", "s3tables:GetTableData", "s3tables:GetTableMetadataLocation", "s3tables:UpdateTableMetadataLocation", "s3tables:PutTableData", "s3tables:GetTableBucket", "s3tables:GetNamespace", "s3tables:ListNamespaces", "s3tables:ListTables", "s3tables:CreateNamespace", "s3tables:CreateTable"]
        Resource = ["arn:aws:s3tables:${var.region}:${local.account_id}:bucket/${var.table_bucket_name}", "arn:aws:s3tables:${var.region}:${local.account_id}:bucket/${var.table_bucket_name}/*"]
      },
      {
        Sid = "LakeFormation", Effect = "Allow", Action = ["lakeformation:GetDataAccess"], Resource = "*"
      },
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/aws-glue/*"]
      }
    ]
  })
}

# ============ Glue Zero-ETL Integration (DynamoDB → S3 Tables) ============
# There is no GA native Terraform resource for a Glue Zero-ETL integration into S3 Tables
# (no aws_glue_integration for DynamoDB → S3 Tables). The CloudFormation path creates it
# out-of-band in flow1/deploy.sh steps 2-5 via the AWS CLI, so for parity the Terraform path
# wraps that same CLI sequence in a null_resource. The aws CLI must be on PATH and the
# caller's credentials/region must match the provider. The script is idempotent: it guards
# create-integration with describe-integrations and tolerates "already exists" on the
# resource/table property calls.
locals {
  flow1_catalog_arn        = "arn:aws:glue:${var.region}:${local.account_id}:catalog"
  flow1_target_catalog_arn = "arn:aws:glue:${var.region}:${local.account_id}:catalog/s3tablescatalog/${var.table_bucket_name}"
  flow1_integration_name   = "${var.project_name}-flow1-ddb-to-s3tables"
}

resource "null_resource" "glue_integration" {
  triggers = {
    table_arn         = aws_dynamodb_table.orders.arn
    role_arn          = aws_iam_role.glue_target.arn
    table_bucket_name = var.table_bucket_name
    region            = var.region
    integration_name  = local.flow1_integration_name
  }

  depends_on = [
    aws_dynamodb_resource_policy.glue_access,
    aws_iam_role_policy.glue_target,
  ]

  # (a) Enable hybrid access and allow Glue Zero-ETL inbound integrations on the catalog
  #     and S3 Tables sub-catalog (flow1/deploy.sh step 2).
  # (b) Pin the target processing role on the sub-catalog (step 3).
  # (c) Register the DynamoDB table name as an integration table property (step 4).
  # (d) Create the integration DynamoDB -> S3 Tables sub-catalog, guarded for idempotency (step 5).
  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-c"]
    environment = {
      REGION             = var.region
      ACCOUNT_ID         = local.account_id
      CATALOG_ARN        = local.flow1_catalog_arn
      TARGET_CATALOG_ARN = local.flow1_target_catalog_arn
      ROLE_ARN           = aws_iam_role.glue_target.arn
      DDB_TABLE_ARN      = aws_dynamodb_table.orders.arn
      DDB_TABLE_NAME     = aws_dynamodb_table.orders.name
      INTEGRATION_NAME   = local.flow1_integration_name
    }
    command = <<-EOT
      set -euo pipefail

      # (a) Glue catalog resource policy (enable-hybrid TRUE)
      POLICY=$(cat <<JSON
      {
        "Version": "2012-10-17",
        "Statement": [
          {
            "Sid": "AllowGlueZeroETLInbound",
            "Effect": "Allow",
            "Principal": {"Service": "glue.amazonaws.com"},
            "Action": "glue:AuthorizeInboundIntegration",
            "Resource": ["$CATALOG_ARN", "$TARGET_CATALOG_ARN"]
          },
          {
            "Sid": "AllowAccountCreateInbound",
            "Effect": "Allow",
            "Principal": {"AWS": "arn:aws:iam::$ACCOUNT_ID:root"},
            "Action": "glue:CreateInboundIntegration",
            "Resource": ["$CATALOG_ARN", "$TARGET_CATALOG_ARN"]
          }
        ]
      }
      JSON
      )
      aws glue put-resource-policy \
        --policy-in-json "$POLICY" \
        --enable-hybrid TRUE \
        --region "$REGION"

      # (b) IntegrationResourceProperty on the target sub-catalog
      aws glue create-integration-resource-property \
        --resource-arn "$TARGET_CATALOG_ARN" \
        --target-processing-properties "{\"RoleArn\": \"$ROLE_ARN\"}" \
        --region "$REGION" 2>/dev/null || \
      aws glue update-integration-resource-property \
        --resource-arn "$TARGET_CATALOG_ARN" \
        --target-processing-properties "{\"RoleArn\": \"$ROLE_ARN\"}" \
        --region "$REGION"

      # (c) IntegrationTableProperties for the DynamoDB table
      aws glue create-integration-table-properties \
        --resource-arn "$TARGET_CATALOG_ARN" \
        --table-name "$DDB_TABLE_NAME" \
        --target-table-config '' \
        --region "$REGION" 2>/dev/null || echo "  Table properties already set"

      # (d) Create the Zero-ETL integration (idempotent via describe-integrations guard)
      EXISTING=$(aws glue describe-integrations --region "$REGION" \
        --query "Integrations[?IntegrationName=='$INTEGRATION_NAME'].IntegrationArn" \
        --output text 2>/dev/null || true)
      if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
        echo "  Integration already exists: $EXISTING"
      else
        aws glue create-integration \
          --integration-name "$INTEGRATION_NAME" \
          --source-arn "$DDB_TABLE_ARN" \
          --target-arn "$TARGET_CATALOG_ARN" \
          --description "Flow 1: DynamoDB to S3 Tables via Glue Zero-ETL" \
          --region "$REGION"
      fi
    EOT
  }

  # Best-effort teardown: delete the integration on destroy so re-applies stay clean.
  # Destroy-time provisioners may only reference self.*, so pull values from triggers.
  provisioner "local-exec" {
    when        = destroy
    on_failure  = continue
    interpreter = ["/usr/bin/env", "bash", "-c"]
    environment = {
      REGION           = self.triggers.region
      INTEGRATION_NAME = self.triggers.integration_name
    }
    command = <<-EOT
      set -uo pipefail
      # Resolve the integration ARN by name, then best-effort delete it.
      ARN=$(aws glue describe-integrations --region "$REGION" \
        --query "Integrations[?IntegrationName=='$INTEGRATION_NAME'].IntegrationArn" \
        --output text 2>/dev/null || true)
      if [ -n "$ARN" ] && [ "$ARN" != "None" ]; then
        aws glue delete-integration --integration-identifier "$ARN" --region "$REGION" || true
      fi
    EOT
  }
}

# ============ Outputs ============
output "dynamodb_table_arn" { value = aws_dynamodb_table.orders.arn }
output "dynamodb_table_name" { value = aws_dynamodb_table.orders.name }
output "glue_target_role_arn" { value = aws_iam_role.glue_target.arn }
