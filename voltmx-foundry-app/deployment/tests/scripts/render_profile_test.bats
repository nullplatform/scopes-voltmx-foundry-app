#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/render_profile: renders the service
# profile template with PROFILE_VARS into $WORKDIR/profile.json (mode 600)
# without printing any value.
#
# Run: bats voltmx-foundry-app/deployment/tests/scripts/render_profile_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_foundry_test "$DEPLOYMENT_DIR"
	SCRIPT="$SCRIPTS_DIR/render_profile"
	unset PROFILE_TEMPLATE
}

@test "Should render the default template with the app identity and every parameter" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📝 Rendering the service profile for PetStore in environment uat..."
	assert_line "   ✅ Service profile rendered to $WORKDIR/profile.json (variables: CORE_BASE_URL, IDP_CLIENT_SECRET)"
	refute_output_contains "idp-s3cr3t-value"
	refute_output_contains "https://core.uat.petstore.io"
	assert_json_equal "$(cat "$WORKDIR/profile.json")" '{
		"profile_format": "1.0",
		"app": "PetStore",
		"environment": "uat",
		"version": "1.0.0",
		"app_properties": {
			"CORE_BASE_URL": "https://core.uat.petstore.io",
			"IDP_CLIENT_SECRET": "idp-s3cr3t-value"
		}
	}' "profile"
	assert_equal "$(stat -f '%Lp' "$WORKDIR/profile.json" 2>/dev/null || stat -c '%a' "$WORKDIR/profile.json")" "600"
}

@test "Should substitute placeholders inside strings and escape values as JSON" {
	cat > "$BATS_TEST_TMPDIR/profile.json.tpl" <<'TPL'
{
  "services": [{ "name": "core", "base_url": "${CORE_BASE_URL}/v1" }],
  "identity": { "client_secret": "${IDP_CLIENT_SECRET}", "app": "${FOUNDRY_APP}" }
}
TPL
	export PROFILE_TEMPLATE="$BATS_TEST_TMPDIR/profile.json.tpl"
	export PROFILE_VARS='{"CORE_BASE_URL":"https://core.uat.petstore.io","IDP_CLIENT_SECRET":"quote\"and\\backslash"}'

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_equal "$(jq -r '.services[0].base_url' "$WORKDIR/profile.json")" "https://core.uat.petstore.io/v1"
	assert_equal "$(jq -r '.identity.client_secret' "$WORKDIR/profile.json")" 'quote"and\backslash'
	assert_equal "$(jq -r '.identity.app' "$WORKDIR/profile.json")" "PetStore"
}

@test "Should fail naming the undefined variables without printing any value" {
	cat > "$BATS_TEST_TMPDIR/profile.json.tpl" <<'TPL'
{ "a": "${CORE_BASE_URL}", "b": "${MISSING_ONE}", "c": ["${MISSING_TWO}"] }
TPL
	export PROFILE_TEMPLATE="$BATS_TEST_TMPDIR/profile.json.tpl"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The service profile template uses variables that are not defined: MISSING_ONE, MISSING_TWO"
	assert_line "  💡 Possible causes:"
	assert_line "    • The application has no parameter with those names for this scope"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create the parameters in nullplatform (mark secrets as secret) or remove them from $BATS_TEST_TMPDIR/profile.json.tpl"
	refute_output_contains "https://core.uat.petstore.io"
	assert_file_not_exists "$WORKDIR/profile.json"
}

@test "Should remove a profile left by an earlier run when rendering fails" {
	echo '{"stale":"idp-s3cr3t-value"}' > "$WORKDIR/profile.json"
	export PROFILE_VARS='not json'

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_file_not_exists "$WORKDIR/profile.json"
}

@test "Should fail when the template is not valid JSON" {
	echo '{ "a": ' > "$BATS_TEST_TMPDIR/profile.json.tpl"
	export PROFILE_TEMPLATE="$BATS_TEST_TMPDIR/profile.json.tpl"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The service profile template $BATS_TEST_TMPDIR/profile.json.tpl is missing or is not valid JSON"
}

@test "Should fail when PROFILE_VARS is not a JSON object" {
	export PROFILE_VARS='not json'

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ PROFILE_VARS is not a JSON object"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the deployment workflow from the start so build_context collects the parameters"
}
