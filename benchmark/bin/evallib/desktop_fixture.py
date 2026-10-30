"""The eval home's paired desktop whose machine is offline (M75 §11), for the
device_actions suite.

`seed_capability_home.py --desktop` writes one `desktop` row into the home's trust
store (`mobile/devices.toml`, the shape `FermixChannels.Mobile.DeviceStore` reads)
with actions on, and this module's manifest beside it. No desktop engine ever
connects to an eval home, so the daemon offers `device_action` (a desktop row lets
actions run) and every call meets a desktop that is not connected: the honest
answer the suite grades. A seed without `--desktop` removes both, so no other suite
is offered a tool its turns never asked for.

`home_problem/1` is what `run_eval.py` asks before driving a suite that
`requires: [desktop]`: a home seeded without it holds the suite out as NOT
EVALUATED, never as zeros.
"""

from __future__ import annotations

import base64
import json
import os

MANIFEST = os.path.join("eval-fixtures", "desktop.json")
DEVICES = os.path.join("mobile", "devices.toml")

# Invented: a desktop row as the move writes one (M75 §3). Its Noise key is fresh on
# every seed; nothing can authenticate with it, which is the point.
DESKTOP = {
    "device_id": "5d6c7b8a-9e0f-4a1b-8c2d-3e4f5a6b7c8d",
    "name": "Studio Mac",
    "model": "Mac15,8",
    "created_at": "2026-10-20T07:15:00Z",
}


def devices_toml(noise_pk: bytes) -> str:
    """The trust store holding the one desktop row, actions on."""
    if len(noise_pk) != 32:
        raise ValueError(f"a Noise public key is 32 bytes, got {len(noise_pk)}")
    key = base64.b64encode(noise_pk).decode("ascii")
    return "\n".join([
        "[[devices]]",
        f'created_at = "{DESKTOP["created_at"]}"',
        f'device_id = "{DESKTOP["device_id"]}"',
        "executor = true",
        'kind = "desktop"',
        f'model = "{DESKTOP["model"]}"',
        f'name = "{DESKTOP["name"]}"',
        f'noise_pk = "{key}"',
        "",
    ])


def manifest() -> str:
    """What the runner reads to know the home was seeded, and with which desktop."""
    return json.dumps({"devices": DEVICES, "desktop": DESKTOP}, indent=2)


def home_problem(home: str) -> str | None:
    """Why this eval home cannot run a suite that `requires: [desktop]`, or None."""
    if not os.path.isfile(os.path.join(home, MANIFEST)):
        return (f"the eval home has no seeded desktop ({MANIFEST} is missing; seed it with "
                "seed_capability_home.py --desktop)")
    if not os.path.isfile(os.path.join(home, DEVICES)):
        return f"the eval home's seeded desktop row is gone ({DEVICES} is missing; seed again)"
    return None
