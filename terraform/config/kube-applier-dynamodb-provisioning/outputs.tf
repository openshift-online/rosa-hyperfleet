output "specs_table_arns" {
  description = "ARNs of the specs DynamoDB tables"
  value       = module.kube_applier_dynamodb.specs_table_arns
}

output "status_table_arns" {
  description = "ARNs of the status DynamoDB tables"
  value       = module.kube_applier_dynamodb.status_table_arns
}

