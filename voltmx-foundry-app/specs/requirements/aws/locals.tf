locals {
  # Module identifier
  iam_module_name = "requirements-voltmx-foundry-app"

  # Whether resources are created
  iam_create = var.iam_create_role

  # Derived names (overridable via variables): role
  # nullplatform_<cluster>_voltmx_foundry_app_role and policy
  # nullplatform_<cluster>_voltmx_foundry_app_policy.
  role_name            = var.role_name != "" ? var.role_name : "nullplatform_${var.cluster_name}_voltmx_foundry_app_role"
  policies_name_prefix = var.policies_name_prefix != "" ? var.policies_name_prefix : "nullplatform_${var.cluster_name}"

  # Primary agent role trusted by the permissions role. Defaults to the
  # conventional agent role name for the cluster when not provided explicitly.
  agent_role_arn = var.agent_role_arn != "" ? var.agent_role_arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/nullplatform-${var.cluster_name}-agent-role"

  assets_bucket_arn  = "arn:aws:s3:::${var.assets_bucket_name}"
  assets_objects_arn = "${local.assets_bucket_arn}/${var.assets_prefix}*"
  # A folder: "voltmx" would also match voltmx-other/*.
  secrets_prefix     = endswith(var.secrets_prefix, "/") ? var.secrets_prefix : "${var.secrets_prefix}/"
  secrets_prefix_arn = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${local.secrets_prefix}*"

  # Default tags applied to every IAM resource
  iam_default_tags = merge(var.iam_resource_tags_json, {
    ManagedBy = "nullplatform-custom-scope-role"
    Module    = local.iam_module_name
  })
}
