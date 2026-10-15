#!/usr/bin/env bats
# =============================================================================
# Smoke test of the real engine: runs deployment/workflows/{initial,rollback,delete}.yaml
# with `np service workflow exec` (one bash -c that sources every step, joined
# by &&), the mfcli mock as MFCLI_CMD and the CLI mocks of tests/resources/mocks
# for everything else (np API calls, aws). No --build-context: CONTEXT comes
# from the environment, so no API call and no credentials are needed. The
# worker environment wins over the configuration of values.yaml, which is how
# MFCLI_CMD, WORKDIR and the publish timeouts are set here.
#
# Skipped when the real np CLI is not installed.
#
# Run: bats voltmx-foundry-app/deployment/tests/workflows/engine_smoke_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"

	REAL_NP=$(command -v np || true)
	if [ -z "$REAL_NP" ] || ! "$REAL_NP" service workflow exec --help 2>/dev/null | grep -q -- "--workflow"; then
		skip "the np CLI is required for the engine smoke test"
	fi

	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_foundry_test "$DEPLOYMENT_DIR"

	# Only what the platform and values.yaml provide: build_context,
	# fetch_asset and read_credentials produce the rest.
	unset FOUNDRY_APP APP_VERSION ENVIRONMENT_NAME MFCLI_AUTH_ARGS CREDENTIALS_SECRET SECRETS_PREFIX
	unset PROFILE_VARS DEPLOYMENT_ID SCOPE_ID PREVIOUS_DEPLOYMENT_ID PREVIOUS_RELEASE_SEMVER
	unset ASSETS_BUCKET ASSETS_REGION ASSET_URL FOUNDRY_ZIP WORKDIR_BASE BUILD_CONTEXT_MODE UNPUBLISH_MODE
	export WORKDIR="$BATS_TEST_TMPDIR/work"
	export NP_MOCK_SPECIFICATION_LIST="$MOCKS_DIR/scope_configuration/specification_list.json"
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list.json"
	export AWS_MOCK_S3_OBJECT="$BATS_TEST_TMPDIR/PetStore.zip"
	make_foundry_zip "$AWS_MOCK_S3_OBJECT" "PetStore" "1.0.0"
	write_mock_secret "voltmx/mobile/foundry-uat" '{"username":"np-foundry","password":"Pa55-w0rd-x9"}'
	# The password only comes from the secret. The context carries no IAM
	# provider, so the assume role step keeps the agent credentials (the aws mock).
	SECRET_PASSWORD="$MFCLI_PASSWORD"
	unset MFCLI_USER MFCLI_PASSWORD
}

run_engine() {
	run bash -c 'cd "$1" && "$0" service workflow exec --workflow "$2" 2>&1' \
		"$REAL_NP" "$SERVICE_PATH" "$SERVICE_PATH/deployment/workflows/$1.yaml"
}

seed_as() {
	MFCLI_USER=np-foundry MFCLI_PASSWORD="$SECRET_PASSWORD" FOUNDRY_APP=PetStore ENVIRONMENT_NAME=uat seed_active_version "$1"
}

publish_status_as() {
	MFCLI_USER=np-foundry MFCLI_PASSWORD="$SECRET_PASSWORD" FOUNDRY_APP=PetStore ENVIRONMENT_NAME=uat mock_publish_status
}

@test "Should run the whole initial workflow through the engine and leave the release active" {
	seed_as "0.9.0"

	run_engine initial

	assert_equal "$status" "0"
	[[ "$output" == *"Executing step: export outputs"* ]]
	assert_line "✨ Publish finished"
	assert_line "✨ Outputs exported"
	local auth="-u np-foundry -p *** -t 100000001" work="$BATS_TEST_TMPDIR/work/77"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli Import $auth -f $work/foundry.zip -a PetStore -v 1.0.0" \
		"mfcli import-config $auth -f $work/profile.json -a PetStore -e uat" \
		"mfcli Publish $auth -e uat -a PetStore -v 1.0.0" \
		"mfcli publish-status $auth -e uat -a PetStore" \
		"mfcli appinfo $auth -e uat -a PetStore -v 1.0.0")"
	assert_json_equal "$(publish_status_as)" '{"status":"success","version":"1.0.0","active_version":"1.0.0"}' "publish state"
	assert_file_not_exists "$work/profile.json"
	assert_file_exists "$work/foundry.json"
	assert_np_called "np deployment patch --id 77"
	refute_output_contains "$SECRET_PASSWORD"
	refute_output_contains "idp-s3cr3t-value"
}

@test "Should roll back through the engine to the previous finalized release" {
	seed_as "0.9.0"
	seed_as "1.0.0"

	run_engine rollback

	assert_equal "$status" "0"
	assert_line "✨ Rollback complete: version 0.9.0 is active in environment uat"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli Publish -u np-foundry -p *** -t 100000001 -e uat -a PetStore -v 0.9.0" \
		"mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore")"
	assert_equal "$(publish_status_as | jq -r .active_version)" "0.9.0"
	refute_output_contains "$SECRET_PASSWORD"
}

@test "Should restore the previous finalized release through the engine when the deleted deployment is the active one" {
	seed_as "0.9.0"
	seed_as "1.0.0"
	export CONTEXT
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.asset) | .deployment.status = "deleting"')

	run_engine delete

	assert_equal "$status" "0"
	[[ "$output" == *"Executing step: restore or unpublish"* ]]
	assert_line "✅ Restored version 0.9.0 of PetStore in environment uat after deleting deployment 77"
	local auth="-u np-foundry -p *** -t 100000001"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli publish-status $auth -e uat -a PetStore" \
		"mfcli Publish $auth -e uat -a PetStore -v 0.9.0" \
		"mfcli publish-status $auth -e uat -a PetStore")"
	assert_equal "$(publish_status_as | jq -r .active_version)" "0.9.0"
	refute_output_contains "$SECRET_PASSWORD"
}

@test "Should stop the chain at the first failing step" {
	seed_as "0.9.0"
	export CONTEXT
	CONTEXT=$(echo "$CONTEXT" | jq -c '.scope.capabilities.foundry_app_name = "Payments"')

	run_engine initial

	assert_equal "$status" "1"
	assert_line "   ❌ Foundry app 'Payments' is not allowed for this scope: it does not match allowed_apps (PetStore)"
	[[ "$output" == *"Executing step: build context"* ]]
	[[ "$output" != *"Executing step: fetch asset"* ]]
	assert_mfcli_calls ""
	[ ! -f "$AWS_MOCK_CALLS_LOG" ] || ! grep -q "s3 cp" "$AWS_MOCK_CALLS_LOG"
}
