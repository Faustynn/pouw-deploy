#!/usr/bin/env bash
# Smoke tests of a running network: ./e2e/smoke.sh [compose project]
# Commands run inside the containers via `docker exec`, so they work without
# ports on the host and also in Jenkins, where Docker runs elsewhere.
# Checks of a service from an optional profile that does not run are skipped,
# a service without a profile that does not run is a failure.
# With JUNIT_XML=<file> the results are also written as JUnit (Tests tab in Jenkins).
set -euo pipefail

project="${1:-pouw}"
failed=0
skipped=0
tests=0
cases=""

# Text for XML: escaped and without control characters
xml() {
    tr -d '\000-\010\013\014\016-\037' |
        sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# Services in profiles (compose.yml), they may be off
optional=" node-exporter cadvisor "

# Container of a running service of the project, empty when it does not run
container() {
    docker ps -q --filter "label=com.docker.compose.project=$project" \
        --filter "label=com.docker.compose.service=$1" --filter status=running | head -1
}

# check <description> <service> <shell command inside the container>
check() {
    local out name id
    id="$(container "$2")"
    name="$(printf '%s' "$1" | xml)"
    tests=$((tests + 1))
    if [[ -z "$id" && "$optional" != *" $2 "* ]]; then
        echo "FAIL  $1 ($2 does not run)"
        failed=$((failed + 1))
        cases+="  <testcase classname=\"smoke.$2\" name=\"$name\"><failure message=\"$2 does not run\"/></testcase>"$'\n'
        return
    fi
    if [[ -z "$id" ]]; then
        echo "skip  $1 ($2 does not run)"
        skipped=$((skipped + 1))
        cases+="  <testcase classname=\"smoke.$2\" name=\"$name\"><skipped message=\"$2 does not run\"/></testcase>"$'\n'
        return
    fi
    if out="$(docker exec -i "$id" sh -c "$3" 2>&1)"; then
        echo "ok    $1"
        cases+="  <testcase classname=\"smoke.$2\" name=\"$name\"/>"$'\n'
    else
        echo "FAIL  $1"
        printf '%s\n' "$out" | sed 's/^/      /'
        failed=$((failed + 1))
        cases+="  <testcase classname=\"smoke.$2\" name=\"$name\"><failure message=\"command failed\">$(printf '%s' "$out" | xml)</failure></testcase>"$'\n'
    fi
}

# check_host <description> <function>: a check of Docker itself, on this machine
check_host() {
    local out name
    name="$(printf '%s' "$1" | xml)"
    tests=$((tests + 1))
    if out="$("$2" 2>&1)"; then
        echo "ok    $1"
        cases+="  <testcase classname=\"smoke.docker\" name=\"$name\"/>"$'\n'
    else
        echo "FAIL  $1"
        printf '%s\n' "$out" | sed 's/^/      /'
        failed=$((failed + 1))
        cases+="  <testcase classname=\"smoke.docker\" name=\"$name\"><failure message=\"command failed\">$(printf '%s' "$out" | xml)</failure></testcase>"$'\n'
    fi
}

# Docker keeps at most 3 log files of 10 MB of every container (x-logging in compose.yml)
logs_capped() {
    local id name size bad=0
    for id in $(docker ps -q --filter "label=com.docker.compose.project=$project"); do
        read -r name size <<<"$(docker inspect -f '{{.Name}} {{index .HostConfig.LogConfig.Config "max-size"}}' "$id")"
        if [[ -z "$size" ]]; then
            echo "no log limit: ${name#/}"
            bad=1
        fi
    done
    return "$bad"
}

check "prometheus is ready" prometheus \
    'wget -qO- http://localhost:9090/-/ready'

check "prometheus scrapes its own metrics" prometheus \
    'wget -qO- "http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22prometheus%22%7D" | grep -q "\"1\"\]"'

# Alerts (monitoring/prometheus/rules), e-mailed by Alertmanager
check "alertmanager is ready" alertmanager \
    'wget -qO /dev/null http://localhost:9093/-/ready'

check "prometheus has the alert rules" prometheus \
    "wget -qO- http://localhost:9090/api/v1/rules | grep -q '\"name\":\"ChainStalled\"'"

check "prometheus sends alerts to alertmanager" prometheus \
    "wget -qO- http://localhost:9090/api/v1/alertmanagers | grep -q 'alertmanager:9093'"

# The first dump is made right after the start, then every night
check "a dump of the database younger than 26 hours exists" backup \
    "find /backups -maxdepth 1 -name 'pouw-*.dump' -mmin -1560 | grep -q ."

check "grafana and its database" grafana \
    'wget -qO- http://localhost:3000/api/health | grep -q "\"database\": *\"ok\""'

check "grafana connects to prometheus" grafana \
    'wget -qO- "http://admin:$(cat /run/secrets/grafana_admin_password)@localhost:3000/api/datasources/uid/prometheus/health" | grep -q "\"status\": *\"OK\""'

check "postgres accepts connections" postgres \
    'pg_isready -U pouw -d pouw'

# Dashboards as code (monitoring/grafana/dashboards), loaded at start without clicking
for uid in pouw-network pouw-services pouw-server pouw-workload; do
    check "grafana has the dashboard $uid" grafana \
        "wget -qO- \"http://admin:\$(cat /run/secrets/grafana_admin_password)@localhost:3000/api/dashboards/uid/$uid\" | grep -q '\"uid\":\"$uid\"'"
done

# Postgres datasource: logs in as the read-only user grafana (ADR-0008). Up to
# 3 tries: after Postgres was recreated (a new image of postgres:16), the first
# query of Grafana takes a dead connection of its pool and fails once
check "grafana reads the indexer database" grafana \
    'for i in 1 2 3; do wget -qO- "http://admin:$(cat /run/secrets/grafana_admin_password)@localhost:3000/api/datasources/uid/indexer/health" | grep -q "\"status\": *\"OK\"" && exit 0; sleep 2; done; exit 1'

check "the grafana database user is read-only" postgres \
    "psql -U pouw -d pouw -tAc \"SELECT rolsuper OR rolcreatedb OR rolcreaterole OR NOT ('default_transaction_read_only=on' = ANY(coalesce(rolconfig, '{}'))) OR EXISTS (SELECT FROM information_schema.role_table_grants WHERE grantee = 'grafana' AND privilege_type <> 'SELECT') FROM pg_roles WHERE rolname = 'grafana'\" | grep -qx f"

# Hasura runs only the operations of the contract (web-api.graphql, the
# allow-list of pouw-dashboard) for anonymous clients, so the checks send
# LatestBlocks exactly as the contract has it
LATEST_BLOCKS='{"query": "query LatestBlocks($limit: Int = 10) { blocks(where: {canonical: {_eq: true}}, order_by: {height: desc}, limit: $limit) { ...BlockRow } } fragment BlockRow on blocks { hash height time miner transfer_count registration_count proof_count fee_total }", "variables": {"limit": 1}}'
MUTATION='{"query": "mutation { delete_blocks(where: {}) { affected_rows } }"}'

# strict: 500 when the metadata does not match the schema of the indexer
check "hasura is up and its metadata is consistent" hasura \
    'curl -fsS "http://localhost:8080/healthz?strict=true"'

check "hasura serves the api views without a token" hasura \
    "curl -fsS http://localhost:8080/v1/graphql -d '$LATEST_BLOCKS' | grep -q '\"data\"'"

check "hasura has no console" hasura \
    "curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/console | grep -qx 404"

# Without a token a mutation is rejected and nothing is written
check "anonymous clients cannot write through hasura" hasura \
    "r=\$(curl -sS http://localhost:8080/v1/graphql -d '$MUTATION'); echo \"\$r\" | grep -q '\"errors\"' && ! echo \"\$r\" | grep -q '\"data\"'"

# Anonymous visitors of Grafana (the panels embedded in the explorer)
check "grafana shows the public dashboard without a login" grafana \
    "wget -qO- http://localhost:3000/api/dashboards/uid/pouw-public | grep -q '\"uid\":\"pouw-public\"'"

check "grafana hides the team dashboards from anonymous visitors" grafana \
    "! wget -qO- 'http://localhost:3000/api/search?type=dash-db' | grep -qE 'pouw-(network|services|server)'"

# The datasource is what matters: a Viewer can send it any SQL
check "anonymous visitors of grafana cannot query the database" grafana \
    "! wget -qO- --header 'Content-Type: application/json' --header 'X-Grafana-Org-Id: 1' --post-data '{\"from\":\"now-1h\",\"to\":\"now\",\"queries\":[{\"refId\":\"A\",\"datasource\":{\"uid\":\"indexer\"},\"rawSql\":\"SELECT 1\",\"format\":\"table\"}]}' http://localhost:3000/api/ds/query 2>/dev/null | grep -q frames"

check "grafana admin API needs the password" grafana \
    "! wget -qO /dev/null http://localhost:3000/api/admin/settings 2>/dev/null"

# Every scrape job of monitoring/prometheus/prometheus.yml is a target, also
# when its service does not run (then the target is down)
for job in prometheus pouw-node pouw-indexer pouw-workload node-exporter cadvisor; do
    check "prometheus has the target $job" prometheus \
        "wget -qO- http://localhost:9090/api/v1/targets | grep -q '\"job\":\"$job\"'"
done

# Prometheus scrapes every 15 s, so a new target waits up to ~30 s for its first scrape
for job in node-exporter cadvisor; do
    [[ -n "$(container "$job")" ]] || continue
    check "prometheus scrapes $job" prometheus \
        "for i in \$(seq 20); do wget -qO- 'http://localhost:9090/api/v1/query?query=up%7Bjob%3D%22$job%22%7D' | grep -q '\"1\"\]' && exit 0; sleep 3; done; exit 1"
done

# Without the Docker and containerd sockets cAdvisor reports only cgroups, without container names
if [[ -n "$(container cadvisor)" ]]; then
    check "cadvisor sees the containers by name" prometheus \
        "for i in \$(seq 20); do wget -qO- 'http://localhost:9090/api/v1/query?query=count(container_last_seen%7Bname%3D~%22.%2B%22%7D)' | grep -q '\"result\":\[{' && exit 0; sleep 3; done; exit 1"
fi

# Network services. How the devnet behaves (blocks, peers, the indexer behind
# the node, ...) is tested by e2e/test_devnet.py.
for n in node-1 node-2 node-3; do
    check "$n is healthy (REST API)" "$n" 'curl -fsS -o /dev/null http://localhost:8000/health'
done

check "indexer is healthy (database reachable)" indexer \
    'curl -fsS -o /dev/null http://localhost:8000/health'

if [[ -n "$(container indexer)" ]]; then
    check "indexer applied its migrations" postgres \
        "psql -U pouw -d pouw -tAc 'SELECT count(*) FROM _sqlx_migrations WHERE success' | grep -qv '^0$'"
fi

check "workload is healthy" workload \
    'curl -fsS http://localhost:8000/health | grep -q UP'

check "dashboard serves the explorer" dashboard \
    'wget -qO /dev/null http://127.0.0.1:8080/'

# What runs where: every service answers the commit of its image (build args
# of docker.yml and make images). remote.sh also compares it with the deployed version.
has_commit='grep -Eq "\"commit\": *\"[0-9a-f]{7}"'
for n in node-1 node-2 node-3 indexer workload; do
    check "$n shows its commit at /manage/info" "$n" "curl -fsS http://localhost:8000/manage/info | $has_commit"
done
check "dashboard shows its commit at /manage/info" dashboard \
    "wget -qO- http://127.0.0.1:8080/manage/info | $has_commit"

# The explorer asks /v1/graphql on its own host: on staging the proxy sends it
# to Hasura, elsewhere the nginx of the explorer does
check "the explorer reaches hasura" dashboard \
    "wget -qO- --header 'Content-Type: application/json' --post-data '$LATEST_BLOCKS' http://127.0.0.1:8080/v1/graphql | grep -q '\"data\"'"

check_host "every container caps its logs" logs_capped

if [[ -n "${JUNIT_XML:-}" ]]; then
    mkdir -p "$(dirname "$JUNIT_XML")"
    {
        echo '<?xml version="1.0" encoding="UTF-8"?>'
        echo "<testsuite name=\"smoke\" tests=\"$tests\" failures=\"$failed\" skipped=\"$skipped\">"
        printf '%s' "$cases"
        echo '</testsuite>'
    } >"$JUNIT_XML"
fi

((failed == 0))
