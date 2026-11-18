#!/bin/sh
# Service genesis (compose.yml): the chain spec of the devnet, which all nodes
# share. Written once, when the volume devnet is empty: the template
# devnet/chainspec.json (a copy of pouw-node/chainspec/devnet.json) with the
# current time as genesis.timestamp and the matching expected_genesis_id.
#
# Why not the spec built into the node: the target schedule of the chain counts
# from genesis.timestamp (pouw-node docs/CHAINSPEC.md), so a chain started
# days after its genesis mines a burst of easy blocks until it catches up. So
# every new devnet (staging, every test copy) gets a genesis of its own. The
# volume keeps it: a node never sees another genesis than the one of its
# database, which it would refuse (exit 1). A new devnet: scripts/devnet-reset.sh
set -eu

spec=/devnet/chainspec.json

if [ -s "$spec" ]; then
    echo "Devnet genesis $(pouw genesis-id "$spec")"
    exit 0
fi

sed "s/\"timestamp\": *[0-9]*/\"timestamp\": $(date +%s)/" /template/chainspec.json >"$spec.part"
id="$(pouw genesis-id "$spec.part")"
sed -i "s/\"expected_genesis_id\": *\"[^\"]*\"/\"expected_genesis_id\": \"$id\"/" "$spec.part"
chmod 644 "$spec.part"
mv "$spec.part" "$spec"
echo "New devnet genesis $id at $(date -u +%FT%TZ)"
