#!/usr/bin/env bash
# Installs the self-hosted GitHub Actions runner that runs the Deploy workflow
# on this server. Port 22 is closed from outside on the FIIT firewall, so GitHub
# cannot SSH in; the runner connects out to GitHub over HTTPS and picks up the job.
#
#   # on your laptop (the token is valid for 1 hour):
#   gh api -X POST repos/PoUW-ZK/pouw-deploy/actions/runners/registration-token --jq .token
#   # on the server, from your own account:
#   sudo ./scripts/runner-setup.sh <token>
#
# The runner runs as the system user gh-runner: no sudo, not in the docker group.
# The Deploy job only SSHes to 127.0.0.1 with the deploy key, which may run
# nothing but scripts/remote.sh (forced command in authorized_keys).
# Safe to re-run: an already registered runner is left as it is.
set -euo pipefail

version=2.338.0
sha256=af4b794c1bc41d73d40535e3fe092a39f9679cd8d965954c2aca25a05ca41d32
repo_url=https://github.com/PoUW-ZK/pouw-deploy
user=gh-runner
dir=/opt/actions-runner

if [[ $EUID -ne 0 ]]; then
    echo "Run via sudo: sudo $0 <token>" >&2
    exit 1
fi
token="${1:?Usage: sudo $0 <registration token>}"

id "$user" >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin "$user"

if [[ ! -x "$dir/config.sh" ]]; then
    tmp="$(mktemp)"
    curl -fsSL -o "$tmp" \
        "https://github.com/actions/runner/releases/download/v$version/actions-runner-linux-x64-$version.tar.gz"
    echo "$sha256  $tmp" | sha256sum -c --quiet -
    install -d -o "$user" -g "$user" "$dir"
    tar -xzf "$tmp" -C "$dir"
    rm -f "$tmp"
    chown -R "$user:$user" "$dir"
    "$dir/bin/installdependencies.sh"
fi

cd "$dir"
if [[ -f .runner ]]; then
    echo "Runner is already registered. To register it again:"
    echo "  cd $dir && sudo ./svc.sh uninstall && sudo -u $user ./config.sh remove --token <token>"
else
    # the runner refuses to be configured as root
    sudo -u "$user" ./config.sh --unattended --replace \
        --url "$repo_url" --token "$token" \
        --name "$(hostname)" --labels staging --work _work
fi

# systemd service, starts after a reboot
[[ -f .service ]] || ./svc.sh install "$user"
./svc.sh start
./svc.sh status | head -5
