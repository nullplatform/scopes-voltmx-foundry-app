#!/usr/bin/env bats
# =============================================================================
# Unit tests for the instance:data routing of the root entrypoint and
# service/instance/entrypoint.
#
# instance:data runs voltmx-foundry-app/instance/workflows/list.yaml with
# np service workflow exec --no-output --build-context, after copying the
# scope id of the request into .notification.parameters.scope_id (what
# build-context reads). stdout must be the JSON answer only. np is a mock
# that records its arguments and the context it received.
#
# Run: bats voltmx-foundry-app/instance/tests/entrypoint_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SCOPE_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	source "$PROJECT_ROOT/testing/assertions.sh"
	source "$SCOPE_DIR/deployment/tests/helpers.bash"
	ENTRYPOINT="$PROJECT_ROOT/entrypoint"

	TEST_TMP_DIR=$(mktemp -d)
	mkdir -p "$TEST_TMP_DIR/bin"
	cat > "$TEST_TMP_DIR/bin/np" <<'MOCK'
#!/bin/bash
if [ "${*: -1}" = "--help" ]; then
	echo "${NP_MOCK_HELP-      --no-params           Skip fetching parameters during build context}"
	exit 0
fi
printf '%s\n' "$*" >> "$NP_MOCK_CALLS_LOG"
printf '%s\n' "$NP_ACTION_CONTEXT" > "$NP_MOCK_CONTEXT_FILE"
echo "workflow logs go to stderr" >&2
echo '{"results":[{"id":"uat/PetStore","state":"Running"}]}'
MOCK
	chmod +x "$TEST_TMP_DIR/bin/np"
	export PATH="$TEST_TMP_DIR/bin:$PATH"
	export NP_MOCK_CALLS_LOG="$TEST_TMP_DIR/np_calls.log"
	export NP_MOCK_CONTEXT_FILE="$TEST_TMP_DIR/context.json"
	unset NULLPLATFORM_API_KEY NP_API_KEY NP_MOCK_HELP
}

teardown() {
	rm -rf "$TEST_TMP_DIR"
}

# notification <action> <arguments json>
notification() {
	jq -nc --arg action "$1" --argjson arguments "$2" \
		'{notification: {action: $action, arguments: $arguments, tags: {}, parameters: {}}}'
}

run_entrypoint() {
	run bash -c '"$0" "$@" 2>/dev/null' "$ENTRYPOINT" "$@"
}

@test "Should run the instance list workflow for instance:data and print only its JSON" {
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "instance:data" '{"scope_id": ["7"], "application_id": ["442353700"]}')

	run_entrypoint --service-path="$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "$output" '{"results":[{"id":"uat/PetStore","state":"Running"}]}'
	assert_mock_call "$NP_MOCK_CALLS_LOG" "service workflow exec --no-output --build-context --no-params --workflow $SCOPE_DIR/instance/workflows/list.yaml"
	assert_equal "$(jq -r '.notification.parameters.scope_id' "$NP_MOCK_CONTEXT_FILE")" "7"
}

@test "Should accept a scalar scope id" {
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "instance:data" '{"scope_id": 7}')

	run_entrypoint --service-path="$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "$(jq -r '.notification.parameters.scope_id' "$NP_MOCK_CONTEXT_FILE")" "7"
}

@test "Should layer the instance workflow of an override directory" {
	mkdir -p "$TEST_TMP_DIR/overrides/instance/workflows"
	: > "$TEST_TMP_DIR/overrides/instance/workflows/list.yaml"
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "instance:data" '{"scope_id": ["7"]}')

	run_entrypoint --service-path="$SCOPE_DIR" --overrides-path="$TEST_TMP_DIR/overrides"

	assert_equal "$status" "0"
	assert_mock_call "$NP_MOCK_CALLS_LOG" "service workflow exec --no-output --build-context --no-params --workflow $SCOPE_DIR/instance/workflows/list.yaml --overrides $TEST_TMP_DIR/overrides/instance/workflows/list.yaml"
}

@test "Should answer no instances without calling np when the request has no scope id" {
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "instance:data" '{"application_id": ["442353700"]}')

	run_entrypoint --service-path="$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "$output" '{"results":[]}'
	[ ! -f "$NP_MOCK_CALLS_LOG" ]
}

@test "Should keep answering empty results for log:read and metric:list" {
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "log:read" '{"scope_id": ["7"]}')
	run_entrypoint --service-path="$SCOPE_DIR"
	assert_equal "$output" '{"results":[],"next_page_token":""}'

	NP_ACTION_CONTEXT=$(notification "metric:list" '{"scope_id": ["7"]}')
	run_entrypoint --service-path="$SCOPE_DIR"
	assert_equal "$output" '{"results":[]}'
	[ ! -f "$NP_MOCK_CALLS_LOG" ]
}

# =============================================================================
# Routing hardening: the instance branch is chosen by NOTIFICATION_ACTION
# (.action) alone, like log:read and metric:*, and service/instance/entrypoint
# refuses anything that is not a pure instance:data telemetry request. A
# service action (it carries a slug) or a deployment never reaches the
# instance workflow, whatever its .action says.
# =============================================================================
# action_notification <action> <slug>: a service action notification (slug, type, deployment).
action_notification() {
	jq -nc --arg action "$1" --arg slug "$2" '{notification: {
		action: $action, slug: $slug, type: "custom",
		parameters: {scope_id: "7", deployment_id: "77"}, arguments: {scope_id: ["7"]}, tags: {}}}'
}

@test "Should never route start-initial to the instance workflow, whatever its notification action" {
	local action
	for action in "deployment:create" "service:action:create" "scope:update" "" "instance:data"; do
		rm -f "$NP_MOCK_CALLS_LOG"
		export NP_ACTION_CONTEXT
		NP_ACTION_CONTEXT=$(action_notification "$action" "start-initial")

		run_entrypoint --service-path="$SCOPE_DIR"

		if grep -q "instance/workflows/list.yaml" "$NP_MOCK_CALLS_LOG" 2>/dev/null; then
			echo "start-initial with action '$action' reached the instance workflow"
			cat "$NP_MOCK_CALLS_LOG"
			return 1
		fi
		assert_mock_call "$NP_MOCK_CALLS_LOG" "service-action exec --live-output --live-report --script=$PROJECT_ROOT/service/deployment/entrypoint"
	done
}

@test "Should refuse in the instance handler a service action that claims to be instance:data" {
	# The root entrypoint never sends it here (see above); the handler refuses it too.
	export NP_ACTION_CONTEXT CONTEXT NOTIFICATION_ACTION="instance:data" WORKING_DIRECTORY="$PROJECT_ROOT" SERVICE_PATH="$SCOPE_DIR"
	NP_ACTION_CONTEXT=$(action_notification "instance:data" "start-initial")
	CONTEXT=$(echo "$NP_ACTION_CONTEXT" | jq -c .notification)

	run bash -c '"$0" 2>&1 >/dev/null' "$PROJECT_ROOT/service/instance/entrypoint"

	assert_equal "$status" "1"
	assert_line "❌ instance:data must be a telemetry request, got slug='start-initial' deployment='77'"
	assert_line "💡 Possible causes:"
	assert_line "   • A service action notification carries action instance:data"
	assert_line "🔧 How to fix:"
	assert_line "   • Check the notification channel: instance:data requests carry no slug and no deployment_id"
	[ ! -f "$NP_MOCK_CALLS_LOG" ]
}

@test "Should refuse to run the instance handler for any other notification action" {
	export NP_ACTION_CONTEXT CONTEXT NOTIFICATION_ACTION="metric:list" WORKING_DIRECTORY="$PROJECT_ROOT" SERVICE_PATH="$SCOPE_DIR"
	NP_ACTION_CONTEXT=$(notification "metric:list" '{"scope_id": ["7"]}')
	CONTEXT=$(echo "$NP_ACTION_CONTEXT" | jq -c .notification)

	run bash -c '"$0" 2>&1 >/dev/null' "$PROJECT_ROOT/service/instance/entrypoint"

	assert_equal "$status" "1"
	assert_line "❌ service/instance/entrypoint only answers instance:data, got 'metric:list'"
	[ ! -f "$NP_MOCK_CALLS_LOG" ]
}

@test "Should take the scope of an instance:data request from its arguments only" {
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(jq -nc '{notification: {action: "instance:data", arguments: {scope_id: ["7"]}, tags: {scope_id: "99"}, parameters: {}}}')

	run_entrypoint --service-path="$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "$(jq -r '.notification.parameters.scope_id' "$NP_MOCK_CONTEXT_FILE")" "7"
}

@test "Should not pass --no-params to a CLI that does not support it" {
	export NP_MOCK_HELP="      --build-context   Generate context for the action"
	export NP_ACTION_CONTEXT
	NP_ACTION_CONTEXT=$(notification "instance:data" '{"scope_id": ["7"]}')

	run_entrypoint --service-path="$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_mock_call "$NP_MOCK_CALLS_LOG" "service workflow exec --no-output --build-context --workflow $SCOPE_DIR/instance/workflows/list.yaml"
}

@test "Should send a service action to its handler even when its action is a telemetry one" {
	local action
	for action in "log:read" "metric:list" "metric:cpu"; do
		rm -f "$NP_MOCK_CALLS_LOG"
		export NP_ACTION_CONTEXT
		NP_ACTION_CONTEXT=$(action_notification "$action" "start-initial")

		run_entrypoint --service-path="$SCOPE_DIR"

		assert_mock_call "$NP_MOCK_CALLS_LOG" "service-action exec --live-output --live-report --script=$PROJECT_ROOT/service/deployment/entrypoint"
	done
}
