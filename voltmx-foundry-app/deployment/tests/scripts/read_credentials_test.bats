#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/read_credentials (sourced): reads the
# Foundry technical user from the secrets manager and exports MFCLI_USER and
# MFCLI_PASSWORD in memory only.
#
# Run: bats voltmx-foundry-app/deployment/tests/scripts/read_credentials_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_foundry_test "$DEPLOYMENT_DIR"
	SCRIPT="$SCRIPTS_DIR/read_credentials"

	unset MFCLI_USER MFCLI_PASSWORD
	write_mock_secret "voltmx/mobile/foundry-uat" '{"username":"np-foundry","password":"Pa55-w0rd-x9"}'
}

@test "Should export the Foundry user and password from the secret without printing the password" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Reading the Foundry credentials..."
	assert_line "   📡 Reading secret 'voltmx/mobile/foundry-uat'"
	assert_line "   ✅ Foundry user: np-foundry"
	refute_output_contains "Pa55-w0rd-x9"
	assert_mock_call "$AWS_MOCK_CALLS_LOG" "aws secretsmanager get-secret-value --secret-id voltmx/mobile/foundry-uat --query SecretString --output text --region us-east-1"

	source "$SCRIPT"
	assert_equal "$MFCLI_USER" "np-foundry"
	assert_equal "$MFCLI_PASSWORD" "Pa55-w0rd-x9"
	assert_equal "$(grep -rlF "Pa55-w0rd-x9" "$WORKDIR" | wc -l | tr -d ' ')" "0"
}

@test "Should refuse a secret outside the voltmx/ namespace without reading it" {
	export CREDENTIALS_SECRET="mobile/firebase-sa"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Secret name 'mobile/firebase-sa' is outside the voltmx/ namespace (credentials_secret)"
	assert_file_not_exists "$AWS_MOCK_CALLS_LOG"
}

@test "Should fail with the troubleshooting block when the secret cannot be read" {
	export CREDENTIALS_SECRET="voltmx/mobile/missing"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not read secret 'voltmx/mobile/missing' from the secrets manager"
	assert_line "  💡 Possible causes:"
	assert_line "    • The secret does not exist in region us-east-1"
	assert_line "    • The agent role has no secretsmanager:GetSecretValue permission on it"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create the secret with {\"username\": ..., \"password\": ...} or grant the agent role read access to it"
}

@test "Should fail without echoing the secret when it is not a username/password JSON" {
	local value
	for value in 'plain-password-123' '{"user":"np-foundry","pass":"plain-password-123"}' '{"username":"np-foundry","password":""}'; do
		write_mock_secret "voltmx/mobile/foundry-uat" "$value"

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Secret 'voltmx/mobile/foundry-uat' is not a {\"username\", \"password\"} JSON"
		assert_line "  💡 Possible causes:"
		assert_line "    • The secret holds the password alone or uses other field names"
		assert_line "  🔧 How to fix:"
		assert_line "    • Store the Foundry technical user as {\"username\": \"<user>\", \"password\": \"<password>\"}"
		refute_output_contains "plain-password-123"
	done
}

@test "Should refuse a secret of another namespace without reading it" {
	export CREDENTIALS_SECRET="voltmx/payments/foundry-uat"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Secret 'voltmx/payments/foundry-uat' is outside the secrets of this namespace: credentials_secret must start with voltmx/mobile/"
	assert_file_not_exists "$AWS_MOCK_CALLS_LOG"
}

@test "Should fail closed when the secrets prefix of the namespace is unknown" {
	unset SECRETS_PREFIX

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ SECRETS_PREFIX is not set: cannot check that credentials_secret belongs to this namespace"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the deployment workflow from the start so build_context resolves the secrets prefix"
	assert_file_not_exists "$AWS_MOCK_CALLS_LOG"
}
