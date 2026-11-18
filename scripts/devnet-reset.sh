#!/usr/bin/env bash
# Starts a new devnet: a new genesis, the nodes and the indexer database from
# scratch. Run it where the network runs, on the server in ~/pouw/pouw-deploy:
#
#   ./scripts/devnet-reset.sh
#
# Needed when the genesis changes: devnet/chainspec.json was updated (e.g. after
# pouw-node/chainspec/devnet.json changed), or the chain should start over.
# A node refuses its database under another genesis, and the indexer stops
# syncing a chain that shares no block with its database ("not even the
# genesis"). Monitoring, Grafana and Jenkins keep their data, the dumps of the
# old database stay in BACKUP_DIR.
set -euo pipefail

cd "$(dirname "$0")/.."
project="${COMPOSE_PROJECT_NAME:-pouw}"

read -r -p "Delete the chain of the devnet (genesis, nodes, indexer database) and start a new one? Type yes: " answer
[[ "$answer" == yes ]] || { echo "Nothing changed"; exit 1; }

# What holds the chain or reads it from the database
docker compose stop indexer hasura workload dashboard
docker compose rm -fs genesis node-1 node-2 node-3
for v in devnet node-1-data node-2-data node-3-data; do
    docker volume rm -f "${project}_$v" >/dev/null
done
docker compose exec -T postgres dropdb -U pouw --force pouw
docker compose exec -T postgres createdb -U pouw pouw

# A new genesis (service genesis), the indexer migrates and syncs from block 0,
# Hasura applies its metadata again
make up
echo "New devnet: $(docker compose logs --no-log-prefix genesis | tail -1)"
