# Copy to terraform.tfvars (or pass with -var-file) and fill in real values.
# Usage: terraform apply -var-file=example.tfvars

project_name = "zero-etl-REPLACE_ME"
# Deploy region. Must support both S3 Tables and Glue zero-ETL-to-S3-Tables
# (e.g. us-east-1, us-east-2, us-west-2, eu-west-1, ap-northeast-1).
region = "us-west-2"

# Master DB password for the Aurora (flow2) and DocumentDB (flow3) clusters.
# Set via TF_VAR_db_password or here; never commit a real value.
# db_password = "REPLACE_ME"
