#!/usr/bin/env bats
# =============================================================================
# The workflows as the engine runs them: np service workflow exec builds ONE
# bash -c that sources every step, joined by &&. These tests emulate that chain
# with the real scripts, the mfcli mock and the np/aws mocks, from the
# CONTEXT the platform sends (start-initial, delete-deployment, delete-scope).
#
# Run: bats voltmx-foundry-app/deployment/tests/scripts/workflow_chain_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_foundry_test "$DEPLOYMENT_DIR"
	export SCRIPTS_DIR

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
	# The password only comes from the secret.
	SECRET_PASSWORD="$MFCLI_PASSWORD"
	unset MFCLI_USER MFCLI_PASSWORD
}

# Sources the steps in order, joined by &&, like the engine.
run_chain() {
	local chain="" step
	for step in "$@"; do
		chain="${chain:+$chain && }source \"\$SCRIPTS_DIR/$step\""
	done
	run bash -c "$chain && echo CHAIN-COMPLETED"
}

seed_as() {
	MFCLI_USER=np-foundry MFCLI_PASSWORD="$SECRET_PASSWORD" FOUNDRY_APP=PetStore ENVIRONMENT_NAME=uat seed_active_version "$1"
}

INITIAL_STEPS=(build_context fetch_asset read_credentials do_import render_profile do_reconfig do_publish wait_publish export_outputs)

@test "start-initial: the sourced chain runs every step and reaches the end" {
	seed_as "0.9.0"

	run_chain "${INITIAL_STEPS[@]}"

	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	local auth="-u np-foundry -p *** -t 100000001" work="$BATS_TEST_TMPDIR/work/77"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli Import $auth -f $work/foundry.zip -a PetStore -v 1.0.0" \
		"mfcli import-config $auth -f $work/profile.json -a PetStore -e uat" \
		"mfcli Publish $auth -e uat -a PetStore -v 1.0.0" \
		"mfcli publish-status $auth -e uat -a PetStore" \
		"mfcli appinfo $auth -e uat -a PetStore -v 1.0.0")"
	refute_output_contains "$SECRET_PASSWORD"
	refute_output_contains "idp-s3cr3t-value"
	assert_file_not_exists "$work/profile.json"
}

@test "start-initial: a failing step stops the chain" {
	seed_as "0.9.0"
	export MFCLI_MOCK_VALID_PASSWORD="rotated-password"

	run_chain "${INITIAL_STEPS[@]}"

	assert_equal "$status" "1"
	refute_line "CHAIN-COMPLETED"
	assert_line "  💡 Possible causes: the Foundry technical user is locked or the password rotated"
	assert_mfcli_calls "mfcli Import -u np-foundry -p *** -t 100000001 -f $BATS_TEST_TMPDIR/work/77/foundry.zip -a PetStore -v 1.0.0"
}

@test "start-initial: a chain that dies at import leaves no service profile on disk, and a residual one is removed" {
	seed_as "0.9.0"
	local work="$BATS_TEST_TMPDIR/work/77"
	mkdir -p "$work"
	echo '{"left": "by a previous run"}' > "$work/profile.json"
	export MFCLI_MOCK_VALID_PASSWORD="rotated-password"

	run_chain "${INITIAL_STEPS[@]}"

	assert_equal "$status" "1"
	refute_line "CHAIN-COMPLETED"
	assert_line "   🧹 Removed a service profile left by a previous run of deployment 77"
	assert_line "  💡 Possible causes: the Foundry technical user is locked or the password rotated"
	assert_file_not_exists "$work/profile.json"
	assert_mfcli_calls "mfcli Import -u np-foundry -p *** -t 100000001 -f $work/foundry.zip -a PetStore -v 1.0.0"
}

@test "start-initial: parameter values and the password never reach the argv of jq" {
	local real_jq
	real_jq=$(command -v jq)
	mkdir -p "$BATS_TEST_TMPDIR/jq-wrapper"
	cat > "$BATS_TEST_TMPDIR/jq-wrapper/jq" <<WRAPPER
#!/bin/bash
printf '%s\n' "\$*" >> "$BATS_TEST_TMPDIR/jq_argv.log"
exec "$real_jq" "\$@"
WRAPPER
	chmod +x "$BATS_TEST_TMPDIR/jq-wrapper/jq"
	export PATH="$BATS_TEST_TMPDIR/jq-wrapper:$PATH"

	run_chain "${INITIAL_STEPS[@]}"

	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	assert_greater_than "$(wc -l < "$BATS_TEST_TMPDIR/jq_argv.log")" "10" "jq invocations recorded"
	refute_file_contains "$BATS_TEST_TMPDIR/jq_argv.log" "idp-s3cr3t-value"
	refute_file_contains "$BATS_TEST_TMPDIR/jq_argv.log" "https://core.uat.petstore.io"
	refute_file_contains "$BATS_TEST_TMPDIR/jq_argv.log" "$SECRET_PASSWORD"
}

@test "delete-scope: a real scope context (no deployment, release or asset) unpublishes the app this scope released" {
	seed_as "0.9.0"
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.deployment, .release, .asset)')
	export CONTEXT BUILD_CONTEXT_MODE="scope" UNPUBLISH_MODE="scope"

	run_chain build_context read_credentials do_unpublish

	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	assert_line "🔍 Building scope context..."
	assert_line "   📋 Active version 0.9.0 was released by a finalized deployment of scope 7"
	assert_line "✅ PetStore is no longer published in environment uat"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore" \
		"mfcli Unpublish -u np-foundry -p *** -t 100000001 -e uat -a PetStore")"
}

@test "delete-scope: the app active in a version this scope never released stays published" {
	seed_as "2.0.0"
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.deployment, .release, .asset)')
	export CONTEXT BUILD_CONTEXT_MODE="scope" UNPUBLISH_MODE="scope"

	run_chain build_context read_credentials do_unpublish

	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	assert_line "   ⚠️ Version 2.0.0 of PetStore is active in environment uat, but no finalized deployment of scope 7 released it; leaving it published (it may belong to another scope)"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "delete-scope: the app of another team is refused before calling Foundry" {
	seed_as "0.9.0"
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.deployment, .release, .asset) | .scope.capabilities.foundry_app_name = "Payments"')
	export CONTEXT BUILD_CONTEXT_MODE="scope" UNPUBLISH_MODE="scope"

	run_chain build_context read_credentials do_unpublish

	assert_equal "$status" "1"
	refute_line "CHAIN-COMPLETED"
	assert_line "   ❌ Foundry app 'Payments' is not allowed for this scope: it does not match allowed_apps (PetStore)"
	assert_mfcli_calls ""
}

@test "delete-deployment: the deployment that took over is deleted and the previous finalized release is restored" {
	# Deployment 77 (release 1.0.0) published over deployment 70 (release 0.9.0, still active in the scope), then was cancelled.
	seed_as "0.9.0"
	seed_as "1.0.0"
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.asset) | .deployment.status = "deleting"')
	export CONTEXT BUILD_CONTEXT_MODE="rollback" UNPUBLISH_MODE="deployment"

	run_chain build_context read_credentials do_unpublish

	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	assert_line "   📋 Previous deployment: 70 (release 0.9.0)"
	assert_line "   📋 Version 1.0.0 of deployment 77 is the active version of PetStore in environment uat"
	assert_line "✅ Restored version 0.9.0 of PetStore in environment uat after deleting deployment 77"
	refute_line "✅ PetStore is no longer published in environment uat"
	local auth="-u np-foundry -p *** -t 100000001"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli publish-status $auth -e uat -a PetStore" \
		"mfcli Publish $auth -e uat -a PetStore -v 0.9.0" \
		"mfcli publish-status $auth -e uat -a PetStore")"
	assert_equal "$(MFCLI_USER=np-foundry MFCLI_PASSWORD="$SECRET_PASSWORD" FOUNDRY_APP=PetStore ENVIRONMENT_NAME=uat mock_publish_status | jq -c .)" \
		'{"status":"success","version":"0.9.0","active_version":"0.9.0"}'
	refute_output_contains "$SECRET_PASSWORD"
}

@test "delete-deployment: a deployment whose version is not the active one leaves Foundry alone" {
	seed_as "0.9.0"
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.asset) | .deployment.status = "deleting"')
	export CONTEXT BUILD_CONTEXT_MODE="rollback" UNPUBLISH_MODE="deployment"

	run_chain build_context read_credentials do_unpublish

	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	assert_line "   📋 Version 1.0.0 is not the active version of PetStore in environment uat (active: 0.9.0); leaving it published"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "delete-deployment: without another finalized deployment of the scope the active version is unpublished" {
	seed_as "1.0.0"
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list_no_previous.json"
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.asset) | .deployment.status = "deleting"')
	export CONTEXT BUILD_CONTEXT_MODE="rollback" UNPUBLISH_MODE="deployment"

	run_chain build_context read_credentials do_unpublish

	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	assert_line "   📋 Previous deployment: none"
	assert_line "   📋 Scope 7 has no other finalized deployment: nothing to restore, unpublishing"
	assert_line "✅ PetStore is no longer published in environment uat"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore" \
		"mfcli Unpublish -u np-foundry -p *** -t 100000001 -e uat -a PetStore")"
}

@test "delete-deployment: when the deployments of the scope cannot be listed the active version is left as it is" {
	seed_as "1.0.0"
	unset NP_MOCK_DEPLOYMENT_LIST
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.asset) | .deployment.status = "deleting"')
	export CONTEXT BUILD_CONTEXT_MODE="rollback" UNPUBLISH_MODE="deployment"

	run_chain build_context read_credentials do_unpublish

	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	assert_line "   ⚠️ Could not list the deployments of scope 7; continuing without a previous deployment"
	assert_line "   ⚠️ Could not list the deployments of scope 7 to find the version that should take over; leaving version 1.0.0 published"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "delete-deployment then delete-scope: the scope can be deleted after its only deployment unpublished the active version" {
	seed_as "1.0.0"
	local deployment_context="$CONTEXT"
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list_no_previous.json"
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.asset) | .deployment.status = "deleting"')
	export CONTEXT BUILD_CONTEXT_MODE="rollback" UNPUBLISH_MODE="deployment"

	run_chain build_context read_credentials do_unpublish
	assert_equal "$status" "0"
	assert_line "✅ PetStore is no longer published in environment uat"

	CONTEXT=$(echo "$deployment_context" | jq -c 'del(.deployment, .release, .asset)')
	export CONTEXT BUILD_CONTEXT_MODE="scope" UNPUBLISH_MODE="scope" NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list.json"
	: > "$MFCLI_MOCK_LOG"

	run_chain build_context read_credentials do_unpublish
	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	assert_line "   📋 PetStore is not published in environment uat (Error: App 'PetStore' is not published to environment 'uat'.); nothing to unpublish"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "engine configuration: prefix assignments on source (no export) reach the steps that re-run in a child shell" {
	seed_as "0.9.0"
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.deployment, .release, .asset)')
	export CONTEXT
	unset BUILD_CONTEXT_MODE UNPUBLISH_MODE

	run bash -c '
		BUILD_CONTEXT_MODE=scope source "$SCRIPTS_DIR/build_context" &&
		source "$SCRIPTS_DIR/read_credentials" &&
		UNPUBLISH_MODE=scope BUILD_CONTEXT_MODE=scope source "$SCRIPTS_DIR/do_unpublish" &&
		echo CHAIN-COMPLETED'

	assert_equal "$status" "0"
	assert_line "CHAIN-COMPLETED"
	assert_line "🔍 Building scope context..."
	assert_line "📝 Unpublishing PetStore from environment uat (scope mode)..."
	assert_line "✅ PetStore is no longer published in environment uat"
}
