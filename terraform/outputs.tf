# ============ Shared ============
output "table_bucket_name" {
  description = "S3 Table bucket name shared by all three flows."
  value       = module.shared.table_bucket_name
}

output "table_bucket_arn" {
  description = "S3 Table bucket ARN."
  value       = module.shared.table_bucket_arn
}

# ============ Flow 1 ============
output "dynamodb_table_name" {
  description = "Flow 1 source DynamoDB table name."
  value       = module.flow1.dynamodb_table_name
}

# ============ Flow 2 ============
output "aurora_endpoint" {
  description = "Flow 2 Aurora PostgreSQL writer endpoint."
  value       = module.flow2.aurora_endpoint
}

output "kinesis_stream_arn" {
  description = "Flow 2 Kinesis CDC stream ARN."
  value       = module.flow2.kinesis_stream_arn
}

output "flow2_firehose_stream_name" {
  description = "Flow 2 Firehose delivery stream name."
  value       = module.flow2.firehose_stream_name
}

# ============ Flow 3 ============
output "docdb_endpoint" {
  description = "Flow 3 DocumentDB cluster endpoint."
  value       = module.flow3.docdb_endpoint
}

output "flow3_firehose_stream_name" {
  description = "Flow 3 Firehose delivery stream name."
  value       = module.flow3.firehose_stream_name
}
