#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/build_context
#
# The script reads CONTEXT (the deployment context JSON) and exports the
# variables every later step relies on. The np CLI is replaced by
# tests/resources/mocks/np, which answers with the JSON files named by
# NP_MOCK_* variables (see the mock header).
#
# Run: bats voltmx-foundry-app/deployment/tests/scripts/build_context_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	SCOPE_DIR="$(cd "$DEPLOYMENT_DIR/.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	RESOURCES_DIR="$DEPLOYMENT_DIR/tests/resources"
	MOCKS_DIR="$RESOURCES_DIR/mocks"
	SCRIPT="$DEPLOYMENT_DIR/scripts/build_context"

	source "$PROJECT_ROOT/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"

	export SERVICE_PATH="$SCOPE_DIR"
	export CONTEXT
	CONTEXT=$(cat "$RESOURCES_DIR/context_initial.json")
	export WORKDIR="$BATS_TEST_TMPDIR/work"
	unset WORKDIR_BASE

	export PATH="$MOCKS_DIR:$PATH"
	export NP_MOCK_CALLS_LOG="$BATS_TEST_TMPDIR/np_calls.log"
	export NP_MOCK_SPECIFICATION_LIST="$MOCKS_DIR/scope_configuration/specification_list.json"
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list.json"
	export NP_MOCK_ASSET_LIST="$MOCKS_DIR/asset_list.json"
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list.json"
	export NP_MOCK_RELEASE_READ="$MOCKS_DIR/release_read.json"

	unset ENVIRONMENT_NAME FOUNDRY_ACCOUNT_ID FOUNDRY_IDENTITY_URL FOUNDRY_CONSOLE_URL CREDENTIALS_SECRET ASSETS_BUCKET ASSETS_REGION
	unset FOUNDRY_ALLOWED_APPS FOUNDRY_APP_NAME_PREFIX SECRETS_PREFIX BUILD_CONTEXT_MODE SCOPE_ID
}

teardown() {
	if [ -n "${EXTRA_CLEANUP_DIR:-}" ]; then
		rm -rf "$EXTRA_CLEANUP_DIR"
	fi
}

run_build_context() {
	source "$SCRIPT"
}

with_context() {
	CONTEXT=$(echo "$CONTEXT" | jq "$@")
	export CONTEXT
}

# Scope configuration taken from the context (the platform lookup finds nothing).
use_context_configuration() {
	export NP_MOCK_PROVIDER_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"
}

# =============================================================================
# Happy path
# =============================================================================
@test "Should export the full Foundry deployment context" {
	run_build_context

	assert_equal "$FOUNDRY_APP" "PetStore"
	assert_equal "$APP_VERSION" "1.0.0"
	assert_equal "$ASSET_TYPE" "bundle"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/foundry/442353700/30/PetStore.zip"
	assert_equal "$ENVIRONMENT_NAME" "uat"
	assert_equal "$MFCLI_AUTH_ARGS" "-t 100000001"
	assert_equal "$CREDENTIALS_SECRET" "voltmx/mobile/foundry-uat"
	assert_equal "$SECRETS_PREFIX" "voltmx/mobile/"
	assert_equal "$ASSETS_BUCKET" "assets-aws-mobile"
	assert_equal "$ASSETS_REGION" "us-east-1"
	assert_json_equal "$PROFILE_VARS" '{"CORE_BASE_URL":"https://core.uat.petstore.io","IDP_CLIENT_SECRET":"idp-s3cr3t-value"}' "PROFILE_VARS"
	assert_equal "$DEPLOYMENT_ID" "77"
	assert_equal "$SCOPE_ID" "7"
	assert_equal "$DIMENSION" "uat"
	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "70"
	assert_equal "$PREVIOUS_RELEASE_SEMVER" "0.9.0"
	assert_equal "$WORKDIR_BASE" "$BATS_TEST_TMPDIR/work"
	assert_equal "$WORKDIR" "$BATS_TEST_TMPDIR/work/77"
	assert_directory_exists "$WORKDIR"
	assert_equal "$(echo "$CONTEXT" | jq -r '.providers["scope-configurations"].marker')" "application-level"

	assert_np_called "np provider list --nrn organization=1:account=2:namespace=3:application=442353700:scope=7 --categories scope-configurations --show-ascendants --dimensions environment:uat --format json"
	assert_np_called "np deployment list --scope-id 7 --all --max-pages 5 --format json"
	assert_np_called "np release read --id 60 --format json"
	refute_np_called "asset list"
}

@test "Should print a readable summary without parameter values or the scope configuration" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Building deployment context..."
	assert_line "   📋 Scope: mobile/petstore-foundry/uat (id 7) | Dimension: uat | Deployment: 77 | Release: 1.0.0"
	assert_line "   📋 Foundry app: PetStore | Version: 1.0.0"
	assert_line "   📋 Scope configuration: resolved from the platform (nrn organization=1:account=2:namespace=3:application=442353700)"
	assert_line "   ✅ environment_name=uat"
	assert_line "   ✅ auth=cloud (account 100000001)"
	assert_line "   ✅ foundry_app=PetStore is allowed for this scope (allowed_apps: PetStore)"
	assert_line "   ✅ credentials_secret=voltmx/mobile/foundry-uat (secrets prefix voltmx/mobile/)"
	assert_line "   ✅ assets_bucket=assets-aws-mobile (region us-east-1)"
	assert_line "   ✅ foundry asset -> s3://assets-aws-mobile/foundry/442353700/30/PetStore.zip (type bundle, build 30)"
	assert_line "   📋 Profile variables: CORE_BASE_URL, IDP_CLIENT_SECRET"
	assert_line "   📋 Previous deployment: 70 (release 0.9.0)"
	assert_line "   📋 Workdir: $BATS_TEST_TMPDIR/work/77"
	assert_line "✨ Build context ready"
	refute_output_contains "idp-s3cr3t-value"
	refute_output_contains "https://core.uat.petstore.io"
	refute_output_contains "marker"
}

@test "Should keep the same workdir when sourced twice in the same session" {
	run_build_context
	run_build_context

	assert_equal "$WORKDIR_BASE" "$BATS_TEST_TMPDIR/work"
	assert_equal "$WORKDIR" "$BATS_TEST_TMPDIR/work/77"
}

@test "Should default the workdir to /tmp/voltmx-foundry-app/<deployment id>" {
	unset WORKDIR WORKDIR_BASE
	EXTRA_CLEANUP_DIR="/tmp/voltmx-foundry-app/77"

	run_build_context

	assert_equal "$WORKDIR" "/tmp/voltmx-foundry-app/77"
	assert_directory_exists "$WORKDIR"
}

@test "Should build on-premises auth args from the identity and console URLs" {
	use_context_configuration
	with_context '.providers["scope-configurations"].auth = {"identity_url": "https://identity.foundry.example.com", "console_url": "https://console.foundry.example.com:8443/mfconsole"}'

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   ✅ auth=on-premises (identity https://identity.foundry.example.com, console https://console.foundry.example.com:8443/mfconsole)"

	run_build_context
	assert_equal "$MFCLI_AUTH_ARGS" "-au https://identity.foundry.example.com -cu https://console.foundry.example.com:8443/mfconsole"
}

# =============================================================================
# Asset
# =============================================================================
@test "Should look the foundry asset up in the build when the context carries another one" {
	with_context '.asset = {"id": 23, "build_id": 30, "name": "web", "type": "bundle", "url": "s3://assets-aws-mobile/web/442353700/30/site.zip"}'

	run_build_context

	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/foundry/442353700/30/PetStore.zip"
	assert_np_called "np asset list --build-id 30 --format json"
}

@test "Should filter the listed assets by the type of the asset in the context" {
	with_context '.asset.name = "web" | .asset.type = "docker-image"'

	run_build_context

	assert_equal "$ASSET_TYPE" "docker-image"
	assert_equal "$ASSET_URL" "s3://assets-aws-mobile/foundry/442353700/30/wrong-type.zip"
}

@test "Should fail with the full troubleshooting block when the build has no foundry asset" {
	with_context '.asset.name = "web"'
	export NP_MOCK_ASSET_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ No asset named 'foundry' of type 'bundle' in release 1.0.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI did not export the Foundry app or registered it with another name"
	assert_line "  🔧 How to fix:"
	assert_line "    • Make the CI register the exported app zip as an asset named 'foundry' (type bundle) for this build"
}

@test "Should warn and still fail when the asset listing itself fails" {
	with_context '.asset.name = "web"'
	unset NP_MOCK_ASSET_LIST

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ⚠️ Could not list the assets of build 30 (np asset list failed)"
	assert_line "   ❌ No asset named 'foundry' of type 'bundle' in release 1.0.0"
}

@test "Should fail before listing assets when the release has no build id" {
	with_context 'del(.asset) | del(.release.build_id)'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The release has no build id"
	assert_line "  💡 Possible causes:"
	assert_line "    • The context carries no asset and the release is not linked to a build"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create the release from a build whose CI registered the Foundry app as an asset named 'foundry'"
	refute_np_called "asset list"
}

@test "Should reject an asset outside the configured bucket" {
	with_context '.asset.url = "s3://someone-else/foundry/PetStore.zip"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Asset URL is outside the configured assets bucket 'assets-aws-mobile': s3://someone-else/foundry/PetStore.zip"
	refute_np_called "deployment list"
}

# =============================================================================
# Developer capabilities and release
# =============================================================================
@test "Should reject a Foundry app name with path characters or spaces" {
	local name
	for name in "../PetStore" "Pet Store" "-pet" "Pet..Store"; do
		CONTEXT=$(jq --arg n "$name" '.scope.capabilities.foundry_app_name = $n' "$RESOURCES_DIR/context_initial.json")
		export CONTEXT

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Invalid Foundry app name '$name': use letters, digits, '.', '_' or '-', starting with a letter or digit"
		assert_line "  💡 Possible causes:"
		assert_line "    • The scope was created with a foundry_app_name that is not a Foundry app name"
		assert_line "  🔧 How to fix:"
		assert_line "    • Recreate the scope with the app name exactly as it appears in the Foundry console (it is only editable on create)"
	done
	refute_np_called "provider list"
}

@test "Should fail when the scope has no Foundry app name" {
	with_context 'del(.scope.capabilities.foundry_app_name)'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid Foundry app name '': use letters, digits, '.', '_' or '-', starting with a letter or digit"
}

@test "Should not offer set_as_default_version until set-appversion is validated" {
	with_context '.scope.capabilities.set_as_default_version = false'

	run_build_context

	assert_equal "${SET_AS_DEFAULT_VERSION:-unset}" "unset"
}

@test "Should reject a release semver that is not a version" {
	with_context '.release.semver = "1.0.0; rm -rf /"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid release version '1.0.0; rm -rf /': must be a semantic version such as 1.2.3"
	assert_line "  💡 Possible causes:"
	assert_line "    • The release was created with a version Foundry cannot use as an app version"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create the release with a semantic version (e.g. 1.2.3 or 1.2.3-rc.1)"
}

# =============================================================================
# Scope configuration: platform lookup > context > environment variables
# =============================================================================
@test "Should fall back to the configuration of the context when the platform lookup finds nothing" {
	use_context_configuration

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   📋 Scope configuration: taken from the context"

	run_build_context
	assert_equal "$(echo "$SCOPE_CONFIGURATION" | jq -r .marker)" "from-context"
}

@test "Should warn and trust the context when the voltmx-foundry-app specification does not exist" {
	export NP_MOCK_SPECIFICATION_LIST="$MOCKS_DIR/scope_configuration/provider_list_empty.json"

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not resolve the Volt MX Foundry app scope configuration from the platform; trusting the context, which may belong to another scope type"
	assert_line "   📋 Scope configuration: taken from the context"
	refute_np_called "np provider list"
}

@test "Should treat a context configuration of another scope type as missing" {
	unset NP_MOCK_PROVIDER_LIST
	with_context '.providers["scope-configurations"] = {"signing_layer": "prebuilt", "assets": {"bucket": "assets-aws-mobile"}}'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   📋 Scope configuration: taken from environment variables"
	assert_line "   ❌ Scope configuration is incomplete: missing environment_name, auth, credentials_secret, assets.bucket"
	assert_line "  💡 Possible causes:"
	assert_line "    • No 'Volt MX Foundry app' scope configuration is attached to the account, namespace or dimension of this scope"
	assert_line "    • The scope configuration does not set those fields"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create a 'Volt MX Foundry app' scope configuration (category scope-configurations) for the account, namespace or dimension of this scope"
	assert_line "    • Or set the ENVIRONMENT_NAME, FOUNDRY_ACCOUNT_ID (or FOUNDRY_IDENTITY_URL and FOUNDRY_CONSOLE_URL), CREDENTIALS_SECRET and ASSETS_BUCKET environment variables"
}

@test "Should fall back to environment variables when there is no scope configuration at all" {
	use_context_configuration
	with_context 'del(.providers["scope-configurations"])'
	export ENVIRONMENT_NAME="dev"
	export FOUNDRY_IDENTITY_URL="https://identity.example.com"
	export FOUNDRY_CONSOLE_URL="https://console.example.com"
	export CREDENTIALS_SECRET="voltmx/mobile/foundry-dev"
	export ASSETS_BUCKET="assets-aws-mobile"
	export FOUNDRY_ALLOWED_APPS="PetStore,Inventory*"

	run_build_context

	assert_equal "$ENVIRONMENT_NAME" "dev"
	assert_equal "$MFCLI_AUTH_ARGS" "-au https://identity.example.com -cu https://console.example.com"
	assert_equal "$CREDENTIALS_SECRET" "voltmx/mobile/foundry-dev"
	assert_json_equal "$SCOPE_CONFIGURATION" '{
		"environment_name": "dev",
		"auth": {"identity_url": "https://identity.example.com", "console_url": "https://console.example.com"},
		"credentials_secret": "voltmx/mobile/foundry-dev",
		"assets": {"bucket": "assets-aws-mobile", "region": "us-east-1"},
		"allowed_apps": ["PetStore", "Inventory*"]
	}' "SCOPE_CONFIGURATION"
	assert_json_equal "$(echo "$CONTEXT" | jq -c '.providers["scope-configurations"]')" "$SCOPE_CONFIGURATION" "context configuration"
}

@test "Should reject an environment name with path characters" {
	use_context_configuration
	with_context '.providers["scope-configurations"].environment_name = "../uat"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid environment_name '../uat': use letters, digits, '.', '_' or '-', starting with a letter or digit"
	assert_line "  💡 Possible causes:"
	assert_line "    • environment_name of the 'Volt MX Foundry app' scope configuration (or ENVIRONMENT_NAME) is not a Foundry environment name"
	assert_line "  🔧 How to fix:"
	assert_line "    • Set environment_name to the environment name exactly as it appears in the Foundry console"
}

@test "Should reject a cloud account id that is not 9 digits" {
	use_context_configuration
	with_context '.providers["scope-configurations"].auth = {"account_id": "1234 -p x"}'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid auth.account_id '1234 -p x': must be the 9-digit Volt MX cloud account id"
	assert_line "  💡 Possible causes:"
	assert_line "    • The value was copied with extra characters, or it is not the cloud account id"
	assert_line "  🔧 How to fix:"
	assert_line "    • Copy the account id from the Volt MX cloud portal (9 digits)"
}

@test "Should reject on-premises URLs that are not https or carry spaces" {
	use_context_configuration
	local url
	for url in "http://identity.example.com" "https://identity.example.com -t 1" "https://"; do
		CONTEXT=$(jq --arg u "$url" '.providers["scope-configurations"].auth = {"identity_url": $u, "console_url": "https://console.example.com"}' "$RESOURCES_DIR/context_initial.json")
		export CONTEXT

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Invalid auth.identity_url '$url': must be an https URL without spaces"
		assert_line "  💡 Possible causes:"
		assert_line "    • The on-premises URL of the 'Volt MX Foundry app' scope configuration is incomplete or not https"
		assert_line "  🔧 How to fix:"
		assert_line "    • Set auth.identity_url to the https URL of the Foundry server (e.g. https://foundry.example.com)"
	done
}

@test "Should reject an auth with both the cloud account and the on-premises URLs, or with neither" {
	use_context_configuration
	with_context '.providers["scope-configurations"].auth = {"account_id": "100000001", "identity_url": "https://identity.example.com", "console_url": "https://console.example.com"}'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ auth must set either account_id (cloud) or identity_url and console_url (on-premises), not both"
	assert_line "  💡 Possible causes:"
	assert_line "    • The 'Volt MX Foundry app' scope configuration mixes the cloud and the on-premises settings"
	assert_line "  🔧 How to fix:"
	assert_line "    • Keep account_id for Volt MX cloud, or identity_url and console_url for an on-premises Foundry"

	with_context '.providers["scope-configurations"].auth = {"identity_url": "https://identity.example.com"}'
	run source "$SCRIPT"
	assert_equal "$status" "1"
	assert_line "   ❌ Scope configuration is incomplete: missing auth"
}

@test "Should reject a credentials secret outside the voltmx/ namespace" {
	use_context_configuration
	local secret
	for secret in "mobile/firebase-sa" "voltmx/../mobile/firebase-sa" "arn:aws:secretsmanager:us-east-1:1:secret:voltmx/x"; do
		CONTEXT=$(jq --arg s "$secret" '.providers["scope-configurations"].credentials_secret = $s' "$RESOURCES_DIR/context_initial.json")
		export CONTEXT

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Secret name '$secret' is outside the voltmx/ namespace (credentials_secret)"
		assert_line "  💡 Possible causes:"
		assert_line "    • The 'Volt MX Foundry app' scope configuration names a secret this scope is not allowed to read"
		assert_line "  🔧 How to fix:"
		assert_line "    • Store the secret under the voltmx/ prefix (e.g. voltmx/mobile/foundry-uat) and set credentials_secret to that name"
	done
}

@test "Should reject an assets bucket with path characters" {
	use_context_configuration
	with_context '.providers["scope-configurations"].assets.bucket = "../assets bucket"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid assets bucket '../assets bucket': only lowercase letters, digits, dots and dashes are allowed"
}

# =============================================================================
# Profile variables
# =============================================================================
@test "Should export only environment parameters with valid variable names, by name" {
	with_context '.parameters.results += [
		{"name": "bad name", "variable": "bad name", "type": "environment", "values": [{"value": "x"}]},
		{"name": "CERT", "variable": "CERT", "type": "file", "values": [{"value": "pem"}]},
		{"name": "EMPTY", "variable": "EMPTY", "type": "environment", "values": []}
	]'

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   ⚠️ Skipping parameter 'bad name': not a valid variable name"
	assert_line "   📋 Profile variables: CORE_BASE_URL, IDP_CLIENT_SECRET"

	run_build_context
	assert_json_equal "$PROFILE_VARS" '{"CORE_BASE_URL":"https://core.uat.petstore.io","IDP_CLIENT_SECRET":"idp-s3cr3t-value"}' "PROFILE_VARS"
}

@test "Should export an empty profile when the application has no parameters" {
	with_context 'del(.parameters)'

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   📋 Profile variables: none"

	run_build_context
	assert_equal "$PROFILE_VARS" "{}"
}

# =============================================================================
# Previous deployment
# =============================================================================
@test "Should prefer the finalized deployment still active in the scope" {
	run_build_context

	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "70"
	assert_equal "$PREVIOUS_RELEASE_SEMVER" "0.9.0"
}

@test "Should pick the most recent finalized deployment when none is active in the scope" {
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list_no_active.json"

	run_build_context

	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "69"
	assert_np_called "np release read --id 58"
}

@test "Should leave the previous deployment empty when only failed or rolled back deployments exist" {
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list_no_previous.json"

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   📋 Previous deployment: none"

	run_build_context
	assert_empty "$PREVIOUS_DEPLOYMENT_ID" "PREVIOUS_DEPLOYMENT_ID"
	assert_empty "$PREVIOUS_RELEASE_SEMVER" "PREVIOUS_RELEASE_SEMVER"
	refute_np_called "release read"
}

@test "Should not fail when the deployment listing fails" {
	unset NP_MOCK_DEPLOYMENT_LIST

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not list the deployments of scope 7; continuing without a previous deployment"
	assert_line "   📋 Previous deployment: none"
}

@test "Should drop a previous release semver that is not a version" {
	jq '.semver = "0.9.0 -v 1"' "$MOCKS_DIR/release_read.json" > "$BATS_TEST_TMPDIR/release_read.json"
	export NP_MOCK_RELEASE_READ="$BATS_TEST_TMPDIR/release_read.json"

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   ⚠️ Ignoring the release of previous deployment 70: '0.9.0 -v 1' is not a semantic version"

	run_build_context
	assert_equal "$PREVIOUS_DEPLOYMENT_ID" "70"
	assert_empty "$PREVIOUS_RELEASE_SEMVER" "PREVIOUS_RELEASE_SEMVER"
}

# =============================================================================
# Context hardening
# =============================================================================
@test "Should fail when CONTEXT is missing or not JSON" {
	unset CONTEXT
	run source "$SCRIPT"
	assert_equal "$status" "1"
	assert_line "   ❌ CONTEXT is not set or is not valid JSON"

	export CONTEXT="not json"
	run source "$SCRIPT"
	assert_equal "$status" "1"
	assert_line "   ❌ CONTEXT is not set or is not valid JSON"
}

@test "Should reject deployment and scope ids that are not integers before calling np" {
	with_context '.deployment.id = "../77"'
	run source "$SCRIPT"
	assert_equal "$status" "1"
	assert_line "   ❌ Invalid deployment id '../77': must be an integer"

	CONTEXT=$(jq '.scope.id = "7 8"' "$RESOURCES_DIR/context_initial.json")
	run source "$SCRIPT"
	assert_equal "$status" "1"
	assert_line "   ❌ Invalid scope id '7 8': must be an integer"
	refute_np_called "provider"
}

@test "Should reject a dimension with path characters" {
	with_context '.scope.dimensions.environment = "../prod"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid dimension '../prod': only lowercase letters, digits and dashes are allowed"
}

# =============================================================================
# Multi-tenant Foundry environments: the app and the credentials of a scope
# are bound to what DevOps allowed for its namespace or dimension.
# =============================================================================
@test "Should allow the app when it matches allowed_apps exactly or by a Prefix* glob" {
	use_context_configuration
	local patterns
	for patterns in '["PetStore"]' '["Inventory", "Pet*"]' '["PetStore*"]'; do
		CONTEXT=$(jq --argjson p "$patterns" '.providers["scope-configurations"].allowed_apps = $p' "$RESOURCES_DIR/context_initial.json")
		export CONTEXT

		run source "$SCRIPT"

		assert_equal "$status" "0"
		assert_line "   ✅ foundry_app=PetStore is allowed for this scope (allowed_apps: $(echo "$patterns" | jq -r 'join(", ")'))"
	done
}

@test "Should allow the app when it starts with app_name_prefix" {
	use_context_configuration
	with_context '.providers["scope-configurations"] |= (del(.allowed_apps) | .app_name_prefix = "Pet")'

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ foundry_app=PetStore is allowed for this scope (app_name_prefix: Pet)"
}

@test "Should refuse the app of another team before touching assets or deployments" {
	use_context_configuration
	with_context '.providers["scope-configurations"].allowed_apps = ["Payments", "Pay*"]'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Foundry app 'PetStore' is not allowed for this scope: it does not match allowed_apps (Payments, Pay*)"
	assert_line "  💡 Possible causes:"
	assert_line "    • The app belongs to another team: Foundry environments are shared by the apps of many namespaces"
	assert_line "    • The 'Volt MX Foundry app' scope configuration of this namespace or dimension does not list the app yet"
	assert_line "  🔧 How to fix:"
	assert_line "    • Create the scope for an app of your team, or ask DevOps to add 'PetStore' to allowed_apps (or app_name_prefix) of the scope configuration"
	refute_np_called "asset list"
	refute_np_called "deployment list"
}

@test "Should refuse an app outside app_name_prefix even when allowed_apps matches (both must hold)" {
	use_context_configuration
	with_context '.providers["scope-configurations"].allowed_apps = ["Pet*"] | .providers["scope-configurations"].app_name_prefix = "Shop"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Foundry app 'PetStore' is not allowed for this scope: it does not start with app_name_prefix 'Shop'"
}

@test "Should fail closed when neither allowed_apps nor app_name_prefix is configured" {
	use_context_configuration
	local configuration
	for configuration in 'del(.allowed_apps)' '.allowed_apps = []' '.allowed_apps = [] | .app_name_prefix = ""'; do
		CONTEXT=$(jq ".providers[\"scope-configurations\"] |= ($configuration)" "$RESOURCES_DIR/context_initial.json")
		export CONTEXT

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Configure allowed_apps or app_name_prefix in the Volt MX Foundry app scope configuration"
		assert_line "  💡 Possible causes:"
		assert_line "    • The scope configuration does not say which Foundry apps the scopes of this namespace or dimension may deploy"
		assert_line "  🔧 How to fix:"
		assert_line "    • Set allowed_apps (app names, or Prefix* globs) or app_name_prefix in the 'Volt MX Foundry app' scope configuration"
	done
	refute_np_called "asset list"
}

@test "Should reject allowed_apps entries that are not an app name or a Prefix* glob" {
	use_context_configuration
	local entry
	for entry in '*' 'Pet*Store' '../Pet' 'Pet?'; do
		CONTEXT=$(jq --arg e "$entry" '.providers["scope-configurations"].allowed_apps = ["PetStore", $e]' "$RESOURCES_DIR/context_initial.json")
		export CONTEXT

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Invalid allowed_apps entry '$entry': use an app name or a prefix followed by * (e.g. Payments*)"
	done
}

@test "Should require the credentials secret to live under voltmx/<namespace>/" {
	use_context_configuration
	with_context '.providers["scope-configurations"].credentials_secret = "voltmx/payments/foundry-uat"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Secret 'voltmx/payments/foundry-uat' is outside the secrets of this namespace: credentials_secret must start with voltmx/mobile/"
	assert_line "  💡 Possible causes:"
	assert_line "    • The scope configuration points at the Foundry technical user of another team"
	assert_line "  🔧 How to fix:"
	assert_line "    • Store the Foundry user of this namespace under voltmx/mobile/ (or set secrets_prefix in the scope configuration) and point credentials_secret at it"
	refute_np_called "asset list"
}

@test "Should accept the credentials secret under the secrets_prefix of the scope configuration" {
	use_context_configuration
	with_context '.providers["scope-configurations"].secrets_prefix = "voltmx/shared-uat/" | .providers["scope-configurations"].credentials_secret = "voltmx/shared-uat/foundry"'

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   ✅ credentials_secret=voltmx/shared-uat/foundry (secrets prefix voltmx/shared-uat/)"

	run_build_context
	assert_equal "$SECRETS_PREFIX" "voltmx/shared-uat/"
}

@test "Should reject a secrets_prefix that is not a folder under voltmx/" {
	use_context_configuration
	local prefix
	for prefix in "voltmx/" "mobile/" "voltmx/shared" "voltmx/../x/"; do
		CONTEXT=$(jq --arg p "$prefix" '.providers["scope-configurations"].secrets_prefix = $p' "$RESOURCES_DIR/context_initial.json")
		export CONTEXT

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Invalid secrets_prefix '$prefix': must be a folder under voltmx/ ending in / (e.g. voltmx/mobile/)"
	done
}

@test "Should reject a namespace slug that cannot be a secrets folder" {
	use_context_configuration
	with_context '.namespace.slug = "../payments"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid namespace slug '../payments': only lowercase letters, digits and dashes are allowed"
}

# =============================================================================
# BUILD_CONTEXT_MODE: rollback and delete-deployment (rollback) and the scope
# workflows (scope) have no usable asset; scope has no deployment or release.
# =============================================================================
scope_context() {
	CONTEXT=$(echo "$CONTEXT" | jq -c 'del(.deployment, .release, .asset)')
	export CONTEXT
	export BUILD_CONTEXT_MODE="scope"
}

@test "Should resolve a delete-scope context without deployment, release or asset in scope mode" {
	scope_context

	run_build_context

	assert_equal "$FOUNDRY_APP" "PetStore"
	assert_empty "$APP_VERSION" "APP_VERSION"
	assert_empty "$DEPLOYMENT_ID" "DEPLOYMENT_ID"
	assert_empty "$ASSET_URL" "ASSET_URL"
	assert_equal "$PROFILE_VARS" "{}"
	assert_empty "$PREVIOUS_DEPLOYMENT_ID" "PREVIOUS_DEPLOYMENT_ID"
	assert_equal "$ENVIRONMENT_NAME" "uat"
	assert_equal "$MFCLI_AUTH_ARGS" "-t 100000001"
	assert_equal "$CREDENTIALS_SECRET" "voltmx/mobile/foundry-uat"
	assert_equal "$SCOPE_ID" "7"
	[[ "$WORKDIR" == "$BATS_TEST_TMPDIR/work/scope-7-"* ]]
	assert_directory_exists "$WORKDIR"
	refute_np_called "asset list"
	refute_np_called "deployment list"
	refute_np_called "release read"
}

@test "Should print the scope mode summary and still enforce the app binding and the secrets" {
	scope_context

	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "🔍 Building scope context..."
	assert_line "   📋 Scope: mobile/petstore-foundry/uat (id 7) | Dimension: uat"
	assert_line "   📋 Foundry app: PetStore | Version: none (scope mode)"
	assert_line "   ✅ foundry_app=PetStore is allowed for this scope (allowed_apps: PetStore)"
	assert_line "   📋 Foundry app asset: skipped (scope mode)"
	assert_line "   📋 Profile variables: skipped (scope mode)"
	assert_line "   📋 Previous deployment: skipped (scope mode)"

	use_context_configuration
	with_context '.providers["scope-configurations"].allowed_apps = ["Payments"]'
	run source "$SCRIPT"
	assert_equal "$status" "1"
	assert_line "   ❌ Foundry app 'PetStore' is not allowed for this scope: it does not match allowed_apps (Payments)"

	with_context '.providers["scope-configurations"].allowed_apps = ["PetStore"] | .providers["scope-configurations"].credentials_secret = "voltmx/payments/foundry-uat"'
	run source "$SCRIPT"
	assert_equal "$status" "1"
	assert_line "   ❌ Secret 'voltmx/payments/foundry-uat' is outside the secrets of this namespace: credentials_secret must start with voltmx/mobile/"
}

@test "Should refuse a scope mode context of another scope than the requested one" {
	scope_context
	export SCOPE_ID="8"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The context belongs to scope 7, not to the requested scope 8"
}

@test "Should still validate a deployment id present in scope mode" {
	export BUILD_CONTEXT_MODE="scope"
	with_context '.deployment.id = "../etc"'

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Invalid deployment id '../etc': must be an integer"
}

@test "Should resolve the previous deployment but not the asset in rollback mode" {
	export BUILD_CONTEXT_MODE="rollback"
	with_context 'del(.asset) | del(.release.build_id)'

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "🔍 Building rollback context..."
	assert_line "   📋 Foundry app asset: skipped (rollback mode)"
	assert_line "   📋 Previous deployment: 70 (release 0.9.0)"

	run_build_context
	assert_equal "$APP_VERSION" "1.0.0"
	assert_equal "$PREVIOUS_RELEASE_SEMVER" "0.9.0"
	assert_empty "$ASSET_URL" "ASSET_URL"
	assert_equal "$WORKDIR" "$BATS_TEST_TMPDIR/work/77"
}

@test "Should fail on an unknown BUILD_CONTEXT_MODE" {
	export BUILD_CONTEXT_MODE="instance"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Unknown BUILD_CONTEXT_MODE 'instance': expected deployment, rollback or scope"
	assert_line "  💡 Possible causes:"
	assert_line "    • The workflow step that runs build_context sets configuration.BUILD_CONTEXT_MODE to an unexpected value"
	assert_line "  🔧 How to fix:"
	assert_line "    • Set BUILD_CONTEXT_MODE to scope (scope workflows), rollback (rollback and delete-deployment) or leave it unset (start-initial)"
}

@test "Should fail when the workdir cannot be created" {
	: > "$BATS_TEST_TMPDIR/not-a-dir"
	export WORKDIR="$BATS_TEST_TMPDIR/not-a-dir"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	refute_line "✨ Build context ready"
}

# =============================================================================
# mfcli.command: only the bundled mock may replace the Foundry CLI (testing)
# =============================================================================
@test "Should let the scope configuration replace the Foundry CLI with the bundled mock (mfcli.command)" {
	use_context_configuration
	with_context --arg mock "$SCOPE_DIR/tools/mfcli-mock/mfcli" '.providers["scope-configurations"].mfcli = {command: $mock}'
	export MFCLI_CMD="java -jar /opt/mfcli/mfcli.jar"

	run source "$SCRIPT"
	assert_equal "$status" "0"
	assert_line "   ⚠️ mfcli.command of the scope configuration replaces the Foundry CLI with the bundled mock: $(realpath "$SCOPE_DIR/tools/mfcli-mock/mfcli") (testing only)"

	run_build_context
	assert_equal "$MFCLI_CMD" "$(realpath "$SCOPE_DIR/tools/mfcli-mock/mfcli")"
	assert_equal "$(bash -c 'echo "$MFCLI_CMD"')" "$(realpath "$SCOPE_DIR/tools/mfcli-mock/mfcli")"
}

@test "Should keep MFCLI_CMD from values.yaml when the scope configuration sets no mfcli.command" {
	export MFCLI_CMD="java -jar /opt/mfcli/mfcli.jar"

	run source "$SCRIPT"
	assert_equal "$status" "0"
	[[ "$output" != *"mfcli.command"* ]]

	run_build_context
	assert_equal "$MFCLI_CMD" "java -jar /opt/mfcli/mfcli.jar"
}

@test "Should reject every mfcli.command that is not exactly the bundled mock" {
	use_context_configuration
	export MFCLI_CMD="java -jar /opt/mfcli/mfcli.jar"
	local mock="$SCOPE_DIR/tools/mfcli-mock/mfcli" command reason
	while IFS='|' read -r command reason; do
		CONTEXT=$(echo "$CONTEXT" | jq --arg c "$command" '.providers["scope-configurations"].mfcli.command = $c')
		export CONTEXT

		run source "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ Invalid mfcli.command '$command': $reason"
		assert_line "    • The only allowed override is the bundled mock, $mock (one word, no arguments)"
		assert_line "    • A real Foundry mounts or bakes mfcli.jar at \$MFCLI_JAR and keeps the default java -jar \$MFCLI_JAR of values.yaml: remove mfcli.command"
		refute_line "✨ Build context ready"
	done <<-CASES
		sh -c env|it carries arguments, spaces or control characters
		env JAVA_TOOL_OPTIONS=-Dx java -jar /opt/mfcli/mfcli.jar|it carries arguments, spaces or control characters
		$mock --verbose|it carries arguments, spaces or control characters
		/bin/sh|it is not the bundled mock
		java|it is not the absolute path of the bundled mock
		tools/mfcli-mock/mfcli|it is not the absolute path of the bundled mock
		$SCOPE_DIR/tools/mfcli-mock/../mfcli-mock/mfcli|it is not the absolute path of the bundled mock
		$SCOPE_DIR/tools/mfcli-mock/README.md|it is not the bundled mock
	CASES
}

@test "Should reject an mfcli.command with a newline, a tab or a control character" {
	use_context_configuration
	local mock="$SCOPE_DIR/tools/mfcli-mock/mfcli" command
	for command in $'mfcli\ntouch /x' $'mfcli\ttouch /x' $'mfcli\rtouch /x' $"$mock"$'\x01'; do
		CONTEXT=$(echo "$CONTEXT" | jq --arg c "$command" '.providers["scope-configurations"].mfcli.command = $c')
		export CONTEXT

		run source "$SCRIPT"

		assert_equal "$status" "1"
		[[ "$output" == *"❌ Invalid mfcli.command '"*"': it carries arguments, spaces or control characters"* ]]
		refute_line "✨ Build context ready"
	done
}

@test "Should leave the shell options of the workflow shell as they were" {
	run bash -c 'set +e +u +o pipefail; source "$0" >/dev/null 2>&1 || exit 9; printf "%s:%s" "$-" "$SHELLOPTS"' "$SCRIPT"
	assert_equal "$status" "0"
	[[ "${output%%:*}" != *e* ]]
	[[ "${output%%:*}" != *u* ]]
	[[ ":${output#*:}:" != *:pipefail:* ]]

	run bash -c 'set -euo pipefail; source "$0" >/dev/null 2>&1; printf "%s:%s" "$-" "$SHELLOPTS"' "$SCRIPT"
	assert_equal "$status" "0"
	[[ "${output%%:*}" == *e* ]]
	[[ "${output%%:*}" == *u* ]]
	[[ ":${output#*:}:" == *:pipefail:* ]]
}
