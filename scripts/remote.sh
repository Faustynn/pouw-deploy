#!/usr/bin/env bash
# The only command the SSH key from GitHub Actions (Deploy workflow) may run.
# In ~/.ssh/authorized_keys on the server:
#
#   command="/home/<user>/pouw/pouw-deploy/scripts/remote.sh",restrict ssh-ed25519 AAAA... github-actions
#
# Allowed commands (arrive in SSH_ORIGINAL_COMMAND), the network first:
#   [staging|dev] deploy <sha> [NODE_VERSION=sha-xxxxxxx ...]
#                  deploys a commit of pouw-deploy (an older one = rollback)
#                  with the given service versions (without them :main from GHCR).
#                  If the new version does not start, fails the smoke tests
#                  (Hasura metadata, nothing to write for anonymous clients, ...)
#                  or a service answers another commit at /manage/info than its
#                  version, the previous one is restored.
#   [staging|dev] restart        restarts the services with the current version
#   [staging|dev] status         container status, the deployed version and the default load
#   [staging|dev] load <scenario|off>
#                  switches the default load (workload-driver) at once
#
# staging (the default) is this checkout, compose project pouw, and deploys only
# commits of main. dev is the checkout ../pouw-deploy-dev next to it (project
# pouw-dev, scripts/dev-setup.sh) and deploys a commit of any branch of PoUW-ZK,
# so a branch of pouw-deploy can be tried there too.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
read -r -a args <<<"${SSH_ORIGINAL_COMMAND:-}"
target=staging
if [[ "${args[0]:-}" == staging || "${args[0]:-}" == dev ]]; then
    target="${args[0]}"
    args=("${args[@]:1}")
fi
action="${args[0]:-}"

case "$target" in
    staging)
        project=pouw
        cd "$root"
        ;;
    dev)
        project=pouw-dev
        if [[ ! -d "$root/../pouw-deploy-dev/.git" ]]; then
            echo "The dev network is not set up: scripts/dev-setup.sh" >&2
            exit 2
        fi
        cd "$root/../pouw-deploy-dev"
        ;;
esac

status() {
    echo "Network: $target ($project)"
    echo "Deployed version: $(git rev-parse HEAD)"
    [[ -s versions.env ]] && cat versions.env
    echo "Default load: $(sed -n 's/^LOAD_SCENARIO=//p' load.env 2>/dev/null | grep . || echo transfers-steady)"
    docker compose ps --format 'table {{.Service}}\t{{.Status}}'
}

# The commit every service answers at /manage/info starts with the sha of its
# version (Hasura has no /manage/info, its image is the one of the dashboard)
verify_versions() {
    local v var sha hosts host got
    for v in "$@"; do
        var="${v%%=*}"
        sha="${v#*=sha-}"
        case "$var" in
            NODE_VERSION) hosts="node-1:8000 node-2:8000 node-3:8000" ;;
            INDEXER_VERSION) hosts="indexer:8000" ;;
            WORKLOAD_VERSION) hosts="workload:8000" ;;
            DASHBOARD_VERSION) hosts="dashboard:8080" ;;
            *) continue ;;
        esac
        for host in $hosts; do
            got="$(docker run --rm --network "${project}_default" curlimages/curl:8.17.0 -fsS --max-time 10 \
                "http://$host/manage/info" | grep -oE '"commit": *"[0-9a-f]+' | grep -oE '[0-9a-f]+$')" || got=""
            if [[ "$got" != "$sha"* ]]; then
                echo "FAIL  ${host%%:*} runs commit ${got:-unknown}, expected $sha ($var)" >&2
                return 1
            fi
            echo "ok    ${host%%:*} runs $sha"
        done
    done
}

deploy() {
    local sha="${1:-}" prev v
    shift || true
    if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        echo "deploy needs a full commit SHA" >&2
        exit 2
    fi
    for v in "$@"; do
        if [[ ! "$v" =~ ^(NODE|INDEXER|WORKLOAD|DASHBOARD|DASHBOARD_HASURA)_VERSION=sha-[0-9a-f]{7}$ ]]; then
            echo "Invalid service version: $v" >&2
            exit 2
        fi
    done
    if [[ "$target" == staging ]]; then
        git fetch -q origin main
        if ! git merge-base --is-ancestor "$sha" origin/main; then
            echo "Commit $sha is not in main" >&2
            exit 2
        fi
    else
        git fetch -q --prune origin '+refs/heads/*:refs/remotes/origin/*'
        if [[ -z "$(git branch -r --contains "$sha" 2>/dev/null)" ]]; then
            echo "Commit $sha is on no branch of PoUW-ZK/pouw-deploy" >&2
            exit 2
        fi
    fi

    prev="$(git rev-parse HEAD)"
    cp versions.env versions.env.prev 2>/dev/null || : >versions.env.prev
    git checkout -q --detach "$sha"
    # The Makefile loads versions.env, so the versions also apply to `make restart`
    printf '%s\n' "$@" >versions.env
    # The Hasura image applies its metadata on start and does not start with
    # metadata that does not match the schema, so `make up` covers that too
    if ! { make up && ./e2e/smoke.sh "$project" && verify_versions "$@"; }; then
        echo "Deploy failed, restoring the previous version $prev" >&2
        git checkout -q --detach "$prev"
        mv -f versions.env.prev versions.env
        make up || true
        echo "$(date -u +%FT%TZ) $sha failed, rolled back to $prev" >>deploy-history.log
        exit 1
    fi
    echo "$(date -u +%FT%TZ) $sha $*" >>deploy-history.log
}

case "$action" in
    deploy)
        deploy "${args[@]:1}"
        status
        ;;
    restart | status)
        ((${#args[@]} == 1)) || { echo "Too many arguments" >&2; exit 2; }
        [[ "$action" == restart ]] && make restart
        status
        ;;
    load)
        scenario="${args[1]:-}"
        ((${#args[@]} == 2)) || { echo "load needs one scenario (or off)" >&2; exit 2; }
        # A forced command: the name goes into make, so only plain names
        [[ "$scenario" =~ ^[a-z0-9-]+$ ]] || { echo "Invalid scenario: $scenario" >&2; exit 2; }
        if [[ "$scenario" == off ]]; then
            make load-stop
        else
            make load-start SCENARIO="$scenario"
        fi
        status
        ;;
    *)
        echo "Unknown command: ${action:-<empty>} ([staging|dev] deploy <sha> [versions] | restart | status | load <scenario|off>)" >&2
        exit 2
        ;;
esac
