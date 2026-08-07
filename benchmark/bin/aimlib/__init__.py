"""Aimed-click accuracy harness library (M28 Phase C1).

Measures the MODEL, not the click pipeline: coordinate arithmetic inside a known
rect (hit rate + miss vectors in CSS px and cell units) and click-effect blindness
(the model's own "did the target fire?" report graded against page ground truth).

Composition order a runner follows: `page.plan_batch` + `page.render_page` build
the seeded fixture, `server.AimServer` publishes it on loopback, `prompts` renders
the one turn per batch, `cdp` attaches the harness's own DevTools client for
window geometry + the READY handshake + the 500 ms readback, `traces` reads the
daemon's JSONL delivery evidence, and `score` time-merges the two into typed
outcomes, `results.json`, and `report.md`.
"""

__all__ = ["page", "server", "cdp", "traces", "prompts", "score"]
