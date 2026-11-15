#!/bin/sh
# Organization "Public" of Grafana, the one anonymous visitors see (the panels
# the explorer embeds). A Viewer can send any query to every datasource of its
# organization, so this one has Prometheus only and no database, and the
# dashboards of the team stay in the main organization behind the password.
#
# Runs inside the Grafana container on every start, safe to run again. It goes
# through the API because provisioning files cannot create an organization, and
# Grafana does not start when a provisioning file names one that does not exist.
# The healthcheck of the container waits for /tmp/public-org-ready.
set -eu

url=http://localhost:3000
auth="admin:$(cat /run/secrets/grafana_admin_password)"

api() {
    curl -fsS -u "$auth" -H 'Content-Type: application/json' "$@"
}

rm -f /tmp/public-org-ready
until curl -fsS -o /dev/null "$url/api/health" 2>/dev/null; do
    sleep 2
done

if ! api -o /dev/null "$url/api/orgs/name/Public" 2>/dev/null; then
    api -o /dev/null -X POST "$url/api/orgs" -d '{"name": "Public"}'
fi
org="$(api "$url/api/orgs/name/Public" | sed -E 's/.*"id":([0-9]+).*/\1/')"

in_org() {
    api -H "X-Grafana-Org-Id: $org" "$@"
}

# The same uid as in the main organization, so a panel copied from there works
if ! in_org -o /dev/null "$url/api/datasources/uid/prometheus" 2>/dev/null; then
    in_org -o /dev/null -X POST "$url/api/datasources" -d '{
        "name": "Prometheus", "type": "prometheus", "uid": "prometheus",
        "access": "proxy", "url": "http://prometheus:9090", "isDefault": true
    }'
fi

for file in /public-org/dashboards/*.json; do
    { printf '{"overwrite": true, "dashboard": '; cat "$file"; printf '}'; } |
        in_org -o /dev/null -X POST "$url/api/dashboards/db" --data-binary @-
    echo "Loaded $file into organization $org"
done

touch /tmp/public-org-ready
