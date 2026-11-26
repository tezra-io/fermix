"""An eval home whose owner inbox is the local terminal chat (`requires: [owner_inbox_cli]`)
or the Fermix app's chat (`requires: [owner_inbox_app]`).

Every eval home's configured default delivery target is a Telegram chat with an
owner id and no bot token (`seed_capability_home.render_config`), so a message
Fermix sends to the owner's inbox (a job heal's, M106 §5.4) resolves to an inbox
no adapter can reach, and nothing an eval reads records it as sent.
`seed_capability_home.py --owner-inbox-cli` makes the local `cli` chat the
configured target instead. `Delivery.OwnerInbox` takes a local channel at rung
one as the owner's own (`for_approval/2`, `resolve/1`), the jobs channels map
names `FermixChannels.CLI` for `cli`, and its `send_message/3` needs no
credentials, so the send succeeds and the heal's row records it delivered. The
local chat keeps no history row for it (`Jobs.HealRun` writes history only for an
inbox keyed as a turn is), so an eval reads the row, never the chat.

`--owner-inbox-app` makes the app's chat the target instead (M106 §8, stage S6): the
companion channel's conversation `main`, the Mac chat's, which a paired phone shares.
`OwnerInbox` takes a target naming it as the owner's own at rung one, while the
`companion` adapter names that chat as its inbox (`owner_inbox/0`); a message is a row
in the app's timeline (`mobile_timeline`, keyed by its send key, `metadata.origin` its
job) and a row in that conversation's history, and a heal's proposal is offered to the
app as an `approval` card of kind `job_change`, answered by sending its route as a
`command` on the companion socket (`drive: app`, evallib/app_drive.py).

The seed writes `MANIFEST`, naming the target it set; a seed with neither flag removes
it, and both runners hold a case that requires one inbox out as NOT EVALUATED on a home
seeded for the other or for none.
"""

from __future__ import annotations

import json
import os

REQUIREMENT = "owner_inbox_cli"
MANIFEST = os.path.join("eval-fixtures", "owner_inbox.json")
# The `[fermix_core.jobs] default_delivery_target` the seed writes: the local chat
# `FermixChannels.CLI` serves, keyed as the open-loop seeds key it (seed_state.exs).
TARGET = {"platform": "cli", "chat_id": "cli"}
APP_REQUIREMENT = "owner_inbox_app"
# The app's chat: the `companion` channel's conversation, as its adapter names it.
APP_TARGET = {"platform": "companion", "chat_id": "main"}
# Each requirement, the target its home's manifest names and the seed flag that sets it.
INBOXES = {REQUIREMENT: (TARGET, "--owner-inbox-cli"),
           APP_REQUIREMENT: (APP_TARGET, "--owner-inbox-app")}


def home_problem(home: str, requirement: str = REQUIREMENT) -> str | None:
    """Why `home` cannot run a case that requires `requirement`'s owner inbox, or None."""
    target, flag = INBOXES[requirement]
    path = os.path.join(os.path.expanduser(home), MANIFEST)
    if not os.path.isfile(path):
        return (f"the eval home was not seeded with {flag} (seed_capability_home.py), "
                "so the owner's inbox is a Telegram chat no message reaches")
    try:
        with open(path, encoding="utf-8") as fh:
            seeded = json.load(fh).get("default_delivery_target")
    except (OSError, ValueError, AttributeError) as exc:
        return f"the eval home's {MANIFEST} cannot be read ({exc}); seed it again with {flag}"
    if seeded != target:
        return (f"the eval home's owner inbox is {seeded!r}, not {target!r}: seed it with "
                f"{flag}")
    return None
