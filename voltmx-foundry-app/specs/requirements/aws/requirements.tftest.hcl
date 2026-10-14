mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_region" {
    defaults = {
      region = "us-east-1"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/mock-policy"
    }
  }
}

variables {
  cluster_name       = "test-cluster"
  assets_bucket_name = "assets-test-mobile"
}

run "default_role_name" {
  command = apply

  assert {
    condition     = aws_iam_role.nullplatform_voltmx_foundry_app[0].name == "nullplatform_test-cluster_voltmx_foundry_app_role"
    error_message = "the role name must default to nullplatform_<cluster>_voltmx_foundry_app_role"
  }

  assert {
    condition     = output.role_name == "nullplatform_test-cluster_voltmx_foundry_app_role"
    error_message = "role_name must expose the role name"
  }

  assert {
    condition     = output.permissions_role_arn == "arn:aws:iam::123456789012:role/mock-role"
    error_message = "permissions_role_arn must expose the role ARN"
  }

  assert {
    condition     = aws_iam_policy.nullplatform_voltmx_foundry_app[0].name == "nullplatform_test-cluster_voltmx_foundry_app_policy"
    error_message = "the policy name must default to nullplatform_<cluster>_voltmx_foundry_app_policy"
  }

  assert {
    condition     = jsondecode(aws_iam_role.nullplatform_voltmx_foundry_app[0].assume_role_policy).Statement[0].Principal.AWS == ["arn:aws:iam::123456789012:role/nullplatform-test-cluster-agent-role"]
    error_message = "the role must trust the derived agent role"
  }
}

run "least_privilege_policy" {
  command = apply

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_policy.nullplatform_voltmx_foundry_app[0].policy).Statement :
      !contains(flatten([s.Resource]), "*")
    ])
    error_message = "no statement may use Resource = \"*\""
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_policy.nullplatform_voltmx_foundry_app[0].policy).Statement :
      s.Resource if startswith(s.Sid, "SecretsManager")
    ] == ["arn:aws:secretsmanager:us-east-1:123456789012:secret:voltmx/*"]
    error_message = "the secrets resource must be the voltmx/ prefix in the current region and account"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_policy.nullplatform_voltmx_foundry_app[0].policy).Statement :
      s.Resource if startswith(s.Sid, "S3")
    ] == ["arn:aws:s3:::assets-test-mobile/foundry/*", "arn:aws:s3:::assets-test-mobile"]
    error_message = "the S3 statements must point at the foundry/ objects of the assets bucket and at the bucket itself"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_policy.nullplatform_voltmx_foundry_app[0].policy).Statement :
      s.Condition.StringLike["s3:prefix"] if s.Sid == "S3ListFoundryApps"
    ] == [["foundry/*"]]
    error_message = "listing the bucket must be limited to the foundry/ prefix"
  }

  assert {
    condition = sort(flatten([
      for s in jsondecode(aws_iam_policy.nullplatform_voltmx_foundry_app[0].policy).Statement : s.Action
    ])) == sort(["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation", "secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"])
    error_message = "the policy must grant exactly the read actions the scope needs"
  }
}

run "custom_prefixes" {
  command = plan

  variables {
    secrets_prefix = "voltmx/payments/"
    assets_prefix  = "apps/foundry/"
  }

  assert {
    condition     = local.secrets_prefix_arn == "arn:aws:secretsmanager:us-east-1:123456789012:secret:voltmx/payments/*"
    error_message = "the secrets resource must follow secrets_prefix"
  }

  assert {
    condition     = local.assets_objects_arn == "arn:aws:s3:::assets-test-mobile/apps/foundry/*"
    error_message = "the objects resource must follow assets_prefix"
  }
}

run "normalises_secrets_prefix_to_a_folder" {
  command = plan

  variables {
    secrets_prefix = "voltmx"
  }

  assert {
    condition     = local.secrets_prefix_arn == "arn:aws:secretsmanager:us-east-1:123456789012:secret:voltmx/*"
    error_message = "a secrets_prefix without a trailing slash must be treated as a folder"
  }
}

run "no_role_when_disabled" {
  command = apply

  variables {
    iam_create_role = false
  }

  assert {
    condition     = length(aws_iam_role.nullplatform_voltmx_foundry_app) == 0 && length(aws_iam_policy.nullplatform_voltmx_foundry_app) == 0 && length(aws_iam_role_policy_attachment.voltmx_foundry_app) == 0
    error_message = "iam_create_role = false must create nothing"
  }

  assert {
    condition     = output.permissions_role_arn == "" && output.role_name == ""
    error_message = "the outputs must be empty when nothing is created"
  }
}

run "rejects_invalid_bucket_name" {
  command = plan

  variables {
    assets_bucket_name = "Assets_Bucket/*"
  }

  expect_failures = [var.assets_bucket_name]
}

run "rejects_wildcard_secrets_prefix" {
  command = plan

  variables {
    secrets_prefix = "*"
  }

  expect_failures = [var.secrets_prefix]
}

run "rejects_assets_prefix_without_trailing_slash_or_with_wildcards" {
  command = plan

  variables {
    assets_prefix = "foundry*"
  }

  expect_failures = [var.assets_prefix]
}
