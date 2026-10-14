#!/usr/bin/env bats
# =============================================================================
# Spec templates: every specs/**/*.json.tpl renders with gomplate into valid
# JSON, carries the scope's identity, and the schemas match what the
# deployment scripts read.
#
# Run: bats voltmx-foundry-app/deployment/tests/specs/specs_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	MODULE_DIR="$(cd "$TEST_DIR/../../.." && pwd)"
	PROJECT_ROOT="$(cd "$MODULE_DIR/.." && pwd)"
	SPECS_DIR="$MODULE_DIR/specs"
	source "$PROJECT_ROOT/testing/assertions.sh"

	command -v gomplate >/dev/null || skip "gomplate is not installed"

	export NRN="organization=1:account=2"
	export SERVICE_SPECIFICATION_ID="spec_test"
	export NP_API_KEY="test-key"
	export REPO_PATH="/app/pkg"
	export SERVICE_PATH="voltmx-foundry-app"
	export ENVIRONMENT="test"
	export SERVICE_SLUG="voltmx-foundry-app"
}

render() {
	gomplate -f "$1"
}

EXPECTED_ACTIONS='["create-scope","update-scope","delete-scope","start-initial","rollback-deployment","delete-deployment","diagnose-scope"]'

@test "Every spec template renders into valid JSON" {
	local count=0
	for tpl in "$SPECS_DIR"/*.json.tpl "$SPECS_DIR"/actions/*.json.tpl; do
		run bash -c "gomplate -f '$tpl' | jq -e . >/dev/null"
		[ "$status" -eq 0 ] || { echo "invalid JSON: $tpl"; echo "$output"; return 1; }
		count=$((count + 1))
	done
	local expected
	expected=$(( $(find "$SPECS_DIR" -maxdepth 1 -name "*.json.tpl" | wc -l) + $(find "$SPECS_DIR/actions" -name "*.json.tpl" | wc -l) ))
	assert_equal "$count" "11"
	assert_equal "$count" "$expected"
}

@test "Service spec declares the Volt MX Foundry app identity and every action it lists has a template" {
	local spec
	spec=$(render "$SPECS_DIR/service-spec.json.tpl")
	assert_equal "$(echo "$spec" | jq -r .name)" "Volt MX Foundry app"
	assert_equal "$(echo "$spec" | jq -r .selectors.sub_category)" "Volt MX Foundry app"
	assert_equal "$(echo "$spec" | jq -r .selectors.provider)" "Agent"
	assert_equal "$(echo "$spec" | jq -r .type)" "scope"
	assert_equal "$(echo "$spec" | jq -r .use_default_actions)" "false"
	assert_equal "$(echo "$spec" | jq -r '.visible_to[0]')" "organization=1:account=2"
	assert_equal "$(echo "$spec" | jq -c .available_actions)" "$EXPECTED_ACTIONS"
	for action in $(echo "$spec" | jq -r '.available_actions[]'); do
		assert_file_exists "$SPECS_DIR/actions/$action.json.tpl"
		assert_equal "$(render "$SPECS_DIR/actions/$action.json.tpl" | jq -r .slug)" "$action"
		assert_equal "$(render "$SPECS_DIR/actions/$action.json.tpl" | jq -r .service_specification_id)" "spec_test"
	done
}

@test "Service spec has no blue-green actions: Foundry keeps one active version per app and environment" {
	local spec
	spec=$(render "$SPECS_DIR/service-spec.json.tpl")
	assert_equal "$(echo "$spec" | jq -r '.available_actions | map(select(test("blue-green|switch-traffic"))) | length')" "0"
	assert_file_not_exists "$SPECS_DIR/actions/start-blue-green.json.tpl"
	assert_file_not_exists "$SPECS_DIR/actions/switch-traffic.json.tpl"
	assert_file_not_exists "$SPECS_DIR/actions/finalize-blue-green.json.tpl"
	run grep -c "blue-green" "$MODULE_DIR/README.md"
	assert_greater_than "$output" "0" "README mentions why there is no blue-green"
}

@test "Every action template is listed in available_actions (no orphan templates)" {
	local spec tpl slug
	spec=$(render "$SPECS_DIR/service-spec.json.tpl")
	for tpl in "$SPECS_DIR"/actions/*.json.tpl; do
		slug=$(basename "$tpl" .json.tpl)
		assert_equal "$(echo "$spec" | jq -r --arg s "$slug" '.available_actions | index($s) != null')" "true"
	done
}

@test "Scope type and notification channel point at the service specification" {
	assert_equal "$(render "$SPECS_DIR/scope-type-definition.json.tpl" | jq -r .provider_id)" "spec_test"
	assert_equal "$(render "$SPECS_DIR/scope-type-definition.json.tpl" | jq -r .name)" "Volt MX Foundry app"
	assert_equal "$(render "$SPECS_DIR/scope-type-definition.json.tpl" | jq -r .type)" "custom"
	assert_equal "$(render "$SPECS_DIR/notification-channel.json.tpl" | jq -r .description)" "Channel to handle Volt MX Foundry app scopes"
	assert_equal "$(render "$SPECS_DIR/notification-channel.json.tpl" | jq -r '.filters["$or"][0]["service.specification.slug"]')" "voltmx-foundry-app"
	assert_equal "$(render "$SPECS_DIR/notification-channel.json.tpl" | jq -r '.filters["$or"][1]["arguments.scope_provider"]')" "spec_test"
	assert_equal "$(render "$SPECS_DIR/notification-channel.json.tpl" | jq -r '.configuration.command.data.cmdline')" "/app/pkg/entrypoint --service-path=/app/pkg/voltmx-foundry-app"
}

# Every uiSchema scope (controls and rule conditions) must resolve to a schema property:
# "#/properties/a/properties/b" -> getpath(["properties","a","properties","b"]).
assert_ui_scopes_resolve() {
	local schema="$1" uischema="$2" scope
	for scope in $(echo "$uischema" | jq -r '[.. | objects | (.scope? // empty), (.condition?.scope? // empty)] | unique[]'); do
		[ "$scope" = "#" ] && continue
		assert_true "$(echo "$schema" | jq -r --arg s "$scope" '($s | ltrimstr("#/") | split("/")) as $p | getpath($p) != null')" "uiSchema scope $scope resolves to a schema property"
	done
}

@test "Service spec exposes only the app name in developer vocabulary" {
	local schema
	schema=$(render "$SPECS_DIR/service-spec.json.tpl" | jq .attributes.schema)
	assert_equal "$(echo "$schema" | jq -c .required)" '["foundry_app_name"]'
	assert_equal "$(echo "$schema" | jq -c '.properties | keys')" '["asset_type","foundry_app_name"]'
	assert_equal "$(echo "$schema" | jq -c '.properties.asset_type | {type, default, export}')" '{"type":"string","default":"bundle","export":false}'
	assert_equal "$(echo "$schema" | jq -r .properties.foundry_app_name.type)" "string"
	assert_equal "$(echo "$schema" | jq -r .properties.foundry_app_name.pattern)" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
	assert_equal "$(echo "$schema" | jq -c .properties.foundry_app_name.editableOn)" '["create"]'
	assert_equal "$(echo "$schema" | jq -r '.uiSchema.type')" "VerticalLayout"
	assert_equal "$(echo "$schema" | jq -c '.uiSchema.elements | map(.scope)')" '["#/properties/foundry_app_name"]'
	assert_equal "$(echo "$schema" | jq -r '[.properties | .. | (.title?, .description?) | strings] | map(test("mfcli|HCL"; "i")) | any')" "false"
}

@test "The app name pattern accepts Foundry names and rejects paths and spaces" {
	local pattern name
	pattern=$(render "$SPECS_DIR/service-spec.json.tpl" | jq -r .attributes.schema.properties.foundry_app_name.pattern)
	for name in PetStore pet-store Pet_Store.v2 9lives; do
		assert_equal "$(jq -nr --arg p "$pattern" --arg n "$name" '$n | test($p)')" "true"
	done
	for name in "../x" "Pet Store" "-pet" ".pet" "pet/store" ""; do
		assert_equal "$(jq -nr --arg p "$pattern" --arg n "$name" '$n | test($p)')" "false"
	done
}

@test "Scope configuration declares the Foundry environment, auth, credentials and assets for DevOps" {
	local cfg
	cfg=$(render "$SPECS_DIR/scope-configuration.json.tpl")
	assert_equal "$(echo "$cfg" | jq -r .name)" "Volt MX Foundry app"
	assert_equal "$(echo "$cfg" | jq -r .category)" "scope-configurations"
	assert_true "$(echo "$cfg" | jq -r .allow_dimensions)" "allow_dimensions"
	assert_equal "$(echo "$cfg" | jq -r '.visible_to[0]')" "organization=1:account=2"
	assert_equal "$(echo "$cfg" | jq -c .schema.required)" '["environment_name","auth","credentials_secret","assets"]'
	assert_equal "$(echo "$cfg" | jq -r .schema.properties.environment_name.pattern)" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
	assert_equal "$(echo "$cfg" | jq -r .schema.properties.credentials_secret.pattern)" '^voltmx/[A-Za-z0-9/_-]+$'
	assert_equal "$(echo "$cfg" | jq -c .schema.properties.assets.required)" '["bucket"]'
	assert_equal "$(echo "$cfg" | jq -r .schema.properties.assets.properties.region.default)" "us-east-1"
	assert_equal "$(echo "$cfg" | jq -c '.schema.properties | keys')" '["allowed_apps","app_name_prefix","assets","auth","credentials_secret","environment_name","secrets_prefix"]'
}

@test "Scope configuration binds apps and secrets to the namespace (multi-tenant Foundry environments)" {
	local props
	props=$(render "$SPECS_DIR/scope-configuration.json.tpl" | jq .schema.properties)
	assert_equal "$(echo "$props" | jq -r .allowed_apps.type)" "array"
	assert_equal "$(echo "$props" | jq -c .allowed_apps.default)" "[]"
	assert_equal "$(echo "$props" | jq -r .allowed_apps.items.pattern)" '^[A-Za-z0-9][A-Za-z0-9._-]*[*]?$'
	assert_equal "$(echo "$props" | jq -r .app_name_prefix.pattern)" '^[A-Za-z0-9][A-Za-z0-9._-]*$'
	assert_equal "$(echo "$props" | jq -r .secrets_prefix.pattern)" '^voltmx/[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*/$'
	local schema
	schema=$(render "$SPECS_DIR/scope-configuration.json.tpl" | jq .schema)
	assert_equal "$(echo "$schema" | jq -c '.anyOf | map(.required)')" '[["allowed_apps"],["app_name_prefix"]]'
	assert_equal "$(echo "$schema" | jq -r '.anyOf[0].properties.allowed_apps.minItems')" "1"
	assert_equal "$(echo "$schema" | jq -r '.anyOf[1].properties.app_name_prefix.minLength')" "1"
}

@test "Scope configuration auth is either a cloud account id or the on-premises identity and console URLs" {
	local auth
	auth=$(render "$SPECS_DIR/scope-configuration.json.tpl" | jq .schema.properties.auth)
	assert_equal "$(echo "$auth" | jq -r '.oneOf | length')" "2"
	assert_equal "$(echo "$auth" | jq -c '.oneOf[0].required')" '["account_id"]'
	assert_equal "$(echo "$auth" | jq -r '.oneOf[0].properties.account_id.pattern')" '^[0-9]{9}$'
	assert_equal "$(echo "$auth" | jq -r '.oneOf[0].additionalProperties')" "false"
	assert_equal "$(echo "$auth" | jq -c '.oneOf[1].required')" '["identity_url","console_url"]'
	assert_equal "$(echo "$auth" | jq -r '.oneOf[1].properties.identity_url.pattern')" '^https://'
	assert_equal "$(echo "$auth" | jq -r '.oneOf[1].properties.console_url.pattern')" '^https://'
	assert_equal "$(echo "$auth" | jq -r '.oneOf[1].additionalProperties')" "false"
}

@test "Every uiSchema scope of both specs resolves to an existing schema property" {
	local schema
	schema=$(render "$SPECS_DIR/service-spec.json.tpl" | jq .attributes.schema)
	assert_greater_than "$(echo "$schema" | jq '[.uiSchema | .. | objects | .scope? // empty] | length')" "0" "service spec uiSchema scopes"
	assert_ui_scopes_resolve "$schema" "$(echo "$schema" | jq .uiSchema)"
	schema=$(render "$SPECS_DIR/scope-configuration.json.tpl" | jq .schema)
	assert_greater_than "$(echo "$schema" | jq '[.uiSchema | .. | objects | .scope? // empty] | length')" "0" "scope configuration uiSchema scopes"
	assert_ui_scopes_resolve "$schema" "$(echo "$schema" | jq .uiSchema)"
}

@test "values.yaml carries the provider categories and the mfcli settings the scripts read" {
	local values="$MODULE_DIR/values.yaml"
	assert_file_exists "$values"
	run grep -A3 '^provider_categories:' "$values"
	assert_contains "$output" "  - scope-configurations"
	assert_contains "$output" "  - cloud-providers"
	assert_contains "$output" "  - identity-access-control"
	run grep -E '^  (MFCLI_CMD|PUBLISH_TIMEOUT_SECONDS|PUBLISH_POLL_SECONDS|WORKDIR):' "$values"
	assert_contains "$output" '  MFCLI_CMD: "java -jar /opt/mfcli/mfcli.jar"'
	assert_contains "$output" "  PUBLISH_TIMEOUT_SECONDS: 900"
	assert_contains "$output" "  PUBLISH_POLL_SECONDS: 15"
	assert_contains "$output" "  WORKDIR: /tmp/voltmx-foundry-app"
	run grep -E '^  MFCLI_CALL_TIMEOUT_SECONDS:' "$values"
	assert_contains "$output" "  MFCLI_CALL_TIMEOUT_SECONDS: 300"
}
