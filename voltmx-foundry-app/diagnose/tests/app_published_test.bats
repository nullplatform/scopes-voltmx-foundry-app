#!/usr/bin/env bats
# =============================================================================
# Unit tests for diagnose/checks/app_published against the mfcli mock.
#
# Run: bats voltmx-foundry-app/diagnose/tests/app_published_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SCOPE_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$SCOPE_DIR/.." && pwd)/testing/assertions.sh"
	source "$TEST_DIR/helpers.bash"
	setup_diagnose_test "$SCOPE_DIR"
}

import_as_mock() {
	make_foundry_zip "$BATS_TEST_TMPDIR/import-$1.zip" "PetStore" "$1"
	"$MFCLI_CMD" Import -u "$MFCLI_USER" -p "$MFCLI_PASSWORD" -t 100000001 -f "$BATS_TEST_TMPDIR/import-$1.zip" -a PetStore -v "$1" >/dev/null
}

publish_as_mock() {
	"$MFCLI_CMD" Publish -u "$MFCLI_USER" -p "$MFCLI_PASSWORD" -t 100000001 -e uat -a PetStore -v "$1" >/dev/null 2>&1 || true
	: > "$MFCLI_MOCK_LOG"
}

@test "Should skip when the credentials check did not load the Foundry user" {
	unset MFCLI_USER MFCLI_PASSWORD

	run_check app_published

	assert_equal "$status" "0"
	assert_equal "$(result_field .status)" "skipped"
	assert_equal "$(result_field '.evidence.suggested_actions[0]')" "Fix the credentials check first"
	assert_mfcli_calls ""
}

@test "Should succeed when the app has an active version" {
	seed_active_version "1.0.0"

	run_check app_published

	assert_equal "$status" "0"
	assert_equal "$(result_field .status)" "success"
	assert_json_equal "$(result_field -c .evidence.details)" '{"app":"PetStore","environment":"uat","status":"success","version":"1.0.0","active_version":"1.0.0"}' "details"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "Should fail when the app is not published in the environment" {
	run_check app_published

	assert_equal "$status" "1"
	assert_equal "$(result_field .status)" "failed"
	assert_equal "$(result_field .evidence.severity)" "critical"
	assert_equal "$(result_field .evidence.summary)" "PetStore is not published in environment uat"
	assert_equal "$(result_field '.evidence.affected | join(",")')" "uat/PetStore"
	[[ "$(result_field '.evidence.suggested_actions[0]')" == "Deploy a release of the scope"* ]]
}

@test "Should fail when the app has no active version yet" {
	import_as_mock "1.0.0"
	MFCLI_MOCK_PUBLISH_FAIL=1 publish_as_mock "1.0.0"

	run_check app_published

	assert_equal "$status" "1"
	assert_equal "$(result_field .status)" "failed"
	assert_equal "$(result_field .evidence.summary)" "PetStore has no active version in environment uat"
	assert_equal "$(result_field .evidence.details.status)" "failed"
}

@test "Should warn when a publish is in progress and the previous version still serves" {
	seed_active_version "0.9.0"
	import_as_mock "1.0.0"
	MFCLI_MOCK_PUBLISH_HANG=1 publish_as_mock "1.0.0"

	run_check app_published

	assert_equal "$status" "0"
	assert_equal "$(result_field .status)" "warning"
	assert_equal "$(result_field .evidence.severity)" "warning"
	assert_equal "$(result_field .evidence.summary)" "A publish of PetStore version 1.0.0 is in progress; version 0.9.0 serves"
}

@test "Should warn when the last publish failed and the previous version still serves" {
	seed_active_version "0.9.0"
	import_as_mock "1.0.0"
	MFCLI_MOCK_PUBLISH_FAIL=1 publish_as_mock "1.0.0"

	run_check app_published

	assert_equal "$status" "0"
	assert_equal "$(result_field .status)" "warning"
	assert_equal "$(result_field .evidence.summary)" "The last publish of PetStore version 1.0.0 failed; version 0.9.0 still serves"
	assert_equal "$(result_field '.evidence.suggested_actions[0]')" "Check the publish logs of the app in the Foundry console, fix the app and deploy again"
}

@test "Should fail with the mfcli error when Foundry cannot be asked, without the password" {
	seed_active_version "1.0.0"
	export MFCLI_MOCK_AUTH_FAIL=1

	run_check app_published

	assert_equal "$status" "1"
	assert_equal "$(result_field .status)" "failed"
	assert_equal "$(result_field .evidence.details.error)" "Error: Authentication failed. Invalid credentials for user 'np-foundry'."
	refute_output_contains "$MFCLI_PASSWORD"
	refute_file_contains "$SCRIPT_OUTPUT_FILE" "$MFCLI_PASSWORD"
}
