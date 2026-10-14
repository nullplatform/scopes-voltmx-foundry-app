#!/usr/bin/env bats
# =============================================================================
# Unit tests for deployment/scripts/fetch_asset (sourced): downloads the
# Foundry app zip from the configured assets bucket and exports FOUNDRY_ZIP.
#
# Run: bats voltmx-foundry-app/deployment/tests/scripts/fetch_asset_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	source "$(cd "$DEPLOYMENT_DIR/../.." && pwd)/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	setup_foundry_test "$DEPLOYMENT_DIR"
	SCRIPT="$SCRIPTS_DIR/fetch_asset"

	unset FOUNDRY_ZIP
	export AWS_MOCK_S3_OBJECT="$BATS_TEST_TMPDIR/PetStore.zip"
	make_foundry_zip "$AWS_MOCK_S3_OBJECT" "PetStore" "1.0.0"
}

@test "Should download the app zip from the bucket and export FOUNDRY_ZIP" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "📡 Downloading the Foundry app from s3://assets-aws-mobile/foundry/442353700/30/PetStore.zip..."
	assert_line "   ✅ Foundry app downloaded to $WORKDIR/foundry.zip"
	assert_mock_call "$AWS_MOCK_CALLS_LOG" "aws s3 cp s3://assets-aws-mobile/foundry/442353700/30/PetStore.zip $WORKDIR/foundry.zip --region us-east-1"

	source "$SCRIPT"
	assert_equal "$FOUNDRY_ZIP" "$WORKDIR/foundry.zip"
	assert_file_exists "$FOUNDRY_ZIP"
}

@test "Should refuse an asset outside the configured bucket without downloading it" {
	export ASSET_URL="s3://someone-else/PetStore.zip"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Asset URL is outside the configured assets bucket 'assets-aws-mobile': s3://someone-else/PetStore.zip"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI uploaded the asset to a bucket other than assets.bucket of the 'Volt MX Foundry app' scope configuration"
	assert_line "    • The asset url was tampered with"
	assert_line "  🔧 How to fix:"
	assert_line "    • Make the CI upload the app to s3://assets-aws-mobile and register that url, or set assets.bucket to the bucket the CI uses"
	assert_file_not_exists "$AWS_MOCK_CALLS_LOG"
}

@test "Should fail with the troubleshooting block when the download fails" {
	export AWS_MOCK_S3_FAIL=1

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ Could not download the Foundry app from s3://assets-aws-mobile/foundry/442353700/30/PetStore.zip"
	assert_line "  💡 Possible causes:"
	assert_line "    • The object does not exist or the agent role cannot read the bucket assets-aws-mobile"
	assert_line "  🔧 How to fix:"
	assert_line "    • Check that the CI uploaded the app and that the agent role has s3:GetObject on assets-aws-mobile"
}

@test "Should fail when the downloaded file is not a zip" {
	echo "not a zip" > "$AWS_MOCK_S3_OBJECT"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The asset s3://assets-aws-mobile/foundry/442353700/30/PetStore.zip is not a zip file"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI registered something other than the app exported from Foundry (Export or the Iris publish zip)"
	assert_line "  🔧 How to fix:"
	assert_line "    • Register the zip produced by exporting the Foundry app as the 'foundry' asset"
}

@test "Should fail when build_context did not run" {
	unset ASSET_URL

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ ASSET_URL or WORKDIR is not set"
	assert_line "  🔧 How to fix:"
	assert_line "    • Run the deployment workflow from the start so build_context resolves the asset"
}

@test "Should report the app and version found in the zip" {
	run source "$SCRIPT"

	assert_equal "$status" "0"
	assert_line "   ✅ Zip contents: app PetStore version 1.0.0 (Apps/PetStore/Meta.json)"
}

@test "Should refuse the export of another app, and delete it" {
	rm -f "$AWS_MOCK_S3_OBJECT"
	make_foundry_zip "$AWS_MOCK_S3_OBJECT" "Payments" "1.0.0"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The zip is app 'Payments' version '1.0.0', but this deployment publishes app 'PetStore' version 1.0.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI registered the export of another app or another version as the 'foundry' asset of this release"
	assert_line "  🔧 How to fix:"
	assert_line "    • Register the export of 'PetStore' version 1.0.0 (the release semver) as the 'foundry' asset of this build"
	assert_file_not_exists "$WORKDIR/foundry.zip"
}

@test "Should refuse the export of another version of the app" {
	rm -f "$AWS_MOCK_S3_OBJECT"
	make_foundry_zip "$AWS_MOCK_S3_OBJECT" "PetStore" "0.9.0"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The zip is app 'PetStore' version '0.9.0', but this deployment publishes app 'PetStore' version 1.0.0"
}

@test "Should refuse a zip without Apps/<app>/Meta.json" {
	local dir
	dir=$(mktemp -d)
	echo "x" > "$dir/readme.txt"
	rm -f "$AWS_MOCK_S3_OBJECT"
	(cd "$dir" && zip -q "$AWS_MOCK_S3_OBJECT" readme.txt)
	rm -rf "$dir"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	assert_line "   ❌ The Foundry app zip has no Apps/<app>/Meta.json: cannot check that it is app 'PetStore' version 1.0.0"
	assert_line "  💡 Possible causes:"
	assert_line "    • The CI registered a zip that is not a Foundry app export"
	assert_line "  🔧 How to fix:"
	assert_line "    • Export the app with mfcli Export (or from the Foundry console) and register that zip as the 'foundry' asset"
}

@test "Should refuse a zip that carries several apps" {
	local dir
	dir=$(mktemp -d)
	mkdir -p "$dir/Apps/PetStore" "$dir/Apps/Payments"
	echo '{"name":"PetStore","version":"1.0.0"}' > "$dir/Apps/PetStore/Meta.json"
	echo '{"name":"Payments","version":"1.0.0"}' > "$dir/Apps/Payments/Meta.json"
	rm -f "$AWS_MOCK_S3_OBJECT"
	(cd "$dir" && zip -qr "$AWS_MOCK_S3_OBJECT" Apps)
	rm -rf "$dir"

	run source "$SCRIPT"

	assert_equal "$status" "1"
	[[ "$output" == *"   ❌ The Foundry app zip carries more than one app ("*")"* ]]
}
