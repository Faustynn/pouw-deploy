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
# A real transfer for test_transfer_reaches_the_explorer: signed here with the
# pouw CLI of the running node image and the test key of the contracts (seed
# 32 × 0x01, the miner of node-1) at its current nonce, to a new address
node_image="$(docker inspect "${project}-node-1-1" --format '{{.Config.Image}}')"
sender=addr:8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c
nonce="$(docker run --rm --network "${project}_default" curlimages/curl:8.17.0 -fsS \
    -H 'Accept: application/json' "http://node-1:8000/v1/accounts/$sender" |
    grep -oE '"nonce": *[0-9]+' | grep -oE '[0-9]+$')"
transfer_to="$(docker run --rm --entrypoint pouw "$node_image" keygen | grep -oE 'addr:[0-9a-f]{64}' | head -n 1)"
transfer_amount=12345
transfer="$(docker run --rm --entrypoint pouw "$node_image" transfer \
    --seed "$(printf '01%.0s' $(seq 32))" --chain-id 1 --nonce "$nonce" \
    --to "$transfer_to" --amount "$transfer_amount" --fee 10)"

docker run --rm \
    --network "${project}_default" \
    -e E2E_TRANSFER="$transfer" \
    -e E2E_TRANSFER_TO="$transfer_to" \
    -e E2E_TRANSFER_AMOUNT="$transfer_amount" \
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
