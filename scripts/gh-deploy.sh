#!/usr/bin/env bash
# Runs the Deploy workflow (GitHub Actions → SSH → scripts/remote.sh on the
# server) and waits for its result. Called by Jenkins:
#
#   GH_TOKEN=<token GitHub App> ./scripts/gh-deploy.sh <staging|dev> deploy <sha of pouw-deploy>
#   GH_TOKEN=<token GitHub App> ./scripts/gh-deploy.sh <staging|dev> load <scenario|off>
#
# deploy takes the service versions from build/versions.env (scripts/build-images.sh).
# The GitHub App needs the Actions: Read and write permission.
set -euo pipefail

target="${1:?Usage: $0 <staging|dev> deploy <sha> | load <scenario|off>}"
action="${2:?Usage: $0 <staging|dev> deploy <sha> | load <scenario|off>}"
arg="${3:?Usage: $0 <staging|dev> deploy <sha> | load <scenario|off>}"
repo="PoUW-ZK/pouw-deploy"
api="https://api.github.com/repos/$repo/actions"
# Part of the run name, so this run is found even when another one starts in
# the same minute (the dispatch API does not return the run)
request="${BUILD_TAG:-manual}-$(date +%s)"

[[ "$target" == staging || "$target" == dev ]] || { echo "Unknown network: $target" >&2; exit 2; }
case "$action" in
    deploy)
        [[ "$arg" =~ ^[0-9a-f]{40}$ ]] || { echo "deploy needs a full commit SHA" >&2; exit 2; }
        versions="$(paste -sd ' ' build/versions.env)"
        inputs="$(jq -n --arg t "$target" --arg sha "$arg" --arg v "$versions" --arg r "$request" \
            '{target: $t, action: "deploy", sha: $sha, versions: $v, request: $r}')"
        echo "Deploying $arg to $target: $versions"
        ;;
    load)
        [[ "$arg" =~ ^[a-z0-9-]+$ ]] || { echo "Invalid scenario: $arg" >&2; exit 2; }
        inputs="$(jq -n --arg t "$target" --arg s "$arg" --arg r "$request" \
            '{target: $t, action: "load", scenario: $s, request: $r}')"
        echo "Default load of $target: $arg"
        ;;
    *)
        echo "Unknown action: $action (deploy or load)" >&2
        exit 2
        ;;
esac

gh_api() {
    curl -fsS -H "Authorization: Bearer $GH_TOKEN" \
        -H "Accept: application/vnd.github+json" "$@"
}

since="$(date -u -d '2 minutes ago' +%FT%TZ)"
jq -n --argjson inputs "$inputs" '{ref: "main", inputs: $inputs}' |
    gh_api -X POST "$api/workflows/deploy.yml/dispatches" --data @-

run=""
for _ in $(seq 30); do
    sleep 10
    run="$(gh_api "$api/workflows/deploy.yml/runs?event=workflow_dispatch&created=%3E%3D$since" |
        jq -r --arg r "[$request]" '[.workflow_runs[] | select(.display_title | endswith($r))][0].id // empty')"
    [[ -n "$run" ]] && break
done
[[ -n "$run" ]] || { echo "Deploy workflow run not found" >&2; exit 1; }
echo "Deploy workflow: https://github.com/$repo/actions/runs/$run"

while :; do
    read -r state conclusion < <(gh_api "$api/runs/$run" | jq -r '"\(.status) \(.conclusion)"')
    [[ "$state" == completed ]] && break
    sleep 15
done
echo "Result: $conclusion"
[[ "$conclusion" == success ]]
