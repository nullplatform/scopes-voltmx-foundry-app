#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/do_unpublish: removes the app from the
# Foundry environment. UNPUBLISH_MODE is required: in deployment mode
# (delete-deployment) it only acts when APP_VERSION is the active version,
# and then restores the previous finalized release (PREVIOUS_RELEASE_SEMVER,
# through do_rollback) or unpublishes when the scope has none; in scope mode
# (delete-scope) it only unpublishes when the active version was released by
# a finalized deployment of this scope. The end-to-end chains with real
# delete-deployment and delete-scope contexts live in workflow_chain_test.bats.
#
# Run: bats voltmx-foundry-app/deployment/tests/scripts/do_unpublish_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_foundry_test "$DEPLOYMENT_DIR"
	SCRIPT="$SCRIPTS_DIR/do_unpublish"
	export UNPUBLISH_MODE="deployment"
}

@test "Should restore the previous finalized release when the deployment version is the active one" {
	seed_active_version "0.9.0"
	seed_active_version "1.0.0"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📝 Unpublishing PetStore from environment uat (deployment mode)..."
	assert_line "   📋 Version 1.0.0 of deployment 77 is the active version of PetStore in environment uat"
	assert_line "   📝 Restoring version 0.9.0 of previous deployment 70 (Foundry keeps one active version per app and environment)"
	assert_line "   ✅ Version 0.9.0 is active in environment uat"
	assert_line "✅ Restored version 0.9.0 of PetStore in environment uat after deleting deployment 77"
	refute_line "✅ PetStore is no longer published in environment uat"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore" \
		"mfcli Publish -u np-foundry -p *** -t 100000001 -e uat -a PetStore -v 0.9.0" \
		"mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore")"
	assert_equal "$(mock_publish_status | jq -c .)" '{"status":"success","version":"0.9.0","active_version":"0.9.0"}'
	refute_output_contains "$MFCLI_PASSWORD"
}

@test "Should unpublish the app when the deployment version is the active one and the scope has no other finalized deployment" {
	seed_active_version "1.0.0"
	export PREVIOUS_DEPLOYMENT_ID="" PREVIOUS_RELEASE_SEMVER="" PREVIOUS_DEPLOYMENT_LOOKUP="ok"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📝 Unpublishing PetStore from environment uat (deployment mode)..."
	assert_line "   📋 Scope 7 has no other finalized deployment: nothing to restore, unpublishing"
	assert_line "   📋 App 'PetStore' unpublished successfully from environment 'uat'."
	assert_line "✅ PetStore is no longer published in environment uat"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore" \
		"mfcli Unpublish -u np-foundry -p *** -t 100000001 -e uat -a PetStore")"
}

@test "Should leave the app as it is when the previous deployment released the same version" {
	seed_active_version "1.0.0"
	export PREVIOUS_RELEASE_SEMVER="1.0.0"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 Previous deployment 70 released the same version 1.0.0; leaving it published"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "deployment mode: should leave the app as it is when the deployments of the scope could not be listed" {
	seed_active_version "1.0.0"
	export PREVIOUS_DEPLOYMENT_ID="" PREVIOUS_RELEASE_SEMVER="" PREVIOUS_DEPLOYMENT_LOOKUP="failed"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not list the deployments of scope 7 to find the version that should take over; leaving version 1.0.0 published"
	assert_line "   🔧 How to fix: deploy or roll back to the release that should serve in environment uat"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "deployment mode: should leave the app as it is when the release of the previous deployment has no version" {
	seed_active_version "1.0.0"
	export PREVIOUS_RELEASE_SEMVER="" PREVIOUS_DEPLOYMENT_LOOKUP="ok"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ The release of previous deployment 70 has no readable version; leaving version 1.0.0 published"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "deployment mode: should fail when the previous version cannot be published again" {
	seed_active_version "1.0.0"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ mfcli Publish failed (exit 1): Error: App 'PetStore' version '0.9.0' not found. Import it before publishing."
	assert_line "   ❌ Could not restore version 0.9.0 of PetStore in environment uat; version 1.0.0 of deleted deployment 77 may still be active"
	assert_line "    • Check the publish of PetStore in the Foundry console (environment uat), then delete the deployment again or deploy the release you want to serve"
	refute_line "✅ PetStore is no longer published in environment uat"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "deployment mode: should fail when the restore does not finish in time" {
	seed_active_version "0.9.0"
	seed_active_version "1.0.0"
	export MFCLI_MOCK_PUBLISH_HANG=1 PUBLISH_TIMEOUT_SECONDS=1

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Publish did not finish in 1s; version 1.0.0 is still active. Re-run the deployment: Publish is idempotent"
	assert_line "   ❌ Could not restore version 0.9.0 of PetStore in environment uat; version 1.0.0 of deleted deployment 77 may still be active"
}

@test "Should leave the app published when the deployment version is not the active one" {
	seed_active_version "0.9.0"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 Version 1.0.0 is not the active version of PetStore in environment uat (active: 0.9.0); leaving it published"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "Should unpublish on scope deletion when the active version was released by this scope" {
	seed_active_version "0.9.0"
	export UNPUBLISH_MODE="scope"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 Active version 0.9.0 was released by a finalized deployment of scope 7"
	assert_line "✅ PetStore is no longer published in environment uat"
	assert_mfcli_calls "$(printf '%s\n' \
		"mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore" \
		"mfcli Unpublish -u np-foundry -p *** -t 100000001 -e uat -a PetStore")"
	assert_np_called "np deployment list --scope-id 7 --all --max-pages 5 --format json"
	assert_np_called "np release read --id 60 --format json"
}

@test "Should not unpublish on scope deletion when the active version is not a release of this scope" {
	seed_active_version "2.0.0"
	export UNPUBLISH_MODE="scope"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Version 2.0.0 of PetStore is active in environment uat, but no finalized deployment of scope 7 released it; leaving it published (it may belong to another scope)"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "2.0.0"
}

@test "Should fail closed on scope deletion when the deployments of the scope cannot be listed" {
	seed_active_version "0.9.0"
	export UNPUBLISH_MODE="scope"
	unset NP_MOCK_DEPLOYMENT_LIST

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not list the deployments of scope 7 to check which versions it released; not unpublishing"
	assert_line "  💡 Possible causes:"
	assert_line "    • The np CLI failed or the agent cannot read the deployments of the scope"
	assert_line "  🔧 How to fix:"
	assert_line "    • Retry the scope deletion; if it keeps failing, unpublish PetStore from environment uat in the Foundry console after checking it is not used by another scope"
	assert_mfcli_calls ""
}

@test "Should fail closed on scope deletion when a release of the scope cannot be read" {
	seed_active_version "0.9.0"
	export UNPUBLISH_MODE="scope"
	unset NP_MOCK_RELEASE_READ NP_MOCK_RELEASE_READ_DIR

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not list the deployments of scope 7 to check which versions it released; not unpublishing"
	assert_mfcli_calls ""
}

@test "Should not call Foundry on scope deletion when the scope never finalized a deployment" {
	seed_active_version "0.9.0"
	export UNPUBLISH_MODE="scope"
	export NP_MOCK_DEPLOYMENT_LIST="$MOCKS_DIR/deployment_list_no_previous.json"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 Scope 7 has no finalized deployments: nothing it published can be active; nothing to unpublish"
	assert_mfcli_calls ""
	assert_equal "$(mock_publish_status | jq -r .active_version)" "0.9.0"
}

@test "deployment mode: should warn and leave the app as it is when publish-status fails" {
	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not read the publish status of PetStore in environment uat; leaving the app as it is"
	assert_line "   📋 publish-status: Error: App 'PetStore' is not published to environment 'uat'."
	refute_line "✅ PetStore is no longer published in environment uat"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "scope mode: should succeed with nothing to unpublish when Foundry says the app is not published" {
	export UNPUBLISH_MODE="scope"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 PetStore is not published in environment uat (Error: App 'PetStore' is not published to environment 'uat'.); nothing to unpublish"
	refute_line "✅ PetStore is no longer published in environment uat"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "scope mode: should unpublish a version released by any finalized deployment of the scope, not only the first" {
	export UNPUBLISH_MODE="scope"
	local version
	for version in 1.1.0 0.5.0; do
		seed_active_version "$version"
		rm -f "$NP_MOCK_CALLS_LOG"

		run bash "$SCRIPT"

		assert_equal "$status" "0"
		assert_line "   📋 Active version $version was released by a finalized deployment of scope 7"
		assert_line "✅ PetStore is no longer published in environment uat"
		assert_np_called "np release read --id 65 --format json"
		assert_np_called "np release read --id 60 --format json"
		assert_np_called "np release read --id 50 --format json"
	done
}

@test "scope mode: should leave a version published when no release of the scope carries it, even with three finalized deployments" {
	seed_active_version "1.0.0"
	export UNPUBLISH_MODE="scope"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Version 1.0.0 of PetStore is active in environment uat, but no finalized deployment of scope 7 released it; leaving it published (it may belong to another scope)"
	assert_np_called "np release read --id 65 --format json"
	assert_np_called "np release read --id 50 --format json"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "deployment mode: should warn and not unpublish when publish-status does not answer" {
	seed_active_version "1.0.0"
	cat > "$BATS_TEST_TMPDIR/hanging-mfcli" <<CLI
#!/bin/bash
if [ "\$1" = "publish-status" ]; then exec sleep 30; fi
exec "$MFCLI_CMD" "\$@"
CLI
	chmod +x "$BATS_TEST_TMPDIR/hanging-mfcli"
	local real_mfcli="$MFCLI_CMD"
	export MFCLI_CMD="$BATS_TEST_TMPDIR/hanging-mfcli" MFCLI_CALL_TIMEOUT_SECONDS=1

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not read the publish status of PetStore in environment uat; leaving the app as it is"
	assert_line "   📋 publish-status: no answer in 1s"
	MFCLI_CMD="$real_mfcli"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "Should succeed without unpublishing when the app has no active version" {
	seed_active_version "1.0.0"
	MFCLI_MOCK_PUBLISH_FAIL=1 "$MFCLI_CMD" Unpublish -u np-foundry -p "$MFCLI_PASSWORD" -t 100000001 -e uat -a PetStore >/dev/null
	make_foundry_zip "$BATS_TEST_TMPDIR/v.zip" PetStore 1.0.1
	"$MFCLI_CMD" Import -u np-foundry -p "$MFCLI_PASSWORD" -t 100000001 -f "$BATS_TEST_TMPDIR/v.zip" -a PetStore -v 1.0.1 >/dev/null
	MFCLI_MOCK_PUBLISH_FAIL=1 "$MFCLI_CMD" Publish -u np-foundry -p "$MFCLI_PASSWORD" -t 100000001 -e uat -a PetStore -v 1.0.1 >/dev/null 2>&1 || true
	: > "$MFCLI_MOCK_LOG"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   📋 PetStore has no active version in environment uat; nothing to unpublish"
	assert_mfcli_calls "mfcli publish-status -u np-foundry -p *** -t 100000001 -e uat -a PetStore"
}

@test "scope mode: should fail closed when publish-status does not answer JSON" {
	seed_active_version "0.9.0"
	export UNPUBLISH_MODE="scope"
	cat > "$BATS_TEST_TMPDIR/text-mfcli" <<CLI
#!/bin/bash
if [ "\$1" = "publish-status" ]; then echo "Status: PUBLISHED (1.0.0)"; exit 0; fi
exec "$MFCLI_CMD" "\$@"
CLI
	chmod +x "$BATS_TEST_TMPDIR/text-mfcli"
	local real_mfcli="$MFCLI_CMD"
	export MFCLI_CMD="$BATS_TEST_TMPDIR/text-mfcli"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ publish-status of PetStore did not return the expected JSON ({\"status\", \"version\", \"active_version\"}); not unpublishing"
	refute_line "✅ PetStore is no longer published in environment uat"
	MFCLI_CMD="$real_mfcli"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "0.9.0"
}

@test "deployment mode: should warn and not unpublish when publish-status does not answer JSON" {
	seed_active_version "1.0.0"
	cat > "$BATS_TEST_TMPDIR/text-mfcli" <<CLI
#!/bin/bash
if [ "\$1" = "publish-status" ]; then echo "Status: PUBLISHED (1.0.0)"; exit 0; fi
exec "$MFCLI_CMD" "\$@"
CLI
	chmod +x "$BATS_TEST_TMPDIR/text-mfcli"
	local real_mfcli="$MFCLI_CMD"
	export MFCLI_CMD="$BATS_TEST_TMPDIR/text-mfcli"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not read the publish status of PetStore in environment uat; leaving the app as it is"
	assert_line "   📋 publish-status: the answer is not the expected JSON"
	MFCLI_CMD="$real_mfcli"
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "scope mode: should fail with the locked user hint when the credentials are invalid" {
	seed_active_version "0.9.0"
	export UNPUBLISH_MODE="scope" MFCLI_MOCK_VALID_PASSWORD="rotated-password"

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "  💡 Possible causes: the Foundry technical user is locked or the password rotated"
	refute_output_contains "$MFCLI_PASSWORD"
}

@test "deployment mode: invalid credentials do not block deleting the deployment" {
	seed_active_version "1.0.0"
	export MFCLI_MOCK_VALID_PASSWORD="rotated-password"

	run bash "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ⚠️ Could not read the publish status of PetStore in environment uat; leaving the app as it is"
	assert_line "   📋 publish-status: Error: Authentication failed. Invalid credentials for user 'np-foundry'."
	refute_output_contains "$MFCLI_PASSWORD"
	unset MFCLI_MOCK_VALID_PASSWORD
	assert_equal "$(mock_publish_status | jq -r .active_version)" "1.0.0"
}

@test "Should refuse to run without an explicit UNPUBLISH_MODE" {
	seed_active_version "1.0.0"
	local mode
	for mode in "" "auto"; do
		export UNPUBLISH_MODE="$mode"

		run bash "$SCRIPT"

		assert_equal "$status" "1"
		assert_line "   ❌ UNPUBLISH_MODE must be scope or deployment, got '$mode'"
		assert_line "  💡 Possible causes:"
		assert_line "    • The workflow step that runs do_unpublish does not set configuration.UNPUBLISH_MODE"
		assert_line "  🔧 How to fix:"
		assert_line "    • Set UNPUBLISH_MODE: scope in the delete-scope workflow and UNPUBLISH_MODE: deployment in the delete-deployment workflow"
	done
	assert_mfcli_calls ""
}

@test "Should refuse deployment mode without the version of the deployment" {
	seed_active_version "1.0.0"
	export APP_VERSION=""

	run bash "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ UNPUBLISH_MODE=deployment needs the version of the deployment (APP_VERSION is '')"
	assert_mfcli_calls ""
}
