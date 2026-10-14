variable "agent_role_arn" {
  description = "ARN of the primary nullplatform agent IRSA role allowed to assume this permissions role via sts:AssumeRole, and always a trusted principal of the role's trust policy. Defaults (when empty) to the conventional agent role for the cluster: arn:aws:iam::<account>:role/nullplatform-<cluster_name>-agent-role."
  type        = string
  default     = ""

  validation {
    condition     = var.agent_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/.+", var.agent_role_arn))
    error_message = "agent_role_arn must be empty (to use the derived default) or match arn:aws:iam::<account-id>:role/<role-name>"
  }
}

variable "additional_agent_role_arns" {
  description = "Extra IAM role ARNs allowed to assume this permissions role, appended to agent_role_arn in the trust policy. Defaults to none."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for arn in var.additional_agent_role_arns : can(regex("^arn:aws:iam::[0-9]{12}:role/.+", arn))])
    error_message = "each additional_agent_role_arns entry must match arn:aws:iam::<account-id>:role/<role-name>"
  }
}

variable "cluster_name" {
  description = "Name of the cluster where the agent runs. Used to derive default resource names."
  type        = string
}

variable "role_name" {
  description = "Override for the voltmx-foundry-app permissions IAM role name. Defaults to nullplatform_{cluster_name}_voltmx_foundry_app_role."
  type        = string
  default     = ""
}

variable "policies_name_prefix" {
  description = "Override for the IAM policy name prefix. Defaults to nullplatform_{cluster_name}."
  type        = string
  default     = ""
}

variable "iam_create_role" {
  description = "Whether to create the permissions role and its policy. When false, the module produces no resources."
  type        = bool
  default     = true
}

variable "iam_resource_tags_json" {
  description = "Tags to apply to IAM resources created by this module."
  type        = map(string)
  default     = {}
}

variable "assets_bucket_name" {
  description = "Name of the S3 bucket the CI uploads the exported Foundry apps to (the scope configuration's assets.bucket). The role gets read-only access to it."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9.-]+$", var.assets_bucket_name))
    error_message = "assets_bucket_name must be a bucket name (lowercase letters, digits, dots and hyphens)"
  }
}

variable "secrets_prefix" {
  description = "Secrets Manager name prefix the scope reads the Foundry technical user from (the scope configuration's credentials_secret, one folder per namespace below it). The role can read every secret in that folder (a trailing / is added when missing, so voltmx never matches voltmx-other/*)."
  type        = string
  default     = "voltmx/"

  validation {
    condition     = can(regex("^[A-Za-z0-9/_+=.@-]+$", var.secrets_prefix))
    error_message = "secrets_prefix must be a non-empty Secrets Manager name prefix (letters, digits and /_+=.@-), without wildcards"
  }
}

variable "assets_prefix" {
  description = "Key prefix of the assets bucket the CI uploads the exported Foundry apps under. The role can only read objects below it."
  type        = string
  default     = "foundry/"

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*/$", var.assets_prefix))
    error_message = "assets_prefix must be a folder ending in / (letters, digits and _.-), without wildcards"
  }
}
