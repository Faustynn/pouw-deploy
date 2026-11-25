"""e2e tests of the whole devnet: 3 nodes, the indexer, Hasura and the explorer.

They run in a fresh test copy of the network (make test, every PR of
pouw-deploy and every night in Jenkins): a new genesis, all three nodes mine
from the start, node-2 and node-3 dial node-1. A block takes about 10 s, so the waits are
generous; a test that fails says what it saw last.
"""

import asyncio
import json
import os
import pathlib
import re
import time

import pytest
import requests
import websockets

NODES = ["node-1", "node-2", "node-3"]
# Reward addresses of the miners (compose.yml, test keys of the contracts)
MINERS = {
    "node-1": "addr:8a88e3dd7409f195fd52db2d3cba5d72ca6709bf1d94121bf3748801b40f6f5c",
    "node-2": "addr:43a72e714401762df66b68c26dfbdf2682aaec9f2474eca4613e424a0fbafd3c",
    "node-3": "addr:66be7e332c7a453332bd9d0a7f7db055f5c5ef1a06ada66d98b39fb6810c473a",
}
HASURA = "http://hasura:8080/v1/graphql"
# Waiting for one or two blocks. The target is 10 s, but on a busy machine
# (Docker Desktop with the whole network) a block takes about 50 s on average
# and single gaps of 4 minutes happen, so a short limit makes the tests flaky.
# Passing tests return as soon as the block is there.
BLOCKS_WAIT = 600
# How far the indexer may be behind node-1
MAX_LAG = 5


def get(url):
    # the node answers in Borsh unless asked for JSON
    r = requests.get(url, headers={"Accept": "application/json"}, timeout=10)
    r.raise_for_status()
    return r.json()


def node(name):
    """GET /v1/node: chain_id, version, height, peers."""
    return get(f"http://{name}:8000/v1/node")


# Hasura runs only the operations of the contract (web-api.graphql, the
# allow-list of pouw-dashboard) for anonymous clients, so the tests send
# LatestBlocks exactly as the contract has it
BLOCK_ROW = (
    "fragment BlockRow on blocks { hash height time miner transfer_count"
    " registration_count proof_count fee_total }"
)
LATEST_BLOCKS = (
    "{kind} LatestBlocks($limit: Int = 10) { blocks(where: {canonical: {_eq: true}},"
    " order_by: {height: desc}, limit: $limit) { ...BlockRow } } " + BLOCK_ROW
)


def graphql(query, variables=None, url=HASURA):
    r = requests.post(url, json={"query": query, "variables": variables or {}}, timeout=10)
    r.raise_for_status()
    body = r.json()
    assert "errors" not in body, body
    return body["data"]


def newest_block():
    """Newest canonical block in Hasura as {height, hash}, None without blocks."""
    rows = graphql(LATEST_BLOCKS.replace("{kind}", "query"), {"limit": 1})["blocks"]
    return rows[0] if rows else None


def wait_for(what, check, timeout=BLOCKS_WAIT):
    """Calls check() until it returns (True, seen); fails with the last seen."""
    deadline = time.monotonic() + timeout
    while True:
        try:
            done, seen = check()
            if done:
                return seen
        except (requests.RequestException, KeyError, IndexError, TypeError) as e:
            seen = e
        if time.monotonic() > deadline:
            pytest.fail(f"{what}: not within {timeout} s, last seen: {seen!r}")
        time.sleep(2)


def heights():
    return {n: node(n)["height"] for n in NODES}


def node_1_has_a_block():
    h = node("node-1")["height"]
    return h >= 1, {"node-1 height": h}


def test_nodes_share_the_genesis():
    ids = {n: get(f"http://{n}:8000/v1/blocks/0")["id"] for n in NODES}
    assert len(set(ids.values())) == 1, ids


def test_nodes_find_each_other():
    # node-2 and node-3 dial node-1 (POUW_BOOTNODES)
    def connected():
        peers = {n: node(n)["peers"] for n in NODES}
        return all(p >= 1 for p in peers.values()), peers

    wait_for("every node has a peer", connected, timeout=60)


def test_height_grows():
    start = node("node-1")["height"]

    def grew():
        h = node("node-1")["height"]
        return h >= start + 2, {"start": start, "now": h}

    wait_for("node-1 mines two blocks", grew)


def test_nodes_have_the_same_tip():
    # gossip (pouw-node#130) and the initial sync (pouw-node#128) keep the
    # chains of the 3 nodes together
    wait_for("node-1 has a block", node_1_has_a_block)

    def same_tip():
        tips = {n: get(f"http://{n}:8000/v1/blocks/head")["id"] for n in NODES}
        return len(set(tips.values())) == 1, heights()

    wait_for("all nodes on the same tip", same_tip, timeout=60)


def test_more_than_one_miner_finds_blocks():
    """All three nodes mine. Each has a third of the hash power, so within a few
    blocks at least two miners have one; the chain of node-1 and the explorer
    (Hasura) both show them, and only the miners of the devnet."""

    def miners_at_node():
        tip = node("node-1")["height"]
        found = {
            get(f"http://node-1:8000/v1/blocks/{h}")["header"]["miner"]
            for h in range(max(1, tip - 49), tip + 1)
        }
        return len(found) >= 2, {"height": tip, "miners": sorted(found)}

    seen = wait_for("blocks of two miners in the chain of node-1", miners_at_node)
    assert set(seen["miners"]) <= set(MINERS.values()), seen

    def miners_in_explorer():
        rows = graphql(LATEST_BLOCKS.replace("{kind}", "query"), {"limit": 50})["blocks"]
        # genesis has no miner (addr:000…0), the newest 50 include it early on
        found = {r["miner"] for r in rows if r["height"] >= 1}
        return len(found) >= 2, sorted(found)

    found = wait_for("blocks of two miners in the explorer", miners_in_explorer)
    assert set(found) <= set(MINERS.values()), found


def test_indexer_keeps_up_with_the_node():
    wait_for("node-1 has a block", node_1_has_a_block)

    def close():
        tip = node("node-1")["height"]
        block = newest_block()
        indexed = block["height"] if block else -1
        return tip - indexed < MAX_LAG, {"node-1": tip, "indexer": indexed}

    wait_for(f"the indexer less than {MAX_LAG} blocks behind node-1", close)


INDEXER_METRICS = "http://indexer:8000/metrics"
CURSOR = re.compile(r'^pouw_indexer_event_cursor\{node_id="([^"]+)"\} (\d+)$', re.M)


def event_cursors():
    """The last stored event seq of every node, from the metrics of the indexer."""
    text = requests.get(INDEXER_METRICS, timeout=10).text
    return {name: int(seq) for name, seq in CURSOR.findall(text)}


def test_indexer_stores_events_of_every_node():
    """The indexer reads the event log of every node (EVENT_SOURCES), and every node
    writes an event for each block it accepts, so the cursor of each node grows.
    pouw-node#142: the indexer once stored no events for days without any error."""

    def every_node_has_events():
        cursors = event_cursors()
        return all(cursors.get(n, 0) > 0 for n in NODES), cursors

    start = wait_for("events of every node in the indexer", every_node_has_events)

    def more_events():
        now = event_cursors()
        return all(now.get(n, 0) > start[n] for n in NODES), {"start": start, "now": now}

    wait_for("new events of every node in the indexer", more_events)


def test_hasura_serves_the_newest_block_of_the_node():
    # The newest block in Hasura is the block of node-1 at that height: the
    # same id all the way from the node through the indexer and Postgres
    def has_block():
        block = newest_block()
        return bool(block) and block["height"] >= 1, block

    wait_for("a block after genesis in Hasura", has_block)

    def same_block():
        block = newest_block()
        at_node = get(f"http://node-1:8000/v1/blocks/{block['height']}")["id"]
        return at_node == block["hash"], {"hasura": block, "node-1": at_node}

    wait_for("Hasura and node-1 agree on the newest block", same_block, timeout=60)


def test_subscription_gets_a_new_block():
    """The live view of the explorer: a GraphQL subscription over WebSocket."""
    query = LATEST_BLOCKS.replace("{kind}", "subscription")
    seen = []

    async def run():
        async with websockets.connect(
            "ws://hasura:8080/v1/graphql", subprotocols=["graphql-transport-ws"]
        ) as ws:
            async def recv():
                # Hasura sends keepalive pings, also before connection_ack
                while True:
                    msg = json.loads(await ws.recv())
                    if msg["type"] != "ping":
                        return msg
                    await ws.send(json.dumps({"type": "pong"}))

            await ws.send(json.dumps({"type": "connection_init", "payload": {}}))
            ack = await asyncio.wait_for(recv(), 10)
            assert ack["type"] == "connection_ack", ack
            await ws.send(json.dumps({"id": "1", "type": "subscribe", "payload": {"query": query, "variables": {"limit": 1}}}))
            while True:
                msg = await recv()
                assert msg["type"] not in ("error", "complete"), msg
                if msg["type"] == "next":
                    rows = msg["payload"]["data"]["blocks"]
                    seen.append(rows[0]["height"] if rows else -1)
                    if seen[-1] > seen[0]:
                        return

    async def limited():
        await asyncio.wait_for(run(), BLOCKS_WAIT)

    try:
        asyncio.run(limited())
    except TimeoutError:
        pytest.fail(f"no new block over the subscription within {BLOCKS_WAIT} s, heights seen: {seen}")


def test_explorer_responds():
    r = requests.get("http://dashboard:8080/", timeout=10)
    assert r.status_code == 200 and "<html" in r.text.lower(), r.text[:200]
    # The explorer asks /v1/graphql on its own host, as a browser does
    query = LATEST_BLOCKS.replace("{kind}", "query")
    assert "blocks" in graphql(query, {"limit": 1}, url="http://dashboard:8080/v1/graphql")


TRANSACTION = (pathlib.Path(__file__).parent / "queries" / "Transaction.graphql").read_text()


@pytest.mark.skipif(not os.environ.get("E2E_TRANSFER"), reason="run.sh signs the transfer (E2E_TRANSFER)")
def test_transfer_reaches_the_explorer():
    """A real transfer, signed with the test key of the contracts by run.sh, goes
    through node-1, a block, the indexer and Hasura to the explorer."""
    to = os.environ["E2E_TRANSFER_TO"]
    amount = int(os.environ["E2E_TRANSFER_AMOUNT"])
    r = requests.post(
        "http://node-1:8000/v1/txs",
        data=os.environ["E2E_TRANSFER"],
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        timeout=10,
    )
    assert r.status_code == 202, r.text
    txid = r.json()["txid"]

    def included():
        status = get(f"http://node-1:8000/v1/txs/{txid}")["status"]
        return status == "included", status

    wait_for(f"{txid} in a block of node-1", included)
    assert get(f"http://node-1:8000/v1/accounts/{to}")["balance"] == amount

    def in_explorer():
        rows = graphql(TRANSACTION, {"txid": txid}, url="http://dashboard:8080/v1/graphql")["transfers"]
        return bool(rows) and rows[0]["canonical"], rows

    wait_for(f"{txid} in the explorer", in_explorer)
    row = graphql(TRANSACTION, {"txid": txid})["transfers"][0]
    assert (row["recipient"], row["amount"]) == (to, amount), row
