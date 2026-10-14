# mfcli mock

A bash stand-in for `mfcli.jar`, the HCL Volt MX Foundry command-line utility. It lets the
`voltmx-foundry-app` scope be developed and tested without a real Foundry. It follows the command names and
flags from the HCL documentation and keeps its state in local JSON files.

The scope always calls `$MFCLI_CMD <Command> <flags>`:

| Where | `MFCLI_CMD` |
|---|---|
| Production | `java -jar /opt/mfcli/mfcli.jar` |
| Tests / POC | `<repo>/voltmx-foundry-app/tools/mfcli-mock/mfcli` |

Requirements: bash 3.2+, `jq`, `zip`, `unzip`.

## HCL documentation used

- Foundry CLI reference (commands, auth flags, Import/Export/Publish/Unpublish/appinfo/authenticate):
  https://help.hcl-software.com/voltmx/v9.5/Foundry/voltmx_foundry_user_guide/Content/CI_Foundry.html
- Service configuration profiles (`import-config` / `export-config`, `-x`, `-y`):
  https://help.hcl-software.com/voltmx/v9.2/Foundry/voltmx_foundry_user_guide/Content/ServiceConfigProfile.html
- Long-form flag names (`--user`, `--password`, `--account`, `--app`, `--environment`, `--version`, `--identity`, `--console`):
  https://opensource.hcltechsw.com/volt-mx-docs/docs/documentation/Foundry/voltmx_foundry_user_guide/Content/CI_NativeUploadPublish.html

## Authentication (every command)

| Flag | Long form | Meaning |
|---|---|---|
| `-u` | `--user` | Volt MX user. Required. |
| `-p` | `--password` | Password. Required. Never printed or logged. |
| `-t` | `--account` | Cloud account id. Use either this... |
| `-au` | `--identity` | ...or Identity Services URL (on-premise) |
| `-cu` | `--console` | ...together with the Console URL (on-premise) |

Missing `-u`, `-p`, or both `-t` and the `-au`/`-cu` pair gives exit 2 with usage.
`MFCLI_MOCK_AUTH_FAIL=1` makes every command fail with exit 1 and
`Error: Authentication failed. Invalid credentials for user '<user>'.`

Every value flag can also be given as `--flag=value` / `-f=value` (for example `--password=X`, `-p=X`).
This form is an assumption: the docs only show `-p X`, but Java CLI parsers usually accept it.

Password masking: the mock collects the password from `-p X`, `--password X`, `-p=X`, `--password=X`, and from
`-p X` / `--password X` / `--password=X` inside a single argument that has several flags pasted together
(`"-u u -p X -t 1"`, which is then rejected with exit 2). Every literal occurrence of those values is replaced
by `***` in the log line and in error messages, including inside other arguments such as file paths. A
password with spaces inside a pasted argument is only masked up to the first space.

Commands are case-insensitive (`Import`, `import`, `IMPORT`). Accepted no-op flags: `--skipwebapp`,
`-ay/--async`, `--release-lock`, `--mfa`, `--verbose`, `-x`, `-y`, `-to/--timeout`. Any other flag gives exit 2.

## Commands

Exit codes: `0` ok, `1` operation error (auth, not found, publish failure, lock timeout), `2` usage error (unknown
command or flag, required flag missing, invalid app/env name). Messages go to stderr. The JSON outputs are the only
thing on stdout.

| Command | Required flags | Optional | Effect | Stdout | Exit 1 when |
|---|---|---|---|---|---|
| `authenticate` | auth | | none | `mock-token-<n>-<epoch>` | auth fail |
| `Import` | auth, `-f <zip>` | `-a <app>`, `-v <version>` | adds the version to `apps.json` (no duplicates; the last import is the "latest") | `App '<app>' version '<v>' imported successfully.` | file missing (`File not found: <f>`), not a valid zip |
| `Export` | auth, `-a`, `-f <zip>` | `-v` (default: latest imported) | builds a zip with `Apps/<app>/Meta.json` = `{"name","version"}` in a temp dir and moves it to `-f` | `App ... exported to <f>` | app/version not imported, directory of `-f` missing |
| `Publish` | auth, `-e`, `-a` | `-v` (default: latest imported), `--skipwebapp[=<bool>]` | sets `envs/<env>.json[<app>]` (see "Publish state"). Republishing is idempotent. Publishing an older version is how the mock rolls back | `App ... published successfully ...` | version not imported, `MFCLI_MOCK_PUBLISH_FAIL=1` |
| `Unpublish` | auth, `-e`, `-a` | | removes the app from `envs/<env>.json`. Imported versions are kept | `App ... unpublished ...` | not published to that env |
| `publish-status` | auth, `-e`, `-a` | | advances `MFCLI_MOCK_PUBLISH_POLLS` | `{"status":"success\|in_progress\|failed","version":"<v>","active_version":"<v>\|null"}` | not published to that env |
| `appinfo` | auth, `-e`, `-a` | `-v` (must match the active version) | none | `{"appKey":"mock-key-<env>-<app>","appSecret":"mock-secret","serviceUrl":"https://mock-<env>.foundry.local/services/<app>"}` | no active version, or `-v` is not the active version |
| `import-config` | auth, `-f <json>`, `-a`, `-e` | `-v`, `-x`, `-y` | stores the profile in `configs/<env>/<app>.json` | `Service configuration profile imported ...` | file missing, invalid JSON |
| `export-config` | auth, `-a`, `-e` | `-f <json>`, `-v`, `-x`, `-y` | none | with `-f`: writes the file. Without it: prints the profile (`{}` if none) | directory of `-f` missing |

App and environment names (`-a`, `-e`, and the `name` read from `Meta.json`) are used as file names in the state
directory. They must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` and must not contain `..`; otherwise the command exits 2 and
nothing is written.

Import without `-a`/`-v` reads `name`/`version` from `Apps/<name>/Meta.json` in the zip. If that is missing, `-a`
is required (exit 2) and the version defaults to `1.0`. Any valid zip is accepted; the structure is not enforced.

### Publish state

Each app in `envs/<env>.json` has `status`, `version` (the last version a Publish was attempted with) and
`active_version` (the version that is serving traffic, or `null`):

| Publish outcome | `status` | `version` | `active_version` |
|---|---|---|---|
| success | `success` | new | new |
| `MFCLI_MOCK_PUBLISH_FAIL=1` | `failed` | new | unchanged (previous active, or `null`) |
| `MFCLI_MOCK_PUBLISH_HANG=1` | `in_progress` (forever) | new | unchanged |
| `MFCLI_MOCK_PUBLISH_POLLS=N` | `in_progress` for N `publish-status` calls, then `success` | new | unchanged, then new |

`appinfo` answers for `active_version`, so a failed or pending publish does not take the app down.

### Locking

Every command except `authenticate` takes a lock (`mkdir $MFCLI_MOCK_STATE/.lock`) for its whole run and releases
it on exit with a `trap`. Concurrent calls wait (polling every 0.1s) up to `MFCLI_MOCK_LOCK_TIMEOUT` seconds and
then exit 1. A lock left by a killed process (`kill -9`) has to be removed by hand.

## Variables

| Variable | Default | Effect |
|---|---|---|
| `MFCLI_MOCK_STATE` | `/tmp/mfcli-mock-state` | State directory: `apps.json`, `envs/<env>.json`, `configs/<env>/<app>.json`, `.lock` |
| `MFCLI_MOCK_LOG` | unset | If set, appends `mfcli <args>` per invocation with the password replaced by `***` (see below). If its directory does not exist, a warning goes to stderr and the command continues |
| `MFCLI_MOCK_AUTH_FAIL` | `0` | `1`: every command fails authentication (exit 1) |
| `MFCLI_MOCK_VALID_PASSWORD` | unset | If set, any other password fails authentication (exit 1, same message) |
| `MFCLI_MOCK_PUBLISH_HANG` | `0` | `1`: Publish leaves status `in_progress` and exits 0 right away (async publish that never finishes) |
| `MFCLI_MOCK_PUBLISH_FAIL` | `0` | `1`: Publish records status `failed` and exits 1 |
| `MFCLI_MOCK_PUBLISH_POLLS` | `0` | `N`: Publish exits 0 with status `in_progress`; the next N `publish-status` calls report `in_progress` and the one after that turns it into `success`. Read at Publish time |
| `MFCLI_MOCK_LOCK_TIMEOUT` | `30` | Seconds to wait for the state lock |

When several publish variables are set, `MFCLI_MOCK_PUBLISH_FAIL` wins over `MFCLI_MOCK_PUBLISH_HANG`, which wins over `MFCLI_MOCK_PUBLISH_POLLS`.

## Confirmed vs assumed

Confirmed in the HCL docs:
- Command names: `authenticate`, `Import`, `Export`, `Publish`, `Unpublish`, `publish-status`, `appinfo`,
  `import-config`, `export-config`.
- Auth flags `-u -p` plus `-t` (cloud) or `-au -cu` (on-premise), and their long forms.
- Import: `-f` required, `-a`/`-v` optional ("defaults to the version info present in the package").
- Export: `-a` plus `-f` or `-r`. Publish/Unpublish: `-e -a`. appinfo: `-a -e [-v]`.
- appinfo returns the App key, App Secret and Service URL (as fields; the format is not documented).
- export-config/import-config work on a `.json` profile per app and environment, with `-x` (format 1.0/2.0) and
  `-y` (complete/delta).
- Republishing keeps the app's metadata. Unpublish removes it.

Assumed (not in the docs):
- `publish-status`: the docs only say it "queries the publish/unpublish status". Its flags (`-e -a`) and output
  format (JSON with `status`, `version`, `active_version`) are guesses.
- The output format of `authenticate` and `appinfo`. The mock prints a token line and compact JSON.
- `Publish -v` default: the HCL docs say `-v` defaults to `1.0`; the mock publishes the latest imported version.
- Rollback: the mock rolls back by publishing an older imported version again. The docs do not describe rollback;
  the real Foundry may need `set-appversion` or a re-import.
- Publishing a version that was not imported gives exit 1.
- A failed publish keeps the previous version serving (`active_version`).
- Exit codes and error messages.
- The layout of the export zip. `Apps/<app>/Meta.json` is a guess, so Import accepts any valid zip.
- Whether `Publish` returns before the publish finishes. The mock is synchronous unless
  `MFCLI_MOCK_PUBLISH_HANG` or `MFCLI_MOCK_PUBLISH_POLLS` is set.
- `--flag=value` forms (`--password=X`, `-p=X`, `--skipwebapp=true`).

## Checklist for D1 (validate against the real mfcli.jar)

- [ ] `authenticate`: what it prints and the exit code with wrong credentials.
- [ ] `publish-status`: required flags, output format, the exact status values, and whether it reports the
      version that is serving.
- [ ] `appinfo`: output format (JSON, key=value, plain text?) and field names for app key, secret and service URL.
- [ ] `Publish`: sync or async; default version when `-v` is missing (docs: `1.0`); exit code when the version
      was not imported; whether republishing the same version is idempotent.
- [ ] Rollback: does re-`Publish` of an older version work, or is `set-appversion` / re-import needed?
- [ ] A failed publish: does the previous version keep serving, and what do `publish-status`/`appinfo` show?
- [ ] `Unpublish` of an app that is not published: exit code.
- [ ] Export zip layout (is there an `Apps/<app>/Meta.json`?), and Import without `-a`/`-v`.
- [ ] `export-config` without `-e`, and the 1.0/2.0 profile formats.
- [ ] Exit codes for usage errors vs operation errors.
- [ ] `--flag=value` forms and case-insensitive command names.
- [ ] Locking behaviour of concurrent operations (`--release-lock`).
- [ ] Characters allowed in app and environment names (the mock only accepts `^[A-Za-z0-9][A-Za-z0-9._-]*$`; a real name with spaces would be rejected here).

## Known differences from the real mfcli

- Not implemented: `publish-cancel`, `set-appversion`, `export-service`, `import-service`, `build*`,
  `binary-upload`, `native-publish`, `encrypt`, `healthcheck` and other commands (they give exit 2).
- `Export -r <dir>` is not supported. Use `-f`.
- `export-config` requires `-e`. In the real CLI it is optional.
- The service profile is stored as given. It is not validated against the 1.0/2.0 formats, and `-x`/`-y` are ignored.
- The app key does not change after Unpublish followed by Publish. The real Foundry creates a new key/secret.
- The lock is a local `mkdir` lock on the state dir, not the real database lock; `--release-lock` is a no-op. No MFA
  or async import (`-ay`, `-to`). Credentials are only checked when `MFCLI_MOCK_VALID_PASSWORD` is set.
- One status per app and environment. The real Foundry can keep several published versions (`set-appversion`).

## Tests

```bash
shellcheck -S warning voltmx-foundry-app/tools/mfcli-mock/mfcli
bats voltmx-foundry-app/tools/mfcli-mock/tests/
```
