#!/usr/bin/env bash
# Builds Docker images of the services from the current main of their repositories:
#
#   make images IMAGE_TAG=local
#
# or, with SRC, from your working copies (uncommitted changes included):
#
#   make images SRC=..          # ../pouw-node, ../pouw-indexer, ...
#
# or with other branches than main (Jenkins PouwZK-dev), the rest from main:
#
#   make images REFS="pouw-indexer=feature/x pouw-node=fix/y"
#
# Every image gets GIT_COMMIT, GIT_BRANCH and BUILD_TIME as build args, the
# services show them at GET /manage/info.
#
# Images are tagged ghcr.io/pouw-zk/<repository>:$IMAGE_TAG and make uses them
# with the same IMAGE_TAG instead of :main from GHCR (e.g. make images test).
# NO_CACHE=1 builds from scratch, without Docker cache (evening build in Jenkins).
#
# An image whose directory has no Dockerfile yet, or whose required file is
# missing, is skipped: its :main from GHCR is tagged as $IMAGE_TAG instead, and
# when there is none, build/skip.yml moves the service to a profile that is
# never on, so make does not start or pull it (e.g. the dashboard before its
# web/ has a project). The commits that were built are listed in build/versions.txt,
# the versions for staging (:sha-xxxxxxx images in GHCR, built by docker.yml from
# the same commits) in build/versions.env as <IMAGE>_VERSION, e.g.
# pouw-dashboard-hasura -> DASHBOARD_HASURA_VERSION. Builds from SRC do not
# write versions.env, their commits are not in GHCR.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
tag="${IMAGE_TAG:?Set IMAGE_TAG, e.g. make images IMAGE_TAG=local}"
build="$root/build"
src_root=""
if [[ -n "${SRC:-}" ]]; then
    src_root="$(cd "$root" && cd "$SRC" && pwd)"
fi

# repository      directory with Dockerfile  image             required file                 compose services (comma-separated)
images=(
    "pouw-node      .       pouw-node              Dockerfile                    genesis,node-1,node-2,node-3"
    "pouw-indexer   .       pouw-indexer           Dockerfile                    indexer"
    "pouw-workload  .       pouw-workload          Dockerfile                    workload"
    "pouw-dashboard web     pouw-dashboard         web/package.json              dashboard"
    "pouw-dashboard hasura  pouw-dashboard-hasura  hasura/metadata/version.yaml  hasura"
)

flags=(--pull)
[[ "${NO_CACHE:-}" == 1 ]] && flags+=(--no-cache)
build_time="$(date -u +%FT%TZ)"

# REFS="pouw-indexer=feature/x ...": checked here, read by ref_of (no
# associative arrays, the bash of macOS is 3.2)
for r in ${REFS:-}; do
    if [[ ! "$r" =~ ^(pouw-[a-z]+)=([A-Za-z0-9._/-]+)$ ]]; then
        echo "Invalid entry of REFS: $r (expected pouw-<repository>=<branch>)" >&2
        exit 2
    fi
    printf '%s\n' "${images[@]}" | grep -q "^${BASH_REMATCH[1]} " ||
        { echo "REFS: unknown repository ${BASH_REMATCH[1]}" >&2; exit 2; }
done
if [[ -n "$src_root" && -n "${REFS:-}" ]]; then
    echo "REFS and SRC cannot be combined: SRC builds your working copies as they are" >&2
    exit 2
fi

# Branch of a repository from REFS, main when it is not there
ref_of() {
    local r
    for r in ${REFS:-}; do
        [[ "${r%%=*}" == "$1" ]] && { echo "${r#*=}"; return; }
    done
    echo main
}

mkdir -p "$build"
: >"$build/versions.txt"
: >"$build/versions.env"
# Written to a temporary file and moved at the end, so an interrupted build
# never leaves a half-written skip.yml for make
skip_yml="$build/skip.yml.tmp"
echo "# Services without an image, written by scripts/build-images.sh" >"$skip_yml"
echo "services:" >>"$skip_yml"

# Services that cannot run without another one: Hasura tracks the views that
# the indexer's migrations create
dependents() {
    case "$1" in
        indexer) echo hasura ;;
    esac
}

# off <service> <reason>: the service (and what needs it) does not start
stopped=" "
off() {
    local d
    [[ "$stopped" == *" $1 "* ]] && return
    stopped+="$1 "
    printf '  %s:\n    profiles: !override [no-image]\n' "$1" >>"$skip_yml"
    echo "  $1 does not start ($2)" | tee -a "$build/versions.txt"
    for d in $(dependents "$1"); do
        off "$d" "needs $1"
    done
}

# skip <image> <services> <reason>: use :main from GHCR, or do not start the services
skip() {
    if docker pull -q "ghcr.io/pouw-zk/$1:main" >/dev/null 2>&1; then
        docker tag "ghcr.io/pouw-zk/$1:main" "ghcr.io/pouw-zk/$1:$tag"
        echo "$1 ($3, using :main from GHCR)" | tee -a "$build/versions.txt"
    else
        echo "$1 ($3, not in GHCR either)" | tee -a "$build/versions.txt"
        for s in ${2//,/ }; do off "$s" "no image"; done
    fi
}

cloned=" "
for entry in "${images[@]}"; do
    read -r repo dir image requires service <<<"$entry"
    if [[ -n "$src_root" ]]; then
        src="$src_root/$repo"
        if [[ ! -d "$src/.git" ]]; then
            skip "$image" "$service" "no $src"
            continue
        fi
    else
        src="$build/src/$repo"
        branch="$(ref_of "$repo")"
        if [[ "$cloned" != *" $repo "* ]]; then
            rm -rf "$src"
            git clone -q --depth 1 --branch "$branch" "https://github.com/PoUW-ZK/$repo.git" "$src"
            cloned+="$repo "
        fi
    fi
    commit="$(git -C "$src" rev-parse HEAD)"
    sha="${commit:0:7}"
    if [[ -n "$src_root" ]]; then
        branch="$(git -C "$src" branch --show-current)"
        if [[ -n "$(git -C "$src" status --porcelain)" ]]; then
            sha+="-dirty"
            commit+="-dirty"
        fi
    fi
    if [[ ! -f "$src/$dir/Dockerfile" || ! -f "$src/$requires" ]]; then
        skip "$image" "$service" "$sha has no $dir/Dockerfile or $requires"
        continue
    fi
    docker build "${flags[@]}" \
        --label "org.opencontainers.image.revision=$sha" \
        --build-arg "GIT_COMMIT=$commit" \
        --build-arg "GIT_BRANCH=${branch:-unknown}" \
        --build-arg "BUILD_TIME=$build_time" \
        -t "ghcr.io/pouw-zk/$image:$tag" "$src/$dir"
    if [[ -n "$src_root" ]]; then
        echo "$image $sha ($branch, $src)" | tee -a "$build/versions.txt"
    else
        echo "$image $sha ($branch)" | tee -a "$build/versions.txt"
        echo "$(echo "${image#pouw-}" | tr a-z- A-Z_)_VERSION=sha-$sha" >>"$build/versions.env"
    fi
done
# An empty `services:` is not valid compose
grep -q '^  ' "$skip_yml" || echo "services: {}" >"$skip_yml"
mv -f "$skip_yml" "$build/skip.yml"
