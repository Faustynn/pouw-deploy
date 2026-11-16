#!/usr/bin/env bash
# e2e tests of the whole devnet (e2e/test_*.py): ./e2e/run.sh <compose project>
#
# Called by `make test` after the smoke tests, in Jenkins and locally. The same
# contract as e2e/run.sh in the service repositories: the argument is the
# compose project of the running network, JUnit XML goes to $JUNIT_DIR (here
# devnet.xml, suite devnet in Jenkins → Tests), exit code other than 0 = the
# tests failed and staging is not deployed.
#
# The tests run with pytest in a container attached to the network, so they
# reach the services by their compose name (http://node-1:8000).
set -euo pipefail

project="${1:?Usage: $0 <compose project>}"
here="$(cd "$(dirname "$0")" && pwd)"

# Created here, otherwise Docker would create it as root and cleanWs() could not delete it
mkdir -p "${JUNIT_DIR:=reports}"
junit_dir="$(cd "$JUNIT_DIR" && pwd)"

# Runs as the current user, so results are not owned by root. HOME=/tmp lets pip
# install there, the e2e directory itself is read-only.
docker run --rm \
    --network "${project}_default" \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -e E2E_PROJECT="$project" \
    -e PIP_DISABLE_PIP_VERSION_CHECK=1 \
    -e PYTHONDONTWRITEBYTECODE=1 \
    -v "$here:/e2e:ro" \
    -v "$junit_dir:/reports" \
    -w /e2e \
    python:3.12-slim \
    sh -c "pip install -q --user --no-warn-script-location -r requirements.txt &&
        python -m pytest -p no:cacheprovider -rxXs -o junit_suite_name=devnet --junitxml=/reports/devnet.xml"
