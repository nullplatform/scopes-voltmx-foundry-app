#!/usr/bin/env bats
# =============================================================================
# Unit tests for diagnose/utils/diagnose_utils: the result file a check
# updates and the results sent to the platform.
#
# Run: bats voltmx-foundry-app/diagnose/tests/diagnose_utils_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SCOPE_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$SCOPE_DIR/.." && pwd)/testing/assertions.sh"
	source "$TEST_DIR/helpers.bash"
	setup_diagnose_test "$SCOPE_DIR"
}

@test "evidence_json: builds the evidence schema with defaults for the empty parts" {
	run evidence_json "All good" "info" "" "" ""

	assert_equal "$status" "0"
	assert_json_equal "$output" '{"summary":"All good","severity":"info","affected":[],"details":{},"suggested_actions":[]}' "evidence"
}

@test "update_check_result: writes the status, the evidence, the log tail and the end time" {
	printf 'line 1\n\nline 2\n' > "$SCRIPT_LOG_FILE"

	update_check_result --status "failed" --evidence '{"summary":"broken","severity":"critical"}'

	assert_equal "$(result_field .status)" "failed"
	assert_equal "$(result_field .evidence.summary)" "broken"
	assert_equal "$(result_field '.logs | join("|")')" "line 1|line 2"
	assert_equal "$(result_field .name)" "Check"
	[[ "$(result_field .end_at)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]
	assert_equal "$(result_field '.start_at // "none"')" "none"
}

@test "update_check_result: running sets the start time and the positional form works" {
	update_check_result running '{}'

	assert_equal "$(result_field .status)" "running"
	[[ "$(result_field .start_at)" =~ ^[0-9]{4}- ]]
}

@test "update_check_result: fails without a status, an evidence or the result file" {
	run update_check_result --status "success"
	assert_equal "$status" "1"

	SCRIPT_OUTPUT_FILE="$BATS_TEST_TMPDIR/missing.json" run update_check_result --status "success" --evidence '{}'
	assert_equal "$status" "1"
	assert_line "Error: SCRIPT_OUTPUT_FILE is not set or not found: $BATS_TEST_TMPDIR/missing.json"

	run update_check_result --status "success" --evidence 'not json'
	assert_equal "$status" "1"
	assert_equal "$(result_field .status)" "pending"
}

@test "notify_results: groups the results by category and patches the action with a body file" {
	echo '{"category":"Foundry","status":"success","evidence":{}}' > "$NP_OUTPUT_DIR/checks/a.json"
	echo '{"category":"Foundry","status":"failed","evidence":{}}' > "$NP_OUTPUT_DIR/checks/b.json"
	mkdir -p "$NP_OUTPUT_DIR/data"
	echo '{"category":"ignored"}' > "$NP_OUTPUT_DIR/data/snapshot.json"
	np() {
		echo "np $*" >> "$NP_MOCK_CALLS_LOG"
		while [ $# -gt 0 ]; do [ "$1" = "--body" ] && cp "$2" "$BATS_TEST_TMPDIR/body.json"; shift; done
	}
	export -f np

	run notify_results

	assert_equal "$status" "0"
	assert_np_called "np service action patch --id action-123 --serviceId service-456 --body "
	assert_np_called ".json --no-output"
	assert_equal "$(jq -c '.results.categories | map({category, summary: {success: .summary.success, failed: .summary.failed, pending: .summary.pending}, checks: (.checks | length)})' "$BATS_TEST_TMPDIR/body.json")" \
		'[{"category":"Foundry","summary":{"success":1,"failed":1,"pending":1},"checks":3}]'
}

@test "notify_results: fails without result files or without the action in NP_ACTION_CONTEXT" {
	rm -f "$SCRIPT_OUTPUT_FILE"
	run notify_results
	assert_equal "$status" "1"
	[[ "$output" == *"No JSON result files found"* ]]

	echo '{"category":"Foundry","status":"success","evidence":{}}' > "$NP_OUTPUT_DIR/checks/a.json"
	np() { echo "np $*" >> "$NP_MOCK_CALLS_LOG"; }
	export -f np
	NP_ACTION_CONTEXT='{"notification":{}}' run notify_results
	assert_equal "$status" "1"
	[[ "$output" == *"No action id or service id in NP_ACTION_CONTEXT"* ]]
	[ ! -f "$NP_MOCK_CALLS_LOG" ]
}

@test "notify_check_running and notify_diagnose_results: the executor hooks mark the check running and send the results" {
	np() { echo "np $*" >> "$NP_MOCK_CALLS_LOG"; }
	export -f np

	source "$DIAGNOSE_DIR/notify_check_running"
	assert_equal "$(result_field .status)" "running"

	source "$DIAGNOSE_DIR/notify_diagnose_results"
	assert_np_called "np service action patch --id action-123 --serviceId service-456"
}
