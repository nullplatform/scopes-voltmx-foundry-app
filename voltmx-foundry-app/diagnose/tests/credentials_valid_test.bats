#!/usr/bin/env bats
# =============================================================================
# Unit tests for diagnose/checks/credentials_valid: reads the secret with the
# aws mock and authenticates against the mfcli mock.
#
# Run: bats voltmx-foundry-app/diagnose/tests/credentials_valid_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SCOPE_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$SCOPE_DIR/.." && pwd)/testing/assertions.sh"
	source "$TEST_DIR/helpers.bash"
	setup_diagnose_test "$SCOPE_DIR"

	# The credentials only come from the secret.
	SECRET_PASSWORD="$MFCLI_PASSWORD"
	unset MFCLI_USER MFCLI_PASSWORD
	write_mock_secret "voltmx/mobile/foundry-uat" "$(jq -nc --arg p "$SECRET_PASSWORD" '{username: "np-foundry", password: $p}')"
}

@test "Should read the secret, authenticate and report the user without the password" {
	run_check credentials_valid

	assert_equal "$status" "0"
	assert_equal "$(result_field .status)" "success"
	assert_equal "$(result_field .evidence.severity)" "info"
	assert_json_equal "$(result_field -c .evidence.details)" '{"user":"np-foundry","credentials_secret":"voltmx/mobile/foundry-uat","auth":"cloud"}' "details"
	assert_mfcli_calls "mfcli authenticate -u np-foundry -p *** -t 100000001"
	refute_output_contains "$SECRET_PASSWORD"
	refute_file_contains "$SCRIPT_OUTPUT_FILE" "$SECRET_PASSWORD"
	refute_file_contains "$SCRIPT_OUTPUT_FILE" "mock-token"
}

@test "Should export the credentials for the checks that follow in the same shell" {
	source "$DIAGNOSE_DIR/checks/credentials_valid" >/dev/null

	assert_equal "$MFCLI_USER" "np-foundry"
	assert_equal "$MFCLI_PASSWORD" "$SECRET_PASSWORD"
}

@test "Should fail with the secret as affected when it cannot be read" {
	export CREDENTIALS_SECRET="voltmx/mobile/foundry-missing"

	run_check credentials_valid

	assert_equal "$status" "1"
	assert_equal "$(result_field .status)" "failed"
	assert_equal "$(result_field .evidence.severity)" "critical"
	assert_equal "$(result_field '.evidence.affected | join(",")')" "voltmx/mobile/foundry-missing"
	assert_equal "$(result_field .evidence.details.secrets_prefix)" "voltmx/mobile/"
	[[ "$output" == *"Could not read secret 'voltmx/mobile/foundry-missing' from the secrets manager"* ]]
	assert_mfcli_calls ""
}

@test "Should refuse a secret outside the namespace prefix before reading it" {
	export CREDENTIALS_SECRET="voltmx/payments/foundry-uat"

	run_check credentials_valid

	assert_equal "$status" "1"
	assert_equal "$(result_field .status)" "failed"
	[[ "$output" == *"credentials_secret must start with voltmx/mobile/"* ]]
	[ ! -f "$AWS_MOCK_CALLS_LOG" ]
}

@test "Should fail and explain a rotated password without printing it" {
	export MFCLI_MOCK_VALID_PASSWORD="rotated-password"

	run_check credentials_valid

	assert_equal "$status" "1"
	assert_equal "$(result_field .status)" "failed"
	assert_equal "$(result_field .evidence.details.user)" "np-foundry"
	assert_equal "$(result_field .evidence.details.error)" "Error: Authentication failed. Invalid credentials for user 'np-foundry'."
	assert_equal "$(result_field '.evidence.suggested_actions[0]')" "Unlock the user np-foundry in the Foundry console and store its current password in the secret voltmx/mobile/foundry-uat"
	[[ "$output" == *"Possible causes: the Foundry technical user is locked or the password rotated"* ]]
	refute_output_contains "$SECRET_PASSWORD"
	refute_file_contains "$SCRIPT_OUTPUT_FILE" "$SECRET_PASSWORD"
}
