# =============================================================================
# Shared setup of the diagnose tests: the executor contract (SCRIPT_OUTPUT_FILE
# with the pending result JSON, SCRIPT_LOG_FILE, NP_OUTPUT_DIR), the functions
# of diagnose/utils/diagnose_utils and the mfcli/np/aws mocks of the
# deployment tests (setup_foundry_test). Call from setup() with the scope dir.
# =============================================================================

setup_diagnose_test() {
	SCOPE_DIR="$1"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	DIAGNOSE_DIR="$SCOPE_DIR/diagnose"
	UTILS="$DIAGNOSE_DIR/utils/diagnose_utils"
	source "$SCOPE_DIR/deployment/tests/helpers.bash"
	setup_foundry_test "$SCOPE_DIR/deployment"
	source "$UTILS"

	export NP_OUTPUT_DIR="$BATS_TEST_TMPDIR/output"
	mkdir -p "$NP_OUTPUT_DIR/checks"
	export SCRIPT_OUTPUT_FILE="$NP_OUTPUT_DIR/checks/check.json"
	export SCRIPT_LOG_FILE="$NP_OUTPUT_DIR/checks/check.log"
	echo '{"name":"Check","description":"A check","category":"Foundry","status":"pending","evidence":{},"logs":[]}' > "$SCRIPT_OUTPUT_FILE"
	: > "$SCRIPT_LOG_FILE"
	export NP_ACTION_CONTEXT='{"notification":{"id":"action-123","service":{"id":"service-456"}}}'
}

# run_check <check name>: sources the utils and the check in a fresh shell, like the executor.
run_check() {
	run bash -c 'source "$0" && source "$1"' "$UTILS" "$DIAGNOSE_DIR/checks/$1"
}

result_field() {
	jq -r "$@" "$SCRIPT_OUTPUT_FILE"
}
