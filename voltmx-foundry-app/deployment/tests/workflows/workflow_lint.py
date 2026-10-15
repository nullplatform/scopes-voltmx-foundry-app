"""Static checks of the voltmx-foundry-app workflows, run by workflows_test.bats.

usage: python3 workflow_lint.py <scope dir> <check> <workflow yaml>...

checks:
  files    every script step names a file that exists under $SERVICE_PATH; an
           executor step names folders whose workflow.yml lists existing files
  outputs  every variable a step consumes (CONSUMES below) is declared in the
           output of an earlier step, or comes from the engine (ENGINE_PROVIDED
           and the configuration of the included values.yaml)
  consumes every variable CONSUMES lists really appears in the files of that
           consumer (keeps the table honest)

Includes are resolved like np service workflow exec does: the included
workflows come first, and a step of the including workflow is inserted
before/after the named step, replaces a step with its name, or is appended.
"""
import glob
import os
import re
import sys

import yaml

ENGINE_PROVIDED = {"SERVICE_PATH", "CONTEXT", "NP_ACTION_CONTEXT", "SCOPE_ID", "DEPLOYMENT_ID",
                   "SERVICE_ACTION", "SERVICE_ACTION_TYPE", "NOTIFICATION_ACTION"}
AWS = ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN"]
# What every mfcli call needs (mfcli_run) plus the app and environment it targets.
MFCLI = ["MFCLI_USER", "MFCLI_PASSWORD", "MFCLI_AUTH_ARGS", "FOUNDRY_APP", "ENVIRONMENT_NAME"]
MFCLI_RUN = "deployment/scripts/mfcli_run"

# consumer key -> (variables it consumes, files/globs that consume them, relative to the scope dir)
CONSUMES = {
    "fetch_asset": (
        AWS + ["ASSET_URL", "WORKDIR", "ASSETS_BUCKET", "ASSETS_REGION", "ASSETS_PREFIX", "FOUNDRY_APP", "APP_VERSION"],
        ["deployment/scripts/fetch_asset", "deployment/scripts/download_asset", "deployment/scripts/validators"]),
    "read_credentials": (
        AWS + ["CREDENTIALS_SECRET", "SECRETS_PREFIX", "ASSETS_REGION"],
        ["deployment/scripts/read_credentials", "deployment/scripts/validators"]),
    "render_profile": (
        ["PROFILE_VARS", "WORKDIR", "FOUNDRY_APP", "ENVIRONMENT_NAME", "APP_VERSION"],
        ["deployment/scripts/render_profile"]),
    "do_import": (MFCLI + ["FOUNDRY_ZIP", "APP_VERSION"], ["deployment/scripts/do_import", MFCLI_RUN]),
    "do_reconfig": (MFCLI + ["WORKDIR"], ["deployment/scripts/do_reconfig", MFCLI_RUN]),
    "do_publish": (MFCLI + ["APP_VERSION"], ["deployment/scripts/do_publish", MFCLI_RUN]),
    "wait_publish": (MFCLI + ["APP_VERSION"], ["deployment/scripts/wait_publish", MFCLI_RUN]),
    "export_outputs": (
        MFCLI + ["APP_VERSION", "DEPLOYMENT_ID", "WORKDIR"],
        ["deployment/scripts/export_outputs", MFCLI_RUN]),
    "do_rollback": (
        MFCLI + ["PREVIOUS_RELEASE_SEMVER", "PREVIOUS_DEPLOYMENT_ID"],
        ["deployment/scripts/do_rollback", "deployment/scripts/wait_publish", MFCLI_RUN,
         "deployment/scripts/validators"]),
    # do_unpublish consumes different variables per UNPUBLISH_MODE (consumer_key tells them apart).
    "do_unpublish:scope": (MFCLI + ["APP_VERSION", "SCOPE_ID"], ["deployment/scripts/do_unpublish", MFCLI_RUN]),
    # Deployment mode restores the previous release through do_rollback when the deleted one is active.
    "do_unpublish:deployment": (
        MFCLI + ["APP_VERSION", "SCOPE_ID", "DEPLOYMENT_ID", "PREVIOUS_RELEASE_SEMVER", "PREVIOUS_DEPLOYMENT_ID",
                 "PREVIOUS_DEPLOYMENT_LOOKUP"],
        ["deployment/scripts/do_unpublish", "deployment/scripts/do_rollback", "deployment/scripts/wait_publish",
         "deployment/scripts/validators", MFCLI_RUN]),
    "instance_list": (MFCLI + ["WORKDIR_BASE", "WORKDIR"], ["instance/scripts/list", MFCLI_RUN]),
    # The checks read the credentials themselves (credentials_valid sources read_credentials).
    "diagnose_checks": (
        AWS + ["MFCLI_AUTH_ARGS", "CREDENTIALS_SECRET", "SECRETS_PREFIX", "ASSETS_REGION",
               "FOUNDRY_APP", "ENVIRONMENT_NAME"],
        ["diagnose/checks/console_reachable", "diagnose/checks/credentials_valid",
         "diagnose/checks/app_published", "deployment/scripts/read_credentials", MFCLI_RUN]),
}


def load(path, scope):
    with open(path) as f:
        workflow = yaml.safe_load(f) or {}
    steps, configuration = [], {}
    for include in workflow.get("include") or []:
        included_steps, included_configuration = load(include.replace("$SERVICE_PATH", scope), scope)
        steps = merge(steps, included_steps)
        configuration.update(included_configuration)
    configuration.update(workflow.get("configuration") or {})
    return merge(steps, workflow.get("steps") or []), configuration


def merge(base, overrides):
    base = list(base)
    for step in overrides:
        names = [s.get("name") for s in base]
        if step.get("before") in names:
            base.insert(names.index(step["before"]), step)
        elif step.get("after") in names:
            base.insert(names.index(step["after"]) + 1, step)
        elif step.get("name") in names:
            base[names.index(step["name"])] = step
        else:
            base.append(step)
    return base


def consumer_key(step):
    if step.get("type") == "executor":
        return "diagnose_checks"
    file = os.path.basename(step.get("file", ""))
    if file == "list" and "/instance/" in step.get("file", ""):
        return "instance_list"
    if file == "do_unpublish":
        return "do_unpublish:" + str((step.get("configuration") or {}).get("UNPUBLISH_MODE", ""))
    return file


def outputs(step):
    return {o["name"] for o in step.get("output") or [] if o.get("type") == "environment"}


def executor_files(scope, step):
    """The script files an executor step runs: the notifiers and the steps of each folder's workflow.yml."""
    files, errors = [], []
    for hook in ("before_each", "after_each"):
        if step.get(hook):
            files.append(step[hook].get("file", ""))
    for folder in step.get("folders") or []:
        manifest = os.path.join(folder.replace("$SERVICE_PATH", scope), "workflow.yml")
        if not os.path.isfile(manifest):
            errors.append(f"executor folder {folder} has no workflow.yml")
            continue
        with open(manifest) as f:
            for check in (yaml.safe_load(f) or {}).get("steps") or []:
                files.append(check.get("file", ""))
    return files, errors


def check_files(scope, steps, path):
    errors = []
    for step in steps:
        if step.get("type") == "executor":
            files, folder_errors = executor_files(scope, step)
            errors += [f"{path}: step '{step.get('name')}': {e}" for e in folder_errors]
        elif step.get("type") == "script":
            files = [step.get("file", "")]
        else:
            continue
        for file in files:
            if not os.path.isfile(file.replace("$SERVICE_PATH", scope)):
                errors.append(f"{path}: step '{step.get('name')}' runs a missing file {file}")
    return errors


def check_outputs(scope, steps, configuration, path):
    errors, available = [], set(ENGINE_PROVIDED) | set(configuration)
    for step in steps:
        key = consumer_key(step)
        for var in CONSUMES.get(key, ([], []))[0]:
            if var not in available:
                errors.append(f"{path}: step '{step.get('name')}' consumes {var}, which no earlier step declares in its output")
        available |= outputs(step)
    return errors


def check_consumes(scope):
    errors = []
    for key, (variables, patterns) in CONSUMES.items():
        text = ""
        for pattern in patterns:
            files = glob.glob(os.path.join(scope, pattern))
            if not files:
                errors.append(f"{key}: no file matches {pattern}")
            for file in files:
                with open(file) as f:
                    text += f.read()
        for var in variables:
            if var in AWS:
                if not re.search(r"\baws\s", text):
                    errors.append(f"{key}: listed as consuming {var} but never calls aws")
                continue
            if not re.search(r"\b" + re.escape(var) + r"\b", text):
                errors.append(f"{key}: listed as consuming {var} but its files never reference it")
    return errors


def main():
    scope, check, paths = sys.argv[1], sys.argv[2], sys.argv[3:]
    errors = []
    if check == "consumes":
        errors = check_consumes(scope)
    for path in paths:
        steps, configuration = load(path, scope)
        if not steps:
            errors.append(f"{path}: no steps")
        if check == "files":
            errors += check_files(scope, steps, path)
        elif check == "outputs":
            errors += check_outputs(scope, steps, configuration, path)
    for error in errors:
        print(error)
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
