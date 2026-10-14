################################################################################
# voltmx-foundry-app scope — assume-role IAM
#
# The voltmx-foundry-app scope downloads the Foundry app the CI exported to the
# assets bucket (under the foundry/ prefix) and reads the Foundry technical
# user from Secrets Manager (under the voltmx/ prefix: one folder per
# namespace, see the scope's secrets_prefix). It does so via the ASSUME-ROLE
# pattern: this dedicated role holds the permissions and the nullplatform agent
# assumes it (sts:AssumeRole). The consuming stack passes this role's ARN to
# the agent (assume_role_arns) and publishes it in the identity-access-control
# provider with the selector voltmx-foundry-app (utils/assume_role_step).
#
# The role trusts the agent role BY NAME (derived default) rather than by a
# module output, so the consuming stack can wire the ARN back into the agent
# without creating a dependency cycle. The agent role name is the conventional
# "nullplatform-{cluster_name}-agent-role".
#
# Least privilege: read-only on one prefix of one bucket and on the secrets
# under one prefix.
################################################################################

resource "aws_iam_role" "nullplatform_voltmx_foundry_app" {
  count = local.iam_create ? 1 : 0

  name        = local.role_name
  description = "Permissions role assumed by the nullplatform agent role for the voltmx-foundry-app scope"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = concat([local.agent_role_arn], var.additional_agent_role_arns) }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.iam_default_tags
}

resource "aws_iam_policy" "nullplatform_voltmx_foundry_app" {
  count = local.iam_create ? 1 : 0

  name        = "${local.policies_name_prefix}_voltmx_foundry_app_policy"
  description = "Policy for the voltmx-foundry-app scope (read the exported apps of the assets bucket and the Foundry credentials)"
  tags        = local.iam_default_tags

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "S3ReadFoundryApps"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = local.assets_objects_arn
      },
      {
        Sid    = "S3ListFoundryApps"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = local.assets_bucket_arn
        Condition = {
          StringLike = { "s3:prefix" = ["${var.assets_prefix}*"] }
        }
      },
      {
        Sid    = "SecretsManagerReadFoundryCredentials"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = local.secrets_prefix_arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "voltmx_foundry_app" {
  count = local.iam_create ? 1 : 0

  role       = aws_iam_role.nullplatform_voltmx_foundry_app[0].name
  policy_arn = aws_iam_policy.nullplatform_voltmx_foundry_app[0].arn
}
