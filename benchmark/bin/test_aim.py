#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the aimed-click harness library (`bin/aimlib`).

Hermetic by construction: no daemon, no Opik, no live browser, no display, no
network beyond a loopback ephemeral-port `http.server` started inside this
process, and nothing under `~/.fermix*` is read or written. Every trace and echo
fixture string below is copied verbatim from the Elixir source that renders it,
with the file:line it came from — a paraphrase here would test the harness
against a daemon that does not exist. Run: `uv run bin/test_aim.py`.
"""
from __future__ import annotations

import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402

import run_aim  # noqa: E402
from aimlib import cdp, page, prompts, score, server, traces  # noqa: E402

BASE_MS = 1_780_000_000_000
# The name the harness hands to `fermix ask`. It reaches NO trace field: the daemon
# stamps each main-agent turn with its own id (`agents/turn_runner.ex:221`) and
# `Telemetry` copies only `:session_id`/`:parent_session` (`telemetry.ex:16`). Every
# row fixture below therefore carries the shape the daemon really writes.
SESSION = "e2e-aim-r1-s1-full_screen-b1"
TURN_ID = "main-7"


def iso(ms: float, zulu: bool = False) -> str:
    stamp = datetime.fromtimestamp(ms / 1000.0, tz=timezone.utc).isoformat()
    return stamp.replace("+00:00", "Z") if zulu else stamp


def cu_row(*, at_ms: float, action: str = "left_click", success: bool = True,
           output: str = "", args: str | None = None, duration: int = 200,
           session: str = TURN_ID, agent: str = "main") -> dict:
    row = {"agent": agent, "tool": "computer_use", "action": action, "success": success,
           "duration_ms": duration, "output": output, "session_id": session,
           "ts": iso(at_ms), "type": "tool_exec"}
    if args is not None:
        row["input"] = args
    return row


def browser_row(*, at_ms: float, action: str, kind: str | None = None,
                session: str = TURN_ID, args: str | None = None,
                success: bool = True) -> dict:
    row = {"agent": "main", "tool": "browser", "action": action, "success": success,
           "duration_ms": 50, "session_id": session, "ts": iso(at_ms), "type": "tool_exec"}
    if kind:
        row["kind"] = kind
    if args is not None:
        row["input"] = args
    return row


AIM_FRAGMENT = "127.0.0.1:50256/aim.html?batch=s1-full_screen-b1"
OPEN_INPUT = ('%{"action" => "open", "profile" => "fermix_visible", '
              '"url" => "http://' + AIM_FRAGMENT + '&mode=grid"}')


def llm_row(*, at_ms: float, provider: str, model: str, effort: str | None = None,
            agent: str = "main", session: str = TURN_ID) -> dict:
    row = {"agent": agent, "session_id": session, "provider": provider, "model": model,
           "ts": iso(at_ms), "type": "llm_call"}
    if effort:
        row["reasoning_effort"] = effort
    return row


# --- fixture strings, copied from the daemon sources ------------------------

# apps/fermix_core/lib/fermix_core/computer_use/session.ex:920 area (screenshot_summary
# dims) + :981 (cursor echo) + the trailing untrusted-image notice.
FULL_SHOT_OUTPUT = ("screenshot 1931x543 (display 0). Cursor at (417,152). "
                    "This is what is really on screen — read it and act on what it shows.")
# session.ex:993 — the full-screen equivalent, present only on a magnified crop.
CROP_SHOT_OUTPUT = ("screenshot 1355x959 (display 0). Cursor at (700,400)"
                    " = (830,495) on the full screen.")
# session.ex:965 — the delivery marker.
NOT_DELIVERED_OUTPUT = (" NOT delivered at (418,152) — the pointer never reached that point, so this "
                        "action did nothing. Re-send the SAME action with the SAME region and coordinates.")
# session.ex:926-927 — an empty marks table is a loud absence.
NO_MARKS_OUTPUT = ("screenshot 1931x543 (display 0). 0 accessibility marks — AX exposed no "
                   "click targets in this view.")
MARKS_OUTPUT = ("screenshot 1931x543 (display 0). 12 numbered mark(s) badged on the image — "
                "act on one by sending `mark: <id>` instead of x,y:\nmark 1: button \"Anchor\" at (300,300)")

# apps/fermix_core/lib/fermix_core/tools/computer_use.ex — the five typed refusals:
# region mismatch :410, ambiguous :454, no marks :428, stale marks :433, unknown mark :439.
REGION_MISMATCH_OUTPUT = ('your latest coordinate source uses region {"x": 100, "y": 50, "w": 482, "h": 341}, '
                          "so the x,y you just sent would be read in full-screen space and miss. Re-send this "
                          'action with `"region": {"x": 100, "y": 50, "w": 482, "h": 341}` and the coordinates '
                          "from that source — or take a fresh full `screenshot` first and use full-screen coordinates.")
AMBIGUOUS_OUTPUT = ('ambiguous coordinates: (300,200) fits both this 1355x959 magnified crop and the on-screen '
                    'region box {"x": 100, "y": 50, "w": 482, "h": 341}. Your latest view is the CROP. If you '
                    'meant pixels of that magnified image, re-send the SAME action with `"confirm_grid": true`. '
                    "If you read the full screen instead, convert — subtract the region origin, then multiply "
                    "by 2.81: that lands at (562,421) in this crop.")
NO_MARKS_REFUSAL = ("no live marks — take a fresh `screenshot` with `\"marks\": true` and use the mark "
                    "numbers it returns.")
STALE_MARKS_REFUSAL = ("the marks were taken on a view you have since left, so their numbers no longer point "
                       "where the badges showed. Take a fresh `screenshot` with `\"marks\": true` and use ITS "
                       "mark numbers.")
UNKNOWN_MARK_REFUSAL = ("mark 19 does not exist — the latest marks screenshot has 12 mark(s). Use one of its "
                        "numbers, or take a fresh `screenshot` with `\"marks\": true`.")

# `Telemetry.preview/1` writes `input` with Elixir's `inspect/2`, not JSON.
CLICK_INPUT = '%{"action" => "left_click", "x" => 418, "y" => 152}'
SHOT_INPUT = '%{"action" => "screenshot", "display" => 0}'
CROP_INPUT = '%{"action" => "screenshot", "region" => %{"x" => 100, "y" => 50, "w" => 482, "h" => 341}}'


# --- target plans -----------------------------------------------------------

def test_plan_is_deterministic_for_a_seed():
    a = page.plan_batch(7, "s1", "full_screen", 1, 4)
    b = page.plan_batch(7, "s1", "full_screen", 1, 4)
    assert a.targets == b.targets and a.seed_key == b.seed_key


def test_plan_differs_across_batch_condition_and_suite():
    base = page.plan_batch(7, "s1", "full_screen", 1, 4).targets
    assert page.plan_batch(7, "s1", "full_screen", 2, 4).targets != base
    assert page.plan_batch(7, "s1", "crop", 1, 4).targets != base
    assert page.plan_batch(8, "s1", "full_screen", 1, 4).targets != base


def test_plan_never_repeats_a_target_within_a_batch():
    for suite, probes in (("s1", 4), ("s2", 8), ("s3", 8)):
        plan = page.plan_batch(3, suite, "full_screen", 1, probes)
        assert len(set(plan.targets)) == probes


def test_every_grid_target_clears_the_window_edges():
    for batch in range(1, 7):
        plan = page.plan_batch(11, "s1", "full_screen", batch, 4)
        assert page.min_edge_clearance(plan) >= page.MIN_EDGE_CLEARANCE_PX
        for target in plan.targets:
            col, row = page.parse_cell_id(target)
            assert 0 < col < page.GRID_COLS - 1 and 0 < row < page.GRID_ROWS - 1


def test_single_and_marks_targets_also_clear_the_edges():
    for suite, probes in (("s2", 8), ("s3", 8)):
        plan = page.plan_batch(5, suite, "na", 1, probes)
        assert page.min_edge_clearance(plan) >= page.MIN_EDGE_CLEARANCE_PX


def test_cell_id_round_trips_and_rejects_junk():
    assert page.cell_id(3, 2) == "D3"
    assert page.parse_cell_id("D3") == (3, 2)
    with pytest.raises(page.PlanError):
        page.parse_cell_id("Z9")
    with pytest.raises(page.PlanError):
        page.parse_cell_id("D9")


def test_plan_refuses_impossible_requests():
    with pytest.raises(page.PlanError):
        page.plan_batch(1, "s3", "na", 1, 13)          # more probes than buttons
    with pytest.raises(page.PlanError):
        page.plan_batch(1, "cal", "na", 1, 2)          # the cal page has one target
    with pytest.raises(page.PlanError):
        page.plan_batch(1, "nope", "na", 1, 1)


# --- page generation --------------------------------------------------------

def test_page_is_entirely_self_contained():
    html = page.render_page(page.plan_batch(1, "s1", "full_screen", 1, 4))
    for forbidden in ("src=", "href=", "@import", "url(", "fetch(", "XMLHttpRequest"):
        assert forbidden not in html


def test_page_carries_the_listener_and_the_localstorage_mirror():
    html = page.render_page(page.plan_batch(1, "s1", "full_screen", 1, 4))
    assert "addEventListener('click'" in html and ", true);" in html
    assert "window.localStorage.setItem('aim:' + CFG.batch_id" in html
    assert "aim.setReady = function" in html
    assert "isTrusted" in html and "getBoundingClientRect" in html


def test_page_root_forbids_scrolling():
    html = page.render_page(page.plan_batch(1, "s1", "full_screen", 1, 4))
    assert "overflow: hidden" in html


def _markup(html: str) -> str:
    """The document body without the inline script — the script legitimately
    contains a `data-aim-target` selector, which would inflate element counts."""
    return html.split("<script>")[0]


def test_grid_page_has_every_cell_and_no_in_cell_label():
    plan = page.plan_batch(1, "s1", "full_screen", 1, 4)
    html = page.render_page(plan)
    assert _markup(html).count("data-aim-target=") == page.GRID_COLS * page.GRID_ROWS
    assert '<div class="cell light" data-aim-target="A1"' in html
    assert re.search(r'data-aim-target="D3"[^>]*></div>', html), "cells must render empty"
    assert html.count('class="lbl"') == 2 * page.GRID_COLS + 2 * page.GRID_ROWS


def test_grid_cell_geometry_matches_the_generated_style():
    left, top, width, height = page.cell_rect(*page.parse_cell_id("D3"))
    html = page.render_page(page.plan_batch(1, "s1", "full_screen", 1, 4))
    inner_left = left - page.GRID_ORIGIN_X
    inner_top = top - page.GRID_ORIGIN_Y
    assert f'style="left:{inner_left}px;top:{inner_top}px;width:{width}px;height:{height}px"' in html
    assert f'left:{page.GRID_ORIGIN_X}px;top:{page.GRID_ORIGIN_Y}px' in html


def test_single_page_bakes_the_position_sequence_and_hides_the_pending_rings():
    plan = page.plan_batch(2, "s2", "full_screen", 1, 8)
    html = page.render_page(plan)
    assert _markup(html).count("data-aim-target=") == 8
    assert html.count('class="ring pending"') == 7        # only the current ring is visible
    first_x, first_y = plan.meta["positions"][plan.targets[0]]
    assert f'class="ring" data-aim-target="{plan.targets[0]}" style="left:{first_x}px;top:{first_y}px' in html


def test_marks_page_renders_real_buttons():
    html = page.render_page(page.plan_batch(2, "s3", "na", 1, 8))
    assert html.count("<button") == len(page.MARK_LABELS)
    for label in page.MARK_LABELS:
        assert f'data-aim-target="{label}"' in html


def test_cal_page_has_exactly_one_target():
    html = page.render_page(page.plan_batch(2, "cal", "na", 1, 1))
    assert _markup(html).count("data-aim-target=") == 1
    assert 'data-aim-target="CAL"' in html


def test_fired_rendering_is_the_only_state_signal():
    """A fired target must be PERCEIVED as a colour change; no HUD text may name
    hit/miss state, or the fired report becomes a reading task."""
    html = page.render_page(page.plan_batch(1, "s1", "full_screen", 1, 4))
    assert page.FIRED_COLOR in html and "'FIRED'" in html
    for scoreboard_word in ("hit", "miss", "correct", "target 1", "score"):
        assert scoreboard_word not in _markup(html).lower()


# --- fixture server ---------------------------------------------------------

def test_server_serves_only_the_published_page():
    plan = page.plan_batch(1, "s1", "full_screen", 1, 4)
    srv = server.AimServer()
    srv.publish(plan.batch_id, page.render_page(plan))
    port = srv.start()
    try:
        assert port > 0
        url = srv.url_for(plan.batch_id, plan.mode)
        assert f"127.0.0.1:{port}/aim.html?batch={plan.batch_id}" in url
        with urllib.request.urlopen(url, timeout=5) as resp:
            assert resp.status == 200
            assert "window.__aim" in resp.read().decode("utf-8")
        assert _status(f"http://127.0.0.1:{port}/aim.html?batch=nope") == 404
        assert _status(f"http://127.0.0.1:{port}/other") == 404
    finally:
        srv.stop()


def test_server_refuses_an_unpublished_url_and_a_double_start():
    srv = server.AimServer()
    with pytest.raises(server.ServerError):
        srv.port
    srv.publish("b1", "<html></html>")
    srv.start()
    try:
        with pytest.raises(server.ServerError):
            srv.url_for("b2", "grid")
        with pytest.raises(server.ServerError):
            srv.start()
    finally:
        srv.stop()


def _status(url: str) -> int:
    try:
        with urllib.request.urlopen(url, timeout=5) as resp:
            return resp.status
    except urllib.error.HTTPError as exc:
        return exc.code


# --- CDP framing and discovery ----------------------------------------------

def test_framer_allocates_monotonic_ids_and_routes_by_session():
    framer = cdp.Framer()
    first_id, first = framer.command("Page.enable")
    second_id, second = framer.command("Runtime.evaluate", {"expression": "1"}, "S1")
    assert (first_id, second_id) == (1, 2)
    assert json.loads(first) == {"id": 1, "method": "Page.enable", "params": {}}
    assert json.loads(second)["sessionId"] == "S1"


def test_evaluate_round_trip_and_page_exception():
    params = cdp.evaluate_params("JSON.stringify(window.__aim)")
    assert params == {"expression": "JSON.stringify(window.__aim)",
                      "returnByValue": True, "awaitPromise": False}
    reply = {"id": 4, "result": {"result": {"type": "string", "value": "{}"}}}
    assert cdp.evaluate_value(cdp.result_of(cdp.decode(json.dumps(reply)))) == "{}"
    thrown = {"result": {"type": "object"},
              "exceptionDetails": {"exception": {"description": "TypeError: nope"}}}
    with pytest.raises(cdp.CdpError, match="TypeError: nope"):
        cdp.evaluate_value(thrown)


def test_protocol_error_and_junk_frames_are_typed():
    with pytest.raises(cdp.CdpError, match="CDP error -32000"):
        cdp.result_of({"id": 1, "error": {"code": -32000, "message": "no target"}})
    with pytest.raises(cdp.CdpError):
        cdp.decode("{not json")
    with pytest.raises(cdp.CdpError):
        cdp.result_of({"id": 1})


def test_port_discovery_picks_the_newest_profile(tmp_path):
    root = tmp_path / "profiles"
    _write_port(root, "ownerA", "9222", mtime=1_000_000)
    _write_port(root, "ownerB", "9333", mtime=2_000_000)
    assert cdp.discover_port(str(root)) == 9333


def test_a_malformed_newest_file_keeps_waiting_rather_than_using_an_older_browser(tmp_path):
    # Chrome writes the port file as it starts, so a half-written newest file means
    # THAT browser is not ready yet. Falling back to an older profile's port would
    # attach the harness to the wrong Chrome — it waits instead.
    root = tmp_path / "profiles"
    _write_port(root, "ownerA", "9222", mtime=1_000_000)
    _write_port(root, "ownerB", "", mtime=2_000_000)
    assert cdp.read_devtools_port(str(root / "ownerB" / "fermix_visible" / "DevToolsActivePort")) is None
    with pytest.raises(cdp.CdpError, match="never started"):
        cdp.discover_port(str(root), timeout_s=0.0, sleep=lambda _s: None)


def test_port_discovery_fails_loud_when_nothing_is_there(tmp_path):
    ticks = []
    with pytest.raises(cdp.CdpError, match="never started"):
        cdp.discover_port(str(tmp_path / "profiles"), timeout_s=0.0, sleep=ticks.append)
    assert cdp.read_devtools_port(str(tmp_path / "missing")) is None


def test_a_stale_port_file_from_an_earlier_conversation_is_not_this_run_s_browser(tmp_path):
    # A home keeps one profile dir per conversation and Chrome does not always
    # remove DevToolsActivePort, so "newest" alone can name a browser this run
    # never launched. The runner passes the turn's start as the freshness floor.
    root = tmp_path / "profiles"
    _write_port(root, "lastWeek", "9222", mtime=1_000_000)
    assert cdp.newest_port_file(str(root), since_ms=2_000_000 * 1000) is None
    with pytest.raises(cdp.CdpError, match="never started"):
        cdp.discover_port(str(root), timeout_s=0.0, sleep=lambda _s: None,
                          since_ms=2_000_000 * 1000)
    _write_port(root, "thisRun", "9444", mtime=3_000_000)
    assert cdp.discover_port(str(root), since_ms=2_000_000 * 1000) == 9444


def test_find_target_uses_the_json_list_id_key(monkeypatch):
    # Shape observed live 2026-08-01: the HTTP /json/list surface keys targets by
    # "id" — "targetId" exists only on the CDP Target.getTargets method. The first
    # live calibration crashed on exactly that difference, uncovered because this
    # lookup had no test at all.
    entry = {
        "description": "",
        "devtoolsFrontendUrl": "/devtools/inspector.html?ws=127.0.0.1:65226/devtools/page/8A1B",
        "id": "8A1B33F0C2D14E5F9A7B6C5D4E3F2A1B",
        "title": "aim",
        "type": "page",
        "url": "http://127.0.0.1:65226/aim.html?batch=cal-na-b1&mode=cal",
        "webSocketDebuggerUrl": "ws://127.0.0.1:65226/devtools/page/8A1B33F0C2D14E5F9A7B6C5D4E3F2A1B",
    }
    other = {"type": "background_page", "id": "FFFF", "url": "chrome://extensions"}
    monkeypatch.setattr(cdp, "http_json", lambda _port, _path: [other, entry])
    got = cdp.find_target(9222, "batch=cal-na-b1")
    assert got is entry
    assert "targetId" not in got and got["id"]


def test_a_matching_page_without_an_id_is_a_typed_contract_failure(monkeypatch):
    monkeypatch.setattr(cdp, "http_json", lambda _port, _path: [
        {"type": "page", "url": "http://127.0.0.1:1/aim.html?batch=b1&mode=cal"}])
    with pytest.raises(cdp.CdpError, match="/json/list contract"):
        cdp.find_target(9222, "batch=b1")


def test_wait_for_target_timeout_names_the_never_opened_page(monkeypatch):
    monkeypatch.setattr(cdp, "http_json", lambda _port, _path: [])
    with pytest.raises(cdp.CdpError, match="never opened"):
        cdp.wait_for_target(9222, "batch=b1", timeout_s=0.0, sleep=lambda _s: None)


def test_closing_the_socket_keeps_the_first_observed_close_time():
    """`browser_lost` is decided by WHEN the socket went away; a tidy-up close
    must never overwrite the moment a transport failure already recorded."""
    client = cdp.CdpClient("ws://127.0.0.1:1/devtools/browser/x")
    client._conn = _FakeConn()
    client.closed_at_ms = 1_000.0
    client.close()
    assert client.closed_at_ms == 1_000.0


def test_a_readback_that_finds_no_page_state_is_typed_not_a_crash():
    watcher = cdp.PageWatcher(_FakeClient(None), "S1")
    with pytest.raises(cdp.CdpError, match="no window.__aim state"):
        watcher.poll_once()


def test_a_poll_failing_after_the_turn_ended_is_the_reap_not_a_fault(monkeypatch):
    # Raced live 2026-08-01 16:54: a PERFECT turn ended, the daemon reaped its
    # Chrome, tabs died a beat before the socket closed, and the next 500 ms poll
    # saw -32001 on a live socket — aborting the whole run for normal teardown.
    monkeypatch.setattr(run_aim, "REAP_GRACE_S", 0.0)
    client = cdp.CdpClient("ws://127.0.0.1:1/devtools/browser/x")
    watcher = cdp.PageWatcher(_FakeClient(None), "S1")

    class _DoneTurn:
        finished = True

    assert run_aim._poll_once(watcher, client, _DoneTurn()) is False
    assert client.closed_at_ms is not None  # stamped so F9 browser_lost stays keyed


def test_a_poll_failing_mid_turn_is_still_a_typed_abort(monkeypatch):
    monkeypatch.setattr(run_aim, "REAP_GRACE_S", 0.0)
    client = cdp.CdpClient("ws://127.0.0.1:1/devtools/browser/x")
    watcher = cdp.PageWatcher(_FakeClient(None), "S1")

    class _RunningTurn:
        finished = False

    with pytest.raises(run_aim.HarnessAbort) as err:
        run_aim._poll_once(watcher, client, _RunningTurn())
    assert err.value.kind == "page_readback_failed"


def test_target_lifecycle_events_are_recorded_while_awaiting_a_reply():
    # The live 2026-08-01 calibration died with a bare "-32001 session not found";
    # the browser HAD explained itself (targetDestroyed) on frames the client was
    # skipping past. Interleaved lifecycle events must land in the ring.
    client = cdp.CdpClient("ws://127.0.0.1:1/devtools/browser/x")
    frames = [
        json.dumps({"method": "Target.targetDestroyed", "params": {"targetId": "T1" * 8}}),
        json.dumps({"method": "Runtime.consoleAPICalled", "params": {}}),  # not lifecycle
        json.dumps({"id": 1, "result": {"ok": True}}),
    ]
    client._conn = _ScriptedConn(frames)
    assert client.send("Browser.getVersion") == {"ok": True}
    assert [e["method"] for e in client.events] == ["Target.targetDestroyed"]
    assert "targetDestroyed(T1T1T1T1T1T1)" in client.event_tail()


def test_event_tail_names_the_no_event_case():
    client = cdp.CdpClient("ws://127.0.0.1:1/devtools/browser/x")
    assert client.event_tail() == "no Target lifecycle events observed"


class _ScriptedConn:
    def __init__(self, frames: list[str]) -> None:
        self._frames = list(frames)

    def send(self, _text: str) -> None:
        return None

    def recv(self, timeout: float = 0.0) -> str:
        return self._frames.pop(0)

    def close(self) -> None:
        return None


class _FakeConn:
    def close(self) -> None:
        return None


class _FakeClient:
    """Minimal stand-in for the socket half of `CdpClient` (never opened here)."""

    def __init__(self, value) -> None:
        self._value = value

    def evaluate(self, _expression: str, _session: str):
        return self._value


def _write_port(root, owner: str, body: str, mtime: int) -> None:
    directory = root / owner / "fermix_visible"
    directory.mkdir(parents=True)
    path = directory / "DevToolsActivePort"
    path.write_text(f"{body}\n/devtools/browser/abc\n", encoding="utf-8")
    os.utime(path, (mtime, mtime))


# --- focus / occlusion sampling (F5) ----------------------------------------

def test_focus_gaps_merge_adjacent_bad_samples():
    samples = [_sample(0, True), _sample(1000, False), _sample(1500, False), _sample(3000, True)]
    gaps = cdp.focus_gaps(samples)
    assert gaps == [(500.0, 2000.0)]
    assert cdp.in_gap(1200, gaps) and not cdp.in_gap(2500, gaps)


def test_hidden_counts_as_a_gap_even_when_focused():
    gaps = cdp.focus_gaps([_sample(0, True), _sample(1000, True, visible=False)])
    assert gaps == [(500.0, 1500.0)]


def test_sample_parsing_is_typed():
    raw = json.dumps({"t": 5, "f": True, "v": "visible", "sx": 0, "sy": 0})
    assert cdp.parse_sample(raw).has_focus is True
    with pytest.raises(cdp.CdpError):
        cdp.parse_sample("[]")


def _sample(t: float, focused: bool, visible: bool = True,
            scroll: tuple[float, float] = (0.0, 0.0)) -> cdp.FocusSample:
    return cdp.FocusSample(t_ms=t, has_focus=focused, visible=visible,
                           scroll_x=scroll[0], scroll_y=scroll[1])


# --- trace parsing ----------------------------------------------------------

def test_screenshot_dims_and_cursor_echo_parse_from_the_real_summary():
    assert traces.parse_sent_dims(FULL_SHOT_OUTPUT) == (1931, 543)
    assert traces.parse_cursor_echo(FULL_SHOT_OUTPUT) == (417, 152)
    assert traces.parse_fullscreen_echo(FULL_SHOT_OUTPUT) is None


def test_full_sent_echo_uses_the_right_half_for_each_space():
    # A full capture's bare echo IS the full-sent grid; a crop's is not.
    assert traces.full_sent_echo(FULL_SHOT_OUTPUT, had_region=False) == (417, 152)
    assert traces.full_sent_echo(CROP_SHOT_OUTPUT, had_region=True) == (830, 495)
    assert traces.full_sent_echo("screenshot 100x100 (display 0). Cursor at (5,5).",
                                 had_region=True) is None


def test_not_delivered_marker_parses():
    assert traces.parse_not_delivered(NOT_DELIVERED_OUTPUT) == (418, 152)
    assert traces.parse_not_delivered(FULL_SHOT_OUTPUT) is None


def test_every_typed_refusal_is_recognised():
    assert traces.classify_refusal(AMBIGUOUS_OUTPUT) == "ambiguous_coordinates"
    assert traces.classify_refusal(REGION_MISMATCH_OUTPUT) == "region_mismatch"
    assert traces.classify_refusal(NO_MARKS_REFUSAL) == "no_marks"
    assert traces.classify_refusal(STALE_MARKS_REFUSAL) == "stale_marks"
    assert traces.classify_refusal(UNKNOWN_MARK_REFUSAL) == "unknown_mark"
    assert traces.classify_refusal("action failed: boom") is None


def test_marks_counts_parse_including_the_loud_zero():
    assert traces.parse_marks_count(NO_MARKS_OUTPUT) == 0
    assert traces.parse_marks_count(MARKS_OUTPUT) == 12
    assert traces.parse_marks_count(FULL_SHOT_OUTPUT) is None


def test_elixir_input_preview_decodes():
    assert traces.parse_elixir_input(CLICK_INPUT) == {"action": "left_click", "x": 418, "y": 152}
    assert traces.parse_elixir_input(CROP_INPUT)["region"] == {"x": 100, "y": 50, "w": 482, "h": 341}
    nested = '%{"action" => "left_click", "confirm_grid" => true, "tags" => ["a", "b"], "z" => nil}'
    decoded = traces.parse_elixir_input(nested)
    assert decoded["confirm_grid"] is True and decoded["tags"] == ["a", "b"] and decoded["z"] is None


def test_elixir_input_failures_are_typed():
    for junk in ("%{", '%{"a" "b"}', "not a map", '%{"a" => <<1>>}'):
        with pytest.raises(traces.TraceError):
            traces.parse_elixir_input(junk)


def test_row_classification_covers_the_whole_pointer_set():
    assert traces.classify_row(cu_row(at_ms=BASE_MS, action="left_click")) == "delivered_click"
    assert traces.classify_row(cu_row(at_ms=BASE_MS, action="double_click")) == "delivered_click"
    assert traces.classify_row(cu_row(at_ms=BASE_MS, action="right_click")) == "delivered_click"
    for action in ("mouse_move", "scroll", "inspect", "left_click_drag"):
        assert traces.classify_row(cu_row(at_ms=BASE_MS, action=action)) == "other_pointer"
    assert traces.classify_row(cu_row(at_ms=BASE_MS, action="screenshot")) == "screenshot"
    assert traces.classify_row(cu_row(at_ms=BASE_MS, action="left_click", success=False,
                                      output=AMBIGUOUS_OUTPUT)) == "refusal"
    assert traces.classify_row(cu_row(at_ms=BASE_MS, action="left_click",
                                      output=NOT_DELIVERED_OUTPUT)) == "refusal"
    assert traces.classify_row({"tool": "shell", "action": None}) == "other"


def test_timestamps_parse_in_both_iso_spellings():
    assert traces.parse_ts(iso(BASE_MS)) == pytest.approx(BASE_MS)
    assert traces.parse_ts(iso(BASE_MS, zulu=True)) == pytest.approx(BASE_MS)
    assert traces.row_start_ms(cu_row(at_ms=BASE_MS, duration=250)) == pytest.approx(BASE_MS - 250)
    with pytest.raises(traces.TraceError):
        traces.parse_ts("yesterday")


def test_jsonl_reading_and_turn_window_selection(tmp_path):
    """The daemon writes `session_id: "main-<n>"`, minted per turn — the CLI
    `--session` name appears in no row, so the window is the correlation key."""
    day = tmp_path / "2026-07-31"
    day.mkdir()
    rows = [cu_row(at_ms=BASE_MS),                                  # this turn
            cu_row(at_ms=BASE_MS + 500),                            # this turn
            cu_row(at_ms=BASE_MS - 600_000, session="main-6"),      # an earlier turn
            cu_row(at_ms=BASE_MS + 200, agent="memory_reviewer",
                   session="memory_review:main:cli:e2e-aim")]       # not the main agent
    rows.append(browser_row(at_ms=BASE_MS - 200, action="open", args=OPEN_INPUT))
    (day / "tool_exec.jsonl").write_text("\n".join(json.dumps(r) for r in rows) + "\n",
                                         encoding="utf-8")
    loaded = traces.read_jsonl(str(tmp_path), "tool_exec")
    assert len(loaded) == 5
    assert not any(SESSION in json.dumps(row) for row in loaded)
    picked, sid = traces.rows_for_anchored_turn(loaded, BASE_MS - 1000, BASE_MS + 5000,
                                                AIM_FRAGMENT)
    assert sid == TURN_ID
    assert len(picked) == 3 and {r["session_id"] for r in picked} == {TURN_ID}
    with pytest.raises(traces.TraceError):
        traces.read_jsonl(str(tmp_path / "nope"), "tool_exec")


def test_foreign_turns_in_the_window_are_excluded_by_the_anchor():
    """The live 2026-08-01 shape: a killed run's orphaned turn (main-11) kept
    failing waits inside the next run's batch window. The anchor keeps only the
    turn that opened THIS batch's URL; the ghost's rows simply drop out."""
    rows = [browser_row(at_ms=BASE_MS - 200, action="open", args=OPEN_INPUT),
            cu_row(at_ms=BASE_MS),
            browser_row(at_ms=BASE_MS + 300, action="act", kind="wait",
                        session="main-11", success=False),
            cu_row(at_ms=BASE_MS + 700, session="main-11")]
    picked, sid = traces.rows_for_anchored_turn(rows, BASE_MS - 1000, BASE_MS + 5000,
                                                AIM_FRAGMENT)
    assert sid == TURN_ID
    assert {r["session_id"] for r in picked} == {TURN_ID} and len(picked) == 2


def test_a_window_with_no_anchor_refuses_by_name():
    rows = [cu_row(at_ms=BASE_MS), cu_row(at_ms=BASE_MS + 100, session="main-8")]
    with pytest.raises(traces.TraceError, match="correlation_anchor_missing"):
        traces.rows_for_anchored_turn(rows, BASE_MS - 1000, BASE_MS + 5000, AIM_FRAGMENT)


def test_a_backwards_window_is_refused():
    with pytest.raises(traces.TraceError, match="before it starts"):
        traces.rows_in_window([], BASE_MS, BASE_MS - 1)


def test_corrupt_jsonl_names_the_line(tmp_path):
    day = tmp_path / "2026-07-31"
    day.mkdir()
    (day / "tool_exec.jsonl").write_text("{}\n{oops\n", encoding="utf-8")
    with pytest.raises(traces.TraceError, match=r"tool_exec\.jsonl:2"):
        traces.read_jsonl(str(tmp_path), "tool_exec")


# --- F2 rail guard ----------------------------------------------------------

def test_browser_open_and_wait_are_not_rail_violations():
    """`doctor` is a deliberate addition to F2's literal allowed set: `browser.ex:48-50`
    returns `chrome_diagnostics(config)` without reaching a page, so it cannot have
    produced the click, and voiding a batch over it would discard real data."""
    rows = [browser_row(at_ms=BASE_MS, action="open"),
            browser_row(at_ms=BASE_MS, action="act", kind="wait"),
            browser_row(at_ms=BASE_MS, action="status"),
            browser_row(at_ms=BASE_MS, action="doctor")]
    assert traces.browser_rail_violations(rows) == []


def test_any_click_capable_browser_call_is_a_rail_violation():
    for action, kind in (("act", "click"), ("act", "click_coords"), ("act", "submit"),
                         ("act", "press"), ("snapshot", None), ("focus", None)):
        rows = [browser_row(at_ms=BASE_MS, action=action, kind=kind)]
        assert len(traces.browser_rail_violations(rows)) == 1, (action, kind)


# --- F10 split trace assertions ---------------------------------------------

def test_trace_visibility_failure_names_both_of_its_causes():
    result = traces.check_trace_visibility([], SESSION)
    assert result.passed is False and result.name == "trace_visibility"
    assert "FERMIX_TRACE_DIR" in result.detail
    assert "time window" in result.detail and "no tools" in result.detail


def test_capture_content_failure_names_the_content_flags():
    rows = [cu_row(at_ms=BASE_MS)]                      # a row exists, but carries no `input`
    assert traces.check_trace_visibility(rows, SESSION).passed is True
    result = traces.check_capture_content(rows, SESSION)
    assert result.passed is False and result.name == "capture_content"
    assert "FERMIX_TRACE_CONTENT" in result.detail and "FERMIX_OPIK_ENABLED" in result.detail


def test_capture_content_passes_when_input_is_present():
    rows = [cu_row(at_ms=BASE_MS, args=CLICK_INPUT)]
    assert traces.check_capture_content(rows, SESSION).passed is True


def test_config_id_detection_takes_the_run_s_own_turns():
    """Selection is by the run's own anchored `main-<n>` ids: a concurrent turn
    shares the wall clock but not the ids, so it can never vote on the label."""
    rows = [llm_row(at_ms=BASE_MS, provider="openai_codex", model="gpt-5.6-sol", effort="xhigh"),
            llm_row(at_ms=BASE_MS + 900, provider="openai_codex", model="gpt-5.6-sol",
                    effort="xhigh"),
            llm_row(at_ms=BASE_MS + 100, provider="anthropic", model="claude-x",
                    session="main-9"),
            llm_row(at_ms=BASE_MS + 200, provider="anthropic", model="claude-y",
                    agent="memory_reviewer")]
    assert traces.detect_config_id(rows, {TURN_ID}) == "openai_codex/gpt-5.6-sol/xhigh"
    assert traces.detect_config_id(rows, {"main-99"}) is None


# --- prompts ----------------------------------------------------------------

def test_batch_plan_is_six_by_four_for_the_grid_suite():
    grid = [entry for entry in prompts.BATCH_PLAN if entry[0] == "s1"]
    assert grid == [("s1", "full_screen", 6, 4), ("s1", "crop", 6, 4)]
    assert all(batches * probes == 24 for _s, _c, batches, probes in grid)


def test_every_template_pins_the_rail_and_the_reply_contract():
    for suite, condition, _batches, probes in prompts.BATCH_PLAN + (prompts.CAL_BATCH,):
        plan = page.plan_batch(1, suite, condition, 1, probes)
        text = prompts.batch_prompt(plan, "http://127.0.0.1:1/aim.html?batch=x")
        assert "ONLY two browser-tool actions" in text
        assert "never click, click_coords, get, or navigate with it" in text
        # The wait is spelled in the tool's REAL argument names: the 03:20 live run
        # showed a paraphrase ("act wait (kind=text)") yields a wait without
        # wait_until, a typed arg error, and a spurious ABORT.
        assert 'kind wait, wait_until "text", text "READY", timeout_ms 60000' in text
        assert "re-send it once with exactly those arguments" in text
        assert "reply with exactly: ABORT" in text
        assert "Exactly one click" in text
        assert "reply with ONLY a JSON array" in text


def test_every_template_pins_the_profile_on_every_browser_call():
    # Live 2026-08-01: the model passed profile only on `open`; the profile-less
    # `wait` silently routed to the DEFAULT profile, which lazily launched a
    # second Chrome with no such tab — target_not_found, three runs in a row.
    # The browser tool routes by profile first, so the pin must cover every call.
    for suite, condition, _batches, probes in prompts.BATCH_PLAN + (prompts.CAL_BATCH,):
        plan = page.plan_batch(1, suite, condition, 1, probes)
        text = prompts.batch_prompt(plan, "http://127.0.0.1:1/aim.html?batch=x")
        assert 'Pass profile "fermix_visible" on EVERY browser call' in text


def test_every_template_judges_fired_from_a_fresh_screenshot():
    for suite, condition, _batches, probes in prompts.BATCH_PLAN + (prompts.CAL_BATCH,):
        plan = page.plan_batch(1, suite, condition, 1, probes)
        text = prompts.batch_prompt(plan, "http://127.0.0.1:1/aim.html?batch=x")
        assert "take ONE more fresh screenshot" in text
        assert "Never judge this from the picture attached to the click action itself" in text


def test_condition_clauses_are_specific():
    grid_full = prompts.batch_prompt(page.plan_batch(1, "s1", "full_screen", 1, 4), "http://x/1")
    grid_crop = prompts.batch_prompt(page.plan_batch(1, "s1", "crop", 1, 4), "http://x/1")
    marks = prompts.batch_prompt(page.plan_batch(1, "s3", "na", 1, 8), "http://x/1")
    assert "magnified" not in grid_full
    assert "sending the SAME region with your click" in grid_crop
    assert "marks: true" in marks and "never x/y" in marks
    assert "fresh marks screenshot before EVERY click" in marks


def test_targets_are_listed_in_probe_order():
    plan = page.plan_batch(9, "s1", "full_screen", 1, 4)
    text = prompts.batch_prompt(plan, "http://x/1")
    listed = ", ".join(f"{i + 1}: {t}" for i, t in enumerate(plan.targets))
    assert f"Targets, in order: {listed}" in text


def test_report_parsing_accepts_bare_and_fenced_arrays():
    bare = '[{"probe":1,"cell":"D3","x":10,"y":20,"fired":true}]'
    fenced = "Here you go:\n```json\n" + bare + "\n```"
    for reply in (bare, fenced):
        rows = prompts.parse_model_report(reply)
        assert rows[0] == {"probe": 1, "fired": True, "x": 10, "y": 20,
                           "cell": "D3", "label": None, "mark": None}


def test_report_parsing_failures_are_typed():
    for reply in ("", "ABORT", "no json here", "[{}]", '[{"probe":1,"fired":"yes"}]',
                  '[{"probe":1,"fired":true,"x":"left"}]', '{"probe":1}', "[{"):
        with pytest.raises(prompts.ReportError):
            prompts.parse_model_report(reply)


# --- F1 coordinate transform ------------------------------------------------

def test_sent_transform_at_dpr_1():
    # 3840x1080 target downscaled to the 1931x543 sent frame (scale 0.503).
    sent_x, sent_y = score.sent_from_screen(830, 495, dpr=1, screen_w_css=3840,
                                            screen_h_css=1080, sent_w=1931, sent_h=543)
    assert sent_x == pytest.approx(830 * 1931 / 3840)
    assert sent_y == pytest.approx(495 * 543 / 1080)


def test_sent_transform_at_dpr_2_has_no_skip_branch():
    # Same physical display, reported as 1920x540 CSS px at DPR 2.
    dpr1 = score.sent_from_screen(830, 495, 1, 3840, 1080, 1931, 543)
    dpr2 = score.sent_from_screen(415, 247.5, 2, 1920, 540, 1931, 543)
    assert dpr2[0] == pytest.approx(dpr1[0]) and dpr2[1] == pytest.approx(dpr1[1])
    assert dpr2[0] == pytest.approx(415 * 2 * (1931 / (1920 * 2)))


def test_sent_transform_refuses_degenerate_inputs():
    for bad in ({"dpr": 0}, {"screen_w_css": 0}, {"sent_w": 0}, {"sent_h": -1}):
        kwargs = {"dpr": 1, "screen_w_css": 3840, "screen_h_css": 1080,
                  "sent_w": 1931, "sent_h": 543, **bad}
        with pytest.raises(score.ScoreError):
            score.sent_from_screen(10, 10, **kwargs)


# --- correlation (F7) -------------------------------------------------------

def _delivered(index: int, start_ms: float, action: str = "left_click") -> score.Delivered:
    return score.Delivered(index=index, action=action, ts_ms=start_ms + 200,
                           start_ms=start_ms, x=None, y=None, region=None,
                           output="", had_input=False)


def _hit(seq: int, t: float, target_id: str | None = "D3", xy=(0.0, 0.0),
         trusted: bool = True, scroll=(0.0, 0.0)) -> score.Hit:
    return score.Hit(seq=seq, t=t, target_id=target_id, x=xy[0], y=xy[1],
                     sx=xy[0], sy=xy[1], trusted=trusted,
                     scroll_x=scroll[0], scroll_y=scroll[1])


def test_time_merge_attaches_a_hit_to_the_most_recent_preceding_click():
    delivered = [_delivered(0, BASE_MS), _delivered(2, BASE_MS + 3000)]
    hits = [_hit(1, BASE_MS + 100), _hit(2, BASE_MS + 3100)]
    assigned, unpaired = score.pair_clicks(delivered, hits)
    assert [h.seq for h in assigned[0]] == [1]
    assert [h.seq for h in assigned[2]] == [2] and unpaired == []


def test_a_double_click_absorbs_both_of_its_page_events():
    """A double_click's second event must not fall back onto an earlier hitless
    row: that would convert a real off-page click into a phantom score."""
    delivered = [_delivered(0, BASE_MS), _delivered(2, BASE_MS + 3000, action="double_click")]
    hits = [_hit(1, BASE_MS + 3100), _hit(2, BASE_MS + 3120)]
    assigned, unpaired = score.pair_clicks(delivered, hits)
    assert [h.seq for h in assigned[2]] == [1, 2]
    assert 0 not in assigned and unpaired == []


def test_a_right_click_is_never_a_pairing_candidate():
    delivered = [_delivered(0, BASE_MS, action="right_click")]
    assigned, unpaired = score.pair_clicks(delivered, [_hit(1, BASE_MS + 50)])
    assert assigned == {} and len(unpaired) == 1


def test_time_merge_leaves_a_hit_outside_the_window_unpaired():
    delivered = [_delivered(0, BASE_MS)]
    assigned, unpaired = score.pair_clicks(delivered, [_hit(1, BASE_MS + 20_000)])
    assert assigned == {} and len(unpaired) == 1


def test_time_merge_ignores_untrusted_hits():
    delivered = [_delivered(0, BASE_MS)]
    assigned, unpaired = score.pair_clicks(delivered, [_hit(1, BASE_MS + 50, trusted=False)])
    assert assigned == {} and unpaired == []


# --- batch scoring ----------------------------------------------------------

def _grid_layout(plan: page.BatchPlan) -> dict:
    layout = {}
    for row in range(page.GRID_ROWS):
        for col in range(page.GRID_COLS):
            left, top, width, height = page.cell_rect(col, row)
            layout[page.cell_id(col, row)] = {"x": left, "y": top, "w": width, "h": height,
                                              "cx": left + width / 2, "cy": top + height / 2}
    return layout


def _aim(plan: page.BatchPlan, hits: list[dict]) -> dict:
    return {"batch_id": plan.batch_id, "mode": plan.mode, "ready": True,
            "meta": {"dpr": 1, "screen_w": 3840, "screen_h": 1080, "inner_w": 3840,
                     "inner_h": 965, "min_clearance": 225, "cell_px": page.CELL_PX},
            "layout": _grid_layout(plan), "hits": hits, "errors": []}


def _page_hit(seq: int, t: float, target: str, offset=(0.0, 0.0), trusted: bool = True,
              scroll=(0.0, 0.0)) -> dict:
    left, top, width, height = page.cell_rect(*page.parse_cell_id(target))
    x, y = left + width / 2 + offset[0], top + height / 2 + offset[1]
    return {"seq": seq, "t": t, "target_id": _cell_at(x, y), "x": x, "y": y,
            "sx": x, "sy": y, "trusted": trusted,
            "scroll_x": scroll[0], "scroll_y": scroll[1]}


def _cell_at(x: float, y: float) -> str | None:
    col = int((x - page.GRID_ORIGIN_X - page.LABEL_PX) // page.CELL_PX)
    row = int((y - page.GRID_ORIGIN_Y - page.LABEL_PX) // page.CELL_PX)
    if not (0 <= col < page.GRID_COLS and 0 <= row < page.GRID_ROWS):
        return None
    return page.cell_id(col, row)


def _batch(plan: page.BatchPlan, rows: list[dict], hits: list[dict], **kwargs) -> score.BatchInput:
    return score.BatchInput(plan=plan, session=SESSION, rows=rows, aim=_aim(plan, hits), **kwargs)


def _four_probe_plan() -> page.BatchPlan:
    return page.plan_batch(42, "s1", "full_screen", 1, 4)


def _clean_run(plan: page.BatchPlan, offsets) -> tuple[list[dict], list[dict]]:
    """One screenshot + one click per probe, each click landing at `offsets[k]`
    relative to the target centre."""
    rows, hits = [], []
    for index, target in enumerate(plan.targets):
        at = BASE_MS + index * 10_000
        rows.append(cu_row(at_ms=at, action="screenshot", output=FULL_SHOT_OUTPUT, args=SHOT_INPUT))
        rows.append(cu_row(at_ms=at + 1000, action="left_click", output=FULL_SHOT_OUTPUT,
                           args=CLICK_INPUT))
        hits.append(_page_hit(index + 1, at + 1000, target, offsets[index]))
    return rows, hits


def test_a_clean_batch_scores_hits_and_residual_vectors():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(2, -3), (0, 0), (1, 1), (-2, 2)])
    result = score.score_batch(_batch(plan, rows, hits))
    assert [p["outcome"] for p in result["probes"]] == ["hit"] * 4
    assert result["probes"][0]["miss_vector_css"] == [2, -3]
    assert result["probes"][0]["miss_vector_cells"] == [0, 0]
    assert result["halt_reason"] is None and result["flags"]["sequence_mismatch"] is False


def test_off_by_one_cell_misses_carry_signed_cell_vectors():
    plan = _four_probe_plan()
    offsets = [(page.CELL_PX, 0), (-page.CELL_PX, 0), (0, page.CELL_PX), (0, -page.CELL_PX)]
    rows, hits = _clean_run(plan, offsets)
    result = score.score_batch(_batch(plan, rows, hits))
    assert [p["outcome"] for p in result["probes"]] == ["miss"] * 4
    assert [p["miss_vector_cells"] for p in result["probes"]] == [[1, 0], [-1, 0], [0, 1], [0, -1]]


def test_a_delivered_click_with_no_page_hit_is_off_page_and_halts():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    result = score.score_batch(_batch(plan, rows, hits[:3]))
    assert result["probes"][3]["outcome"] == "off_page"
    assert result["halt_reason"] == "off_page"


def test_a_click_after_the_socket_closed_is_browser_lost_not_off_page():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    closed = BASE_MS + 25_000
    result = score.score_batch(_batch(plan, rows, hits[:3], socket_closed_ms=closed))
    assert result["probes"][3]["outcome"] == "browser_lost"
    assert result["halt_reason"] == "browser_lost"


def test_a_click_inside_an_unfocused_span_is_occluded():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    samples = [_sample(BASE_MS + 31_000, False)]
    result = score.score_batch(_batch(plan, rows, hits, samples=samples))
    assert result["probes"][3]["outcome"] == "occluded"
    assert result["halt_reason"] is None


def test_more_than_two_occluded_probes_abort_the_batch():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    samples = [_sample(BASE_MS + 1000, False), _sample(BASE_MS + 11_000, False),
               _sample(BASE_MS + 21_000, False)]
    result = score.score_batch(_batch(plan, rows, hits, samples=samples))
    assert result["abort_reason"] == "occluded_batch"


def test_a_scrolled_page_makes_the_probe_scrolled():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    hits[2]["scroll_y"] = 40
    result = score.score_batch(_batch(plan, rows, hits))
    assert result["probes"][2]["outcome"] == "scrolled"


def test_a_stray_scroll_action_causes_no_phantom_halt():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    rows.insert(2, cu_row(at_ms=BASE_MS + 500, action="scroll", output=FULL_SHOT_OUTPUT))
    result = score.score_batch(_batch(plan, rows, hits))
    assert result["other_pointer"] == 1 and result["halt_reason"] is None
    assert [p["outcome"] for p in result["probes"]] == ["hit"] * 4


def test_a_refusal_attaches_to_the_probe_it_recovers_into():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    rows.insert(1, cu_row(at_ms=BASE_MS + 500, action="left_click", success=False,
                          output=AMBIGUOUS_OUTPUT))
    result = score.score_batch(_batch(plan, rows, hits))
    refusal = result["probes"][0]["refusals"][0]
    assert (refusal["kind"], refusal["recovered"]) == ("ambiguous_coordinates", True)
    assert "ambiguous coordinates" in refusal["message"]  # the tool's own words travel
    assert result["probes"][1]["refusals"] == []
    assert result["refusal_rows"] == 1


def test_a_trailing_refusal_leaves_the_probe_unrecovered_and_the_rest_unscored():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    rows = rows[:4]                                   # only two probes ran
    rows.append(cu_row(at_ms=BASE_MS + 25_000, action="left_click", success=False,
                       output=STALE_MARKS_REFUSAL))
    result = score.score_batch(_batch(plan, rows, hits[:2]))
    outcomes = [p["outcome"] for p in result["probes"]]
    assert outcomes == ["hit", "hit", "refused_unrecovered", "unscored"]
    assert result["flags"]["sequence_mismatch"] is True


def test_a_probe_never_attempted_is_no_click():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    result = score.score_batch(_batch(plan, rows[:4], hits[:2]))
    assert [p["outcome"] for p in result["probes"]] == ["hit", "hit", "no_click", "unscored"]


def test_a_rail_violation_unscored_the_whole_batch():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    rows.append(browser_row(at_ms=BASE_MS + 5, action="act", kind="click_coords"))
    result = score.score_batch(_batch(plan, rows, hits))
    assert [p["outcome"] for p in result["probes"]] == ["rail_violation"] * 4
    assert result["flags"]["rail_violation"] is True
    assert result["abort_reason"] == "rail_violation"
    assert result["rail_rows"] == [{"action": "act", "kind": "click_coords"}]


def test_marks_unavailable_is_a_flag_not_a_miss():
    plan = page.plan_batch(4, "s3", "na", 1, 2)
    rows = [cu_row(at_ms=BASE_MS, action="screenshot", output=NO_MARKS_OUTPUT, args=SHOT_INPUT)]
    aim = {"meta": {"dpr": 1, "screen_w": 3840, "screen_h": 1080}, "hits": [],
           "layout": {t: {"x": 0, "y": 0, "w": 10, "h": 10, "cx": 5, "cy": 5}
                      for t in plan.targets}}
    result = score.score_batch(score.BatchInput(plan=plan, session=SESSION, rows=rows, aim=aim))
    assert result["flags"]["marks_unavailable"] is True
    assert [p["outcome"] for p in result["probes"]] == ["no_click", "unscored"]


def test_the_delivery_cross_check_lands_within_tolerance():
    plan = _four_probe_plan()
    left, top, width, height = page.cell_rect(*page.parse_cell_id(plan.targets[0]))
    centre_x, centre_y = left + width / 2, top + height / 2
    sent_x, sent_y = score.sent_from_screen(centre_x, centre_y, 1, 3840, 1080, 1931, 543)
    echo = (f"screenshot 1931x543 (display 0). Cursor at ({round(sent_x)},{round(sent_y)}). ")
    rows = [cu_row(at_ms=BASE_MS, action="screenshot", output=FULL_SHOT_OUTPUT, args=SHOT_INPUT),
            cu_row(at_ms=BASE_MS + 1000, action="left_click", output=echo, args=CLICK_INPUT)]
    hits = [_page_hit(1, BASE_MS + 1000, plan.targets[0])]
    result = score.score_batch(_batch(plan, rows, hits))
    delta = result["probes"][0]["trace"]["sent_cross_check_px"]
    assert delta is not None and delta <= score.CROSS_CHECK_TOLERANCE_SENT_PX


def test_the_cross_check_is_null_when_the_full_sent_dims_are_unknown():
    plan = _four_probe_plan()
    rows = [cu_row(at_ms=BASE_MS, action="screenshot", output=CROP_SHOT_OUTPUT, args=CROP_INPUT),
            cu_row(at_ms=BASE_MS + 1000, action="left_click", output=FULL_SHOT_OUTPUT, args=CLICK_INPUT)]
    hits = [_page_hit(1, BASE_MS + 1000, plan.targets[0])]
    result = score.score_batch(_batch(plan, rows, hits))
    assert result["probes"][0]["trace"]["sent_cross_check_px"] is None


def test_not_delivered_rows_are_refusals_and_do_not_consume_a_probe():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    rows.insert(1, cu_row(at_ms=BASE_MS + 500, action="left_click",
                          output=FULL_SHOT_OUTPUT + NOT_DELIVERED_OUTPUT, args=CLICK_INPUT))
    result = score.score_batch(_batch(plan, rows, hits))
    assert [p["outcome"] for p in result["probes"]] == ["hit"] * 4
    refusal = result["probes"][0]["refusals"][0]
    assert (refusal["kind"], refusal["recovered"]) == ("other", True)
    assert "NOT delivered" in refusal["message"]


# --- fired columns ----------------------------------------------------------

def test_fired_truth_and_the_model_report_are_graded_per_probe():
    plan = _four_probe_plan()
    offsets = [(0, 0), (page.CELL_PX, 0), (0, 0), (0, 0)]
    rows, hits = _clean_run(plan, offsets)
    report = [{"probe": 1, "fired": True, "x": 1, "y": 2, "cell": plan.targets[0],
               "label": None, "mark": None},
              {"probe": 2, "fired": True, "x": 3, "y": 4, "cell": plan.targets[1],
               "label": None, "mark": None}]
    result = score.score_batch(_batch(plan, rows, hits, report=report))
    assert result["probes"][0]["fired_truth"] is True
    assert result["probes"][0]["fired_correct"] is True
    assert result["probes"][1]["fired_truth"] is False       # the click landed a cell over
    assert result["probes"][1]["fired_correct"] is False     # ...and the model said it fired
    assert result["probes"][2]["fired_reported"] is None
    assert result["probes"][0]["model_reported_xy"] == [1, 2]


def test_a_later_hit_cannot_flip_an_earlier_probe_s_fired_truth():
    """Probe 1's click is occluded and produces no page event; probe 3 then misses
    ONTO probe 1's target. The model judged probe 1 from a screenshot taken 20 s
    earlier, so grading its honest "false" as wrong would score a fact it could
    not have seen."""
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    hits.pop(0)                                                  # probe 1: no page event
    hits[1] = _page_hit(3, BASE_MS + 21_000, plan.targets[0])    # probe 3 lands on it
    report = [{"probe": 1, "fired": False, "x": 1, "y": 2, "cell": plan.targets[0],
               "label": None, "mark": None}]
    result = score.score_batch(_batch(plan, rows, hits, report=report,
                                      samples=[_sample(BASE_MS + 1000, False)]))
    assert result["probes"][0]["outcome"] == "occluded"
    assert result["probes"][0]["fired_truth"] is False
    assert result["probes"][0]["fired_correct"] is True
    assert result["probes"][2]["outcome"] == "miss"


def test_an_unparseable_report_nulls_the_fired_column_but_keeps_the_hits():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    result = score.score_batch(_batch(plan, rows, hits, report=None,
                                      report_error="no JSON array in the model reply"))
    assert result["flags"]["report_unparseable"] is True
    assert all(p["fired_correct"] is None for p in result["probes"])
    assert all(p["outcome"] == "hit" for p in result["probes"])


# --- summaries and the results document -------------------------------------

def _scored_batches(seed: int, condition: str, offsets_per_batch) -> list[dict]:
    out = []
    for index, offsets in enumerate(offsets_per_batch, start=1):
        plan = page.plan_batch(seed, "s1", condition, index, 4)
        rows, hits = _clean_run(plan, offsets)
        out.append(score.score_batch(_batch(plan, rows, hits)))
    return out


def test_summary_reports_the_probe_one_headline_and_the_trajectory():
    # batch 1 misses its first probe, batch 2 hits everything.
    batches = _scored_batches(3, "full_screen",
                              [[(page.CELL_PX, 0), (0, 0), (0, 0), (0, 0)], [(0, 0)] * 4])
    summary = score.summarize("s1", batches)
    assert summary["n"] == 8 and summary["hits"] == 7
    assert summary["hit_rate"] == 0.875
    assert summary["first_probe_hit_rate"] == 0.5
    assert summary["by_probe_index"]["1"] == {"n": 2, "hits": 1, "hit_rate": 0.5}
    assert summary["by_probe_index"]["4"]["hit_rate"] == 1.0


def test_summary_uses_the_suite_specific_fired_metric_name():
    batches = _scored_batches(3, "full_screen", [[(0, 0)] * 4])
    assert "fired_target_verification" in score.summarize("s1", batches)
    single = score.summarize("s2", batches)
    assert "fired_report_accuracy" in single and "fired_target_verification" not in single


def test_summary_tallies_off_by_columns_and_rows_separately():
    offsets = [(page.CELL_PX, 0), (page.CELL_PX, 0), (0, -page.CELL_PX), (0, 0)]
    summary = score.summarize("s1", _scored_batches(3, "full_screen", [offsets]))
    assert summary["col_off_by"] == {"0": 2, "1": 2}
    assert summary["row_off_by"] == {"-1": 1, "0": 3}
    # The aim-error distribution covers every scored probe; the exact hit
    # contributes a 0 residual rather than dropping out of the sample.
    assert summary["aim_error_css"]["n"] == 4
    assert summary["aim_error_css"]["median"] == pytest.approx(page.CELL_PX)


def test_results_document_and_report_render(tmp_path):
    batches = (_scored_batches(3, "full_screen", [[(0, 0)] * 4, [(page.CELL_PX, 0)] * 4])
               + _scored_batches(3, "crop", [[(0, 0)] * 4]))
    doc = score.build_results(run_id="aim-20260731-142000", seed=3,
                              started_at="2026-07-31T14:20:00Z",
                              finished_at="2026-07-31T15:05:00Z",
                              config_id="openai_codex/gpt-5.6-sol/xhigh",
                              config_id_source="auto", harness_git_rev="554eb71f",
                              environment={"fermix_home": "~/.fermix-dev", "dpr": 1},
                              calibration={"passed": True}, batches=batches)
    for key in ("run_id", "seed", "started_at", "finished_at", "config_id",
                "config_id_source", "harness_git_rev", "environment", "calibration", "suites"):
        assert key in doc
    conditions = doc["suites"]["s1"]["conditions"]
    assert set(conditions) == {"full_screen", "crop"}
    assert conditions["full_screen"]["summary"]["hit_rate"] == 0.5

    path = score.write_results(str(tmp_path / "out" / "results.json"), doc)
    reloaded = json.loads(open(path, encoding="utf-8").read())
    assert reloaded["run_id"] == doc["run_id"]

    probe = reloaded["suites"]["s1"]["conditions"]["full_screen"]["batches"][0]["probes"][0]
    for key in ("probe", "batch", "session", "target", "outcome", "click_css", "click_trusted",
                "click_events", "miss_vector_css", "miss_vector_cells", "refusals", "fired_truth",
                "fired_reported", "fired_correct", "model_reported_xy", "trace"):
        assert key in probe
    for key in ("input_xy", "region", "echo_full_sent", "delivered", "sent_cross_check_px"):
        assert key in probe["trace"]

    text = score.render_report(doc)
    assert "probe-1 hit rate" in text and "feedback exploitation" in text
    assert "fired_target_verification" in text and "### crop" in text


def test_a_partial_report_says_why_it_stopped():
    """A run that halts writes its batches anyway; a reader comparing two runs
    cannot see a missing batch, so the document has to name the stop itself."""
    batches = _scored_batches(3, "full_screen", [[(0, 0)] * 4])
    common = {"run_id": "aim-1", "seed": 3, "started_at": "a", "finished_at": "b",
              "config_id": "p/m/e", "config_id_source": "auto", "harness_git_rev": "x",
              "environment": {}, "calibration": {"passed": True}, "batches": batches}
    complete = score.build_results(**common)
    assert complete["incomplete"] is None
    assert "- run: complete" in score.render_report(complete)

    partial = score.build_results(**common, incomplete={
        "reason": "off_page", "detail": "a delivered click left no page hit",
        "batch": "s1-full_screen-b2", "session": "e2e-aim-1-s1-full_screen-b2"})
    text = score.render_report(partial)
    assert "run INCOMPLETE" in text and "off_page" in text and "s1-full_screen-b2" in text


def test_results_document_refuses_a_missing_config_id():
    with pytest.raises(score.ScoreError):
        score.build_results(run_id="r", seed=1, started_at="a", finished_at="b",
                            config_id="", config_id_source="auto", harness_git_rev="x",
                            environment={}, calibration={}, batches=[])


def test_scoring_refuses_a_target_the_page_never_laid_out():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    bad = _batch(plan, rows, hits)
    bad.aim["layout"].pop(plan.targets[0])
    with pytest.raises(score.ScoreError, match="no layout rect"):
        score.score_batch(bad)


def test_a_right_click_expecting_no_page_event_never_halts_the_run():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    rows[7] = cu_row(at_ms=BASE_MS + 31_000, action="right_click",
                     output=FULL_SHOT_OUTPUT, args=CLICK_INPUT)
    result = score.score_batch(_batch(plan, rows, hits[:3]))
    assert result["probes"][3]["outcome"] == "no_click"
    assert result["halt_reason"] is None


def test_a_double_clicks_second_event_never_backfills_an_off_page_probe():
    """Probe 3 truly leaves the page; probe 4 is a double_click producing two
    events. Both belong to probe 4 — probe 3 stays `off_page` and still halts."""
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    hits.pop(2)                                            # probe 3 produced no page event
    rows[7] = cu_row(at_ms=BASE_MS + 31_000, action="double_click",
                     output=FULL_SHOT_OUTPUT, args=CLICK_INPUT)
    hits.append(_page_hit(5, BASE_MS + 31_020, plan.targets[3]))
    result = score.score_batch(_batch(plan, rows, hits))
    assert result["probes"][2]["outcome"] == "off_page"
    assert result["probes"][3]["outcome"] == "hit"
    assert result["probes"][3]["click_events"] == 2
    assert result["halt_reason"] == "off_page"


def test_an_extra_click_that_landed_on_the_page_is_counted_not_a_halt():
    """Re-clicking a target it wrongly judged un-fired is the very M2 behaviour
    this harness measures. Calling that `off_page` would abort the run exactly
    when the measured failure occurs."""
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    rows.append(cu_row(at_ms=BASE_MS + 35_000, action="left_click",
                       output=FULL_SHOT_OUTPUT, args=CLICK_INPUT))
    hits.append(_page_hit(5, BASE_MS + 35_000, plan.targets[3]))
    result = score.score_batch(_batch(plan, rows, hits))
    assert [p["outcome"] for p in result["probes"]] == ["hit"] * 4
    assert result["halt_reason"] is None
    assert result["flags"]["sequence_mismatch"] is True
    assert result["leftover_clicks"] == [{"row_index": 8, "action": "left_click",
                                          "outcome": "extra_click", "click_events": 1}]
    assert score.summarize("s1", [result])["extra_clicks"] == 1


def test_a_leftover_click_with_no_page_event_still_halts():
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    rows.append(cu_row(at_ms=BASE_MS + 35_000, action="left_click",
                       output=FULL_SHOT_OUTPUT, args=CLICK_INPUT))
    result = score.score_batch(_batch(plan, rows, hits))
    assert result["leftover_clicks"][0]["outcome"] == "off_page"
    assert result["halt_reason"] == "off_page"


def test_batch_flags_name_only_states_scoring_can_set():
    """A flag nothing assigns renders a permanently-zero column and reads as
    proof of absence. A failed READY handshake is a RUN-level abort typed by the
    runner, so it is not one of these."""
    assert score.BATCH_FLAGS == ("sequence_mismatch", "report_unparseable",
                                 "rail_violation", "marks_unavailable")
    source = open(score.__file__, encoding="utf-8").read()
    for flag in score.BATCH_FLAGS:
        assert f'flags["{flag}"] =' in source or f'"{flag}": True' in source, flag


# --- calibration ------------------------------------------------------------

def _calibration_batch() -> tuple[dict, dict]:
    plan = page.plan_batch(1, "s1", "full_screen", 1, 1)
    target = plan.targets[0]
    left, top, width, height = page.cell_rect(*page.parse_cell_id(target))
    sent_x, sent_y = score.sent_from_screen(left + width / 2, top + height / 2,
                                            1, 3840, 1080, 1931, 543)
    rows = [cu_row(at_ms=BASE_MS, action="screenshot", output=FULL_SHOT_OUTPUT, args=SHOT_INPUT),
            cu_row(at_ms=BASE_MS + 1000, action="left_click", args=CLICK_INPUT,
                   output=f"screenshot 1931x543 (display 0). Cursor at ({round(sent_x)},{round(sent_y)}).")]
    aim = _aim(plan, [_page_hit(1, BASE_MS + 1000, target)])
    aim["meta"].update({"vv_scale": 1, "scroll_x": 0, "scroll_y": 0,
                        "avail_w": 3840, "avail_h": 1055, "min_clearance": 225})
    return score.score_batch(score.BatchInput(plan=plan, session=SESSION, rows=rows, aim=aim)), aim


BOUNDS_OK = {"left": 0, "top": 0, "width": 3840, "height": 1055}
# What macOS actually returns on the 3840x1080 target: `Browser.setWindowBounds`
# asks for top 0, the OS clamps a normal window below the 25 px menu bar, and
# `Browser.getWindowBounds` reports the clamped value.
BOUNDS_MACOS_CLAMPED = {"left": 0, "top": 25, "width": 3840, "height": 1055}


def test_calibration_passes_on_a_healthy_probe():
    batch, aim = _calibration_batch()
    checks = score.calibration_checks(aim=aim, batch=batch, bounds=BOUNDS_OK, multi_client=True,
                                      trace_checks=[traces.check_capture_content(
                                          [cu_row(at_ms=BASE_MS, args=CLICK_INPUT)], SESSION)])
    assert [c.name for c in checks] == ["cdp_multi_client", "cu_ready", "trusted_click",
                                        "zoom_guard", "no_scroll", "window_bounds_applied",
                                        "clearance", "echo_cross_check", "capture_content"]
    assert all(c.passed for c in checks), [c for c in checks if not c.passed]


def test_the_macos_menu_bar_clamp_still_counts_as_applied_bounds():
    """The assertion is "the window fills the workarea", not "top == 0". macOS
    never places a normal window under the menu bar, so an absolute-origin check
    fails closed on the only machine this harness runs on."""
    batch, aim = _calibration_batch()
    checks = {c.name: c for c in score.calibration_checks(
        aim=aim, batch=batch, bounds=BOUNDS_MACOS_CLAMPED, multi_client=True, trace_checks=[])}
    assert checks["window_bounds_applied"].passed is True
    half = {**BOUNDS_MACOS_CLAMPED, "width": 1920}
    narrow = {c.name: c for c in score.calibration_checks(
        aim=aim, batch=batch, bounds=half, multi_client=True, trace_checks=[])}
    assert narrow["window_bounds_applied"].passed is False


def test_each_calibration_failure_names_its_observed_value():
    batch, aim = _calibration_batch()
    cases = {"zoom_guard": ({"vv_scale": 1.5}, BOUNDS_OK, "1.5"),
             "clearance": ({"min_clearance": 12}, BOUNDS_OK, "12px"),
             "no_scroll": ({"scroll_y": 40}, BOUNDS_OK, "40"),
             # Pushed far below the workarea origin: the window is not where the
             # harness put it, and the menu-bar clamp cannot explain it.
             "window_bounds_applied": ({}, {"left": 0, "top": 200, "width": 3840,
                                            "height": 1055}, "200")}
    for name, (meta_patch, bounds, needle) in cases.items():
        broken = json.loads(json.dumps(aim))
        broken["meta"].update(meta_patch)
        checks = {c.name: c for c in score.calibration_checks(
            aim=broken, batch=batch, bounds=bounds, multi_client=True, trace_checks=[])}
        assert checks[name].passed is False, name
        assert needle in checks[name].detail, (name, checks[name].detail)


def test_calibration_reports_a_missing_multi_client_and_a_bad_echo():
    batch, aim = _calibration_batch()
    batch["probes"][0]["trace"]["sent_cross_check_px"] = 40.0
    checks = {c.name: c for c in score.calibration_checks(
        aim=aim, batch=batch, bounds=BOUNDS_OK, multi_client=False, trace_checks=[])}
    assert checks["cdp_multi_client"].passed is False
    assert checks["echo_cross_check"].passed is False and "40.0" in checks["echo_cross_check"].detail


# --- runner wiring (typed aborts, no bare tracebacks) -----------------------

class _FakeTurn:
    def __init__(self, response: str | None) -> None:
        self.result = type("R", (), {"response": response})()


def test_an_abort_reply_is_retyped_from_the_generic_early_end():
    """The model already said why the turn ended early; the operator should see
    its diagnosis, not the generic "never opened it, or the daemon refused"."""
    early = run_aim.HarnessAbort("turn_ended_early", "the turn ended before the page was open")
    retyped = run_aim._diagnosed(early, _FakeTurn(prompts.ABORT_TOKEN))
    assert retyped.kind == "handshake_failed" and "ABORT" in str(retyped)
    assert run_aim._diagnosed(early, _FakeTurn("some other reply")) is early
    other = run_aim.HarnessAbort("cdp_failed", "socket died")
    assert run_aim._diagnosed(other, _FakeTurn(prompts.ABORT_TOKEN)) is other


def test_a_scoring_fault_becomes_a_typed_abort_not_a_traceback():
    """A mid-run ScoreError escaping would exit 1 outside the declared contract
    and lose every batch already scored."""
    plan = _four_probe_plan()
    rows, hits = _clean_run(plan, [(0, 0)] * 4)
    run = run_aim.BatchRun(session=SESSION, reply=None, sent_at=None,
                           observed=run_aim.Observed(aim=_aim(plan, hits)))
    run.observed.aim["layout"].pop(plan.targets[0])
    with pytest.raises(run_aim.HarnessAbort) as caught:
        run_aim.score_turn(plan, SESSION, run, rows, None, None)
    assert caught.value.kind == "scoring_failed" and "no layout rect" in str(caught.value)


def test_a_missing_anchor_becomes_a_typed_abort():
    rows = [cu_row(at_ms=BASE_MS), cu_row(at_ms=BASE_MS + 100, session="main-8")]
    with pytest.raises(run_aim.HarnessAbort) as caught:
        run_aim.select_turn_rows(rows, BASE_MS - 1000, BASE_MS + 5000, AIM_FRAGMENT)
    assert caught.value.kind == "correlation_anchor_missing"


def test_quiet_gate_ignores_own_turns_and_aborts_on_foreign_activity(monkeypatch):
    monkeypatch.setattr(run_aim, "QUIET_MAX_WAIT_S", 0.0)
    monkeypatch.setattr(run_aim, "QUIET_POLL_S", 0.0)
    now_ms = time.time() * 1000.0
    own = cu_row(at_ms=now_ms - 1000)
    foreign = cu_row(at_ms=now_ms - 1000, session="main-11")
    monkeypatch.setattr(run_aim, "read_trace_rows", lambda cfg, kind, dates: [own])
    run_aim.wait_for_daemon_quiet(None, ["2026-08-01"], {TURN_ID})  # own rows: passes
    monkeypatch.setattr(run_aim, "read_trace_rows", lambda cfg, kind, dates: [own, foreign])
    with pytest.raises(run_aim.HarnessAbort) as caught:
        run_aim.wait_for_daemon_quiet(None, ["2026-08-01"], {TURN_ID})
    assert caught.value.kind == "daemon_busy"


def test_every_halt_outcome_has_its_own_message():
    assert set(run_aim.HALT_DETAIL) == set(score.HALT_OUTCOMES)
    assert len(set(run_aim.HALT_DETAIL.values())) == len(score.HALT_OUTCOMES)


# --- F11: profile litter is counted, never deleted --------------------------

def test_profile_dirs_are_counted(tmp_path):
    root = tmp_path / "profiles"
    assert cdp.count_profile_dirs(str(root)) == 0
    for owner in ("ownerA", "ownerB", "ownerC"):
        (root / owner / "fermix_visible").mkdir(parents=True)
    (root / "stray.txt").write_text("x", encoding="utf-8")
    assert cdp.count_profile_dirs(str(root)) == 3


def test_the_library_exposes_no_removal_helper():
    """The harness must never delete anything in the operator's home (SafeRm rule):
    browser-profile litter is documented and counted, not cleaned."""
    for module in (cdp, page, prompts, score, server, traces):
        source = open(module.__file__, encoding="utf-8").read()
        for forbidden in ("shutil.rmtree", "os.remove", "os.unlink", "os.rmdir"):
            assert forbidden not in source, (module.__name__, forbidden)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
