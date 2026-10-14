#!/usr/bin/env bats
# =============================================================================
# Unit tests for utils/assume_role - performs sts:AssumeRole, exports AWS_*.
#
# Success paths source the helper IN-PROCESS and assert the exported env vars
# directly (closest to how the workflow consumes them); output is captured to a
# file so every message is asserted in full. Failure paths use `run` to capture
# the non-zero status and the error message.
# =============================================================================

setup() {
  export PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  source "$PROJECT_ROOT/testing/assertions.sh"
  export HELPER="$BATS_TEST_DIRNAME/../assume_role"

  export SCOPE_ID="scope-123"
  unset VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

  # Mock aws sts assume-role - success by default
  aws() {
    case "$*" in
      *"sts assume-role"*)
        echo '{"Credentials":{"AccessKeyId":"AKIAEXAMPLE","SecretAccessKey":"secret123","SessionToken":"token123"}}'
        return 0
        ;;
      *) return 0 ;;
    esac
  }
  export -f aws
}

teardown() {
  unset VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

@test "assume_role: no-op when VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN is empty (uses agent creds)" {
  logf=$(mktemp)
  source "$HELPER" >"$logf" 2>&1
  # No credentials exported — the agent's own credentials stay in effect.
  [ -z "${AWS_ACCESS_KEY_ID:-}" ]
  [ -z "${AWS_SECRET_ACCESS_KEY:-}" ]
  [ -z "${AWS_SESSION_TOKEN:-}" ]
  assert_contains "$(cat "$logf")" "   ✅ assume_role=skipped (using agent credentials)"
}

@test "assume_role: no-op when VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN is none (keeps the credentials in the environment)" {
  export VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN=none
  export AWS_ACCESS_KEY_ID="mine"
  logf=$(mktemp)
  source "$HELPER" >"$logf" 2>&1
  # The mock would have exported AKIAEXAMPLE had sts:AssumeRole been called.
  assert_equal "$AWS_ACCESS_KEY_ID" "mine"
  [ -z "${AWS_SESSION_TOKEN:-}" ]
  grep -q "assume_role=skipped" "$logf"
  rm -f "$logf"
}

@test "assume_role: exports AWS_* and logs all messages when ARN is set" {
  export VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN="arn:aws:iam::111:role/voltmx-foundry-app-role"
  logf=$(mktemp)
  source "$HELPER" >"$logf" 2>&1
  # Exported env vars asserted directly (no echo).
  [ "$AWS_ACCESS_KEY_ID" = "AKIAEXAMPLE" ]
  [ "$AWS_SECRET_ACCESS_KEY" = "secret123" ]
  [ "$AWS_SESSION_TOKEN" = "token123" ]
  # Every user-facing message asserted in full, including emojis.
  assert_contains "$(cat "$logf")" "   🔑 Assuming role: arn:aws:iam::111:role/voltmx-foundry-app-role"
  assert_contains "$(cat "$logf")" "   ✅ Role assumed successfully"
}

@test "assume_role: returns non-zero and logs error when sts:AssumeRole fails" {
  export VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN="arn:aws:iam::111:role/voltmx-foundry-app-role"
  aws() {
    case "$*" in
      *"sts assume-role"*) echo "AccessDenied" >&2; return 1 ;;
      *) return 0 ;;
    esac
  }
  export -f aws
  run bash -c "source '$HELPER'"
  [ "$status" -ne 0 ]
  assert_contains "$output" "   ❌ sts:AssumeRole failed for arn:aws:iam::111:role/voltmx-foundry-app-role"
}

@test "assume_role: returns non-zero and logs error on malformed STS JSON" {
  export VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN="arn:aws:iam::111:role/voltmx-foundry-app-role"
  aws() { echo "not-json"; return 0; }
  export -f aws
  run bash -c "source '$HELPER'"
  [ "$status" -ne 0 ]
  assert_contains "$output" "   ❌ sts:AssumeRole returned incomplete credentials for arn:aws:iam::111:role/voltmx-foundry-app-role"
}

@test "assume_role: returns non-zero when sts JSON lacks Credentials" {
  export VOLTMX_FOUNDRY_APP_ASSUME_ROLE_ARN="arn:aws:iam::111:role/voltmx-foundry-app-role"
  aws() { echo '{}'; return 0; }
  export -f aws
  run bash -c "source '$HELPER'"
  [ "$status" -ne 0 ]
  assert_contains "$output" "   ❌ sts:AssumeRole returned incomplete credentials for arn:aws:iam::111:role/voltmx-foundry-app-role"
}
