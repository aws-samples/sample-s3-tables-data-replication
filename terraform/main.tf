terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }

  # Remote state backend (optional, recommended for team/customer use).
  # Uncomment and fill in once you have an S3 bucket + DynamoDB lock table in us-east-1.
  # The workshop works with local state out of the box, so this stays commented by default.
  #
  # backend "s3" {
  #   bucket         = "zero-etl-ev-tfstate-REPLACE_ME"
  #   key            = "zero-etl/terraform.tfstate"
  #   region         = "us-east-1" # region of the STATE bucket/lock table (independent of var.region, the deploy region)
  #   dynamodb_table = "zero-etl-ev-tf-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region
}

# ============ Unique naming ============
# H5: every deployment must be uniquely named so the workshop can run multiple times
# in a shared account without resource-name collisions. project_name is required (no
# default, see variables.tf); we append a short random suffix and pass the combined
# local.name as project_name into EVERY module.
#
# CRITICAL (FEAT-001 coupling): each module derives its Firehose stream name, the Lambda
# FIREHOSE_STREAM_NAME env var, and the Lambda IAM policy ARN from its own var.project_name.
# Because we feed the SAME local.name into project_name for all modules, those three stay
# byte-for-byte identical automatically — do not rename only one of them.
resource "random_string" "suffix" {
  length  = 6
  special = false
  upper   = false
}

locals {
  name = "${var.project_name}-${random_string.suffix.result}"
}

# ============ Shared foundation (VPC, S3 Table bucket, error bucket) ============
module "shared" {
  source = "./shared"

  region       = var.region
  project_name = local.name
}

# ============ Flow 1: DynamoDB -> Glue Zero-ETL -> S3 Tables ============
module "flow1" {
  source = "./flow1-dynamodb-glue"

  region            = var.region
  project_name      = local.name
  table_bucket_name = module.shared.table_bucket_name
}

# ============ Flow 2: Aurora -> DMS -> Kinesis -> Firehose -> S3 Tables ============
module "flow2" {
  source = "./flow2-aurora-dms-kinesis"

  region              = var.region
  project_name        = local.name
  db_password         = var.db_password
  vpc_id              = module.shared.vpc_id
  vpc_cidr            = module.shared.vpc_cidr
  private_subnet_1_id = module.shared.private_subnet_1_id
  private_subnet_2_id = module.shared.private_subnet_2_id
  table_bucket_name   = module.shared.table_bucket_name
  table_bucket_arn    = module.shared.table_bucket_arn
  error_bucket_arn    = module.shared.error_bucket_arn
  error_bucket_name   = module.shared.error_bucket_name
}

# ============ Flow 3: DocumentDB -> Lambda -> Firehose -> S3 Tables ============
module "flow3" {
  source = "./flow3-docdb-lambda"

  region              = var.region
  project_name        = local.name
  db_password         = var.db_password
  vpc_id              = module.shared.vpc_id
  vpc_cidr            = module.shared.vpc_cidr
  private_subnet_1_id = module.shared.private_subnet_1_id
  private_subnet_2_id = module.shared.private_subnet_2_id
  table_bucket_name   = module.shared.table_bucket_name
  table_bucket_arn    = module.shared.table_bucket_arn
  error_bucket_arn    = module.shared.error_bucket_arn
  error_bucket_name   = module.shared.error_bucket_name
}
