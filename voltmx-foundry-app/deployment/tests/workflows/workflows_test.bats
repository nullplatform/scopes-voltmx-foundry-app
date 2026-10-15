#!/usr/bin/env bats
# =============================================================================
# Static tests of the workflows (deployment, scope, instance, diagnose) and of
# the action routing of service/{scope,deployment}/entrypoint.
#
# The checks live in workflow_lint.py (python3 + PyYAML): every step file
# exists, every variable a step consumes is declared in the output of an
# earlier step, and the consumer table is honest. The routing tests run the
# real handlers with an np mock that records the workflow it was given.
#
# Run: bats voltmx-foundry-app/deployment/tests/workflows/workflows_test.bats
# =============================================================================

setup() {
	TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
	DEPLOYMENT_DIR="$(cd "$TEST_DIR/../.." && pwd)"
	SCOPE_DIR="$(cd "$DEPLOYMENT_DIR/.." && pwd)"
	PROJECT_ROOT="$(cd "$SCOPE_DIR/.." && pwd)"
	source "$PROJECT_ROOT/testing/assertions.sh"
	source "$DEPLOYMENT_DIR/tests/helpers.bash"
	LINT="$TEST_DIR/workflow_lint.py"

	if ! python3 -c 'import yaml' 2>/dev/null; then
		skip "python3 with PyYAML is required for the workflow checks"
	fi
	export PYTHONDONTWRITEBYTECODE=1
	TEST_TMP_DIR=$(mktemp -d)
}

teardown() {
	rm -rf "${TEST_TMP_DIR:-}"
}

all_workflows() {
	find "$SCOPE_DIR" -path '*/workflows/*.yaml' -not -path '*/tests/*' | sort
}

lint() {
	run python3 "$LINT" "$SCOPE_DIR" "$@"
}

# steps <workflow path>: one line per step as name:BUILD_CONTEXT_MODE or name:UNPUBLISH_MODE
step_summary() {
	run python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import workflow_lint
steps, _ = workflow_lint.load(sys.argv[2], sys.argv[3])
print(",".join("%s:%s" % (s["name"], (s.get("configuration") or {}).get("BUILD_CONTEXT_MODE", (s.get("configuration") or {}).get("UNPUBLISH_MODE", ""))) for s in steps))
' "$TEST_DIR" "$1" "$SCOPE_DIR"
}

@test "Should have every workflow the README routes to" {
	for workflow in deployment/workflows/{initial,rollback,delete}.yaml \
		scope/workflows/{create,update,delete,diagnose}.yaml instance/workflows/list.yaml; do
		assert_file_exists "$SCOPE_DIR/$workflow"
	done
}

@test "Should parse every workflow and run only files that exist" {
	# shellcheck disable=SC2046
	lint files $(all_workflows)

	assert_equal "$output" ""
	assert_equal "$status" "0"
}

@test "Should declare every consumed variable in the output of an earlier step" {
	# shellcheck disable=SC2046
	lint outputs $(all_workflows)

	assert_equal "$output" ""
	assert_equal "$status" "0"
}

@test "Should keep the consumer table in sync with the scripts" {
	lint consumes

	assert_equal "$output" ""
	assert_equal "$status" "0"
}

@test "Should require the delete-deployment workflow to declare what the restore through do_rollback consumes" {
	python3 -c '
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
for step in workflow["steps"]:
    if step["name"] == "build context":
        step["output"] = [o for o in step["output"] if o["name"] not in ("PREVIOUS_RELEASE_SEMVER", "PREVIOUS_DEPLOYMENT_LOOKUP")]
workflow["include"] = []
yaml.safe_dump(workflow, open(sys.argv[2], "w"))
' "$SCOPE_DIR/deployment/workflows/delete.yaml" "$TEST_TMP_DIR/delete.yaml"

	lint outputs "$TEST_TMP_DIR/delete.yaml"

	assert_equal "$status" "1"
	assert_line "$TEST_TMP_DIR/delete.yaml: step 'restore or unpublish' consumes PREVIOUS_RELEASE_SEMVER, which no earlier step declares in its output"
	assert_line "$TEST_TMP_DIR/delete.yaml: step 'restore or unpublish' consumes PREVIOUS_DEPLOYMENT_LOOKUP, which no earlier step declares in its output"

	# delete-scope never restores: its build context (scope mode) has no previous deployment to declare.
	lint outputs "$SCOPE_DIR/scope/workflows/delete.yaml"
	assert_equal "$output" ""
	assert_equal "$status" "0"
}

@test "Should catch a variable that is no longer declared as an output" {
	python3 -c '
import sys, yaml
workflow = yaml.safe_load(open(sys.argv[1]))
for step in workflow["steps"]:
    if step["name"] == "fetch asset":
        del step["output"]
    if step["name"] == "assume role":
        step["output"] = [o for o in step["output"] if o["name"] != "AWS_SESSION_TOKEN"]
workflow["include"] = []
yaml.safe_dump(workflow, open(sys.argv[2], "w"))
' "$SCOPE_DIR/deployment/workflows/initial.yaml" "$TEST_TMP_DIR/initial.yaml"

	lint outputs "$TEST_TMP_DIR/initial.yaml"

	assert_equal "$status" "1"
	assert_line "$TEST_TMP_DIR/initial.yaml: step 'import' consumes FOUNDRY_ZIP, which no earlier step declares in its output"
	assert_line "$TEST_TMP_DIR/initial.yaml: step 'fetch asset' consumes AWS_SESSION_TOKEN, which no earlier step declares in its output"
}

@test "Should catch an executor folder without a manifest or with a missing check" {
	mkdir -p "$TEST_TMP_DIR/checks"
	printf 'steps:\n  - name: Ghost\n    type: script\n    file: "$SERVICE_PATH/diagnose/checks/ghost"\n' > "$TEST_TMP_DIR/checks/workflow.yml"
	cat > "$TEST_TMP_DIR/diagnose.yaml" <<EOF
steps:
  - name: diagnose
    type: executor
    before_each:
      name: notify_check_running
      type: script
      file: "\$SERVICE_PATH/diagnose/notify_check_running"
    folders:
      - "$TEST_TMP_DIR/checks"
      - "$TEST_TMP_DIR/empty"
EOF

	lint files "$TEST_TMP_DIR/diagnose.yaml"

	assert_equal "$status" "1"
	assert_line "$TEST_TMP_DIR/diagnose.yaml: step 'diagnose' runs a missing file \$SERVICE_PATH/diagnose/checks/ghost"
	assert_line "$TEST_TMP_DIR/diagnose.yaml: step 'diagnose': executor folder $TEST_TMP_DIR/empty has no workflow.yml"
}

@test "Should run the initial steps in the documented order" {
	step_summary "$SCOPE_DIR/deployment/workflows/initial.yaml"

	assert_equal "$status" "0"
	assert_equal "$output" "assume role:,build context:,fetch asset:,read credentials:,import:,render profile:,apply profile:,publish:,wait publish:,export outputs:"
}

@test "Should run the scope context and the credentials check on create and update, and nothing in Foundry" {
	for action in create update; do
		step_summary "$SCOPE_DIR/scope/workflows/$action.yaml"

		assert_equal "$output" "assume role:,build context:scope,read credentials:"
	done
}

@test "Should run build_context in rollback mode for rollbacks and deployment deletions, and do_unpublish with the right mode" {
	step_summary "$SCOPE_DIR/deployment/workflows/rollback.yaml"
	assert_equal "$output" "assume role:,build context:rollback,read credentials:,rollback:"

	step_summary "$SCOPE_DIR/deployment/workflows/delete.yaml"
	assert_equal "$output" "assume role:,build context:rollback,read credentials:,restore or unpublish:deployment"

	step_summary "$SCOPE_DIR/scope/workflows/delete.yaml"
	assert_equal "$output" "assume role:,build context:scope,read credentials:,unpublish:scope"
}

@test "Should keep instance:data read-only: only publish-status, never a publish, import, rollback or unpublish" {
	step_summary "$SCOPE_DIR/instance/workflows/list.yaml"
	assert_equal "$output" "reserve stdout:,assume role:,build context:scope,read credentials:,list versions:"

	run grep -hoE 'mfcli_run +(Import|Publish|Unpublish|import-config|Export)|do_publish|do_rollback|do_unpublish|do_import|do_reconfig' \
		"$SCOPE_DIR/instance/scripts/list" "$SCOPE_DIR/instance/scripts/reserve_stdout"
	assert_equal "$output" ""
	grep -q 'mfcli_run publish-status' "$SCOPE_DIR/instance/scripts/list"
}

@test "Should diagnose with an executor over diagnose/checks, after the scope context, and never exit from a check" {
	run python3 -c '
import sys, yaml
sys.path.insert(0, sys.argv[1])
import workflow_lint
steps, _ = workflow_lint.load(sys.argv[2] + "/scope/workflows/diagnose.yaml", sys.argv[2])
print(",".join("%s:%s" % (s["name"], s["type"]) for s in steps))
executor = [s for s in steps if s["type"] == "executor"][0]
print(executor["before_each"]["file"], executor["after_each"]["file"], ",".join(executor["folders"]))
print(yaml.safe_load(open(sys.argv[2] + "/scope/workflows/diagnose.yaml")).get("continue_on_error"))
checks = yaml.safe_load(open(sys.argv[2] + "/diagnose/checks/workflow.yml"))["steps"]
print(",".join(c["file"].split("/")[-1] + ":" + c["category"] for c in checks))
' "$TEST_DIR" "$SCOPE_DIR"

	assert_equal "$status" "0"
	assert_equal "${lines[0]}" "load functions:script,assume role:script,build context:script,diagnose:executor"
	assert_equal "${lines[1]}" "\$SERVICE_PATH/diagnose/notify_check_running \$SERVICE_PATH/diagnose/notify_diagnose_results \$SERVICE_PATH/diagnose/checks"
	assert_equal "${lines[2]}" "True"
	assert_equal "${lines[3]}" "console_reachable:Foundry,credentials_valid:Foundry,app_published:Foundry"

	# A check is sourced in the workflow shell: an exit would end the whole diagnose.
	run grep -nE '^[[:space:]]*exit\b' "$SCOPE_DIR"/diagnose/checks/console_reachable "$SCOPE_DIR"/diagnose/checks/credentials_valid "$SCOPE_DIR"/diagnose/checks/app_published
	assert_equal "$output" ""
}

# =============================================================================
# Routing: every action of specs/actions reaches an existing workflow
# =============================================================================
@test "Should route every action spec to an existing workflow" {
	mkdir -p "$TEST_TMP_DIR/bin"
	cat > "$TEST_TMP_DIR/bin/np" <<'MOCK'
#!/bin/bash
while [ $# -gt 0 ]; do
	if [ "$1" = "--workflow" ]; then echo "$2" > "$NP_MOCK_WORKFLOW_FILE"; fi
	shift
done
MOCK
	chmod +x "$TEST_TMP_DIR/bin/np"
	export PATH="$TEST_TMP_DIR/bin:$PATH"
	export NP_MOCK_WORKFLOW_FILE="$TEST_TMP_DIR/workflow"
	export WORKING_DIRECTORY="$PROJECT_ROOT" SERVICE_PATH="$SCOPE_DIR" OVERRIDES_PATH="" SCOPE_ID=7

	local spec slug type handler routed=0
	for spec in "$SCOPE_DIR"/specs/actions/*.json.tpl; do
		slug=$(sed -nE 's/^  "slug": "([^"]+)".*/\1/p' "$spec")
		type=$(sed -nE 's/^  "type": "([^"]+)".*/\1/p' "$spec")
		handler="scope"
		export DEPLOYMENT_ID=""
		if grep -q '"deployment_id"' "$spec"; then
			handler="deployment"
			DEPLOYMENT_ID=77
		fi
		rm -f "$NP_MOCK_WORKFLOW_FILE"

		SERVICE_ACTION="$slug" SERVICE_ACTION_TYPE="$type" run bash "$PROJECT_ROOT/service/$handler/entrypoint"

		if [ "$status" != "0" ] || [ ! -f "$NP_MOCK_WORKFLOW_FILE" ] || [ ! -f "$(cat "$NP_MOCK_WORKFLOW_FILE")" ]; then
			echo "$slug ($type, $handler) is not routed to an existing workflow: ${output}"
			return 1
		fi
		routed=$((routed + 1))
	done
	assert_equal "$routed" "7"
}

@test "Should route diagnose-scope to scope/workflows/diagnose.yaml by its type" {
	mkdir -p "$TEST_TMP_DIR/bin"
	printf '#!/bin/bash\necho "np $*" >> "%s/np_calls.log"\n' "$TEST_TMP_DIR" > "$TEST_TMP_DIR/bin/np"
	chmod +x "$TEST_TMP_DIR/bin/np"
	export PATH="$TEST_TMP_DIR/bin:$PATH"
	export WORKING_DIRECTORY="$PROJECT_ROOT" SERVICE_PATH="$SCOPE_DIR" OVERRIDES_PATH="" SCOPE_ID=7 DEPLOYMENT_ID=""

	SERVICE_ACTION="diagnose-scope" SERVICE_ACTION_TYPE="diagnose" run bash "$PROJECT_ROOT/service/scope/entrypoint"

	assert_equal "$status" "0"
	assert_mock_call "$TEST_TMP_DIR/np_calls.log" "np service workflow exec --workflow $SCOPE_DIR/scope/workflows/diagnose.yaml --build-context --include-secrets"
}

@test "Should refuse an action slug that is not a plain name before building the workflow path" {
	mkdir -p "$TEST_TMP_DIR/bin"
	printf '#!/bin/bash\necho "np $*" >> "%s/np_calls.log"\n' "$TEST_TMP_DIR" > "$TEST_TMP_DIR/bin/np"
	chmod +x "$TEST_TMP_DIR/bin/np"
	export PATH="$TEST_TMP_DIR/bin:$PATH"
	export WORKING_DIRECTORY="$PROJECT_ROOT" SERVICE_PATH="$SCOPE_DIR" OVERRIDES_PATH="" SCOPE_ID=7 DEPLOYMENT_ID=""

	SERVICE_ACTION="../../instance/workflows/list" SERVICE_ACTION_TYPE="custom" \
		run bash "$PROJECT_ROOT/service/scope/entrypoint"

	assert_equal "$status" "1"
	assert_line "Invalid scope action '../../instance/workflows/list' (slug=../../instance/workflows/list type=custom): only lowercase letters, digits, dashes and underscores are allowed"
	[ ! -f "$TEST_TMP_DIR/np_calls.log" ]

	DEPLOYMENT_ID=77 SERVICE_ACTION="../../instance/workflows/list" SERVICE_ACTION_TYPE="custom" \
		run bash "$PROJECT_ROOT/service/deployment/entrypoint"

	assert_equal "$status" "1"
	[ ! -f "$TEST_TMP_DIR/np_calls.log" ]
}
