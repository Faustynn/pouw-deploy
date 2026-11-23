#!/bin/sh
# Entry point of the service proxy (compose.yml): hashes the password of the
# Alertmanager login (secret alertmanager_password) with bcrypt for basic_auth
# in the Caddyfile, then starts Caddy as the image does.
set -eu

password=/run/secrets/alertmanager_password
if [ ! -s "$password" ]; then
    echo "proxy: $password is empty, run make secrets" >&2
    exit 1
fi
ALERTMANAGER_HASH="$(caddy hash-password <"$password")"
export ALERTMANAGER_HASH
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
