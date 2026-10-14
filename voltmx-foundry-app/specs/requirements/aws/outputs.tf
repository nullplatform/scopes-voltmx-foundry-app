output "permissions_role_arn" {
  description = "ARN of the voltmx-foundry-app permissions role assumed by the nullplatform agent role. Pass it to the agent (assume_role_arns) and publish it with the selector voltmx-foundry-app in the identity-access-control provider."
  value       = local.iam_create ? aws_iam_role.nullplatform_voltmx_foundry_app[0].arn : ""
}

output "role_name" {
  description = "Name of the voltmx-foundry-app permissions role"
  value       = local.iam_create ? aws_iam_role.nullplatform_voltmx_foundry_app[0].name : ""
}
