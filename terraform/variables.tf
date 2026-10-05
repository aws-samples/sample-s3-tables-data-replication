variable "region" {
  description = "AWS region to deploy into. Must be a region where BOTH Amazon S3 Tables and AWS Glue zero-ETL-to-S3-Tables are available (e.g. us-east-1, us-east-2, us-west-2, eu-west-1, ap-northeast-1). No default: set it explicitly via -var region=<region> or TF_VAR_region so the choice is deliberate and matches your AWS CLI region for the local-exec steps."
  type        = string
}

variable "project_name" {
  description = "Name prefix for all resources. No default: it is required so each deployment is uniquely named (supports running the workshop in a shared account). FEAT-002 adds a random-suffix helper for extra uniqueness."
  type        = string
}

variable "db_password" {
  description = "Master DB password shared by the Aurora (flow2) and DocumentDB (flow3) clusters. No default is shipped; supply it via TF_VAR_db_password or -var. It is only used to populate the clusters and their Secrets Manager secrets; never hardcode a value."
  type        = string
  sensitive   = true
}
