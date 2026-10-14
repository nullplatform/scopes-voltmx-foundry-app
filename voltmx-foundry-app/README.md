# voltmx-foundry-app

nullplatform scope that publishes a Volt MX Foundry app (integration, identity and object services) to a Foundry
environment with the Foundry CLI (`mfcli`).

## What the developer and DevOps see

| Who | Where | Fields |
|---|---|---|
| Developer | scope (`specs/service-spec.json.tpl`) | `foundry_app_name` (create only) |
| DevOps | scope configuration `Volt MX Foundry app` (`specs/scope-configuration.json.tpl`, per account, namespace or dimension) | `environment_name`, `auth` (cloud `account_id` or on-premises `identity_url` + `console_url`), `credentials_secret` (`{"username","password"}`), `allowed_apps`, `app_name_prefix`, `secrets_prefix`, `assets.bucket`, `assets.region` |
| Operator | `values.yaml` | `MFCLI_CMD`, `PUBLISH_TIMEOUT_SECONDS`, `PUBLISH_POLL_SECONDS`, `MFCLI_CALL_TIMEOUT_SECONDS`, `WORKDIR` |

The CI exports the app from Foundry, uploads the zip to the assets bucket and registers it as an asset named
`foundry` (type `bundle`) of the build. The release semver is the Foundry app version.

Application parameters become the service configuration profile (`deployment/templates/service-profile.json.tpl`,
overridable with `PROFILE_TEMPLATE`): every `${NAME}` placeholder is replaced by the parameter value, and
`"${PROFILE_VARS}"` by all of them as an object. Values are never printed.

## Multi-tenant Foundry environments

A Foundry environment is shared by the apps of many teams, the technical user of an environment can import,
publish and unpublish any app in it, and `foundry_app_name` is chosen by the developer. Without more checks a scope
of one namespace could overwrite, publish or (on `delete-scope`) unpublish the app of another team. The scope
binds each scope to what DevOps allowed for its namespace or dimension:

- **Apps.** The scope configuration lists `allowed_apps` (exact names, or a prefix followed by `*`, such as
  `Payments*`) and/or `app_name_prefix`. `build_context` fails closed: the app must match `allowed_apps` when it is
  set and start with `app_name_prefix` when it is set, and when neither is set the deployment fails with
  "Configure allowed_apps or app_name_prefix in the Volt MX Foundry app scope configuration". There is no
  permissive default and a lone `*` is rejected. Give each namespace (or dimension) its own scope configuration.
- **Credentials.** `credentials_secret` must live under `voltmx/<namespace slug>/` (or the `secrets_prefix` of the
  scope configuration, a folder under `voltmx/`), checked by `build_context` and again by `read_credentials`, so a
  scope cannot use the technical user of another team. Ideally each team has its own Foundry user with access to
  its apps only; the IAM policy of the agent should grant `voltmx/*` only if every team's folder is separated.
- **Ownership on delete.** Foundry has no tag or attribute where the scope could record that it owns an app (the
  mock has none either, and the service profile is the app's configuration, not ours). `do_unpublish` therefore
  infers ownership: on `delete-scope` it only unpublishes when the active version was released by a `finalized`
  deployment of this scope (`np deployment list` + `np release read`), it leaves the app published with a warning
  otherwise, and it fails closed when the history cannot be read. On `delete-deployment` it only unpublishes when
  the deployment's version is the active one.

Limitations: ownership is matched by version, so two scopes allowed to deploy the same app (for example one per
dimension on the same environment) are indistinguishable when they deployed the same version. Keep one scope per
app and environment. The check happens in the scope, not in Foundry: anyone with the technical user in the
Foundry console can still change any app.

## Actions: no blue-green

Foundry keeps a single active version per app and environment: `Publish` replaces it, there is no way to serve two
versions side by side and move traffic between them. The scope therefore offers `start-initial`,
`rollback-deployment` (publishes the release of the previous finalized deployment again) and `delete-deployment`,
plus `create-scope`, `update-scope` and `delete-scope`. There is no `start-blue-green`, `switch-traffic` or
`finalize-blue-green`.

## Deployment scripts (`deployment/scripts/`)

| Script | Kind | Does |
|---|---|---|
| `build_context` | sourced | validates CONTEXT and the scope configuration; exports `FOUNDRY_APP`, `APP_VERSION`, `ASSET_URL`, `ENVIRONMENT_NAME`, `MFCLI_AUTH_ARGS`, `CREDENTIALS_SECRET`, `SECRETS_PREFIX`, `PROFILE_VARS`, `PREVIOUS_DEPLOYMENT_ID`, `PREVIOUS_RELEASE_SEMVER`, `WORKDIR`, ... |
| `fetch_asset` | sourced | downloads the zip from the configured bucket only; exports `FOUNDRY_ZIP` |
| `read_credentials` | sourced | reads the secret (only under `SECRETS_PREFIX`); exports `MFCLI_USER`, `MFCLI_PASSWORD` (memory only, never printed) |
| `mfcli_run` | library / script | the only caller of `$MFCLI_CMD`; masks the password and translates errors (credentials, not found, timeout) |
| `render_profile` | script | writes `$WORKDIR/profile.json` (mode 600) |
| `do_import`, `do_reconfig`, `do_publish` | script | `Import`, `import-config` (deletes the profile afterwards), `Publish` |
| `wait_publish` | script | polls `publish-status` until `success`, `failed` or the timeout |
| `export_outputs` | script | `appinfo` -> deployment message `VOLTMX_FOUNDRY_APP` with `app_key` and `service_url` (best effort, never the secret) |
| `do_rollback` | script | `Publish -v $PREVIOUS_RELEASE_SEMVER` and waits |
| `do_unpublish` | script | `Unpublish`; with `APP_VERSION` only when that version is active, without it only when the active version was released by this scope |

The engine sources every step of a workflow in one `bash -c`, joined by `&&`. `build_context`, `fetch_asset` and
`read_credentials` export variables, so they run in that shell; every other step re-runs itself in a child shell
when it is sourced, so its `exit`, traps and shell options never end or alter the chain
(`deployment/tests/scripts/workflow_chain_test.bats` runs the chains that way).

| Workflow | Steps | Step configuration |
|---|---|---|
| start-initial | `build_context`, `fetch_asset`, `read_credentials`, `render_profile`, `do_import`, `do_reconfig`, `do_publish`, `wait_publish`, `export_outputs` | |
| rollback-deployment | `build_context`, `read_credentials`, `do_rollback` | `BUILD_CONTEXT_MODE: rollback` |
| delete-deployment | `build_context`, `read_credentials`, `do_unpublish` | `BUILD_CONTEXT_MODE: rollback`, `UNPUBLISH_MODE: deployment` |
| delete-scope | `build_context`, `read_credentials`, `do_unpublish` | `BUILD_CONTEXT_MODE: scope`, `UNPUBLISH_MODE: scope` |

`BUILD_CONTEXT_MODE` is `deployment` (default: asset, profile variables and previous deployment), `rollback` (no
asset or profile variables) or `scope` (no deployment, release or asset; the app binding, auth, environment and
secrets are still validated). `UNPUBLISH_MODE` is required and never inferred.

Every step is idempotent: a deployment that timed out waiting for the publish can be re-run.

Order matters: `do_reconfig` (`import-config`) applies the service profile to the app in the environment *before*
`Publish`. The profile belongs to the app and environment, not to a version, so the version that is still active
runs with the new profile from that moment on, and a publish that fails or times out does not roll the profile back.
Parameter changes must stay compatible with the active version (add new keys before removing old ones).

The zip is checked before Import: it must carry exactly one `Apps/<app>/Meta.json` whose `name` is the scope's app
and whose `version` is the release semver, because `Import -a/-v` would otherwise import another app's export under
this app's name. That layout is the one the mfcli mock exports; it is an assumption until D1.

Every mfcli call is bounded by `MFCLI_CALL_TIMEOUT_SECONDS` (`timeout`, or a watchdog when the image has none),
which sends TERM and, 5 seconds later, KILL. A `publish-status` call that hangs is only stopped by that bound, so
`wait_publish` can run up to `PUBLISH_TIMEOUT_SECONDS` + `MFCLI_CALL_TIMEOUT_SECONDS` (+ 5s) before it fails.
`wait_publish` only accepts a `success` that reports the target as both `version` and `active_version` (otherwise it
keeps polling until `PUBLISH_TIMEOUT_SECONDS`) and fails at once when `publish-status` does not answer JSON.
`do_unpublish` never relies on mfcli error texts. When `publish-status` fails or does not answer JSON, deleting a
deployment warns and leaves the app as it is (it must never be blocked, and not unpublishing is the safe side),
while deleting a scope fails closed.

Secrets: parameter values reach `jq` only through stdin or the environment, never its argv. The Foundry password
does reach the argv of mfcli (`-p`, the documented contract), so it is visible in the process list of the worker
while mfcli runs; see the D1 checklist.

Each deployment becomes the version every client gets. A "publish without making it the default" option
(`set_as_default_version`) is left out until `set-appversion` is validated in D1.

## Tests

```bash
bats -r voltmx-foundry-app/          # or ./testing/run_bats_tests.sh voltmx-foundry-app
shellcheck -S warning voltmx-foundry-app/deployment/scripts/*
```

The deployment tests run against the mfcli mock (`tools/mfcli-mock/mfcli`, `MFCLI_MOCK_BIN` overrides it) with its state
in the test tmpdir. The spec tests need `gomplate`.

## Checklist for D1 (real mfcli.jar)

- [ ] Can mfcli take the password from the environment or a file instead of `-p` (visible in `ps`)?
- [ ] `publish-status`: output format (the scope expects JSON `{"status","version","active_version"}`), status
      values, and the exit code and text for an app that is not published (`do_unpublish` fails closed on any error).
- [ ] `Import`: precedence of `-a`/`-v` over the zip contents, and the export layout (`Apps/<app>/Meta.json` is
      assumed by `fetch_asset`).
- [ ] `set-appversion`: publishing a version without making it the default (the `set_as_default_version` capability
      was left out until then).
- [ ] How long `Import`/`Publish` take on a real environment, to size `MFCLI_CALL_TIMEOUT_SECONDS` and
      `PUBLISH_TIMEOUT_SECONDS`.
