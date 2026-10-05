terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 6.0"
    }
  }
}

variable "region" {
  default = "us-east-1"
}

variable "project_name" {
  default = "zero-etl-workshop"
}

data "aws_caller_identity" "current" {}

# ============ VPC ============
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project_name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

data "aws_availability_zones" "available" { state = "available" }

resource "aws_subnet" "public_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public-1" }
}

resource "aws_subnet" "public_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.project_name}-public-2" }
}

resource "aws_subnet" "private_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.10.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-private-1" }
}

resource "aws_subnet" "private_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.11.0/24"
  availability_zone       = data.aws_availability_zones.available.names[1]
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project_name}-private-2" }
}

resource "aws_eip" "nat" { domain = "vpc" }

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public_1.id
}

resource "aws_route_table" "public" { vpc_id = aws_vpc.main.id }
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
resource "aws_route_table_association" "public_1" {
  subnet_id      = aws_subnet.public_1.id
  route_table_id = aws_route_table.public.id
}
resource "aws_route_table_association" "public_2" {
  subnet_id      = aws_subnet.public_2.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" { vpc_id = aws_vpc.main.id }
resource "aws_route" "private_nat" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}
resource "aws_route_table_association" "private_1" {
  subnet_id      = aws_subnet.private_1.id
  route_table_id = aws_route_table.private.id
}
resource "aws_route_table_association" "private_2" {
  subnet_id      = aws_subnet.private_2.id
  route_table_id = aws_route_table.private.id
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id          = aws_vpc.main.id
  service_name    = "com.amazonaws.${var.region}.s3"
  route_table_ids = [aws_route_table.private.id, aws_route_table.public.id]
}

# ============ S3 Table Bucket ============
# NOTE: encryption_configuration is declared explicitly to match what AWS returns. S3 Table
# buckets are ALWAYS encrypted (SSE-S3/AES256 by default); if this block is omitted the AWS
# provider plans encryption_configuration as null, then AWS returns AES256 on create, and the
# provider aborts with "Provider produced inconsistent result after apply" and taints the
# bucket. Declaring it keeps planned == applied. (Provider-side quirk in the 5.x s3tables
# support; revisit if a later provider computes this cleanly.)
resource "aws_s3tables_table_bucket" "main" {
  name = "${var.project_name}-tables-${data.aws_caller_identity.current.account_id}"

  encryption_configuration = {
    sse_algorithm = "AES256"
    kms_key_arn   = null
  }
}

# ============ Error Bucket ============
resource "aws_s3_bucket" "errors" {
  bucket = "${var.project_name}-errors-${data.aws_caller_identity.current.account_id}"
  # force_destroy lets `terraform destroy` empty the bucket first. Firehose writes
  # failed-record objects and Athena writes query results here, so without this the
  # bucket is non-empty at teardown and DeleteBucket fails with BucketNotEmpty.
  force_destroy = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "errors" {
  bucket = aws_s3_bucket.errors.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_versioning" "errors" {
  bucket = aws_s3_bucket.errors.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Block all public access to the Firehose error/backup bucket.
resource "aws_s3_bucket_public_access_block" "errors" {
  bucket                  = aws_s3_bucket.errors.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Deny any request that is not using TLS (aws:SecureTransport = false).
resource "aws_s3_bucket_policy" "errors" {
  bucket = aws_s3_bucket.errors.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.errors.arn,
        "${aws_s3_bucket.errors.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}

# Expire error/backup objects after 30 days (they are only for Firehose failure triage).
resource "aws_s3_bucket_lifecycle_configuration" "errors" {
  bucket = aws_s3_bucket.errors.id
  rule {
    id     = "expire-errors"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
  }
}

# ============ Outputs ============
output "vpc_id" { value = aws_vpc.main.id }
output "vpc_cidr" { value = aws_vpc.main.cidr_block }
output "public_subnet_1_id" { value = aws_subnet.public_1.id }
output "public_subnet_2_id" { value = aws_subnet.public_2.id }
output "private_subnet_1_id" { value = aws_subnet.private_1.id }
output "private_subnet_2_id" { value = aws_subnet.private_2.id }
output "table_bucket_arn" { value = aws_s3tables_table_bucket.main.arn }
output "table_bucket_name" { value = aws_s3tables_table_bucket.main.name }
output "error_bucket_arn" { value = aws_s3_bucket.errors.arn }
output "error_bucket_name" { value = aws_s3_bucket.errors.id }
