#!/usr/bin/env bash
# Waits until every image of build/versions.env is in GHCR (published by
# docker.yml of its repository for the same commit), at most MAX_WAIT seconds.
# The server pulls the images from there, so a deploy waits for them first.
#
#   ./scripts/ghcr-wait.sh [build/versions.env]
#
# NODE_VERSION=sha-abc1234 -> ghcr.io/pouw-zk/pouw-node:sha-abc1234,
# DASHBOARD_HASURA_VERSION -> pouw-dashboard-hasura. The images are public, no login.
set -euo pipefail

file="${1:-build/versions.env}"
max_wait="${MAX_WAIT:-1800}"
deadline=$((SECONDS + max_wait))

exists() {
    local token
    token="$(curl -fsS "https://ghcr.io/token?scope=repository:pouw-zk/$1:pull" | jq -r .token)" &&
        curl -fs -o /dev/null -I -H "Authorization: Bearer $token" \
            -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json" \
            "https://ghcr.io/v2/pouw-zk/$1/manifests/$2"
}

while read -r line; do
    [[ -z "$line" ]] && continue
    var="${line%%=*}"
    tag="${line#*=}"
    image="pouw-$(echo "${var%_VERSION}" | tr '[:upper:]' '[:lower:]' | tr _ -)"
    until exists "$image" "$tag"; do
        if ((SECONDS >= deadline)); then
            echo "ghcr.io/pouw-zk/$image:$tag is not there after ${max_wait}s." >&2
            echo "Is the branch pushed to PoUW-ZK and did docker.yml of $image pass?" >&2
            exit 1
        fi
        echo "Waiting for ghcr.io/pouw-zk/$image:$tag (docker.yml of its repository)"
        sleep 30
    done
    echo "ok    ghcr.io/pouw-zk/$image:$tag"
done <"$file"
