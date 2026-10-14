#!/usr/bin/env bats
# =============================================================================
# Unit tests for utils/assume_role_step - resolves the role and assumes it.
#
# The IAM provider is read from CONTEXT.providers["identity-access-control"]
# (already dimension-resolved by the platform), so the tests only mock `aws`
# (sts). Success paths source the step IN-PROCESS and assert exported env vars
# directly; failure paths use `run` and assert the full hint output.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  source "$PROJECT_ROOT/testing/assertions.sh"
  export STEP="$BATS_TEST_DIRNAME/../assume_role_step"

  export SCOPE_ID="scope-123"
  # CONTEXT with the IAM provider (resolved) carrying the scope role.
  export CONTEXT='{"providers":{"identity-access-control":{"iam_role_arns":{"arns":[{"selector":"voltmx-foundry-app","arn":"arn:aws:iam::111:role/voltmx-foundry-app-role"}]}}}}'
  unset VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN_DEFAULT VOLTMX_FOUNDRY_APP_ASSUME_ROLE_SELECTOR \
        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

  aws() {
    case "$*" in
      *"sts assume-role"*) echo '{"Credentials":{"AccessKeyId":"AKIA1","SecretAccessKey":"sec1","SessionToken":"tok1"}}'; return 0 ;;
      *) return 0 ;;
    esac
  }
  export -f aws
}

teardown() {
  unset VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN_DEFAULT VOLTMX_FOUNDRY_APP_ASSUME_ROLE_SELECTOR \
        AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

@test "assume_role_step: resolves the scope role from CONTEXT and exports creds" {
  logf=$(mktemp)
  source "$STEP" >"$logf" 2>&1
  [ "$VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN" = "arn:aws:iam::111:role/voltmx-foundry-app-role" ]
  [ "$AWS_ACCESS_KEY_ID" = "AKIA1" ]
  [ "$AWS_SECRET_ACCESS_KEY" = "sec1" ]
  [ "$AWS_SESSION_TOKEN" = "tok1" ]
  assert_contains "$(cat "$logf")" "   🔑 Assuming role: arn:aws:iam::111:role/voltmx-foundry-app-role"
  assert_contains "$(cat "$logf")" "   ✅ Role assumed successfully"
}

@test "assume_role_step: no IAM provider in CONTEXT is not an error (agent creds remain)" {
  export CONTEXT='{"providers":{}}'
  logf=$(mktemp)
  source "$STEP" >"$logf" 2>&1
  [ -z "${AWS_ACCESS_KEY_ID:-}" ]
  [ -z "$VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN" ]
  assert_contains "$(cat "$logf")" "   ✅ assume_role=skipped (using agent credentials)"
}

@test "assume_role_step: uses the dimension-resolved provider already in CONTEXT" {
  # The platform injects whichever IAM config matched the scope's dimensions;
  # the step just reads it. Here the resolved config carries a region-specific role.
  export CONTEXT='{"providers":{"identity-access-control":{"iam_role_arns":{"arns":[{"selector":"voltmx-foundry-app","arn":"arn:aws:iam::111:role/us-east-1-role"}]}}}}'
  logf=$(mktemp)
  source "$STEP" >"$logf" 2>&1
  [ "$VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN" = "arn:aws:iam::111:role/us-east-1-role" ]
  assert_contains "$(cat "$logf")" "   🔑 Assuming role: arn:aws:iam::111:role/us-east-1-role"
  assert_contains "$(cat "$logf")" "   ✅ Role assumed successfully"
}

@test "assume_role_step: honors VOLTMX_FOUNDRY_APP_ASSUME_ROLE_SELECTOR override" {
  export VOLTMX_FOUNDRY_APP_ASSUME_ROLE_SELECTOR="custom"
  export CONTEXT='{"providers":{"identity-access-control":{"iam_role_arns":{"arns":[{"selector":"custom","arn":"arn:aws:iam::111:role/custom-role"}]}}}}'
  logf=$(mktemp)
  source "$STEP" >"$logf" 2>&1
  [ "$VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN" = "arn:aws:iam::111:role/custom-role" ]
}

@test "assume_role_step: pre-set VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN overrides provider resolution" {
  export VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN="arn:aws:iam::111:role/explicit-override"
  logf=$(mktemp)
  source "$STEP" >"$logf" 2>&1
  [ "$VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN" = "arn:aws:iam::111:role/explicit-override" ]
  [ "$AWS_ACCESS_KEY_ID" = "AKIA1" ]
}

@test "assume_role_step: exits non-zero with full hints when sts:AssumeRole fails" {
  aws() {
    case "$*" in
      *"sts assume-role"*) echo "AccessDenied" >&2; return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f aws
  run bash -c "source '$STEP'"
  [ "$status" -ne 0 ]
  assert_contains "$output" "   ❌ assume_role step failed: could not assume arn:aws:iam::111:role/voltmx-foundry-app-role"
  assert_contains "$output" "💡 Possible causes:"
  assert_contains "$output" "   • The agent's role is not allowed to sts:AssumeRole the target role"
  assert_contains "$output" "   • The target role does not exist or does not trust the agent role"
  assert_contains "$output" "   • There is no role ARN configured for selector=voltmx-foundry-app"
}
