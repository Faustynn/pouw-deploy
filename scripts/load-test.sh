#!/usr/bin/env bash
# Load test with pouw-workload: ./scripts/load-test.sh <compose project> <scenario>
#
# Starts a scenario of the generator of the running network (POST
# /api/v1/start), waits until it stops and writes the report to $REPORT_DIR
# (default reports/load):
#
#   <scenario>.csv          per operation: completed, failures, rejected, p50/p95/p99 (µs)
#   <scenario>-status.json  the last status of the generator
#   <scenario>.md           summary with the link to the dashboard PoUW · Load test
#   load-<scenario>.xml     JUnit, one test per operation (suite load in Jenkins → Tests)
#
# Exit code 1 when the generator stops with an error, nothing completed, or
# an operation had failures or rejections. Called by `make load` (staging,
# the panels are in its Grafana while it runs) and by the Jenkins job
# pouw-load-test (a test copy of the network).
set -euo pipefail

project="${1:?Usage: $0 <compose project> <scenario>}"
scenario="${2:?Usage: $0 <compose project> <scenario>}"
report_dir="${REPORT_DIR:-reports/load}"
grafana_url="${GRAFANA_URL:-http://localhost:3000/}"
# Longer than the longest scenario (soak: 1 h)
max_seconds="${LOAD_MAX_SECONDS:-5400}"

mkdir -p "$report_dir"

# The API of the generator is only on the compose network
api() {
    docker run --rm --network "${project}_default" curlimages/curl:8.17.0 \
        -sS --max-time 30 "$@" "http://workload:8000${path}"
}

path=/api/v1/status
if api -f | grep -q '"status":"running"'; then
    echo "The generator of $project is already running a scenario, stop it first" >&2
    exit 1
fi

started_ms="$(($(date +%s) * 1000))"
path=/api/v1/start
api -f -X POST -H 'Content-Type: application/json' -d "{\"scenario_name\":\"$scenario\"}"
echo
echo "Load test $scenario on $project, dashboard: ${grafana_url%/}/d/pouw-workload?var-project=$project&from=$started_ms&to=now&refresh=10s"

path=/api/v1/status
deadline=$(($(date +%s) + max_seconds))
while :; do
    status="$(api -f)"
    state="$(echo "$status" | grep -oE '"status":"[a-z]+"' | cut -d'"' -f4)"
    [[ "$state" != running ]] && break
    if (($(date +%s) > deadline)); then
        path=/api/v1/stop
        api -X POST >/dev/null || true
        echo "Not finished within $max_seconds s, stopped" >&2
        break
    fi
    sleep 10
done
ended_ms="$(($(date +%s) * 1000))"
echo "$status" >"$report_dir/$scenario-status.json"

path=/api/v1/results
api -f >"$report_dir/$scenario.csv"

# Summary, JUnit and the verdict from the CSV
awk -F, -v scenario="$scenario" -v state="$state" -v project="$project" \
    -v dashboard="${grafana_url%/}/d/pouw-workload?var-project=$project&from=$started_ms&to=$ended_ms" \
    -v md="$report_dir/$scenario.md" -v xml="$report_dir/load-$scenario.xml" '
    NR == 1 { next }
    {
        op[++n] = $1; done_[n] = $2; fail[n] = $3; rej[n] = $4
        p50[n] = $5 / 1000; p95[n] = $6 / 1000; p99[n] = $7 / 1000
        total += $2; failures += $3; rejected += $4
    }
    END {
        ok = (state != "error" && total > 0 && failures == 0 && rejected == 0)
        print "# Load test " scenario > md
        print "" > md
        print "- Network: " project ", generator state: " state > md
        print "- Reads: " total " completed, " failures " failures, " rejected " rejected" > md
        print "- Result: " (ok ? "passed" : "FAILED") > md
        print "- Dashboard: " dashboard > md
        print "" > md
        print "| Operation | Completed | Failures | Rejected | p50 ms | p95 ms | p99 ms |" > md
        print "|---|---:|---:|---:|---:|---:|---:|" > md
        tests = 0; bad = 0; skipped = 0
        for (i = 1; i <= n; i++) {
            printf "| %s | %d | %d | %d | %.1f | %.1f | %.1f |\n", op[i], done_[i], fail[i], rej[i], p50[i], p95[i], p99[i] > md
            tests++
            if (fail[i] + rej[i] > 0) bad++
            else if (done_[i] == 0) skipped++
        }
        printf "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuite name=\"load\" tests=\"%d\" failures=\"%d\" skipped=\"%d\">\n", tests, bad, skipped > xml
        for (i = 1; i <= n; i++) {
            printf "  <testcase classname=\"load.%s\" name=\"%s\">", scenario, op[i] > xml
            if (fail[i] + rej[i] > 0)
                printf "<failure message=\"%d failures, %d rejected of %d\"/>", fail[i], rej[i], done_[i] + fail[i] + rej[i] > xml
            else if (done_[i] == 0)
                printf "<skipped message=\"not in the mix of the scenario\"/>" > xml
            printf "<system-out>completed=%d p50=%.1fms p95=%.1fms p99=%.1fms</system-out></testcase>\n", done_[i], p50[i], p95[i], p99[i] > xml
        }
        print "</testsuite>" > xml
        exit ok ? 0 : 1
    }' "$report_dir/$scenario.csv" && verdict=0 || verdict=1

cat "$report_dir/$scenario.md"
exit "$verdict"
