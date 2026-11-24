"""An eval home whose owner inbox is the local terminal chat (`requires: [owner_inbox_cli]`).

Every eval home's configured default delivery target is a Telegram chat with an
owner id and no bot token (`seed_capability_home.render_config`), so a message
Fermix sends to the owner's inbox (a job heal's, M106 §5.4) resolves to an inbox
no adapter can reach, and nothing an eval reads records it as sent.
`seed_capability_home.py --owner-inbox-cli` makes the local `cli` chat the
configured target instead. `Delivery.OwnerInbox` takes a local channel at rung
one as the owner's own (`for_approval/1`, `resolve/1`), the jobs channels map
names `FermixChannels.CLI` for `cli`, and its `send_message/3` needs no
credentials, so the send succeeds and the heal's row records it delivered. The
local chat keeps no history row for it (`Jobs.HealRun` writes history only for an
inbox keyed as a turn is), so an eval reads the row, never the chat.

The seed writes `MANIFEST`; a seed without the flag removes it, and both runners
hold a case that requires `REQUIREMENT` out as NOT EVALUATED on a home without it.
"""

from __future__ import annotations

import os

REQUIREMENT = "owner_inbox_cli"
MANIFEST = os.path.join("eval-fixtures", "owner_inbox.json")
# The `[fermix_core.jobs] default_delivery_target` the seed writes: the local chat
# `FermixChannels.CLI` serves, keyed as the open-loop seeds key it (seed_state.exs).
TARGET = {"platform": "cli", "chat_id": "cli"}


def home_problem(home: str) -> str | None:
    """Why `home` cannot run a case that requires the local owner inbox, or None."""
    path = os.path.join(os.path.expanduser(home), MANIFEST)
    if os.path.isfile(path):
        return None
    return ("the eval home was not seeded with --owner-inbox-cli (seed_capability_home.py), "
            "so the owner's inbox is a Telegram chat no message reaches")
