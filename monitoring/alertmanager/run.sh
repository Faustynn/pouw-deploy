#!/bin/sh
# Entry point of the service alertmanager (compose.yml). Alertmanager e-mails
# the alerts of Prometheus (monitoring/prometheus/rules) through the SMTP
# account of Jenkins: SMTP_HOST, SMTP_PORT and SMTP_FROM from .env, username
# and password from pass (secrets smtp_username and smtp_password).
#
# Alertmanager does not read environment variables in its configuration, so
# the configuration is written here just before the start. The password stays
# in its file (smtp_auth_password_file). Without SMTP_HOST or ALERT_EMAIL (a
# laptop, the test copies of the network) alerts are only listed in
# Alertmanager and nothing is e-mailed.
#
#   run.sh          start Alertmanager
#   run.sh check    only validate the configuration (make check)
set -eu

config=/tmp/alertmanager.yml

{
    if [ -n "${SMTP_HOST:-}" ] && [ -n "${ALERT_EMAIL:-}" ]; then
        cat <<EOF
global:
  smtp_smarthost: '${SMTP_HOST}:${SMTP_PORT:-587}'
  smtp_from: 'PoUW Alertmanager <${SMTP_FROM:-alertmanager@localhost}>'
  smtp_auth_username: '$(cat /run/secrets/smtp_username 2>/dev/null || true)'
  smtp_auth_password_file: /run/secrets/smtp_password

receivers:
  - name: team
    email_configs:
      - to: '${ALERT_EMAIL}'
        send_resolved: true
EOF
    else
        echo "SMTP_HOST or ALERT_EMAIL is not set, alerts are not e-mailed" >&2
        cat <<EOF
receivers:
  - name: team
EOF
    fi
    cat <<EOF

# One e-mail per alert name: 30 s after it starts firing, then a reminder
# every 12 hours while it lasts, and one when it is resolved
route:
  receiver: team
  group_by: [alertname]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 12h
EOF
} >"$config"

if [ "${1:-}" = check ]; then
    exec amtool check-config "$config"
fi
# The UI is reachable only through 127.0.0.1 (an SSH tunnel on the server),
# links in the e-mails point there
exec /bin/alertmanager --config.file="$config" --storage.path=/alertmanager \
    --web.external-url=http://localhost:9093
