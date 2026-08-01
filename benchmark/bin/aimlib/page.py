"""Seeded target plans + the self-contained fixture page they render to.

Runner contract: `plan_batch(seed, suite, condition, batch, probes)` returns a
deterministic `BatchPlan` (same seed -> identical probe order, forever), and
`render_page(plan)` returns ONE self-contained HTML document — no external
resource of any kind, so the default browser policy serves it over loopback HTTP
with zero configuration. The page publishes `window.__aim`
(`meta`/`layout`/`hits`/`ready`), mirrors the whole object into
`localStorage["aim:<batch_id>"]` on every mutation, and exposes
`window.__aim.setReady()` — the harness calls that over CDP once window geometry
is settled, which renders the `READY` token the model is told to wait for.

Ground-truth geometry is whatever the LIVE page reports in `window.__aim.layout`
(`getBoundingClientRect()` at load); the constants here only guarantee the
plan-side invariants a hermetic test can check — chiefly that no target ever sits
within `MIN_EDGE_CLEARANCE_PX` of a window edge, so an off-by-one-cell arithmetic
miss (the measured failure class) still lands inside the page. Nothing in this
module touches the network, the filesystem, or any host state.
"""

from __future__ import annotations

import json
import random
import string
from dataclasses import dataclass, field

# --- geometry (page CSS px; deliberately constants, not knobs) ---------------

GRID_COLS = 12
GRID_ROWS = 6
CELL_PX = 120
LABEL_PX = 40
GRID_ORIGIN_X = 200
GRID_ORIGIN_Y = 100

# Scatter canvas for the non-grid modes. Chosen so every placement clears the
# window edges by >= MIN_EDGE_CLEARANCE_PX on a display at least 1920x1000 CSS px;
# the page also measures the LIVE clearance into `meta.min_clearance` so a smaller
# window fails loud at calibration instead of silently clipping targets.
PLAY_X = 240
PLAY_Y = 240
PLAY_W = 1400
PLAY_H = 480

RING_PX = 90
MARK_W = 140
MARK_H = 48
CAL_W = 200
CAL_H = 80
CAL_X = 240
CAL_Y = 240

MIN_EDGE_CLEARANCE_PX = 160
FIRED_COLOR = "#ff7a00"

# Buttons for the marks suite: one word each, visually and phonetically distinct
# so "the button labeled X" is unambiguous in the accessibility table.
MARK_LABELS = ("Anchor", "Basalt", "Cobalt", "Drift", "Ember", "Fjord",
               "Gambit", "Harbor", "Ingot", "Jetty", "Kelvin", "Lumen")

MODES = ("grid", "single", "marks", "cal")
SUITE_MODES = {"s1": "grid", "s2": "single", "s3": "marks", "cal": "cal"}


class PlanError(ValueError):
    """A batch plan was requested that the fixture page cannot represent."""


@dataclass(frozen=True)
class BatchPlan:
    batch_id: str
    suite: str
    condition: str
    batch: int
    mode: str
    targets: tuple[str, ...]
    seed_key: str
    meta: dict = field(default_factory=dict)

    @property
    def probes(self) -> int:
        return len(self.targets)


def batch_id(suite: str, condition: str, batch: int) -> str:
    """The page/session-visible batch token. `condition` is `na` for the suites
    that have only one view condition (marks, calibration)."""
    if not suite or not condition:
        raise PlanError("batch_id needs a suite and a condition")
    if batch < 1:
        raise PlanError(f"batch number must be >= 1, got {batch}")
    return f"{suite}-{condition}-b{batch}"


def cell_id(col: int, row: int) -> str:
    """Chess-style cell name: column letter A-L, row number 1-6 top to bottom."""
    if not 0 <= col < GRID_COLS or not 0 <= row < GRID_ROWS:
        raise PlanError(f"cell ({col},{row}) is outside the {GRID_COLS}x{GRID_ROWS} grid")
    return f"{string.ascii_uppercase[col]}{row + 1}"


def parse_cell_id(name: str) -> tuple[int, int]:
    """Inverse of `cell_id`. Raises on anything that is not a grid cell name."""
    if len(name) < 2 or name[0] not in string.ascii_uppercase[:GRID_COLS]:
        raise PlanError(f"not a grid cell id: {name!r}")
    col = string.ascii_uppercase.index(name[0])
    if not name[1:].isdigit():
        raise PlanError(f"not a grid cell id: {name!r}")
    row = int(name[1:]) - 1
    if not 0 <= row < GRID_ROWS:
        raise PlanError(f"row out of range in cell id: {name!r}")
    return col, row


def cell_rect(col: int, row: int) -> tuple[int, int, int, int]:
    """(left, top, w, h) of a grid cell in page CSS px."""
    left = GRID_ORIGIN_X + LABEL_PX + col * CELL_PX
    top = GRID_ORIGIN_Y + LABEL_PX + row * CELL_PX
    return left, top, CELL_PX, CELL_PX


def interior_cells() -> list[tuple[int, int]]:
    """Cells eligible to be targets: never the outermost ring, so a one-cell
    arithmetic miss in any direction still lands on the page (stray-click rule)."""
    return [(c, r) for r in range(1, GRID_ROWS - 1) for c in range(1, GRID_COLS - 1)]


# --- plans ------------------------------------------------------------------

def plan_batch(seed: int, suite: str, condition: str, batch: int, probes: int) -> BatchPlan:
    """Deterministic target plan for one batch. The seed key pins the draw to
    (seed, suite, condition, batch), so a rerun with the same `--seed` is
    probe-for-probe identical and two batches never share an order."""
    if suite not in SUITE_MODES:
        raise PlanError(f"unknown suite {suite!r}; known: {sorted(SUITE_MODES)}")
    if probes < 1:
        raise PlanError(f"a batch needs at least one probe, got {probes}")
    mode = SUITE_MODES[suite]
    seed_key = f"{seed}:{suite}:{condition}:{batch}"
    rng = random.Random(seed_key)
    targets, meta = _draw_targets(mode, probes, rng)
    return BatchPlan(batch_id=batch_id(suite, condition, batch), suite=suite,
                     condition=condition, batch=batch, mode=mode,
                     targets=tuple(targets), seed_key=seed_key, meta=meta)


def _draw_targets(mode: str, probes: int, rng: random.Random) -> tuple[list[str], dict]:
    if mode == "grid":
        return _draw_grid(probes, rng), {}
    if mode == "single":
        return _draw_single(probes, rng)
    if mode == "marks":
        return _draw_marks(probes, rng), {}
    return _draw_cal(probes)


def _draw_grid(probes: int, rng: random.Random) -> list[str]:
    cells = interior_cells()
    if probes > len(cells):
        raise PlanError(f"grid batch wants {probes} probes but only {len(cells)} interior cells exist")
    return [cell_id(c, r) for c, r in rng.sample(cells, probes)]


def _draw_single(probes: int, rng: random.Random) -> tuple[list[str], dict]:
    """One ring per probe, placed on a jittered 4x2 lattice so positions never
    overlap and every probe forces a fresh locate."""
    slots = _lattice(4, 2, RING_PX, RING_PX, rng)
    if probes > len(slots):
        raise PlanError(f"single batch wants {probes} probes but the lattice has {len(slots)} slots")
    chosen = rng.sample(slots, probes)
    targets = [f"p{i + 1}" for i in range(probes)]
    return targets, {"positions": {tid: xy for tid, xy in zip(targets, chosen)}}


def _draw_marks(probes: int, rng: random.Random) -> list[str]:
    if probes > len(MARK_LABELS):
        raise PlanError(f"marks batch wants {probes} probes but only {len(MARK_LABELS)} buttons exist")
    return list(rng.sample(list(MARK_LABELS), probes))


def _draw_cal(probes: int) -> tuple[list[str], dict]:
    if probes != 1:
        raise PlanError(f"the calibration page has exactly one target, got {probes} probes")
    return ["CAL"], {}


def _lattice(cols: int, rows: int, w: int, h: int, rng: random.Random) -> list[tuple[int, int]]:
    """Jittered lattice of top-left positions inside the play rect. Cell-bounded
    jitter is what keeps placements non-overlapping without a retry loop."""
    cell_w = PLAY_W // cols
    cell_h = PLAY_H // rows
    if cell_w < w or cell_h < h:
        raise PlanError(f"a {cols}x{rows} lattice cannot hold {w}x{h} items in {PLAY_W}x{PLAY_H}")
    out = []
    for r in range(rows):
        for c in range(cols):
            x = PLAY_X + c * cell_w + rng.randrange(0, cell_w - w + 1)
            y = PLAY_Y + r * cell_h + rng.randrange(0, cell_h - h + 1)
            out.append((x, y))
    return out


def min_edge_clearance(plan: BatchPlan) -> int:
    """Smallest plan-side distance from any target to the page origin edges. The
    live page measures the real four-sided clearance; this is the half a hermetic
    test can assert."""
    boxes = _target_boxes(plan)
    if not boxes:
        raise PlanError(f"plan {plan.batch_id} has no targets to measure")
    return min(min(x, y) for x, y, _w, _h in boxes)


def _target_boxes(plan: BatchPlan) -> list[tuple[int, int, int, int]]:
    if plan.mode == "grid":
        return [cell_rect(*parse_cell_id(t)) for t in plan.targets]
    if plan.mode == "single":
        pos = plan.meta["positions"]
        return [(pos[t][0], pos[t][1], RING_PX, RING_PX) for t in plan.targets]
    if plan.mode == "marks":
        layout = _marks_layout()
        return [(layout[t][0], layout[t][1], MARK_W, MARK_H) for t in plan.targets]
    return [(CAL_X, CAL_Y, CAL_W, CAL_H)]


def _marks_layout() -> dict[str, tuple[int, int]]:
    """Fixed 4x3 arrangement of the twelve buttons. Fixed (not seeded) because the
    measured skill in the marks suite is mark->number resolution, not locating."""
    cell_w = PLAY_W // 4
    cell_h = PLAY_H // 3
    out = {}
    for i, label in enumerate(MARK_LABELS):
        col, row = i % 4, i // 4
        out[label] = (PLAY_X + col * cell_w + (cell_w - MARK_W) // 2,
                      PLAY_Y + row * cell_h + (cell_h - MARK_H) // 2)
    return out


# --- page rendering ---------------------------------------------------------

_CSS = """
html, body { margin: 0; padding: 0; width: 100%; height: 100%; overflow: hidden;
  background: #ffffff; font-family: Helvetica, Arial, sans-serif; }
#aim-status { position: absolute; left: 200px; top: 24px; font-size: 30px;
  font-weight: bold; letter-spacing: 3px; color: #202020; }
#aim-grid, #aim-play { position: absolute; }
.cell { position: absolute; box-sizing: border-box; border: 1px solid #8a8a8a;
  display: flex; align-items: center; justify-content: center; font-size: 22px;
  font-weight: bold; color: #ffffff; }
.light { background: #d8d8d8; }
.dark { background: #b0b0b0; }
.lbl { position: absolute; display: flex; align-items: center; justify-content: center;
  font-size: 28px; font-weight: bold; color: #202020; }
.ring { position: absolute; box-sizing: border-box; border-radius: 50%;
  border: 10px solid #1a4fd6; background: #ffffff; }
.mbtn { position: absolute; box-sizing: border-box; font-size: 20px; font-weight: bold;
  background: #e8e8e8; border: 2px solid #555555; color: #202020; }
.cal { position: absolute; box-sizing: border-box; font-size: 28px; font-weight: bold;
  background: #e8e8e8; border: 2px solid #555555; color: #202020; }
.pending { visibility: hidden; }
.fired { background: __FIRED__ !important; border-color: __FIRED__ !important;
  color: #ffffff !important; }
"""

# The listener is the ground-truth recorder. It runs in the capture phase so no
# page handler can hide a click from it, records EVERY click (trusted or not,
# on a target or not), and mirrors the whole state into localStorage on every
# mutation so the record survives independently of the CDP readback.
_JS = """
(function () {
  var CFG = __CFG__;
  var aim = {batch_id: CFG.batch_id, mode: CFG.mode, ready: false, cursor: 0,
             meta: {}, layout: {}, hits: [], errors: []};
  window.__aim = aim;

  function mirror() {
    try { window.localStorage.setItem('aim:' + CFG.batch_id, JSON.stringify(aim)); }
    catch (err) { aim.errors.push('mirror: ' + err); }
  }

  function node(id) { return document.querySelector('[data-aim-target="' + id + '"]'); }

  function snapshotLayout() {
    var nodes = document.querySelectorAll('[data-aim-target]');
    for (var i = 0; i < nodes.length; i++) {
      var r = nodes[i].getBoundingClientRect();
      aim.layout[nodes[i].getAttribute('data-aim-target')] = {
        x: r.left, y: r.top, w: r.width, h: r.height,
        cx: r.left + r.width / 2, cy: r.top + r.height / 2};
    }
  }

  function minClearance() {
    var best = -1;
    for (var i = 0; i < CFG.targets.length; i++) {
      var b = aim.layout[CFG.targets[i]];
      if (!b) { return -1; }
      var c = Math.min(b.x, b.y, window.innerWidth - (b.x + b.w),
                       window.innerHeight - (b.y + b.h));
      if (i === 0 || c < best) { best = c; }
    }
    return best;
  }

  function snapshotMeta() {
    aim.meta = {
      batch_id: CFG.batch_id, mode: CFG.mode, cell_px: CFG.cell_px,
      dpr: window.devicePixelRatio,
      screen_w: window.screen.width, screen_h: window.screen.height,
      avail_w: window.screen.availWidth, avail_h: window.screen.availHeight,
      screen_x: window.screenX, screen_y: window.screenY,
      inner_w: window.innerWidth, inner_h: window.innerHeight,
      outer_w: window.outerWidth, outer_h: window.outerHeight,
      vv_scale: window.visualViewport ? window.visualViewport.scale : null,
      scroll_x: window.scrollX, scroll_y: window.scrollY,
      min_clearance: minClearance(),
      has_focus: document.hasFocus(), visibility: document.visibilityState,
      ua: navigator.userAgent, loaded_at: Date.now()};
  }

  function fire(id) {
    var el = node(id);
    if (!el || el.className.indexOf('fired') >= 0) { return null; }
    el.className = el.className + ' fired';
    if (CFG.mode !== 'single') { el.textContent = 'FIRED'; }
    return id;
  }

  function advance() {
    if (CFG.mode !== 'single') { return; }
    var cur = node(CFG.targets[aim.cursor]);
    if (cur && cur.className.indexOf('fired') < 0) { cur.className = cur.className + ' pending'; }
    aim.cursor = aim.cursor + 1;
    var next = aim.cursor < CFG.targets.length ? node(CFG.targets[aim.cursor]) : null;
    if (next) { next.className = next.className.replace(' pending', ''); }
  }

  document.addEventListener('click', function (ev) {
    var el = ev.target && ev.target.closest ? ev.target.closest('[data-aim-target]') : null;
    var id = el ? el.getAttribute('data-aim-target') : null;
    var fired = (id && ev.isTrusted) ? fire(id) : null;
    aim.hits.push({seq: aim.hits.length + 1, t: Date.now(), target_id: id,
                   x: ev.clientX, y: ev.clientY, sx: ev.screenX, sy: ev.screenY,
                   trusted: ev.isTrusted === true, fired_target: fired,
                   scroll_x: window.scrollX, scroll_y: window.scrollY,
                   cursor: aim.cursor});
    if (ev.isTrusted) { advance(); }
    mirror();
  }, true);

  aim.setReady = function () {
    aim.ready = true;
    var el = document.getElementById('aim-status');
    if (el) { el.textContent = 'READY'; }
    mirror();
    return true;
  };

  snapshotLayout();
  snapshotMeta();
  mirror();
})();
"""

_HTML = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>aim __BATCH__</title>
<style>__CSS__</style></head>
<body>
<div id="aim-status">WAIT</div>
__BODY__
<script>__JS__</script>
</body></html>
"""


def render_page(plan: BatchPlan) -> str:
    """The complete fixture document for one batch. Self-contained by construction:
    no <link>, <img>, <script src>, @import or fetch anywhere in the output."""
    cfg = {"batch_id": plan.batch_id, "mode": plan.mode,
           "targets": list(plan.targets), "cell_px": CELL_PX}
    body = _render_body(plan)
    js = _JS.replace("__CFG__", json.dumps(cfg))
    css = _CSS.replace("__FIRED__", FIRED_COLOR)
    return (_HTML.replace("__BATCH__", plan.batch_id)
            .replace("__CSS__", css).replace("__BODY__", body).replace("__JS__", js))


def _render_body(plan: BatchPlan) -> str:
    if plan.mode == "grid":
        return _grid_body()
    if plan.mode == "single":
        return _single_body(plan)
    if plan.mode == "marks":
        return _marks_body()
    return _cal_body()


def _grid_body() -> str:
    """Checkerboard with coordinate labels on all four edges and NO in-cell label:
    a printed per-cell name would let the model read the answer instead of
    computing it, and the arithmetic is exactly what M1 measures."""
    parts = [f'<div id="aim-grid" style="left:{GRID_ORIGIN_X}px;top:{GRID_ORIGIN_Y}px;'
             f'width:{2 * LABEL_PX + GRID_COLS * CELL_PX}px;'
             f'height:{2 * LABEL_PX + GRID_ROWS * CELL_PX}px">']
    for row in range(GRID_ROWS):
        for col in range(GRID_COLS):
            shade = "light" if (col + row) % 2 == 0 else "dark"
            left = LABEL_PX + col * CELL_PX
            top = LABEL_PX + row * CELL_PX
            parts.append(f'<div class="cell {shade}" data-aim-target="{cell_id(col, row)}" '
                         f'style="left:{left}px;top:{top}px;'
                         f'width:{CELL_PX}px;height:{CELL_PX}px"></div>')
    parts.extend(_grid_labels())
    parts.append("</div>")
    return "\n".join(parts)


def _grid_labels() -> list[str]:
    out = []
    for col in range(GRID_COLS):
        letter = string.ascii_uppercase[col]
        left = LABEL_PX + col * CELL_PX
        for top in (0, LABEL_PX + GRID_ROWS * CELL_PX):
            out.append(f'<div class="lbl" style="left:{left}px;top:{top}px;'
                       f'width:{CELL_PX}px;height:{LABEL_PX}px">{letter}</div>')
    for row in range(GRID_ROWS):
        top = LABEL_PX + row * CELL_PX
        for left in (0, LABEL_PX + GRID_COLS * CELL_PX):
            out.append(f'<div class="lbl" style="left:{left}px;top:{top}px;'
                       f'width:{LABEL_PX}px;height:{CELL_PX}px">{row + 1}</div>')
    return out


def _single_body(plan: BatchPlan) -> str:
    """Every ring exists at load (so `layout` is complete) but only the current one
    is visible; `visibility: hidden` keeps the rect measurable and makes the
    pending rings unclickable."""
    positions = plan.meta["positions"]
    parts = ['<div id="aim-play" style="left:0px;top:0px">']
    for index, tid in enumerate(plan.targets):
        x, y = positions[tid]
        pending = "" if index == 0 else " pending"
        parts.append(f'<div class="ring{pending}" data-aim-target="{tid}" '
                     f'style="left:{x}px;top:{y}px;width:{RING_PX}px;height:{RING_PX}px"></div>')
    parts.append("</div>")
    return "\n".join(parts)


def _marks_body() -> str:
    layout = _marks_layout()
    parts = ['<div id="aim-play" style="left:0px;top:0px">']
    for label in MARK_LABELS:
        x, y = layout[label]
        parts.append(f'<button class="mbtn" data-aim-target="{label}" '
                     f'style="left:{x}px;top:{y}px;width:{MARK_W}px;height:{MARK_H}px">'
                     f'{label}</button>')
    parts.append("</div>")
    return "\n".join(parts)


def _cal_body() -> str:
    return (f'<button class="cal" data-aim-target="CAL" '
            f'style="left:{CAL_X}px;top:{CAL_Y}px;width:{CAL_W}px;height:{CAL_H}px">CAL</button>')
