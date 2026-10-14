#!/usr/bin/env bats
# =============================================================================
# The start-initial sequence against the mfcli mock:
#   do_import -> render_profile -> do_reconfig -> do_publish -> wait_publish -> export_outputs
#
# Each step is a script; the flow stops at the first failure, like a workflow.
# The mock keeps its state in the test tmpdir and logs every invocation with
# the password masked (MFCLI_MOCK_LOG).
#
# Run: bats voltmx-foundry-app/deployment/tests/scripts/initial_flow_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_foundry_test "$DEPLOYMENT_DIR"
	export SCRIPTS_DIR
}

run_initial_flow() {
	run bash -c 'for step in do_import render_profile do_reconfig do_publish wait_publish export_outputs; do
		bash "$SCRIPTS_DIR/$step" || exit $?
	done'
}

expected_calls() {
	local auth="-u np-foundry -p *** -t 100000001"
	printf '%s\n' \
		"mfcli Import $auth -f $WORKDIR/foundry.zip -a PetStore -v 1.0.0" \
		"mfcli import-config $auth -f $WORKDIR/profile.json -a PetStore -e uat" \
		"mfcli Publish $auth -e uat -a PetStore -v 1.0.0"
	local i
	for ((i = 0; i < ${1:-1}; i++)); do
		echo "mfcli publish-status $auth -e uat -a PetStore"
	done
	echo "mfcli appinfo $auth -e uat -a PetStore -v 1.0.0"
}

@test "Should import, configure, publish, wait and export the outputs in this exact order" {
	seed_active_version "0.9.0"

	run_initial_flow

	assert_equal "$status" "0"
	assert_mfcli_calls "$(expected_calls 1)"

	assert_line "📝 Importing Foundry app PetStore version 1.0.0..."
	assert_line "   📋 App 'PetStore' version '1.0.0' imported successfully."
	assert_line "✅ Import complete"
	assert_line "📝 Applying the service profile to PetStore in environment uat..."
	assert_line "✅ Service profile applied"
	assert_line "📝 Publishing PetStore version 1.0.0 to environment uat..."
	assert_line "   📋 App 'PetStore' version '1.0.0' published successfully to environment 'uat'."
	assert_line "✅ Publish requested"
	assert_line "🔍 Waiting for the publish of PetStore 1.0.0 in environment uat (timeout 5s, every 0s)..."
	assert_line "   ✅ Version 1.0.0 is active in environment uat"
	assert_line "✨ Publish finished"
	assert_line "📡 Reading the app info of PetStore 1.0.0 in environment uat..."
	assert_line "   ✅ app_key=mock-key-uat-PetStore"
	assert_line "   ✅ service_url=https://mock-uat.foundry.local/services/PetStore"
	assert_line "   ✅ Recorded the Foundry app info on deployment 77 (message VOLTMX_FOUNDRY_APP)"
	assert_line "✨ Outputs exported"

	# Foundry state: the new version serves and the profile reached the environment.
	assert_equal "$(mock_publish_status | jq -c .)" '{"status":"success","version":"1.0.0","active_version":"1.0.0"}'
	assert_equal "$(jq -r .app_properties.CORE_BASE_URL "$MFCLI_MOCK_STATE/configs/uat/PetStore.json")" "https://core.uat.petstore.io"
	# The rendered profile carries secrets: it does not outlive import-config.
	assert_file_not_exists "$WORKDIR/profile.json"
}

@test "Should record app key and service url on the deployment, never the app secret" {
	run_initial_flow

	assert_equal "$status" "0"
	assert_np_called "np deployment patch --id 77 --body"
	assert_np_called '\"app_key\":\"mock-key-uat-PetStore\"'
	assert_np_called '\"service_url\":\"https://mock-uat.foundry.local/services/PetStore\"'
	assert_np_called '\"version\":\"1.0.0\"'
	refute_np_called "mock-secret"
	refute_output_contains "mock-secret"
	assert_json_equal "$(cat "$WORKDIR/foundry.json")" '{
		"app": "PetStore",
		"environment": "uat",
		"version": "1.0.0",
		"app_key": "mock-key-uat-PetStore",
		"service_url": "https://mock-uat.foundry.local/services/PetStore"
	}' "foundry.json"
}

@test "Should keep going when the deployment cannot be patched (outputs are best effort)" {
	unset NP_MOCK_DEPLOYMENT_PATCH

	run_initial_flow

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not record the Foundry app info on deployment 77 (np deployment patch failed); it stays in $WORKDIR/foundry.json"
	assert_line "✨ Outputs exported"
}

@test "Should never print or log the password across the whole flow" {
	run_initial_flow

	assert_equal "$status" "0"
	refute_output_contains "$MFCLI_PASSWORD"
	refute_file_contains "$MFCLI_MOCK_LOG" "$MFCLI_PASSWORD"
	refute_file_contains "$NP_MOCK_CALLS_LOG" "$MFCLI_PASSWORD"
	assert_equal "$(grep -rlF "$MFCLI_PASSWORD" "$WORKDIR" | wc -l | tr -d ' ')" "0"
	assert_greater_than "$(grep -c -- '-p \*\*\*' "$MFCLI_MOCK_LOG")" "0" "masked password in the mock log"
}

@test "Should stop at the import with the locked user hint when the credentials are invalid" {
	export MFCLI_MOCK_VALID_PASSWORD="rotated-password"

	run_initial_flow

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli Import failed (exit 1): Error: Authentication failed. Invalid credentials for user 'np-foundry'."
	assert_line "  💡 Possible causes: the Foundry technical user is locked or the password rotated"
	assert_mfcli_calls "mfcli Import -u np-foundry -p *** -t 100000001 -f $WORKDIR/foundry.zip -a PetStore -v 1.0.0"
	refute_output_contains "$MFCLI_PASSWORD"
	refute_file_contains "$MFCLI_MOCK_LOG" "$MFCLI_PASSWORD"
}

@test "Should poll until a slow publish finishes" {
	seed_active_version "0.9.0"
	export MFCLI_MOCK_PUBLISH_POLLS=3

	run_initial_flow

	assert_equal "$status" "0"
	assert_mfcli_calls "$(expected_calls 4)"
	assert_equal "$(printf '%s\n' "${lines[@]}" | grep -c '^   📝 Publish in progress: version 1.0.0, active 0.9.0 (')" "3"
	assert_line "   ✅ Version 1.0.0 is active in environment uat"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "Should fail on a hung publish with the timeout message, keep the previous version and succeed on re-run" {
	seed_active_version "0.9.0"
	export MFCLI_MOCK_PUBLISH_HANG=1
	export PUBLISH_TIMEOUT_SECONDS=1

	run_initial_flow

	assert_equal "$status" "1"
	assert_line "   ❌ Publish did not finish in 1s; version 0.9.0 is still active. Re-run the deployment: Publish is idempotent"
	assert_line "  💡 Possible causes:"
	assert_line "    • Foundry is still publishing (large apps or a busy server take longer)"
	assert_line "    • The publish is stuck in Foundry"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check the publish status of PetStore in the Foundry console (environment uat)"
	assert_line "    • Raise PUBLISH_TIMEOUT_SECONDS if publishes of this app usually take longer than 1s"
	refute_line "✨ Outputs exported"
	refute_np_called "deployment patch"
	assert_equal "$(mock_publish_status | jq -c .)" '{"status":"in_progress","version":"1.0.0","active_version":"0.9.0"}'

	# Re-running the same deployment once Foundry recovers: same steps, same result.
	unset MFCLI_MOCK_PUBLISH_HANG
	: > "$MFCLI_MOCK_LOG"
	run_initial_flow
	assert_equal "$status" "0"
	assert_mfcli_calls "$(expected_calls 1)"
	assert_equal "$(mock_publish_status | jq -c .)" '{"status":"success","version":"1.0.0","active_version":"1.0.0"}'
}

@test "Should report the timeout without an active version on the first publish" {
	export MFCLI_MOCK_PUBLISH_HANG=1
	export PUBLISH_TIMEOUT_SECONDS=1

	run_initial_flow

	assert_equal "$status" "1"
	assert_line "   ❌ Publish did not finish in 1s; no version is active yet. Re-run the deployment: Publish is idempotent"
}

@test "Should fail a rejected publish and keep the previous version serving" {
	seed_active_version "0.9.0"
	export MFCLI_MOCK_PUBLISH_FAIL=1

	run_initial_flow

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli Publish failed (exit 1): Error: Publish of app 'PetStore' version '1.0.0' to environment 'uat' failed."
	assert_line "   📋 Active version in environment uat: 0.9.0 (the failed publish did not replace it)"
	refute_line "✅ Publish requested"
	assert_equal "$(mock_publish_status | jq -c .)" '{"status":"failed","version":"1.0.0","active_version":"0.9.0"}'
	assert_equal "$(MFCLI_MOCK_LOG= "$MFCLI_CMD" appinfo -u np-foundry -p "$MFCLI_PASSWORD" -t 100000001 -e uat -a PetStore | jq -r .appKey)" "mock-key-uat-PetStore"
}

@test "wait_publish: should fail with the active version when Foundry reports the publish as failed" {
	seed_active_version "0.9.0"
	MFCLI_MOCK_PUBLISH_FAIL=1 bash "$SCRIPTS_DIR/do_import" >/dev/null
	MFCLI_MOCK_PUBLISH_FAIL=1 bash "$SCRIPTS_DIR/do_publish" >/dev/null 2>&1 || true

	run bash "$SCRIPTS_DIR/wait_publish"

	assert_equal "$status" "1"
	assert_line "   ❌ Foundry reported the publish of version 1.0.0 as failed; version 0.9.0 is still active"
	assert_line "  💡 Possible causes:"
	assert_line "    • Foundry could not publish the app (services, identity providers or the service profile)"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check the publish logs of PetStore in the Foundry console (environment uat), fix the app and deploy again"
}

@test "wait_publish: should keep polling while Foundry reports another version, then time out" {
	seed_active_version "0.9.0"
	export PUBLISH_TIMEOUT_SECONDS=2

	run bash "$SCRIPTS_DIR/wait_publish"

	assert_equal "$status" "1"
	assert_greater_than "$(grep -c publish-status "$MFCLI_MOCK_LOG")" "1" "publish-status polls"
	assert_line "   ❌ Publish did not finish in 2s; version 0.9.0 is still active. Re-run the deployment: Publish is idempotent"
}

@test "wait_publish: should fail at once when publish-status does not answer JSON" {
	seed_active_version "0.9.0"
	cat > "$BATS_TEST_TMPDIR/text-mfcli" <<CLI
#!/bin/bash
if [ "\$1" = "publish-status" ]; then echo "Publish status: SUCCESS"; exit 0; fi
exec "$MFCLI_CMD" "\$@"
CLI
	chmod +x "$BATS_TEST_TMPDIR/text-mfcli"
	export MFCLI_CMD="$BATS_TEST_TMPDIR/text-mfcli"

	run bash "$SCRIPTS_DIR/wait_publish"

	assert_equal "$status" "1"
	assert_line "   ❌ publish-status of PetStore did not return the expected JSON ({\"status\", \"version\", \"active_version\"})"
	assert_line "  💡 Possible causes:"
	assert_line "    • The installed mfcli prints publish-status in another format than the one this scope expects"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check the publish of PetStore in the Foundry console (environment uat) and adapt wait_publish to this mfcli version"
}

@test "do_reconfig: a failed import-config leaves no rendered profile behind" {
	bash "$SCRIPTS_DIR/render_profile" >/dev/null
	assert_file_exists "$WORKDIR/profile.json"
	export MFCLI_MOCK_VALID_PASSWORD="rotated-password"

	run bash "$SCRIPTS_DIR/do_reconfig"

	assert_equal "$status" "1"
	assert_file_not_exists "$WORKDIR/profile.json"
}

@test "wait_publish: should reject timeouts that are not integers" {
	export PUBLISH_POLL_SECONDS="1s"

	run bash "$SCRIPTS_DIR/wait_publish"

	assert_equal "$status" "1"
	assert_line "   ❌ PUBLISH_TIMEOUT_SECONDS and PUBLISH_POLL_SECONDS must be non-negative integers (got '5' and '1s')"
	assert_file_not_exists "$MFCLI_MOCK_LOG"
}

@test "do_import: should fail before calling mfcli when the zip is missing" {
	rm -f "$FOUNDRY_ZIP"

	run bash "$SCRIPTS_DIR/do_import"

	assert_equal "$status" "1"
	assert_line "   ❌ The Foundry app zip is missing: $FOUNDRY_ZIP"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the deployment workflow from the start so fetch_asset downloads the app"
	assert_file_not_exists "$MFCLI_MOCK_LOG"
}

@test "export_outputs: should warn and not fail when appinfo cannot be read" {
	run bash "$SCRIPTS_DIR/export_outputs"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not read the app info of PetStore 1.0.0 in environment uat; the deployment is published but has no app key recorded"
	refute_np_called "deployment patch"
}
