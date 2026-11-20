# scopes-voltmx-foundry-app

nullplatform scope that publishes a Volt MX Foundry app to a Foundry environment with the Foundry CLI (`mfcli`): each deployment imports the app the CI exported, applies the application parameters as the app's service configuration profile and publishes the release version. Built on the `scopes-*` template; the sections after [Layout](#layout) are the template's operating notes. The contracts of the scripts, the multi-tenant rules and the D1 checklist are in [`voltmx-foundry-app/README.md`](voltmx-foundry-app/README.md); the mock of the Foundry CLI is documented in [`voltmx-foundry-app/tools/mfcli-mock/README.md`](voltmx-foundry-app/tools/mfcli-mock/README.md).

## What a Foundry app is

A Volt MX app has two halves. The client (Iris) is a mobile or web binary that `scopes-mobile-store` distributes. The server half is a **Foundry app**: the integration services (REST, SOAP, database adapters), identity services and object services the client calls, hosted by a Foundry server (Volt MX cloud, or an on-premises installation with its Identity and Console URLs). A Foundry app is developed in the Foundry console and shipped as an export zip; `mfcli Import` loads a version of it into Foundry and `mfcli Publish` makes that version the one an environment serves, after which the app answers on the environment's service URL with an app key. This scope is that server half: one scope per app and Foundry environment, selected through the environment dimension.

## Why there is no blue-green

Foundry keeps **one active version per app and environment**: `Publish` replaces it and there is no way to serve two versions side by side or move a share of the traffic between them. The scope therefore offers `start-initial`, `rollback-deployment` (publishes the version of the previous finalized deployment again; every imported version stays in Foundry, so nothing is downloaded) and `delete-deployment` (when the deleted deployment's version is the one Foundry serves, it publishes the previous finalized release again the same way, or unpublishes when the scope has none), plus `create-scope`, `update-scope`, `delete-scope` and `diagnose-scope`. There is no `start-blue-green`, `switch-traffic` or `finalize-blue-green`, and the deployment is the version every client gets as soon as the publish finishes.

## Asset contract

The CI exports the app from Foundry (`mfcli Export`, or the console), uploads the zip to the assets bucket of the scope configuration (`assets.bucket`, under `foundry/`) and registers it with `np asset create` as an asset named **`foundry`** of type **`bundle`** of the build. The **release semver is the Foundry app version**: `Import -a <app> -v <semver>` and `Publish -v <semver>` use it, so a release `1.4.0` publishes version `1.4.0` of the app. The zip must carry exactly one `Apps/<app>/Meta.json` whose `name` is the scope's `foundry_app_name` and whose `version` is the release semver; `fetch_asset` refuses anything else so an export of another app can never be imported under this app's name.

## Real Foundry or the mock: `MFCLI_CMD`

Every Foundry call goes through `deployment/scripts/mfcli_run`, which runs `$MFCLI_CMD <Command> -u <user> -p <password> <auth> ...`. What `MFCLI_CMD` is decides what the scope talks to:

| Setting | `MFCLI_CMD` | Where |
|---|---|---|
| Production | `java -jar /opt/mfcli/mfcli.jar` | `voltmx-foundry-app/values.yaml` (default) |
| POC and tests | `/app/pkg/voltmx-foundry-app/tools/mfcli-mock/mfcli` | `mfcli.command` of the scope configuration, or `MFCLI_CMD` in the worker environment |

The worker image (`Dockerfile`) ships OpenJDK 17, the AWS CLI and the mock, but **not `mfcli.jar`**: HCL does not allow redistributing it. A real deployment bakes it into a derived image (`COPY mfcli.jar /opt/mfcli/mfcli.jar`) or mounts it at that path (`MFCLI_JAR`) and keeps the default `MFCLI_CMD`. The POC runs the mock instead, selected per scope configuration with the optional `mfcli.command` field ("Foundry CLI (testing)"), whose only accepted value is that bundled mock, exactly `/app/pkg/voltmx-foundry-app/tools/mfcli-mock/mfcli` with no arguments (`build_context` compares the resolved path and fails every action otherwise: whatever runs as `MFCLI_CMD` sees the credentials and the parameter values); the mock keeps its state in `MFCLI_MOCK_STATE` (default `/tmp/mfcli-mock-state`, inside the worker: enough for one session). The worker environment wins over `values.yaml`, and `mfcli.command` wins over both, so switching to a real Foundry is removing `mfcli.command`; nothing else in the scope changes. The mock follows the command names and flags of the HCL documentation; what is assumed rather than documented is listed in its README and in the D1 checklist of the module README.

## Multi-tenant Foundry environments

A Foundry environment is shared by the apps of many teams, and the technical user of an environment can import, publish and unpublish any app in it. The scope binds each scope to what DevOps allowed for its namespace or dimension in the `Volt MX Foundry app` scope configuration, failing closed:

- **Apps.** `allowed_apps` (exact names or `Prefix*` globs) and/or `app_name_prefix` must match the scope's `foundry_app_name`; with neither set, every action fails asking for one. A lone `*` is rejected.
- **Credentials.** `credentials_secret` must live under `voltmx/<namespace slug>/` (or the `secrets_prefix` of the scope configuration, a folder under `voltmx/`), checked by `build_context` and again by `read_credentials`; the IAM role of `specs/requirements/aws` reads `voltmx/*` only.
- **Ownership on delete.** Foundry records no owner, so `delete-scope` only unpublishes when the active version was released by a finalized deployment of this scope, and `delete-deployment` only acts when the deployment's version is the active one (restoring the previous finalized release of the scope, or unpublishing when there is none). Keep one scope per app and environment.

The full rules and their limitations are in [`voltmx-foundry-app/README.md`](voltmx-foundry-app/README.md#multi-tenant-foundry-environments).

## Layout

```
entrypoint              agent calls it; routes deployment actions to service/deployment, the rest to service/scope
service/                scope, deployment and instance handlers (map an action to its workflow) and the shared runner
voltmx-foundry-app/
  scope/workflows/      create, update (resolve the scope configuration, check the app binding, the auth and the
                        credentials secret), delete (unpublish what this scope released), diagnose
  deployment/workflows/ initial, rollback, delete
  instance/workflows/   list: answers instance:data with the version Foundry serves for the app
  diagnose/checks/      console_reachable, credentials_valid, app_published (executor of scope/workflows/diagnose.yaml)
  deployment/scripts/   build_context, fetch_asset, read_credentials, render_profile, do_import, do_reconfig,
                        do_publish, wait_publish, export_outputs, do_rollback, do_unpublish, mfcli_run, validators
  deployment/templates/ service-profile.json.tpl: the service configuration profile built from the parameters
  deployment/tests/     BATS tests of every script, the workflows (static checks + the real engine) and the specs
  utils/                assume_role_step: assumes the scope IAM role (identity-access-control provider, selector voltmx-foundry-app)
  tools/mfcli-mock/     bash stand-in for mfcli.jar with its contract (README) and tests
  specs/                service-spec, scope-configuration, scope-type-definition, notification-channel, actions/*.json.tpl
  specs/requirements/aws  OpenTofu module: the IAM role the agent assumes (assets bucket + voltmx/* secrets)
  values.yaml           operator configuration for the workflows (MFCLI_CMD, timeouts, WORKDIR)
Dockerfile              worker image on the shared worker-bridge base (OpenJDK 17, aws-cli, zip, the mock)
mise.toml               run it on your machine as a package (`np package run`)
```

| Action | Workflow |
|---|---|
| `create-scope` / `update-scope` / `delete-scope` | `scope/workflows/{create,update,delete}.yaml` |
| `diagnose-scope` | `scope/workflows/diagnose.yaml` (executor over `diagnose/checks`) |
| `start-initial` | `deployment/workflows/initial.yaml` |
| `rollback-deployment` | `deployment/workflows/rollback.yaml` |
| `delete-deployment` | `deployment/workflows/delete.yaml` (also for `failed` deployments, and for a deployment cancelled while in flight: with the initial strategy the platform dispatches `delete-deployment`, not `rollback-deployment`) |
| any other slug `foo` | `scope/workflows/foo.yaml`, or `deployment/workflows/foo.yaml` when it carries a `deployment_id` |

A new action needs its `specs/actions/<slug>.json.tpl`, its slug in `available_actions`, and the workflow. Every `--overrides-path` directory can hold `<entity>/workflows/<action>.yaml` to layer steps on top of the base workflow.

`instance:data` runs `instance/workflows/list.yaml` (`service/instance/entrypoint`): it asks `publish-status` for the app and prints only JSON (its first step sends every log to stderr). Logs, metrics and parameters are not implemented: `log:read` and `metric:*` answer empty results, and `parameter:*` fails. To serve one, add `<slug>/<entity>/workflows/` and route it in `entrypoint` (see the `k8s` scope in [nullplatform/scopes](https://github.com/nullplatform/scopes)); their steps must print only JSON.

The engine (`np service workflow exec`) sources every step of a workflow in one `bash -c`, joined by `&&`: what a step exports reaches the next steps, the first step that fails stops the workflow, and a step's `configuration` only applies to that step (as `KEY=value` prefix assignments on the `source`, which the step's child processes inherit). `output:` is informative only (the engine ignores it): steps list what they export there, and `deployment/tests/workflows/` checks that every variable a step consumes is declared by an earlier one. `set -e` does not apply inside steps chained with `&&` (only in the last one), and a bare `exit` in a sourced step ends the whole chain, so the steps that export nothing re-run themselves in a child shell when sourced. The worker environment wins over the `configuration` of `values.yaml`. Keep step `configuration` values to one word (older CLIs splice them unquoted).

## Tests

```bash
make lint                                    # shellcheck of every script
make test-unit MODULE=voltmx-foundry-app     # BATS: deployment, instance, diagnose and utils tests
bats -r voltmx-foundry-app                   # the same plus tools/mfcli-mock/tests (the runner only looks two levels deep)
make test-tofu MODULE=voltmx-foundry-app     # specs/requirements/aws
```

`deployment/tests/workflows/engine_smoke_test.bats` runs `initial` and `rollback` through the real `np` engine against the mock and is skipped when `np` is not installed. The spec tests need `gomplate`; the workflow checks need `python3` with PyYAML.

## Install in your organization

The scope is published once as the package `np-voltmx-foundry-app` (scope type "Volt MX Foundry app"), visible to every organization. You do not copy its specs: you install the package and use it read-only.

How installing a package works, how it coexists with a copy you registered, how to upgrade, and when to fork instead are in the [package installation guide](https://docs.nullplatform.com/docs/packages/install); this section has what is specific to this scope.

Already registered a copy with tofu-modules' `scope_definition` from your infrastructure repository? It keeps working: it registered specs that stay in every release, and the package installs next to it, as the guide explains.

Installing it touches the same three layers as registering a scope yourself, and only the nullplatform layer changes:

| Layer | What | Module |
|---|---|---|
| infrastructure (cloud credentials) | The permissions role the agent assumes: read of the exported apps in the assets bucket and of the `voltmx/*` secrets | [`voltmx-foundry-app/specs/requirements/aws`](./voltmx-foundry-app/specs/requirements/aws) |
| nullplatform (nullplatform API key) | The installation of the package, the scope type, the NRN settings and the scope-configuration schema | tofu-modules' `scope_package_installation` |
| bindings | The agent channel, the role under selector `voltmx-foundry-app` in your IAM provider, and the scope's settings | tofu-modules' `scope_definition_agent_association`, your providers |

Pick ONE release of this repository (the latest is on its [releases page](https://github.com/nullplatform/scopes-voltmx-foundry-app/releases)) and use its version in every place below: the IAM role is the one the worker of that same release expects.

```hcl
# ── infrastructure layer ─────────────────────────────────────────────
module "voltmx_foundry_app_requirements" {
  source = "git::https://github.com/nullplatform/scopes-voltmx-foundry-app.git//voltmx-foundry-app/specs/requirements/aws?ref=vX.Y.Z"

  cluster_name       = "my-cluster" # names the role nullplatform_my-cluster_voltmx_foundry_app_role
  agent_role_arn     = module.agent_iam.nullplatform_agent_role_arn
  assets_bucket_name = aws_s3_bucket.assets_mobile.bucket
}

# The agent role must be allowed to assume it: add it to the assume_role_arns
# of tofu-modules' infrastructure/aws/iam/agent.
#   assume_role_arns = [..., module.voltmx_foundry_app_requirements.permissions_role_arn]

# ── nullplatform layer ───────────────────────────────────────────────
module "voltmx_foundry_app" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_package_installation?ref=v9.16.0"

  nrn             = var.nrn
  np_api_key      = var.np_api_key # for the NRN settings patch (np nrn patch)
  package_slug    = "np-voltmx-foundry-app"
  package_version = "X.Y.Z" # the same release, without the v

  # Yours, created from this repository's templates at the same release:
  service_spec_name                = "Volt MX Foundry app" # the scope type developers pick
  service_spec_description         = "Publishes a Volt MX Foundry app to a Foundry environment"
  service_path                     = "voltmx-foundry-app"
  repository_scope_template        = "https://raw.githubusercontent.com/nullplatform/scopes-voltmx-foundry-app/refs/tags"
  repository_scope_template_branch = "vX.Y.Z" # the same release
  create_scope_configuration       = true
  create_agent_channel             = false # the channel lives in your bindings layer, below
}

# ── bindings layer ───────────────────────────────────────────────────
# voltmx_foundry_app_requirements and voltmx_foundry_app come from the other layers (remote state).
module "voltmx_foundry_app_channel" {
  source = "git::https://github.com/nullplatform/tofu-modules.git//nullplatform/scope_definition_agent_association?ref=v9.16.0"

  nrn                      = var.nrn
  tags_selectors           = { cluster = "runtime" } # must match the agent's TAGS
  scope_specification_id   = local.voltmx_foundry_app.service_specification_id
  scope_specification_slug = local.voltmx_foundry_app.service_specification_slug
  service_path             = "voltmx-foundry-app"

  # The channel template, from the same tag
  repository_notification_channel        = "https://raw.githubusercontent.com/nullplatform/scopes-voltmx-foundry-app/refs/tags"
  repository_notification_channel_branch = "vX.Y.Z" # the same release

  worker_orchestrator = true
  package_slug        = local.voltmx_foundry_app.package_slug
}

# The scope's settings, in a provider of the schema the installation created:
# the Foundry environment, its access and the technical user (every key, and the
# shape of auth, is in voltmx-foundry-app/specs/scope-configuration.json.tpl).
resource "nullplatform_provider_config" "voltmx_foundry_app_configuration" {
  nrn  = var.nrn
  type = local.voltmx_foundry_app.scope_configuration_specification_slug
  attributes = jsonencode({
    environment_name   = "dev"
    auth               = { account_id = "123456789" } # Volt MX cloud; on-premises: { identity_url, console_url }
    credentials_secret = "voltmx/my-namespace/foundry" # under the requirements module's secrets_prefix
    assets             = { bucket = aws_s3_bucket.assets_mobile.bucket }
  })
}

# One aws-iam-configuration per NRN and dimensions: add the entry to the list
# your IAM provider already has.
#   { selector = "voltmx-foundry-app", arn = local.voltmx_foundry_app_requirements.permissions_role_arn }
```

The scope assumes the role it finds under selector `voltmx-foundry-app` in the IAM provider closest to its NRN. To upgrade, move the release in every layer: `ref` of the requirements module, `package_version` and `repository_scope_template_branch` of the installation and `repository_notification_channel_branch` of the channel. See tofu-modules' [`scope_package_installation`](https://github.com/nullplatform/tofu-modules/tree/main/nullplatform/scope_package_installation) for its inputs and outputs.

Prerequisites: an agent whose `TAGS` match the channel's `tags_selectors`, with `np-voltmx-foundry-app` in its `worker_orchestrated_packages` and `public.ecr.aws/nullplatform/*` in `worker.allowedRegistries`.

Every release publishes the new revision from this repository ([`voltmx-foundry-app/publish`](./voltmx-foundry-app/publish), a stack on tofu-modules' `scope_package_publish`, applied by the `publish-package` job of the release workflow).

## Run locally as a package

`np package run` runs this scope on your machine the way production does: a
local controlplane-agent that registers with the platform, spawns the worker
image built from this repo, and hands it every action routed to it. No cluster,
no publish. The two tasks in `mise.toml` are the whole contract with the CLI:

| Command | Runs | Does |
|---|---|---|
| `np package build --image` | `mise run build:image` | Builds `voltmx-foundry-app-worker:dev` |
| `np package run` | `mise run run` | Builds the image, then starts the local agent |

Prerequisites: **Docker** with host networking (Linux as is; on Docker Desktop
enable *host networking*), **[mise](https://mise.jdx.dev)** (`mise trust` once
here), an **`NP_API_KEY`** for the agent to register with, and `np` from the
**alpha** channel, which carries `np package run`:

```bash
curl -fsSL https://cli.nullplatform.com/install.sh | VERSION=alpha sh   # ~/.local/bin/np
np package run --help                                                   # must list --no-forward-env
```

```bash
export NP_API_KEY=...
eval "$(aws configure export-credentials --format env)"   # cloud credentials as variables
export VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN=none            # your own credentials, no role to assume
np package run --log-level DEBUG                          # Ctrl+C to stop
```

The agent is tagged `package:voltmx-foundry-app` and `local:<your user>`. It receives an
action only when the scope's notification channel selects those tags, so
point a channel at `local:<your user>` to route work to your machine.

> **Tags decide who gets the work.** Never start a local agent with tags a
> production channel selects: it would receive production actions.

`np package run` forwards your shell's environment to the agent container,
minus what describes your machine (`PATH`, `HOME`, `DOCKER_*`, `KUBECONFIG`,
`AWS_PROFILE` and the other file-pointing AWS variables), and the `run` task
passes the same variables to the worker through an `NP_WORKER_RULES` entry.
Every secret in your shell crosses too, and is readable with `docker inspect`;
pass `--no-forward-env` to forward nothing.

| Variable | Default | Purpose |
|---|---|---|
| `NP_API_KEY` | required | The key the agent registers with (`--api-key` also sets it) |
| `NP_LOG_LEVEL` | `INFO` | Agent log level (`--log-level` also sets it) |
| `NP_PACKAGE_SLUG` | `voltmx-foundry-app` | The slug in the `package:<slug>` tag, when published under another slug |
| `NP_LOCAL_USER` | `$USER` | The value of the `local:<user>` tag |
| `NP_AGENT_IMAGE` | `controlplane-agent:latest` | The agent image; needs worker rules (0.11.1+) |

The local run never changes what the platform runs. To ship the change, merge
it: the release publishes the image and registers the artifact.

## CI

| Workflow | When | What |
|---|---|---|
| branch-validation | PR | branch named `feat/…`, `fix/…`, `chore/…` |
| conventional-commit | PR | commit messages (release-please reads them) |
| shellcheck | PR | every bash script |
| trivy | PR | IaC misconfiguration and image scan, to the Security tab |
| beta | PR (opened, push, reopened) | publish-test-image-oci: pushes `beta/<image>:test-<branch>-<short sha>` and registers it as a nullplatform artifact |
| release | push to `main` | release-please → build and push `vX.Y.Z` and `latest` to ECR Public → nullplatform artifact → the package revision (`voltmx-foundry-app/publish`) → GitHub release |
| auto-merge-release | after release | merges the release PR |
| dependabot | daily / weekly | base image and shared workflow bumps |

## Image tags

| Image | Moved by | Use it to |
|---|---|---|
| `agent-plugins/scopes/<name>:vX.Y.Z` | its release, once | pin an exact version |
| `agent-plugins/scopes/<name>:latest` | each release | follow the last released version |
| `beta/agent-plugins/scopes/<name>:test-<branch>-<short sha>` | each push to a pull request of this repository | deploy a change to a test scope before merging it |

Beta images live in a separate repository that the beta role can write and the production role cannot, so a beta can never overwrite a released image. Pull requests from this repository can assume the beta role (fork and bot pull requests are skipped), and the tag carries the commit SHA, so two pull requests never overwrite each other by accident. Nothing deletes beta tags: they are ephemeral by convention. Each beta is also registered as its own nullplatform oci_image artifact (the `beta/` repository, under `NP_ARTIFACT_NRN`), separate from the release artifact, so it can be deployed to a test scope from the platform.

## Publishing

After adding the **Public ECR** service to the application, set in this repository:

| Name | Kind | Value |
|---|---|---|
| `AWS_ROLE_ARN_ECR_PUSH` | secret | the publisher role ARN the Public ECR service returns |
| `NP_ARTIFACT_NRN` | variable | the NRN of the organization that owns the artifacts |

`ARTIFACT_NP_API_KEY` comes from the organization, as do `PACKAGE_STATE_AWS_ACCOUNT_ID`, `PACKAGE_TFSTATE_BUCKET` and `PACKAGE_TFSTATE_REGION`, where the publish stack keeps its state (the state role is `github-actions-<repository>-package-state` in that account, by convention). The release checks all three before building and fails with a clear error if one is missing. Beta images assume the role in the organization secret `AWS_BETA_ROLE_ARN` (no role is written in the workflow) and push to the image's `beta/` repository in ECR Public, which the dispatcher creates together with the production one.
