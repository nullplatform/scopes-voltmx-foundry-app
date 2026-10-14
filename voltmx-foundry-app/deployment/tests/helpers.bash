# =============================================================================
# Shared helpers for the voltmx-foundry-app BATS tests, on top of
# testing/assertions.sh (bats-assert is not a dependency of the test runner,
# so the line assertions live here; they work on the `lines` array of `run`).
# =============================================================================

# Assert that `run` produced exactly this line (whole line, whitespace included).
assert_line() {
	local expected="$1" line
	for line in "${lines[@]}"; do
		if [ "$line" = "$expected" ]; then
			return 0
		fi
	done
	echo "Expected line not found: '$expected'"
	echo "Output was:"
	echo "$output"
	return 1
}

# Assert that `run` did not produce this exact line.
refute_line() {
	local unexpected="$1" line
	for line in "${lines[@]}"; do
		if [ "$line" = "$unexpected" ]; then
			echo "Unexpected line found: '$unexpected'"
			echo "Output was:"
			echo "$output"
			return 1
		fi
	done
}

# Assert that the np mock was (or was not) invoked with a command containing the text.
assert_np_called() {
	local needle="$1"
	if ! grep -qF -- "$needle" "$NP_MOCK_CALLS_LOG" 2>/dev/null; then
		echo "Expected an np call containing: '$needle'"
		echo "np calls were:"
		cat "$NP_MOCK_CALLS_LOG" 2>/dev/null || echo "(none)"
		return 1
	fi
}

refute_np_called() {
	local needle="$1"
	if grep -qF -- "$needle" "$NP_MOCK_CALLS_LOG" 2>/dev/null; then
		echo "Did not expect an np call containing: '$needle'"
		echo "np calls were:"
		cat "$NP_MOCK_CALLS_LOG"
		return 1
	fi
}

# Assert that a mock command log (aws) holds exactly this line.
assert_mock_call() {
	local log="$1" expected="$2"
	if ! grep -qxF -- "$expected" "$log" 2>/dev/null; then
		echo "Expected call not found: '$expected'"
		echo "Calls were:"
		cat "$log" 2>/dev/null || echo "(none)"
		return 1
	fi
}

# Assert that `run`'s output does not carry the text anywhere.
refute_output_contains() {
	local secret="$1"
	if [[ "$output" == *"$secret"* ]]; then
		echo "Output leaks '$secret':"
		echo "$output"
		return 1
	fi
}

# Assert that a file does not carry the text anywhere.
refute_file_contains() {
	local file="$1" secret="$2"
	if [ -f "$file" ] && grep -qF -- "$secret" "$file"; then
		echo "$file leaks '$secret':"
		cat "$file"
		return 1
	fi
}

# =============================================================================
# Foundry tests: the contract build_context, fetch_asset and read_credentials
# export, the real mfcli mock (tools/mfcli-mock/mfcli) with its state in the test
# tmpdir, and the np/aws mocks on PATH. Call from setup() with the deployment
# directory.
# =============================================================================
setup_foundry_test() {
	DEPLOYMENT_DIR="$1"
	SCOPE_DIR="$(cd "$DEPLOYMENT_DIR/.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	RESOURCES_DIR="$DEPLOYMENT_DIR/tests/resources"
	MOCKS_DIR="$RESOURCES_DIR/mocks"
	SCRIPTS_DIR="$DEPLOYMENT_DIR/scripts"

	export SERVICE_PATH="$SCOPE_DIR"
	export PATH="$MOCKS_DIR:$PATH"

	export CONTEXT
	CONTEXT=$(cat "$RESOURCES_DIR/context_initial.json")

	# The mock that follows the documented mfcli contract (see tools/mfcli-mock/README.md).
	export MFCLI_CMD="${MFCLI_MOCK_BIN:-$SERVICE_PATH/tools/mfcli-mock/mfcli}"
	export MFCLI_MOCK_STATE="$BATS_TEST_TMPDIR/mfcli-state"
	export MFCLI_MOCK_LOG="$BATS_TEST_TMPDIR/mfcli.log"
	export MFCLI_USER="np-foundry"
	export MFCLI_PASSWORD="Pa55-w0rd-x9"
	export MFCLI_MOCK_VALID_PASSWORD="$MFCLI_PASSWORD"
	unset MFCLI_MOCK_AUTH_FAIL MFCLI_MOCK_PUBLISH_HANG MFCLI_MOCK_PUBLISH_FAIL MFCLI_MOCK_PUBLISH_POLLS

	export FOUNDRY_APP="PetStore"
	export APP_VERSION="1.0.0"
	export ENVIRONMENT_NAME="uat"
	export MFCLI_AUTH_ARGS="-t 100000001"
	export CREDENTIALS_SECRET="voltmx/mobile/foundry-uat"
	export SECRETS_PREFIX="voltmx/mobile/"
	export PROFILE_VARS='{"CORE_BASE_URL":"https://core.uat.petstore.io","IDP_CLIENT_SECRET":"idp-s3cr3t-value"}'
	export DEPLOYMENT_ID="77"
	export SCOPE_ID="7"
	export PREVIOUS_DEPLOYMENT_ID="70"
	export PREVIOUS_RELEASE_SEMVER="0.9.0"
	export ASSETS_BUCKET="assets-aws-mobile"
	export ASSETS_REGION="us-east-1"
	export ASSET_URL="s3://assets-aws-mobile/foundry/442353700/30/PetStore.zip"
	export PUBLISH_TIMEOUT_SECONDS="5"
	export PUBLISH_POLL_SECONDS="0"
	export WORKDIR="$BATS_TEST_TMPDIR/work/77"
	mkdir -p "$WORKDIR"
	export FOUNDRY_ZIP="$WORKDIR/foundry.zip"
	make_foundry_zip "$FOUNDRY_ZIP" "PetStore" "1.0.0"

	export NP_MOCK_CALLS_LOG="$BATS_TEST_TMPDIR/np_calls.log"
	export NP_MOCK_DEPLOYMENT_PATCH="$MOCKS_DIR/deployment_patch.json"
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list.json"
	export NP_MOCK_RELEASE_READ="$MOCKS_DIR/release_read.json"
	export AWS_MOCK_CALLS_LOG="$BATS_TEST_TMPDIR/aws_calls.log"
	export AWS_MOCK_SECRETS_DIR="$BATS_TEST_TMPDIR/secrets"
	mkdir -p "$AWS_MOCK_SECRETS_DIR"
	unset AWS_MOCK_S3_FAIL AWS_MOCK_S3_OBJECT
}

# A Foundry app export: a zip with Apps/<app>/Meta.json.
make_foundry_zip() {
	local target="$1" app="${2:-PetStore}" version="${3:-1.0.0}" dir
	dir=$(mktemp -d)
	mkdir -p "$dir/Apps/$app"
	jq -n --arg app "$app" --arg v "$version" '{name: $app, version: $v}' > "$dir/Apps/$app/Meta.json"
	(cd "$dir" && zip -qr "$target" Apps)
	rm -rf "$dir"
}

# Register a secret the aws mock answers for `secretsmanager get-secret-value`.
write_mock_secret() {
	local secret_id="$1" value="$2"
	printf '%s\n' "$value" > "$AWS_MOCK_SECRETS_DIR/$(echo "$secret_id" | tr '/' '_')"
}

# Leave <version> imported and active in the mock environment, as a previous
# deployment would, then clear the mock log so tests only see their own calls.
seed_active_version() {
	local version="$1" zip="$BATS_TEST_TMPDIR/seed-$1.zip"
	make_foundry_zip "$zip" "$FOUNDRY_APP" "$version"
	"$MFCLI_CMD" Import -u "$MFCLI_USER" -p "$MFCLI_PASSWORD" -t 100000001 -f "$zip" -a "$FOUNDRY_APP" -v "$version" >/dev/null
	"$MFCLI_CMD" Publish -u "$MFCLI_USER" -p "$MFCLI_PASSWORD" -t 100000001 -e "$ENVIRONMENT_NAME" -a "$FOUNDRY_APP" -v "$version" >/dev/null
	: > "$MFCLI_MOCK_LOG"
}

# The publish state of the app as the mock reports it ({status, version, active_version}).
mock_publish_status() {
	MFCLI_MOCK_LOG= "$MFCLI_CMD" publish-status -u "$MFCLI_USER" -p "$MFCLI_PASSWORD" -t 100000001 \
		-e "$ENVIRONMENT_NAME" -a "$FOUNDRY_APP" 2>/dev/null
}

# Assert the exact sequence of mfcli invocations recorded by the mock.
assert_mfcli_calls() {
	local expected="$1" actual
	actual=$(cat "$MFCLI_MOCK_LOG" 2>/dev/null || true)
	if [ "$actual" != "$expected" ]; then
		echo "mfcli calls differ"
		echo "--- expected"
		echo "$expected"
		echo "--- actual"
		echo "$actual"
		return 1
	fi
}
