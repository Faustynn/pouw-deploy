"""e2e tests of the whole devnet: 3 nodes, the indexer, Hasura and the explorer.

They run in a fresh test copy of the network (make test, every PR of
pouw-deploy and every night in Jenkins): a new genesis, node-1 mines from the
start, node-2 and node-3 dial it. A block takes about 10 s, so the waits are
generous; a test that fails says what it saw last.
"""

import asyncio
import json
import time

import pytest
import requests
import websockets

NODES = ["node-1", "node-2", "node-3"]
HASURA = "http://hasura:8080/v1/graphql"
# Waiting for one or two blocks; a slow CPU may need several times 10 s
BLOCKS_WAIT = 180
# How far the indexer may be behind node-1
MAX_LAG = 5


def get(url):
    r = requests.get(url, timeout=10)
    r.raise_for_status()
    return r.json()


def node(name):
    """GET /v1/node: chain_id, version, height, peers."""
    return get(f"http://{name}:8000/v1/node")


def graphql(query, url=HASURA):
    r = requests.post(url, json={"query": query}, timeout=10)
    r.raise_for_status()
    body = r.json()
    assert "errors" not in body, body
    return body["data"]


def newest_block():
    """Newest canonical block in Hasura as {height, hash}, None without blocks."""
    rows = graphql(
        "{ blocks(where: {canonical: {_eq: true}}, order_by: {height: desc}, limit: 1)"
        " { height hash } }"
    )["blocks"]
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


@pytest.mark.xfail(
    reason="the nodes do not exchange blocks yet (pouw-node#86 gossip, #90 initial sync)",
    strict=False,
)
def test_nodes_have_the_same_tip():
    wait_for("node-1 has a block", node_1_has_a_block)

    def same_tip():
        tips = {n: get(f"http://{n}:8000/v1/blocks/head")["id"] for n in NODES}
        return len(set(tips.values())) == 1, heights()

    wait_for("all nodes on the same tip", same_tip, timeout=60)


def test_indexer_keeps_up_with_the_node():
    wait_for("node-1 has a block", node_1_has_a_block)

    def close():
        tip = node("node-1")["height"]
        block = newest_block()
        indexed = block["height"] if block else -1
        return tip - indexed < MAX_LAG, {"node-1": tip, "indexer": indexed}

    wait_for(f"the indexer less than {MAX_LAG} blocks behind node-1", close)


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
    query = "subscription { blocks(order_by: {height: desc}, limit: 1) { height } }"
    seen = []

    async def run():
        async with websockets.connect(
            "ws://hasura:8080/v1/graphql", subprotocols=["graphql-transport-ws"]
        ) as ws:
            await ws.send(json.dumps({"type": "connection_init", "payload": {}}))
            ack = json.loads(await asyncio.wait_for(ws.recv(), 10))
            assert ack["type"] == "connection_ack", ack
            await ws.send(json.dumps({"id": "1", "type": "subscribe", "payload": {"query": query}}))
            while True:
                msg = json.loads(await ws.recv())
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
    assert "blocks" in graphql("{ blocks(limit: 1) { height } }", url="http://dashboard:8080/v1/graphql")
