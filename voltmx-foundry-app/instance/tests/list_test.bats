#!/usr/bin/env bats
# =============================================================================
# Unit tests for voltmx-foundry-app/instance/scripts/{reserve_stdout,list}
#
# The instance workflow answers on stdout with JSON only. Every step is
# sourced in the same shell, so the first step keeps the real stdout on fd 3
# and sends everything else to stderr; the last step asks the mfcli mock for
# the publish status of the app and writes the answer to fd 3.
#
# Run: bats voltmx-foundry-app/instance/tests/list_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	SCOPE_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	source "$PROJECT_ROOT/testing/assertions.sh"
	source "$SCOPE_DIR/deployment/tests/helpers.bash"
	setup_foundry_test "$SCOPE_DIR/deployment"
	RESERVE="$SCOPE_DIR/instance/scripts/reserve_stdout"
	LIST="$SCOPE_DIR/instance/scripts/list"
}

# Import <version> into the mock without publishing it.
import_as_mock() {
	make_foundry_zip "$BATS_TEST_TMPDIR/import-$1.zip" "PetStore" "$1"
	"$MFCLI_CMD" Import -u "$MFCLI_USER" -p "$MFCLI_PASSWORD" -t 100000001 -f "$BATS_TEST_TMPDIR/import-$1.zip" -a PetStore -v "$1" >/dev/null
}

publish_as_mock() {
	"$MFCLI_CMD" Publish -u "$MFCLI_USER" -p "$MFCLI_PASSWORD" -t 100000001 -e uat -a PetStore -v "$1" >/dev/null 2>&1 || true
	: > "$MFCLI_MOCK_LOG"
}

instance_json() {
	jq -nc --arg version "$1" --arg active "$2" --arg status "$3" '{results: [{
		id: "uat/PetStore",
		selector: {app: "PetStore", environment: "uat"},
		state: "Running",
		details: {app: "PetStore", environment: "uat", version: $version, active_version: $active, status: $status}
	}]}'
}

@test "Should send the logs of every step to stderr and only the JSON answer to stdout" {
	seed_active_version "1.0.0"

	run bash -c 'exec 2>/dev/null; source "$0"; echo "a step log"; source "$1"' "$RESERVE" "$LIST"

	assert_equal "$status" "0"
	assert_json_equal "$output" "$(instance_json 1.0.0 1.0.0 success)" "instance answer"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "Should print the answer on stdout when run on its own" {
	seed_active_version "1.0.0"

	run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "0"
	assert_json_equal "$output" "$(instance_json 1.0.0 1.0.0 success)" "instance answer"
}

@test "Should report the version that serves when the last publish failed" {
	seed_active_version "0.9.0"
	import_as_mock "1.0.0"
	MFCLI_MOCK_PUBLISH_FAIL=1 publish_as_mock "1.0.0"

	run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "0"
	assert_json_equal "$output" "$(instance_json 1.0.0 0.9.0 failed)" "instance answer"
}

@test "Should answer no instances when the app is not published in the environment" {
	run bash -c 'exec 2>"$1"; source "$0"' "$LIST" "$BATS_TEST_TMPDIR/stderr"

	assert_equal "$status" "0"
	assert_equal "$output" '{"results":[]}'
	assert_equal "$(cat "$BATS_TEST_TMPDIR/stderr")" "   📋 PetStore is not published in environment uat; no instances"
}

@test "Should answer no instances when the app has no active version yet" {
	import_as_mock "1.0.0"
	MFCLI_MOCK_PUBLISH_FAIL=1 publish_as_mock "1.0.0"

	run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "0"
	assert_equal "$output" '{"results":[]}'
}

@test "Should answer no instances and fail when Foundry rejects the credentials, without the password" {
	seed_active_version "1.0.0"
	export MFCLI_MOCK_VALID_PASSWORD="rotated-password"

	run bash -c 'exec 2>"$1"; source "$0"' "$LIST" "$BATS_TEST_TMPDIR/stderr"

	assert_equal "$status" "1"
	assert_equal "$output" '{"results":[]}'
	grep -qF "  💡 Possible causes: the Foundry technical user is locked or the password rotated" "$BATS_TEST_TMPDIR/stderr"
	refute_file_contains "$BATS_TEST_TMPDIR/stderr" "$MFCLI_PASSWORD"
}

@test "Should fail without calling Foundry when build_context did not run" {
	unset FOUNDRY_APP

	run bash -c 'exec 2>"$1"; source "$0"' "$LIST" "$BATS_TEST_TMPDIR/stderr"

	assert_equal "$status" "1"
	assert_equal "$output" '{"results":[]}'
	grep -qF "FOUNDRY_APP or ENVIRONMENT_NAME is not set" "$BATS_TEST_TMPDIR/stderr"
	assert_mfcli_calls ""
}

@test "Should remove the workdir of its own run and leave a concurrent run's alone" {
	seed_active_version "1.0.0"
	export WORKDIR_BASE="$BATS_TEST_TMPDIR/base"
	local run_a="$WORKDIR_BASE/scope-7-aaaaaa" run_b="$WORKDIR_BASE/scope-7-bbbbbb"
	mkdir -p "$run_a" "$run_b"
	echo '{}' > "$run_b/foundry.json"

	WORKDIR="$run_a" run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "0"
	[ ! -d "$run_a" ]
	assert_file_exists "$run_b/foundry.json"
}

@test "Should remove its workdir when Foundry cannot be asked too" {
	export WORKDIR_BASE="$BATS_TEST_TMPDIR/base" MFCLI_MOCK_AUTH_FAIL=1
	mkdir -p "$WORKDIR_BASE/scope-7-cccccc"

	WORKDIR="$WORKDIR_BASE/scope-7-cccccc" run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "1"
	[ ! -d "$WORKDIR_BASE/scope-7-cccccc" ]
}

@test "Should never remove a deployment workdir" {
	seed_active_version "1.0.0"
	export WORKDIR_BASE="$BATS_TEST_TMPDIR/base"
	mkdir -p "$WORKDIR_BASE/77"

	WORKDIR="$WORKDIR_BASE/77" run bash -c 'exec 2>/dev/null; source "$0"' "$LIST"

	assert_equal "$status" "0"
	assert_directory_exists "$WORKDIR_BASE/77"
}
