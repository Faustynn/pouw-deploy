"""e2e tests after a node restart (pouw-node#142, #143, #144).

run.sh runs them in a second pass, after it has restarted node-3 of the test
copy (E2E_RESTARTED) and noted the event cursor the indexer had for it
(E2E_CURSOR_BEFORE). A restarted node keeps its store: it must catch up with
the others again, and the indexer must keep getting its events although the
event log of the node started anew.
"""

import os

import pytest

from test_devnet import NODES, event_cursors, get, heights, node, wait_for

RESTARTED = os.environ.get("E2E_RESTARTED")

pytestmark = pytest.mark.skipif(
    not RESTARTED, reason="run.sh restarts a node first (E2E_RESTARTED)"
)


def test_the_restarted_node_catches_up_and_keeps_the_same_tip():
    # pouw-node#143: a node restarted with a body above a missing one stopped at its tip
    def connected():
        return node(RESTARTED)["peers"] >= 1, node(RESTARTED)

    wait_for(f"{RESTARTED} has a peer again", connected, timeout=120)

    def same_tip():
        tips = {n: get(f"http://{n}:8000/v1/blocks/head")["id"] for n in NODES}
        return len(set(tips.values())) == 1, heights()

    wait_for("all nodes on the same tip after the restart", same_tip, timeout=180)


def test_the_indexer_gets_events_of_the_restarted_node():
    # pouw-node#144: the node numbered its events from 1 again, below the cursor the
    # indexer kept, and the indexer stored no event of it any more
    before = int(os.environ["E2E_CURSOR_BEFORE"])

    def past_the_restart():
        cursor = event_cursors().get(RESTARTED, 0)
        return cursor > before, {"before": before, "now": cursor}

    seen = wait_for(f"events of {RESTARTED} after its restart", past_the_restart, timeout=180)

    def growing():
        cursor = event_cursors().get(RESTARTED, 0)
        return cursor > seen["now"], {"first": seen["now"], "now": cursor}

    wait_for(f"new events of {RESTARTED} keep coming", growing, timeout=180)
