# specs/requirements/aws

AWS IAM the voltmx-foundry-app scope needs to operate under the **assume-role** pattern,
consumed as an OpenTofu module by the implementation stack (same shape as the
mobile-store and static-files scope requirements).

It creates a dedicated **permissions role** that the nullplatform agent assumes
(`sts:AssumeRole`) plus one least-privilege policy:

- `s3:GetObject` on `arn:aws:s3:::<assets_bucket_name>/<assets_prefix>*` (default
  `foundry/`), and `s3:ListBucket` + `s3:GetBucketLocation` on the bucket limited to that
  prefix: the scope downloads the Foundry app the CI exported and registered as the
  `foundry` asset.
- `secretsmanager:GetSecretValue` + `secretsmanager:DescribeSecret` on
  `arn:aws:secretsmanager:<region>:<account>:secret:<secrets_prefix>*` (default `voltmx/`):
  the scope reads the Foundry technical user (`credentials_secret`, which the scope only
  accepts under `voltmx/<namespace slug>/` or the `secrets_prefix` of its scope
  configuration). Region and account come from the provider the module runs with, so the
  secrets must live in that region.

The role's ARN is wired into the agent (`assume_role_arns`) and published in the
`identity-access-control` provider with the selector `voltmx-foundry-app`, which is how
`utils/assume_role_step` finds it.

## Usage (implementation stack)

```hcl
module "scope_requirements_voltmx_foundry_app" {
  source = "git::https://github.com/nullplatform/scopes-voltmx-foundry-app.git//voltmx-foundry-app/specs/requirements/aws?ref=<tag>"

  cluster_name       = module.eks.eks_cluster_name
  agent_role_arn     = local.agent_role_arn
  assets_bucket_name = aws_s3_bucket.assets_mobile.bucket
}

module "agent_iam" {
  # ...
  assume_role_arns = [
    # ...
    module.scope_requirements_voltmx_foundry_app.permissions_role_arn,
  ]
}
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `cluster_name` | (required) | Cluster name; derives default resource names. |
| `assets_bucket_name` | (required) | Bucket the CI uploads the exported apps to (the scope configuration's `assets.bucket`). |
| `assets_prefix` | `foundry/` | Key prefix of the bucket the role may read. |
| `secrets_prefix` | `voltmx/` | Secrets Manager name prefix the scope may read (one folder per namespace below it). |
| `agent_role_arn` | `""` → derived | Agent role trusted to assume this role. Empty derives `nullplatform-<cluster>-agent-role`. |
| `additional_agent_role_arns` | `[]` | Extra trusted principals. |
| `role_name` | `""` → `nullplatform_<cluster>_voltmx_foundry_app_role` | Override for the role name. |
| `policies_name_prefix` | `""` → `nullplatform_<cluster>` | Override for the policy name prefix. |
| `iam_create_role` | `true` | When false, the module creates nothing. |
| `iam_resource_tags_json` | `{}` | Tags applied to IAM resources. |

## Outputs

`permissions_role_arn`, `role_name`.

## Tests

```bash
tofu init -backend=false && tofu test   # or: make test-tofu MODULE=voltmx-foundry-app
```

## Versioning

Point the module `source` at a **tag** that contains this module, never a branch.
