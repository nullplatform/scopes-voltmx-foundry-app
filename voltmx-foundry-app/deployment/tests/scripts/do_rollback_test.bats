#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/do_rollback: publishes the release of the
# previous finalized deployment again and waits for it, against the mock.
#
# Run: bats voltmx-foundry-app/deployment/tests/scripts/do_rollback_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_foundry_test "$DEPLOYMENT_DIR"
	SCRIPT="$SCRIPTS_DIR/do_rollback"
}

@test "Should publish the previous version again and wait until it is active" {
	seed_active_version "0.9.0"
	seed_active_version "1.0.0"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📝 Rolling back PetStore in environment uat to version 0.9.0 (deployment 70)..."
	assert_line "   ✅ Version 0.9.0 is active in environment uat"
	assert_line "✨ Rollback complete: version 0.9.0 is active in environment uat"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli Publish -u np-foundry -p *** -t 100000001 -e uat -a PetStore -v 0.9.0" \
		"mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore")"
	assert_equal "$(mock_publish_status | jq -c .)" '{"status":"success","version":"0.9.0","active_version":"0.9.0"}'
	refute_output_contains "$MFCLI_PASSWORD"
}

@test "Should fail without touching Foundry when there is no previous finalized deployment" {
	seed_active_version "1.0.0"
	export PREVIOUS_DEPLOYMENT_ID=""
	export PREVIOUS_RELEASE_SEMVER=""

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ No previous finalized deployment to roll back to"
	assert_line "  💡 Possible causes:"
	assert_line "    • This is the first deployment of the scope, or every earlier one failed or was rolled back"
	assert_line "  🔧 How to fix:"
	assert_line "    • Nothing was changed in Foundry: deploy the release you want to return to"
	assert_mfcli_calls ""
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "Should explain when the previous version is no longer in Foundry" {
	seed_active_version "1.0.0"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli Publish failed (exit 1): Error: App 'PetStore' version '0.9.0' not found. Import it before publishing."
	assert_line "    • App 'PetStore' version 0.9.0 was never imported into Foundry, or it is not published in environment 'uat'"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "Should time out like the initial deployment when the rollback publish hangs" {
	seed_active_version "0.9.0"
	seed_active_version "1.0.0"
	export MFCLI_MOCK_PUBLISH_HANG=1
	export PUBLISH_TIMEOUT_SECONDS=1

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Publish did not finish in 1s; version 1.0.0 is still active. Re-run the deployment: Publish is idempotent"
}
