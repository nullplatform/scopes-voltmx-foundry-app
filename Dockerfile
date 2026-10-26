# syntax=docker/dockerfile:1
# Worker image: the bridge runs the root entrypoint on every action. Add the tools your steps need.
FROM public.ecr.aws/nullplatform/scopes/worker-bridge:2.0.6

# Foundry tooling (Alpine base; bash, jq, unzip, curl and a busybox `timeout`
# come with the bridge):
#   openjdk17-jre-headless  runtime of mfcli.jar, the HCL Volt MX Foundry CLI
#   aws-cli                 download the exported app (s3) and read the technical user (secretsmanager)
#   zip                     the mfcli mock builds export zips with it (POC and tests)
#
# mfcli.jar is NOT in this image: HCL does not allow redistributing it. A real
# deployment bakes it into a derived image (COPY mfcli.jar $MFCLI_JAR) or mounts
# it at $MFCLI_JAR, and keeps MFCLI_CMD="java -jar /opt/mfcli/mfcli.jar"
# (values.yaml). The POC runs the mock instead: tools/mfcli-mock/mfcli ships
# with the scope at /app/pkg/voltmx-foundry-app/tools/mfcli-mock/mfcli and is
# selected with mfcli.command in the scope configuration (or MFCLI_CMD in the
# worker environment); its state lives in MFCLI_MOCK_STATE (default
# /tmp/mfcli-mock-state, inside the worker: enough for one session).
USER root
RUN apk add --no-cache openjdk17-jre-headless aws-cli zip \
    && java -version 2>&1 | head -n 1 \
    && aws --version

# --chown: np chmods the action script in place, so the tree must belong to the runtime uid.
COPY --chown=10001:10001 . /app/pkg
ENV NP_PACKAGE_NAME=voltmx-foundry-app \
    NP_SERVICE_PATH=/app/pkg/voltmx-foundry-app \
    NP_SCOPE_ENTRYPOINT=/app/pkg/entrypoint \
    MFCLI_JAR=/opt/mfcli/mfcli.jar

# Numeric so runAsNonRoot admission can verify it; worker-bridge 2.0.0+ ships this user and a writable HOME.
USER 10001:10001
