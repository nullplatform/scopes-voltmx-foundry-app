#!/usr/bin/env bats
# =============================================================================
# Unit tests for diagnose/checks/console_reachable, with a curl mock.
#
# Run: bats voltmx-foundry-app/diagnose/tests/console_reachable_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SCOPE_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$SCOPE_DIR/.." && pwd)/testing/assertions.sh"
	source "$TEST_DIR/helpers.bash"
	setup_diagnose_test "$SCOPE_DIR"

	mkdir -p "$BATS_TEST_TMPDIR/bin"
	cat > "$BATS_TEST_TMPDIR/bin/curl" <<'MOCK'
#!/bin/bash
echo "curl $*" >> "$CURL_MOCK_CALLS_LOG"
if [ -n "${CURL_MOCK_FAIL:-}" ]; then
	echo "curl: (6) Could not resolve host: ${*: -1}" >&2
	exit 6
fi
printf '%s' "${CURL_MOCK_HTTP_CODE:-302}"
MOCK
	chmod +x "$BATS_TEST_TMPDIR/bin/curl"
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
	export CURL_MOCK_CALLS_LOG="$BATS_TEST_TMPDIR/curl_calls.log"
	unset CURL_MOCK_FAIL CURL_MOCK_HTTP_CODE
}

@test "Should skip the check for Volt MX cloud, where there is no console URL" {
	export MFCLI_AUTH_ARGS="-t 100000001"

	run_check console_reachable

	assert_equal "$status" "0"
	assert_equal "$(result_field .status)" "skipped"
	assert_equal "$(result_field .evidence.severity)" "info"
	assert_equal "$(result_field .evidence.details.auth)" "-t 100000001"
	[ ! -f "$CURL_MOCK_CALLS_LOG" ]
}

@test "Should succeed when the on-premises console answers, whatever the HTTP status" {
	export MFCLI_AUTH_ARGS="-au https://id.foundry.example.com -cu https://console.foundry.example.com/mfconsole"
	export CURL_MOCK_HTTP_CODE=302

	run_check console_reachable

	assert_equal "$status" "0"
	assert_equal "$(result_field .status)" "success"
	assert_equal "$(result_field .evidence.details.console_url)" "https://console.foundry.example.com/mfconsole"
	assert_equal "$(result_field .evidence.details.http_code)" "302"
	assert_mock_call "$CURL_MOCK_CALLS_LOG" "curl -sS -o /dev/null -w %{http_code} --connect-timeout 10 --max-time 20 https://console.foundry.example.com/mfconsole"
}

@test "Should fail with the console URL as affected when the worker cannot reach it" {
	export MFCLI_AUTH_ARGS="-au https://id.foundry.example.com -cu https://console.foundry.example.com"
	export CURL_MOCK_FAIL=1 DIAGNOSE_HTTP_TIMEOUT_SECONDS=5

	run_check console_reachable

	assert_equal "$status" "1"
	assert_equal "$(result_field .status)" "failed"
	assert_equal "$(result_field .evidence.severity)" "critical"
	assert_equal "$(result_field '.evidence.affected | join(",")')" "https://console.foundry.example.com"
	assert_equal "$(result_field .evidence.details.error)" "curl: (6) Could not resolve host: https://console.foundry.example.com"
	assert_equal "$(result_field .evidence.details.timeout_seconds)" "5"
	assert_equal "$(result_field '.evidence.suggested_actions | length')" "2"
	[[ "$output" == *"did not answer: curl: (6) Could not resolve host"* ]]
	assert_mock_call "$CURL_MOCK_CALLS_LOG" "curl -sS -o /dev/null -w %{http_code} --connect-timeout 10 --max-time 5 https://console.foundry.example.com"
}
