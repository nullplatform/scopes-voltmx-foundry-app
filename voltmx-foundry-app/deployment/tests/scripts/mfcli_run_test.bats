#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/mfcli_run: the only place that calls
# $MFCLI_CMD. It adds the credentials and auth flags, keeps the password out of
# every log, and translates mfcli errors into causes and fixes.
#
# Runs against the mfcli mock (tools/mfcli-mock/mfcli, see its README).
#
# Run: bats voltmx-foundry-app/deployment/tests/scripts/mfcli_run_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_foundry_test "$DEPLOYMENT_DIR"
	SCRIPT="$SCRIPTS_DIR/mfcli_run"
}

@test "Should call mfcli with the credentials and auth flags and keep stdout in MFCLI_OUTPUT" {
	seed_active_version "0.9.0"
	source "$SCRIPT"

	mfcli_run publish-status -e uat -a PetStore

	assert_equal "$(echo "$MFCLI_OUTPUT" | jq -r .status)" "success"
	assert_equal "$(echo "$MFCLI_OUTPUT" | jq -r .active_version)" "0.9.0"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "Should print stdout when executed instead of sourced" {
	seed_active_version "0.9.0"

	run bash "$SCRIPT" appinfo -e uat -a PetStore

	assert_equal "$status" "0"
	assert_equal "$(echo "$output" | jq -r .appKey)" "mock-key-uat-PetStore"
}

@test "Should pass the on-premises identity and console URLs" {
	export MFCLI_AUTH_ARGS="-au https://identity.example.com -cu https://console.example.com"

	run bash "$SCRIPT" Import -f "$FOUNDRY_ZIP" -a PetStore -v 1.0.0

	assert_equal "$status" "0"
	assert_mfcli_calls "mfcli Import -u np-foundry -p *** -au https://identity.example.com -cu https://console.example.com -f $FOUNDRY_ZIP -a PetStore -v 1.0.0"
}

@test "Should translate invalid credentials into a locked user or rotated password" {
	export MFCLI_MOCK_VALID_PASSWORD="another-password"

	run bash "$SCRIPT" Import -f "$FOUNDRY_ZIP" -a PetStore -v 1.0.0

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli Import failed (exit 1): Error: Authentication failed. Invalid credentials for user 'np-foundry'."
	assert_line "  💡 Possible causes: the Foundry technical user is locked or the password rotated"
	assert_line "    • The secret 'voltmx/mobile/foundry-uat' still holds an old password of user 'np-foundry'"
	assert_line "  🔧 How to fix:"
	assert_line "    • Unlock the user 'np-foundry' in the Foundry console and store its current password in the secret 'voltmx/mobile/foundry-uat'"
	refute_output_contains "$MFCLI_PASSWORD"
	refute_file_contains "$MFCLI_MOCK_LOG" "$MFCLI_PASSWORD"
}

@test "Should translate an app or version that Foundry does not have" {
	run bash "$SCRIPT" Publish -e uat -a PetStore -v 7.7.7

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli Publish failed (exit 1): Error: App 'PetStore' version '7.7.7' not found. Import it before publishing."
	assert_line "  💡 Possible causes:"
	assert_line "    • App 'PetStore' version 7.7.7 was never imported into Foundry, or it is not published in environment 'uat'"
	assert_line "    • The app name of the scope does not match the name of the app in Foundry"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check the apps and versions in the Foundry console, then deploy a release that imports that version"
}

@test "Should translate a timeout waiting for Foundry" {
	export MFCLI_MOCK_LOCK_TIMEOUT=0
	mkdir -p "$MFCLI_MOCK_STATE/.lock"

	run bash "$SCRIPT" Publish -e uat -a PetStore -v 1.0.0

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli Publish failed (exit 1): Error: Could not acquire the mock state lock after 0s. Remove $MFCLI_MOCK_STATE/.lock if it is stale."
	assert_line "  💡 Possible causes:"
	assert_line "    • Foundry did not answer in time, or another import or publish of app 'PetStore' holds the lock"
	assert_line "  🔧 How to fix:"
	assert_line "    • Re-run the deployment when the other operation finishes: Import and Publish are idempotent"
	rmdir "$MFCLI_MOCK_STATE/.lock"
}

@test "Should show any other mfcli error with a generic fix" {
	run bash "$SCRIPT" Import -f "$BATS_TEST_TMPDIR/missing.zip" -a PetStore -v 1.0.0

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli Import failed (exit 1): Error: File not found: $BATS_TEST_TMPDIR/missing.zip"
	assert_line "  💡 Possible causes:"
	assert_line "    • The error reported by mfcli above"
	assert_line "  🔧 How to fix:"
	assert_line "    • Fix the cause reported by mfcli and re-run the deployment"
}

@test "Should mask the password even when the CLI echoes it" {
	cat > "$BATS_TEST_TMPDIR/leaky-mfcli" <<'CLI'
#!/bin/bash
echo "connecting with $*"
echo "Error: Authentication failed for $3 using password $5" >&2
exit 1
CLI
	chmod +x "$BATS_TEST_TMPDIR/leaky-mfcli"
	export MFCLI_CMD="$BATS_TEST_TMPDIR/leaky-mfcli"

	run bash "$SCRIPT" authenticate

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli authenticate failed (exit 1): Error: Authentication failed for np-foundry using password ***"
	assert_line "  💡 Possible causes: the Foundry technical user is locked or the password rotated"
	refute_output_contains "$MFCLI_PASSWORD"
}

@test "Should fail when the CLI is not installed" {
	export MFCLI_CMD="java-that-does-not-exist -jar /opt/mfcli/mfcli.jar"

	run bash "$SCRIPT" authenticate

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli is not available: java-that-does-not-exist was not found"
	assert_line "  💡 Possible causes:"
	assert_line "    • The worker image does not include Java and the Foundry CLI (mfcli.jar)"
	assert_line "  🔧 How to fix:"
	assert_line "    • Build the worker image with OpenJDK and /opt/mfcli/mfcli.jar, or point MFCLI_CMD at the CLI"
}

@test "Should fail when the credentials were not loaded" {
	unset MFCLI_PASSWORD

	run bash "$SCRIPT" authenticate

	assert_equal "$status" "1"
	assert_line "   ❌ The Foundry credentials are not loaded (MFCLI_USER, MFCLI_PASSWORD and MFCLI_AUTH_ARGS are required)"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run build_context and read_credentials before any Foundry step"
	assert_file_not_exists "$MFCLI_MOCK_LOG"
}

@test "Should leave no temporary file behind, on success or failure" {
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$TMPDIR"
	seed_active_version "0.9.0"
	source "$SCRIPT"

	mfcli_run publish-status -e uat -a PetStore
	MFCLI_RUN_QUIET=1 mfcli_run Publish -e uat -a PetStore -v 7.7.7 || true
	MFCLI_RUN_QUIET=1 MFCLI_MOCK_VALID_PASSWORD=other mfcli_run authenticate || true

	assert_equal "$(find "$TMPDIR" -type f | wc -l | tr -d ' ')" "0"
}

@test "Should stop a call that hangs after MFCLI_CALL_TIMEOUT_SECONDS" {
	cat > "$BATS_TEST_TMPDIR/hanging-mfcli" <<'CLI'
#!/bin/bash
exec sleep 30
CLI
	chmod +x "$BATS_TEST_TMPDIR/hanging-mfcli"
	export MFCLI_CMD="$BATS_TEST_TMPDIR/hanging-mfcli"
	export MFCLI_CALL_TIMEOUT_SECONDS=1
	local start
	start=$(date +%s)

	run bash "$SCRIPT" publish-status -e uat -a PetStore

	assert_equal "$status" "124"
	assert_less_than "$(( $(date +%s) - start ))" "10" "seconds the hung call took"
	assert_line "   ❌ mfcli publish-status did not finish in 1s (MFCLI_CALL_TIMEOUT_SECONDS)"
	assert_line "  💡 Possible causes:"
	assert_line "    • Foundry is unreachable from the worker or does not answer (console or identity URL, network, proxy)"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check that the worker reaches Foundry and re-run the deployment: Import and Publish are idempotent"
	assert_line "    • Raise MFCLI_CALL_TIMEOUT_SECONDS if this call is legitimately slow"
}

@test "Should reject a call timeout that is not a positive number" {
	export MFCLI_CALL_TIMEOUT_SECONDS=0

	run bash "$SCRIPT" authenticate

	assert_equal "$status" "1"
	assert_line "   ❌ MFCLI_CALL_TIMEOUT_SECONDS must be a positive number of seconds, got '0'"
	assert_file_not_exists "$MFCLI_MOCK_LOG"
}

@test "Should classify a lock message as a timeout even when it mentions a user, and only user or account lockouts as credentials" {
	cat > "$BATS_TEST_TMPDIR/msg-mfcli" <<'CLI'
#!/bin/bash
echo "$MSG" >&2
exit 1
CLI
	chmod +x "$BATS_TEST_TMPDIR/msg-mfcli"
	export MFCLI_CMD="$BATS_TEST_TMPDIR/msg-mfcli"

	MSG="Error: Timed out waiting for the app lock held by user np-other" run bash "$SCRIPT" Publish -e uat -a PetStore -v 1.0.0
	assert_line "    • Foundry did not answer in time, or another import or publish of app 'PetStore' holds the lock"

	MSG="Error: User np-foundry is locked after 5 failed logins" run bash "$SCRIPT" Publish -e uat -a PetStore -v 1.0.0
	assert_line "  💡 Possible causes: the Foundry technical user is locked or the password rotated"

	MSG="Error: Account locked" run bash "$SCRIPT" Publish -e uat -a PetStore -v 1.0.0
	assert_line "  💡 Possible causes: the Foundry technical user is locked or the password rotated"

	MSG="Error: Version 1.0.0 is locked for editing" run bash "$SCRIPT" Publish -e uat -a PetStore -v 1.0.0
	refute_line "  💡 Possible causes: the Foundry technical user is locked or the password rotated"
}

@test "Should leave no watchdog process behind after a call that finishes in time" {
	export MFCLI_CALL_TIMEOUT_SECONDS=287
	seed_active_version "0.9.0"

	run bash "$SCRIPT" publish-status -e uat -a PetStore

	assert_equal "$status" "0"
	sleep 0.2
	assert_equal "$(pgrep -f "sleep 287" | wc -l | tr -d ' ')" "0"
}

@test "Should KILL a call that ignores TERM, 5 seconds after the timeout" {
	cat > "$BATS_TEST_TMPDIR/stubborn-mfcli" <<'CLI'
#!/bin/bash
trap '' TERM
while :; do sleep 1; done
CLI
	chmod +x "$BATS_TEST_TMPDIR/stubborn-mfcli"
	export MFCLI_CMD="$BATS_TEST_TMPDIR/stubborn-mfcli"
	export MFCLI_CALL_TIMEOUT_SECONDS=1
	local start elapsed
	start=$(date +%s)

	run bash "$SCRIPT" publish-status -e uat -a PetStore

	elapsed=$(( $(date +%s) - start ))
	assert_equal "$status" "124"
	assert_line "   ❌ mfcli publish-status did not finish in 1s (MFCLI_CALL_TIMEOUT_SECONDS)"
	assert_greater_than "$elapsed" "4" "seconds before KILL"
	assert_less_than "$elapsed" "15" "seconds before KILL"
	assert_equal "$(pgrep -f "$BATS_TEST_TMPDIR/stubborn-mfcli" | wc -l | tr -d ' ')" "0"
}
