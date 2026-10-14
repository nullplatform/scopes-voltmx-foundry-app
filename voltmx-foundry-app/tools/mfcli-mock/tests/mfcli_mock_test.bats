#!/usr/bin/env bats

setup() {
  MOCK="$BATS_TEST_DIRNAME/../mfcli"
  export MFCLI_MOCK_STATE="$BATS_TEST_TMPDIR/state"
  export MFCLI_MOCK_LOG="$BATS_TEST_TMPDIR/mfcli.log"
  unset MFCLI_MOCK_AUTH_FAIL MFCLI_MOCK_PUBLISH_HANG MFCLI_MOCK_PUBLISH_FAIL MFCLI_MOCK_PUBLISH_POLLS MFCLI_MOCK_VALID_PASSWORD MFCLI_MOCK_LOCK_TIMEOUT

  SECRET="s3cr3t-P4ss"
  CLOUD=(-u dev@example.com -p "$SECRET" -t 100054321)
  ONPREM=(-u dev@example.com -p "$SECRET" -au https://id.example.com -cu https://console.example.com)

  FIXTURE_DIR="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE_DIR/Apps/PetStore"
  printf '{"name":"PetStore","version":"1.0"}\n' > "$FIXTURE_DIR/Apps/PetStore/Meta.json"
  (cd "$FIXTURE_DIR" && zip -qr "$BATS_TEST_TMPDIR/PetStore.zip" Apps)
  ZIP="$BATS_TEST_TMPDIR/PetStore.zip"
}

import_version() {
  "$MOCK" Import "${CLOUD[@]}" -f "$ZIP" -a PetStore -v "$1"
}

publish_version() {
  "$MOCK" Publish "${CLOUD[@]}" -e uat -a PetStore -v "$1"
}

# --- authentication -------------------------------------------------------

@test "authenticate with cloud account prints a token" {
  run "$MOCK" authenticate "${CLOUD[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *mock-token-* ]]
}

@test "authenticate with on-prem identity and console urls prints a token" {
  run "$MOCK" authenticate "${ONPREM[@]}"
  [ "$status" -eq 0 ]
  [[ "$output" == *mock-token-* ]]
}

@test "authenticate fails with invalid credentials when MFCLI_MOCK_AUTH_FAIL=1" {
  MFCLI_MOCK_AUTH_FAIL=1 run "$MOCK" authenticate "${CLOUD[@]}"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid credentials"* ]]
}

@test "auth failure applies to every authenticated command" {
  MFCLI_MOCK_AUTH_FAIL=1 run "$MOCK" Import "${CLOUD[@]}" -f "$ZIP" -a PetStore -v 1.0
  [ "$status" -eq 1 ]
  [ ! -f "$MFCLI_MOCK_STATE/apps.json" ] || ! jq -e '.PetStore' "$MFCLI_MOCK_STATE/apps.json" >/dev/null
}

@test "missing user or password is a usage error" {
  run "$MOCK" authenticate -p "$SECRET" -t 100054321
  [ "$status" -eq 2 ]
  run "$MOCK" authenticate -u dev@example.com -t 100054321
  [ "$status" -eq 2 ]
}

@test "missing both -t and -au/-cu is a usage error" {
  run "$MOCK" authenticate -u dev@example.com -p "$SECRET"
  [ "$status" -eq 2 ]
  [[ "$output" == *"-t"* ]]
}

@test "on-prem needs both -au and -cu" {
  run "$MOCK" authenticate -u dev@example.com -p "$SECRET" -au https://id.example.com
  [ "$status" -eq 2 ]
}

# --- generic CLI behaviour ------------------------------------------------

@test "unknown command exits 2 with usage" {
  run "$MOCK" frobnicate "${CLOUD[@]}"
  [ "$status" -eq 2 ]
  [[ "$output" == *Usage* ]]
}

@test "no command exits 2 with usage" {
  run "$MOCK"
  [ "$status" -eq 2 ]
  [[ "$output" == *Usage* ]]
}

@test "unknown flag exits 2" {
  run "$MOCK" authenticate "${CLOUD[@]}" --bogus
  [ "$status" -eq 2 ]
}

@test "commands are case-insensitive" {
  run "$MOCK" import "${CLOUD[@]}" -f "$ZIP" -a PetStore -v 1.0
  [ "$status" -eq 0 ]
  run "$MOCK" PUBLISH "${CLOUD[@]}" -e uat -a PetStore -v 1.0
  [ "$status" -eq 0 ]
}

@test "long-form flags are accepted" {
  run "$MOCK" Import --user dev@example.com --password "$SECRET" --account 100054321 \
    --file "$ZIP" --app PetStore --version 1.0
  [ "$status" -eq 0 ]
}

# --- Import ---------------------------------------------------------------

@test "Import registers the version in apps.json" {
  run import_version 1.0
  [ "$status" -eq 0 ]
  run jq -r '.PetStore.versions | join(",")' "$MFCLI_MOCK_STATE/apps.json"
  [ "$output" = "1.0" ]
}

@test "Import of the same version twice does not duplicate it" {
  import_version 1.0
  import_version 1.0
  run jq -r '.PetStore.versions | length' "$MFCLI_MOCK_STATE/apps.json"
  [ "$output" = "1" ]
}

@test "Import with a missing zip exits 1 with File not found" {
  run "$MOCK" Import "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/nope.zip" -a PetStore -v 1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *"File not found"* ]]
}

@test "Import of a file that is not a zip exits 1" {
  echo "not a zip" > "$BATS_TEST_TMPDIR/bad.zip"
  run "$MOCK" Import "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/bad.zip" -a PetStore -v 1.0
  [ "$status" -eq 1 ]
}

@test "Import without -f exits 2" {
  run "$MOCK" Import "${CLOUD[@]}" -a PetStore -v 1.0
  [ "$status" -eq 2 ]
}

@test "Import without -a and -v takes them from Apps/<name>/Meta.json" {
  run "$MOCK" Import "${CLOUD[@]}" -f "$ZIP"
  [ "$status" -eq 0 ]
  run jq -r '.PetStore.versions[0]' "$MFCLI_MOCK_STATE/apps.json"
  [ "$output" = "1.0" ]
}

# --- Export ---------------------------------------------------------------

@test "Export writes a zip with Apps/<app>/Meta.json" {
  import_version 1.0
  run "$MOCK" Export "${CLOUD[@]}" -a PetStore -f "$BATS_TEST_TMPDIR/out.zip"
  [ "$status" -eq 0 ]
  run unzip -p "$BATS_TEST_TMPDIR/out.zip" Apps/PetStore/Meta.json
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .name)" = "PetStore" ]
  [ "$(echo "$output" | jq -r .version)" = "1.0" ]
}

@test "Export output can be imported again" {
  import_version 2.0
  "$MOCK" Export "${CLOUD[@]}" -a PetStore -f "$BATS_TEST_TMPDIR/out.zip"
  run "$MOCK" Import "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/out.zip" -a Clone
  [ "$status" -eq 0 ]
  run jq -r '.Clone.versions[0]' "$MFCLI_MOCK_STATE/apps.json"
  [ "$output" = "2.0" ]
}

@test "Export of an unknown app exits 1" {
  run "$MOCK" Export "${CLOUD[@]}" -a Ghost -f "$BATS_TEST_TMPDIR/out.zip"
  [ "$status" -eq 1 ]
}

@test "Export without -f exits 2" {
  run "$MOCK" Export "${CLOUD[@]}" -a PetStore
  [ "$status" -eq 2 ]
}

# --- Publish / publish-status --------------------------------------------

@test "Publish marks the version active with status success" {
  import_version 1.0
  run publish_version 1.0
  [ "$status" -eq 0 ]
  run jq -r '.PetStore.status + " " + .PetStore.version' "$MFCLI_MOCK_STATE/envs/uat.json"
  [ "$output" = "success 1.0" ]
}

@test "Publish without -v publishes the latest imported version" {
  import_version 1.0
  import_version 1.1
  run "$MOCK" Publish "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
  run jq -r '.PetStore.version' "$MFCLI_MOCK_STATE/envs/uat.json"
  [ "$output" = "1.1" ]
}

@test "republishing the same version is idempotent" {
  import_version 1.0
  publish_version 1.0
  run publish_version 1.0
  [ "$status" -eq 0 ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$(echo "$output" | jq -r .status)" = "success" ]
  [ "$(echo "$output" | jq -r .version)" = "1.0" ]
}

@test "Publish of a version that was not imported exits 1" {
  import_version 1.0
  run publish_version 9.9
  [ "$status" -eq 1 ]
  [ ! -f "$MFCLI_MOCK_STATE/envs/uat.json" ] || ! jq -e '.PetStore' "$MFCLI_MOCK_STATE/envs/uat.json" >/dev/null
}

@test "Publish of an app that was never imported exits 1" {
  run "$MOCK" Publish "${CLOUD[@]}" -e uat -a Ghost
  [ "$status" -eq 1 ]
}

@test "Publish without -e exits 2" {
  run "$MOCK" Publish "${CLOUD[@]}" -a PetStore
  [ "$status" -eq 2 ]
}

@test "publish-status prints JSON with status and version" {
  import_version 1.0
  publish_version 1.0
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
  [ "$output" = '{"status":"success","version":"1.0","active_version":"1.0"}' ]
}

@test "publish-status for an app not published in the env exits 1" {
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 1 ]
}

@test "MFCLI_MOCK_PUBLISH_HANG=1 leaves in_progress and returns 0 immediately" {
  import_version 1.0
  start=$(date +%s)
  MFCLI_MOCK_PUBLISH_HANG=1 run publish_version 1.0
  [ "$status" -eq 0 ]
  [ $(( $(date +%s) - start )) -lt 5 ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$(echo "$output" | jq -r .status)" = "in_progress" ]
  [ "$(echo "$output" | jq -r .version)" = "1.0" ]
}

@test "MFCLI_MOCK_PUBLISH_FAIL=1 records failed and exits 1" {
  import_version 1.0
  MFCLI_MOCK_PUBLISH_FAIL=1 run publish_version 1.0
  [ "$status" -eq 1 ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$(echo "$output" | jq -r .status)" = "failed" ]
}

@test "a successful publish after a failed one recovers to success" {
  import_version 1.0
  MFCLI_MOCK_PUBLISH_FAIL=1 publish_version 1.0 || true
  run publish_version 1.0
  [ "$status" -eq 0 ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$(echo "$output" | jq -r .status)" = "success" ]
}

@test "environments are independent" {
  import_version 1.0
  publish_version 1.0
  run "$MOCK" publish-status "${CLOUD[@]}" -e prod -a PetStore
  [ "$status" -eq 1 ]
}

# --- appinfo --------------------------------------------------------------

@test "appinfo prints app key, secret and service url" {
  import_version 1.0
  publish_version 1.0
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .appKey)" = "mock-key-uat-PetStore" ]
  [ "$(echo "$output" | jq -r .appSecret)" = "mock-secret" ]
  [ "$(echo "$output" | jq -r .serviceUrl)" = "https://mock-uat.foundry.local/services/PetStore" ]
}

@test "appinfo for an unpublished app exits 1" {
  import_version 1.0
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 1 ]
}

@test "appinfo while publish is still in progress exits 1" {
  import_version 1.0
  MFCLI_MOCK_PUBLISH_HANG=1 publish_version 1.0
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 1 ]
}

# --- import-config / export-config ---------------------------------------

@test "import-config stores the profile and export-config returns it" {
  printf '{"integration":{"CORE_BASE_URL":"https://core.example.com"}}\n' > "$BATS_TEST_TMPDIR/profile.json"
  run "$MOCK" import-config "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/profile.json" -a PetStore -e uat
  [ "$status" -eq 0 ]
  run "$MOCK" export-config "${CLOUD[@]}" -a PetStore -e uat -f "$BATS_TEST_TMPDIR/out.json"
  [ "$status" -eq 0 ]
  run jq -r '.integration.CORE_BASE_URL' "$BATS_TEST_TMPDIR/out.json"
  [ "$output" = "https://core.example.com" ]
}

@test "export-config without -f prints the profile to stdout" {
  printf '{"a":1}\n' > "$BATS_TEST_TMPDIR/profile.json"
  "$MOCK" import-config "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/profile.json" -a PetStore -e uat
  run "$MOCK" export-config "${CLOUD[@]}" -a PetStore -e uat
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .a)" = "1" ]
}

@test "export-config with no stored profile returns an empty object" {
  run "$MOCK" export-config "${CLOUD[@]}" -a PetStore -e uat
  [ "$status" -eq 0 ]
  [ "$output" = "{}" ]
}

@test "import-config with a missing file exits 1" {
  run "$MOCK" import-config "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/none.json" -a PetStore -e uat
  [ "$status" -eq 1 ]
}

@test "import-config with invalid JSON exits 1" {
  echo "{not json" > "$BATS_TEST_TMPDIR/bad.json"
  run "$MOCK" import-config "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/bad.json" -a PetStore -e uat
  [ "$status" -eq 1 ]
}

@test "import-config without -e exits 2" {
  printf '{}\n' > "$BATS_TEST_TMPDIR/profile.json"
  run "$MOCK" import-config "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/profile.json" -a PetStore
  [ "$status" -eq 2 ]
}

# --- Unpublish ------------------------------------------------------------

@test "Unpublish removes the active version" {
  import_version 1.0
  publish_version 1.0
  run "$MOCK" Unpublish "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 1 ]
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 1 ]
}

@test "Unpublish of an app that is not published exits 1" {
  run "$MOCK" Unpublish "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 1 ]
}

# --- end-to-end flow ------------------------------------------------------

@test "flow: import, publish, appinfo, rollback to previous, unpublish" {
  run import_version 1.0;  [ "$status" -eq 0 ]
  run publish_version 1.0; [ "$status" -eq 0 ]
  run import_version 1.1;  [ "$status" -eq 0 ]
  run publish_version 1.1; [ "$status" -eq 0 ]

  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .appKey)" = "mock-key-uat-PetStore" ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$(echo "$output" | jq -r .version)" = "1.1" ]

  run publish_version 1.0; [ "$status" -eq 0 ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$output" = '{"status":"success","version":"1.0","active_version":"1.0"}' ]

  run "$MOCK" Unpublish "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 1 ]
  run jq -r '.PetStore.versions | join(",")' "$MFCLI_MOCK_STATE/apps.json"
  [ "$output" = "1.0,1.1" ]
}

# --- logging and secrets --------------------------------------------------

@test "MFCLI_MOCK_LOG records each invocation with the password masked" {
  import_version 1.0
  "$MOCK" Publish -u dev@example.com --password "$SECRET" -t 100054321 -e uat -a PetStore
  run cat "$MFCLI_MOCK_LOG"
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == "mfcli Import -u dev@example.com -p *** -t 100054321 -f "* ]]
  [[ "${lines[1]}" == *"--password ***"* ]]
}

@test "without MFCLI_MOCK_LOG nothing is logged" {
  unset MFCLI_MOCK_LOG
  run import_version 1.0
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/mfcli.log" ]
}

@test "the password never appears in output or log, even on errors" {
  outputs=""
  run "$MOCK" authenticate "${CLOUD[@]}";                 outputs+="$output"
  MFCLI_MOCK_AUTH_FAIL=1 run "$MOCK" authenticate "${CLOUD[@]}"; outputs+="$output"
  run "$MOCK" frobnicate "${CLOUD[@]}";                   outputs+="$output"
  run "$MOCK" Import "${CLOUD[@]}" -f /nope.zip -a X;     outputs+="$output"
  run "$MOCK" Import "${CLOUD[@]}" --bogus;               outputs+="$output"
  run import_version 1.0;                                 outputs+="$output"
  run publish_version 1.0;                                outputs+="$output"
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore;   outputs+="$output"
  [[ "$outputs" != *"$SECRET"* ]]
  ! grep -q "$SECRET" "$MFCLI_MOCK_LOG"
  ! grep -rq "$SECRET" "$MFCLI_MOCK_STATE"
}

# --- password masking in every accepted form ------------------------------

PW='S3cr3t!x'

assert_not_logged() {
  [ "$(grep -c -F -- "$PW" "$MFCLI_MOCK_LOG" || true)" -eq 0 ]
  grep -q -F -- '***' "$MFCLI_MOCK_LOG"
}

@test "password form '-p X' works and is masked" {
  run "$MOCK" authenticate -u dev@example.com -p "$PW" -t 100054321
  [ "$status" -eq 0 ]
  assert_not_logged
}

@test "password form '--password X' works and is masked" {
  run "$MOCK" authenticate -u dev@example.com --password "$PW" -t 100054321
  [ "$status" -eq 0 ]
  assert_not_logged
}

@test "password form '--password=X' works and is masked" {
  run "$MOCK" authenticate -u dev@example.com "--password=$PW" -t 100054321
  [ "$status" -eq 0 ]
  assert_not_logged
}

@test "password form '-p=X' works and is masked" {
  run "$MOCK" authenticate -u dev@example.com "-p=$PW" -t 100054321
  [ "$status" -eq 0 ]
  assert_not_logged
}

@test "a pasted token containing '-p X' is rejected and masked" {
  run "$MOCK" authenticate "-u dev@example.com -p $PW -t 100054321"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$PW"* ]]
  assert_not_logged
}

@test "a pasted token with '--password=X' is masked" {
  run "$MOCK" authenticate "-u dev@example.com --password=$PW -t 100054321"
  [ "$status" -eq 2 ]
  [[ "$output" != *"$PW"* ]]
  assert_not_logged
}

@test "the password value is masked wherever it appears in the log line" {
  run "$MOCK" Import -u dev@example.com -p "$PW" -t 100054321 -f "/tmp/$PW.zip" -a PetStore
  [ "$status" -eq 1 ]
  assert_not_logged
}

# --- path-like names are rejected -----------------------------------------

tree_snapshot() {
  (cd "$BATS_TEST_TMPDIR/.." && find . -type f ! -name mfcli.log -exec cksum {} + | sort)
}

assert_rejected_without_writes() {
  local before after
  before="$(tree_snapshot)"
  run "$@"
  after="$(tree_snapshot)"
  echo "status=$status output=$output"
  [ "$status" -eq 2 ]
  [ "$before" = "$after" ]
}

@test "Publish with -e ../apps does not overwrite apps.json" {
  import_version 1.0
  assert_rejected_without_writes "$MOCK" Publish "${CLOUD[@]}" -e ../apps -a PetStore -v 1.0
  run jq -r '.PetStore.versions[0]' "$MFCLI_MOCK_STATE/apps.json"
  [ "$output" = "1.0" ]
}

@test "-e ../x is rejected with exit 2 and nothing written" {
  import_version 1.0
  assert_rejected_without_writes "$MOCK" Publish "${CLOUD[@]}" -e ../../x -a PetStore -v 1.0
}

@test "-a ../x is rejected with exit 2 and nothing written" {
  assert_rejected_without_writes "$MOCK" Import "${CLOUD[@]}" -f "$ZIP" -a ../x -v 1.0
  printf '{}\n' > "$BATS_TEST_TMPDIR/profile.json"
  assert_rejected_without_writes "$MOCK" import-config "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/profile.json" -a ../../x -e uat
}

@test "-e a/b is rejected with exit 2 and nothing written" {
  printf '{}\n' > "$BATS_TEST_TMPDIR/profile.json"
  assert_rejected_without_writes "$MOCK" import-config "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/profile.json" -a PetStore -e a/b
}

@test "Export with -a ../x is rejected with exit 2" {
  import_version 1.0
  assert_rejected_without_writes "$MOCK" Export "${CLOUD[@]}" -a ../x -f "$BATS_TEST_TMPDIR/out.zip"
}

@test "Import rejects a Meta.json whose name is ../x" {
  mkdir -p "$BATS_TEST_TMPDIR/evil/Apps/evil"
  printf '{"name":"../../x","version":"1.0"}\n' > "$BATS_TEST_TMPDIR/evil/Apps/evil/Meta.json"
  (cd "$BATS_TEST_TMPDIR/evil" && zip -qr "$BATS_TEST_TMPDIR/evil.zip" Apps)
  assert_rejected_without_writes "$MOCK" Import "${CLOUD[@]}" -f "$BATS_TEST_TMPDIR/evil.zip"
}

# --- failed publishes keep the active version (M1) ------------------------

@test "a failed publish keeps the previous version active" {
  import_version 1.0
  import_version 1.1
  publish_version 1.0
  MFCLI_MOCK_PUBLISH_FAIL=1 run publish_version 1.1
  [ "$status" -eq 1 ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
  [ "$output" = '{"status":"failed","version":"1.1","active_version":"1.0"}' ]
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | jq -r .appKey)" = "mock-key-uat-PetStore" ]
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore -v 1.0
  [ "$status" -eq 0 ]
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore -v 1.1
  [ "$status" -eq 1 ]
}

@test "a first publish that fails has no active version" {
  import_version 1.0
  MFCLI_MOCK_PUBLISH_FAIL=1 publish_version 1.0 || true
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$output" = '{"status":"failed","version":"1.0","active_version":null}' ]
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 1 ]
}

@test "a hanging publish keeps the previous version active" {
  import_version 1.0
  import_version 1.1
  publish_version 1.0
  MFCLI_MOCK_PUBLISH_HANG=1 publish_version 1.1
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$output" = '{"status":"in_progress","version":"1.1","active_version":"1.0"}' ]
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
}

# --- slow publishes (M2) --------------------------------------------------

@test "MFCLI_MOCK_PUBLISH_POLLS=N reports in_progress N times, then success" {
  import_version 1.0
  MFCLI_MOCK_PUBLISH_POLLS=2 run publish_version 1.0
  [ "$status" -eq 0 ]
  for _ in 1 2; do
    run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
    [ "$(echo "$output" | jq -r .status)" = "in_progress" ]
  done
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$output" = '{"status":"success","version":"1.0","active_version":"1.0"}' ]
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$(echo "$output" | jq -r .status)" = "success" ]
  run "$MOCK" appinfo "${CLOUD[@]}" -e uat -a PetStore
  [ "$status" -eq 0 ]
}

@test "MFCLI_MOCK_PUBLISH_POLLS=0 behaves like a synchronous publish" {
  import_version 1.0
  MFCLI_MOCK_PUBLISH_POLLS=0 publish_version 1.0
  run "$MOCK" publish-status "${CLOUD[@]}" -e uat -a PetStore
  [ "$(echo "$output" | jq -r .status)" = "success" ]
}

# --- strict credentials (M3) ----------------------------------------------

@test "MFCLI_MOCK_VALID_PASSWORD rejects any other password" {
  MFCLI_MOCK_VALID_PASSWORD=right run "$MOCK" authenticate -u dev@example.com -p wrong -t 100054321
  [ "$status" -eq 1 ]
  [[ "$output" == *"Invalid credentials"* ]]
  MFCLI_MOCK_VALID_PASSWORD=right run "$MOCK" Import -u dev@example.com -p wrong -t 100054321 -f "$ZIP"
  [ "$status" -eq 1 ]
  [ ! -f "$MFCLI_MOCK_STATE/apps.json" ]
}

@test "MFCLI_MOCK_VALID_PASSWORD accepts the matching password" {
  MFCLI_MOCK_VALID_PASSWORD=right run "$MOCK" authenticate -u dev@example.com -p right -t 100054321
  [ "$status" -eq 0 ]
}

# --- locking (M5) ---------------------------------------------------------

@test "concurrent imports do not lose versions" {
  for v in 1 2 3 4 5 6 7 8 9 10; do
    "$MOCK" Import "${CLOUD[@]}" -f "$ZIP" -a PetStore -v "1.$v" &
  done
  wait
  run jq -r '.PetStore.versions | length' "$MFCLI_MOCK_STATE/apps.json"
  [ "$output" = "10" ]
  [ ! -e "$MFCLI_MOCK_STATE/.lock" ]
}

@test "a held lock makes the command fail after MFCLI_MOCK_LOCK_TIMEOUT" {
  mkdir -p "$MFCLI_MOCK_STATE/.lock"
  MFCLI_MOCK_LOCK_TIMEOUT=1 run import_version 1.0
  [ "$status" -eq 1 ]
  [[ "$output" == *lock* ]]
  [ -d "$MFCLI_MOCK_STATE/.lock" ]
}

@test "the lock is released after a failing command" {
  run "$MOCK" Publish "${CLOUD[@]}" -e uat -a Ghost
  [ "$status" -eq 1 ]
  [ ! -e "$MFCLI_MOCK_STATE/.lock" ]
}

# --- small fixes ----------------------------------------------------------

@test "Export into a missing directory exits 1 and leaves no file" {
  import_version 1.0
  run "$MOCK" Export "${CLOUD[@]}" -a PetStore -f "$BATS_TEST_TMPDIR/missing/out.zip"
  [ "$status" -eq 1 ]
  [ ! -e "$BATS_TEST_TMPDIR/missing" ]
}

@test "Export replaces an existing file" {
  import_version 1.0
  echo garbage > "$BATS_TEST_TMPDIR/out.zip"
  run "$MOCK" Export "${CLOUD[@]}" -a PetStore -f "$BATS_TEST_TMPDIR/out.zip"
  [ "$status" -eq 0 ]
  unzip -tq "$BATS_TEST_TMPDIR/out.zip"
}

@test "export-config into a missing directory exits 1" {
  run "$MOCK" export-config "${CLOUD[@]}" -a PetStore -e uat -f "$BATS_TEST_TMPDIR/missing/p.json"
  [ "$status" -eq 1 ]
}

@test "--skipwebapp=true is accepted" {
  import_version 1.0
  run "$MOCK" Publish "${CLOUD[@]}" -e uat -a PetStore --skipwebapp=true
  [ "$status" -eq 0 ]
}

@test "a missing MFCLI_MOCK_LOG directory warns and continues" {
  MFCLI_MOCK_LOG="$BATS_TEST_TMPDIR/nodir/mfcli.log" run import_version 1.0
  [ "$status" -eq 0 ]
  [[ "$output" == *Warning* ]]
}
