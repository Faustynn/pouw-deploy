#!/usr/bin/env bash
# Builds Docker images of the services from the current main of their repositories:
#
#   make images IMAGE_TAG=local
#
# Images are tagged ghcr.io/pouw-zk/<repository>:$IMAGE_TAG and make uses them
# with the same IMAGE_TAG instead of :main from GHCR (e.g. make images test).
# NO_CACHE=1 builds from scratch, without Docker cache (evening build in Jenkins).
#
# An image whose directory has no Dockerfile yet, or whose required file is
# missing, is skipped. The commits that were built are listed in build/versions.txt,
# the versions for staging (:sha-xxxxxxx images in GHCR, built by docker.yml from
# the same commits) in build/versions.env as <IMAGE>_VERSION, e.g.
# pouw-dashboard-hasura -> DASHBOARD_HASURA_VERSION.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${IMAGE_TAG:?Set IMAGE_TAG, e.g. make images IMAGE_TAG=local}"
build="$root/build"

# repository      directory with Dockerfile  image                  required file
images=(
    "pouw-node      .       pouw-node              Dockerfile"
    "pouw-indexer   .       pouw-indexer           Dockerfile"
    "pouw-workload  .       pouw-workload          Dockerfile"
    "pouw-dashboard web     pouw-dashboard         web/package.json"
    "pouw-dashboard hasura  pouw-dashboard-hasura  hasura/metadata/version.yaml"
)

flags=(--pull)
[[ "${NO_CACHE:-}" == 1 ]] && flags+=(--no-cache)

mkdir -p "$build"
: >"$build/versions.txt"
: >"$build/versions.env"
cloned=" "
for entry in "${images[@]}"; do
    read -r repo dir image requires <<<"$entry"
    src="$build/src/$repo"
    if [[ "$cloned" != *" $repo "* ]]; then
        rm -rf "$src"
        git clone -q --depth 1 "https://github.com/PoUW-ZK/$repo.git" "$src"
        cloned+="$repo "
    fi
    sha="$(git -C "$src" rev-parse --short=7 HEAD)"
    if [[ ! -f "$src/$dir/Dockerfile" || ! -f "$src/$requires" ]]; then
        echo "$image $sha (no $dir/Dockerfile or $requires, skipped)" | tee -a "$build/versions.txt"
        continue
    fi
    docker build "${flags[@]}" \
        --label "org.opencontainers.image.revision=$sha" \
        -t "ghcr.io/pouw-zk/$image:$tag" "$src/$dir"
    echo "$image $sha" | tee -a "$build/versions.txt"
    echo "$(echo "${image#pouw-}" | tr a-z- A-Z_)_VERSION=sha-$sha" >>"$build/versions.env"
done
