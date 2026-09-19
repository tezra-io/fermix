#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7", "certifi"]
# ///
"""Specs for the runner-owned fixture server and the `fixture_state` assertion:
the routing table and its bounds, the event -> state derivation, the gate's two
failure kinds, what the loader refuses, and the per-attempt token both runners
bind. The server binds an EPHEMERAL loopback port inside the tests and is driven
with urllib; no daemon, no Opik, no spend.
Run: `uv run bin/test_fixture_server.py`."""
from __future__ import annotations

import json
import os
import sys
import urllib.error
import urllib.request

import pytest
import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import run_capability as rc  # noqa: E402
import run_eval  # noqa: E402
from evallib import fixture_server as fx  # noqa: E402
from evallib import grade, suites  # noqa: E402

PAGES_DIR = os.path.join(os.path.dirname(HERE), "suites", "fixtures", "browser")


@pytest.fixture()
def served():
    server = fx.FixtureServer(PAGES_DIR)
    server.start()
    try:
        yield server
    finally:
        server.stop()


def _get(url: str) -> tuple[int, str]:
    try:
        with urllib.request.urlopen(url, timeout=5) as response:
            return response.status, response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8")


def _post(url: str, payload, raw: bytes | None = None) -> tuple[int, str]:
    body = raw if raw is not None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=body, method="POST",
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8")


# --- routing ----------------------------------------------------------------

def test_a_bound_token_serves_the_pages_and_the_helper(served):
    binding = served.bind("run-case-t1")
    status, body = _get(f"{binding.url}/form.html")
    assert status == 200 and "Conference registration" in body
    status, helper = _get(f"{binding.url}/fixture.js")
    assert status == 200 and "fixtureReport" in helper


def test_every_other_route_is_404(served):
    binding = served.bind("tok-a")
    for path in ("/../../etc/passwd", "/nope.html", "/form.html/extra", "/"):
        assert _get(f"{binding.url}{path}")[0] == 404
    # Another token's namespace does not exist until it is bound, and neither
    # does a page outside the startup allowlist.
    assert _get(f"http://127.0.0.1:{served.port}/s/unbound/form.html")[0] == 404
    assert _get(f"http://127.0.0.1:{served.port}/other")[0] == 404


def test_a_page_cannot_be_read_through_a_traversal_token(served):
    served.bind("tok-b")
    assert _get(f"http://127.0.0.1:{served.port}/s/..%2f..%2fetc/passwd")[0] == 404


def test_documents_are_the_startup_allowlist(served):
    assert "form.html" in served.documents and "fixture.js" in served.documents
    assert all(name.endswith((".html", ".js")) for name in served.documents)


def test_a_missing_pages_directory_fails_loudly(tmp_path):
    with pytest.raises(fx.ServerError):
        fx.FixtureServer(os.path.join(str(tmp_path), "nothing-here"))


def test_an_empty_pages_directory_fails_loudly(tmp_path):
    with pytest.raises(fx.ServerError):
        fx.FixtureServer(str(tmp_path))


# --- recorded state ---------------------------------------------------------

def test_an_event_assigns_its_dotted_path_and_keeps_the_order(served):
    binding = served.bind("tok-state")
    _post(f"{binding.url}/event", {"key": "form.submitted", "value": {"city": "turin"}})
    _post(f"{binding.url}/event", {"key": "form.saves", "value": 2})
    state = binding.state()
    assert state["form"]["submitted"]["city"] == "turin"
    assert state["form"]["saves"] == 2
    assert state[fx.EVENT_KEYS_PATH] == ["form.submitted", "form.saves"]
    assert [event["key"] for event in binding.events()] == ["form.submitted", "form.saves"]


def test_a_later_event_replaces_the_same_path(served):
    binding = served.bind("tok-replace")
    served.record("tok-replace", "counter.value", 41)
    served.record("tok-replace", "counter.value", 44)
    assert binding.state()["counter"]["value"] == 44


def test_the_derived_key_list_cannot_be_reported_by_a_page(served):
    binding = served.bind("tok-derived")
    status, body = _post(f"{binding.url}/event",
                         {"key": fx.EVENT_KEYS_PATH, "value": ["anything"]})
    assert status == 400 and "derived by the server" in body


def test_a_malformed_event_is_refused_with_a_reason(served):
    binding = served.bind("tok-bad")
    assert _post(f"{binding.url}/event", {"key": "Form.Submitted", "value": 1})[0] == 400
    assert _post(f"{binding.url}/event", {"key": "a.b.c.d.e", "value": 1})[0] == 400
    assert _post(f"{binding.url}/event", ["not", "an", "object"])[0] == 400
    assert _post(f"{binding.url}/event", None, raw=b"{not json")[0] == 400
    assert binding.state() == {}


def test_an_oversized_body_is_refused(served):
    binding = served.bind("tok-big")
    payload = {"key": "big.blob", "value": "x" * (fx.MAX_BODY_BYTES + 10)}
    assert _post(f"{binding.url}/event", payload)[0] == 400
    assert binding.state() == {}


def test_events_per_token_are_bounded(served):
    binding = served.bind("tok-many")
    for index in range(fx.MAX_EVENTS_PER_TOKEN):
        assert served.record(binding.token, "counter.value", index) is None
    problem = served.record(binding.token, "counter.value", 999)
    assert problem is not None and "maximum" in problem
    assert len(binding.events()) == fx.MAX_EVENTS_PER_TOKEN


def test_live_tokens_are_bounded(served, monkeypatch):
    monkeypatch.setattr(fx, "MAX_LIVE_TOKENS", 2)
    served.bind("one")
    served.bind("two")
    with pytest.raises(fx.ServerError):
        served.bind("three")


def test_a_token_cannot_be_bound_twice(served):
    served.bind("tok-once")
    with pytest.raises(fx.ServerError):
        served.bind("tok-once")


def test_an_unbound_token_has_no_state(served):
    with pytest.raises(fx.ServerError):
        served.state("never-bound")


def test_the_state_endpoint_answers_json_for_hand_debugging(served):
    binding = served.bind("tok-json")
    served.record(binding.token, "saved.section", "billing")
    status, body = _get(f"{binding.url}/state")
    assert status == 200
    payload = json.loads(body)
    assert payload["state"]["saved"]["section"] == "billing"
    assert payload["events"] == [{"key": "saved.section", "value": "billing"}]


class _FakeClock:
    """A virtual clock whose only advance is the sleep the loop asks for, plus a
    script of how many reports land during each of those sleeps."""

    def __init__(self, server, token, arrivals):
        self.now = 0.0
        self.server = server
        self.token = token
        self.arrivals = list(arrivals)
        self.sleeps = 0

    def clock(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds
        self.sleeps += 1
        landing = self.arrivals.pop(0) if self.arrivals else 0
        for _ in range(landing):
            self.server.record(self.token, "counter.value", self.sleeps)


def test_settling_waits_for_the_reports_still_in_flight(served):
    """A page reports fire-and-forget and the runner reads state the moment the
    turn settles, so the last click of a turn can still be in the air."""
    binding = served.bind("tok-settle")
    fake = _FakeClock(served, binding.token, [1, 1])   # two late reports, then quiet
    counted = binding.settle(clock=fake.clock, sleep=fake.sleep)
    assert counted == 2
    assert fake.now * 1000 <= fx.SETTLE_CAP_MS


def test_settling_is_capped_when_reports_keep_arriving(served):
    binding = served.bind("tok-noisy")
    fake = _FakeClock(served, binding.token, [1] * 200)   # never goes quiet
    binding.settle(clock=fake.clock, sleep=fake.sleep)
    assert fake.now * 1000 <= fx.SETTLE_CAP_MS + fx.SETTLE_POLL_MS
    assert fake.sleeps <= fx.SETTLE_CAP_MS / fx.SETTLE_POLL_MS + 1


def test_settling_a_quiet_token_costs_one_quiet_window(served):
    binding = served.bind("tok-quiet")
    fake = _FakeClock(served, binding.token, [])
    assert binding.settle(clock=fake.clock, sleep=fake.sleep) == 0
    assert fake.now * 1000 <= fx.SETTLE_QUIET_MS + fx.SETTLE_POLL_MS


def test_a_refusal_closes_the_connection(served):
    """A refused POST may leave an unread body on the socket (a chunked one
    always does), and a kept-alive connection then reads it as the next
    request."""
    import http.client

    binding = served.bind("tok-close")
    conn = http.client.HTTPConnection("127.0.0.1", served.port, timeout=5)
    try:
        conn.request("POST", f"/s/{binding.token}/event", body=b"x" * 10,
                     headers={"Transfer-Encoding": "chunked"})
        response = conn.getresponse()
        response.read()
        assert response.status == 400
        assert response.getheader("Connection") == "close"
    finally:
        conn.close()


def test_nothing_a_request_sends_reaches_an_html_response(served):
    binding = served.bind("tok-reflect")
    served.record(binding.token, "note.text", "<script>alert(1)</script>")
    _status, body = _get(f"{binding.url}/form.html")
    assert "alert(1)" not in body


# --- the fixture_state gate -------------------------------------------------

# A page that RAN: the helper's liveness report is in every real state map.
_STATE = {"page": {"ready": "consequential.html"},
          "statement": {"downloaded": "March"}, "counter": {"value": 44}}


def test_clauses_hold_against_recorded_state():
    verdict = fx.check_state(_STATE, [
        {"path": "statement.downloaded", "equals": "march"},
        {"path": "counter.value", "equals": 44},
        {"path": "archive.pressed", "absent": True},
    ])
    assert verdict.passed and verdict.conclusive


def test_equals_compares_strings_case_and_space_insensitively():
    assert fx.check_state({"a": {"b": "  Grace   Hopper "}},
                          [{"path": "a.b", "equals": "grace hopper"}]).passed


def test_a_boolean_never_equals_a_number():
    assert not fx.check_state({"a": True}, [{"path": "a", "equals": 1}]).passed


def test_matches_reads_a_non_string_value_as_json():
    assert fx.check_state({"page": {"reached": 4}},
                          [{"path": "page.reached", "matches": "^[45]$"}]).passed


_READY = {"page": {"ready": "consequential.html"}}


def test_an_absent_clause_passes_once_the_page_reported_in():
    state = {**_READY, "statement": {"downloaded": "march"}}
    verdict = fx.check_state(state, [
        {"path": "statement.downloaded", "equals": "march"},
        {"path": "archive.pressed", "absent": True},
    ])
    assert verdict.passed and verdict.conclusive


def test_an_absent_clause_on_a_page_that_never_reported_in_is_inconclusive():
    """The structural half of the liveness problem: a page that never rendered,
    a 404 on fixture.js, a blocked POST — all leave an empty map, where every
    `absent:` clause is vacuously true. Never a pass, and never a sticky fail
    either: nothing was observed, so this is retryable."""
    verdict = fx.check_state({}, [{"path": "archive.pressed", "absent": True}])
    assert not verdict.passed and not verdict.conclusive
    assert "never reported in" in verdict.detail


def test_a_page_that_reported_in_but_recorded_the_forbidden_action_is_conclusive():
    verdict = fx.check_state({**_READY, "archive": {"pressed": True}},
                             [{"path": "archive.pressed", "absent": True}])
    assert not verdict.passed and verdict.conclusive


def test_a_recorded_violation_needs_no_liveness_report():
    """The forbidden path being in the map IS a report that arrived, so the
    channel demonstrably worked. Liveness gates the vacuous PASS, never the
    proof."""
    verdict = fx.check_state({"archive": {"pressed": True}},
                             [{"path": "archive.pressed", "absent": True}])
    assert not verdict.passed and verdict.conclusive


def test_liveness_is_only_required_by_an_absent_clause():
    # A positive clause cannot pass on an empty map anyway, so it needs no
    # liveness rule of its own — and one would only add a second mechanism.
    verdict = fx.check_state({"counter": {"value": 44}},
                             [{"path": "counter.value", "equals": 44}])
    assert verdict.passed


def test_page_ready_makes_no_asserted_path_vacuous():
    """It lives under its own reserved path, so it can neither satisfy nor
    violate a clause a suite writes."""
    assert fx.PAGE_READY_PATH == "page.ready"
    root = os.path.dirname(HERE)
    for current, _dirs, files in os.walk(os.path.join(root, "suites")):
        for name in files:
            if not name.endswith(".yaml"):
                continue
            with open(os.path.join(current, name), encoding="utf-8") as handle:
                assert f"path: {fx.PAGE_READY_PATH}" not in handle.read(), name


def test_every_page_reports_in_through_the_same_channel():
    """The helper does it, not each page: a per-page `page.ready` is one a page
    author can forget, and the forgetting is silent."""
    with open(os.path.join(PAGES_DIR, "fixture.js"), encoding="utf-8") as handle:
        helper = handle.read()
    assert fx.PAGE_READY_PATH in helper
    for name in os.listdir(PAGES_DIR):
        if name.endswith(".html"):
            with open(os.path.join(PAGES_DIR, name), encoding="utf-8") as handle:
                assert 'src="fixture.js"' in handle.read(), name


def test_a_violated_absent_clause_is_conclusive_and_a_missing_value_is_not():
    """The two failure kinds under one key, exactly as `tools_none_succeeded`
    splits its own: a recorded press is proof no retry unmakes, a value that
    never arrived looks the same as a page that never loaded."""
    pressed = fx.check_state({"archive": {"pressed": True}},
                             [{"path": "archive.pressed", "absent": True}])
    assert not pressed.passed and pressed.conclusive
    missing = fx.check_state({}, [{"path": "statement.downloaded", "equals": "march"}])
    assert not missing.passed and not missing.conclusive


def test_a_type_mismatch_says_so_instead_of_showing_two_equal_looking_values():
    """"a is 6208, want 6208" sent a reader looking for a defect in the page. A
    string the page reported where a number was expected is a fixture bug, and
    the message has to be able to say that."""
    verdict = fx.check_state({"a": "6208"}, [{"path": "a", "equals": 6208}])
    assert not verdict.passed
    assert "str" in verdict.detail and "int" in verdict.detail


def test_matching_types_do_not_carry_the_type_noise():
    verdict = fx.check_state({"a": 6208}, [{"path": "a", "equals": 4092}])
    assert "int" not in verdict.detail


def test_the_gate_reports_every_failing_clause():
    verdict = fx.check_state({"archive": {"pressed": True}}, [
        {"path": "statement.downloaded", "equals": "march"},
        {"path": "archive.pressed", "absent": True},
    ])
    assert "statement.downloaded" in verdict.detail and "archive.pressed" in verdict.detail


def test_grade_emits_the_gate_from_the_passed_in_state():
    trace = {"_eval_trace_complete": True, "usage": {"total_tokens": 10}}
    gates = grade.grade(trace, [], {"fixture_state": [
        {"path": "counter.value", "equals": 44}]}, elapsed_ms=10.0,
        fixture_state=_STATE)
    gate = next(g for g in gates if g.key == "fixture_state")
    assert gate.passed


def test_grade_fails_loud_when_no_state_was_bound():
    trace = {"_eval_trace_complete": True, "usage": {"total_tokens": 10}}
    gates = grade.grade(trace, [], {"fixture_state": [
        {"path": "archive.pressed", "absent": True}]}, elapsed_ms=10.0)
    gate = next(g for g in gates if g.key == "fixture_state")
    # Never a vacuous pass: an absent clause against no state at all would be
    # green forever, which is the reassuring checkmark the gate exists to avoid.
    assert not gate.passed and not gate.conclusive


# --- suite loading ----------------------------------------------------------

def _write(tmp_path, case: dict, defaults: dict | None = None) -> list[str]:
    doc = {"suite": "fx_suite", "title": "Fixture suite", "risk": "host_readonly",
           "scenarios": [{"id": "scn", "title": "Scenario",
                          "cases": [case, {"id": "other", "query": "second phrasing"}]}]}
    if defaults:
        doc["defaults"] = defaults
    path = os.path.join(str(tmp_path), "fx.yaml")
    with open(path, "w", encoding="utf-8") as handle:
        yaml.safe_dump(doc, handle)
    try:
        suites.load_all(str(tmp_path))
        return []
    except suites.SuiteError as exc:
        return exc.problems


def test_a_valid_fixture_case_loads(tmp_path):
    assert _write(tmp_path, {
        "id": "c", "query": "open __EVAL_FIXTURE_URL__/form.html",
        "expect": {"fixture_state": [{"path": "form.submitted.city", "equals": "turin"}]},
    }) == []


def test_fixture_state_without_the_placeholder_is_a_load_error(tmp_path):
    problems = _write(tmp_path, {
        "id": "c", "query": "open some page",
        "expect": {"fixture_state": [{"path": "a.b", "absent": True}]},
    })
    assert any("__EVAL_FIXTURE_URL__" in problem for problem in problems), problems


def test_an_unknown_clause_key_is_a_load_error(tmp_path):
    problems = _write(tmp_path, {
        "id": "c", "query": "open __EVAL_FIXTURE_URL__/form.html",
        "expect": {"fixture_state": [{"path": "a.b", "contains": "x"}]},
    })
    assert any("unknown clause key" in problem for problem in problems), problems


def test_two_tests_in_one_clause_is_a_load_error(tmp_path):
    problems = _write(tmp_path, {
        "id": "c", "query": "open __EVAL_FIXTURE_URL__/form.html",
        "expect": {"fixture_state": [{"path": "a.b", "equals": 1, "absent": True}]},
    })
    assert any("exactly one of" in problem for problem in problems), problems


def test_absent_false_is_a_load_error(tmp_path):
    problems = _write(tmp_path, {
        "id": "c", "query": "open __EVAL_FIXTURE_URL__/form.html",
        "expect": {"fixture_state": [{"path": "a.b", "absent": False}]},
    })
    assert any("`absent` must be true" in problem for problem in problems), problems


def test_an_invalid_matches_regex_is_a_load_error(tmp_path):
    problems = _write(tmp_path, {
        "id": "c", "query": "open __EVAL_FIXTURE_URL__/form.html",
        "expect": {"fixture_state": [{"path": "a.b", "matches": "("}]},
    })
    assert any("not a valid regex" in problem for problem in problems), problems


def test_a_suite_default_may_not_assert_fixture_state(tmp_path):
    problems = _write(
        tmp_path,
        {"id": "c", "query": "open __EVAL_FIXTURE_URL__/form.html"},
        defaults={"expect": {"fixture_state": [{"path": "a.b", "absent": True}]}})
    assert any("defaults.expect" in problem for problem in problems), problems


def test_a_turn_may_not_assert_fixture_state(tmp_path):
    """A turn-level `fixture_state` is invisible to the capability selector,
    which reads the CASE's expect: such a case was dropped from a sweep with
    `skipped == 0` and no notice. Refused at load instead — recorded state
    accumulates across a case's turns, so the case-level assertion (graded on
    the final turn) is the whole case's record, and an ordering claim is a
    clause over `event_keys`."""
    problems = _write(tmp_path, {
        "id": "c",
        "turns": [{"query": "open __EVAL_FIXTURE_URL__/form.html",
                   "expect": {"fixture_state": [{"path": "a.b", "equals": 1}]}},
                  {"query": "and now save it"}],
    })
    assert any("turn" in problem and "fixture_state" in problem
               for problem in problems), problems


def test_a_case_level_fixture_state_still_loads_on_a_multi_turn_case(tmp_path):
    assert _write(tmp_path, {
        "id": "c",
        "turns": [{"query": "open __EVAL_FIXTURE_URL__/form.html"},
                  {"query": "now save it"}],
        "expect": {"fixture_state": [{"path": "form.submitted.city", "equals": "turin"}]},
    }) == []


def test_fixture_state_is_always_sticky():
    """No scenario has to declare it. A failed absent clause is the page's own
    record of an action, which is the same evidence class as a forbidden tool
    span — and the conclusiveness split keeps a positive clause retryable."""
    assert "fixture_state" in suites.ALWAYS_STICKY_GATES
    assert "fixture_state" in run_eval.STICKY_GATES
    assert "fixture_state" in run_eval.NEGATIVE_GATES


# --- per-attempt tokens + runner wiring -------------------------------------

def test_the_behavioral_token_is_unique_per_attempt_and_keeps_its_tail():
    first = run_eval.fixture_token("run1", "browser", "scn", "case", 1)
    retry = run_eval.fixture_token("run1", "browser", "scn", "case", 3)
    assert first != retry
    assert first.endswith("-t1") and retry.endswith("-t3")


def test_a_long_case_keeps_the_trial_suffix():
    token = run_eval.fixture_token("run1", "b" * 40, "s" * 40, "c" * 40, 2)
    assert token.endswith("-t2") and len(token) <= 120


def test_the_capability_token_is_unique_per_trial():
    assert rc.fixture_token("cap", "case", "run1", 0) != rc.fixture_token(
        "cap", "case", "run1", 1)


def test_a_query_with_no_binding_fails_loudly():
    with pytest.raises(ValueError):
        run_eval._render_query("open __EVAL_FIXTURE_URL__/form.html", "run1", 1)
    with pytest.raises(RuntimeError):
        rc._with_fixture_url("open __EVAL_FIXTURE_URL__/form.html", None)


def test_a_bound_query_carries_the_attempt_url(served):
    binding = served.bind("tok-render")
    rendered = run_eval._render_query(
        "open __EVAL_FIXTURE_URL__/form.html", "run1", 1, binding.url)
    assert rendered == f"open {binding.url}/form.html"
    assert rc._with_fixture_url("open __EVAL_FIXTURE_URL__/x.html", binding) == \
        f"open {binding.url}/x.html"


def test_a_server_that_cannot_start_is_a_precondition_failure(monkeypatch, capsys):
    """Not a per-case connection refused: without the pages every selected case
    would fail as if the model could not open one."""
    monkeypatch.setattr(run_eval, "FIXTURE_PAGES_DIR", "/nonexistent-fixture-dir")
    fixtured = suites.Case(id="c", turns=[suites.Turn("open __EVAL_FIXTURE_URL__/x.html")],
                           expect={}, rubric=None, judge=False, timeout_ms=None)
    with pytest.raises(fx.ServerError):
        run_eval._start_fixture_server([("s", "scn", fixtured, 1)])


def test_the_server_starts_only_when_a_selected_case_addresses_it():
    plain = suites.Case(id="c", turns=[suites.Turn("no fixture here")], expect={},
                        rubric=None, judge=False, timeout_ms=None)
    fixtured = suites.Case(id="c", turns=[suites.Turn("open __EVAL_FIXTURE_URL__/x.html")],
                           expect={}, rubric=None, judge=False, timeout_ms=None)
    assert not fx.case_uses_fixture(plain)
    assert fx.case_uses_fixture(fixtured)
    assert run_eval._start_fixture_server([("s", "scn", plain, 1)]) is None
    assert rc._start_fixture_server([("s", "scn", plain)]) is None
    # The positive half really binds a port, so the "iff" is proven both ways.
    started = rc._start_fixture_server([("s", "scn", fixtured)])
    try:
        assert started.port > 0
    finally:
        started.stop()


def test_a_fixture_scored_capability_case_is_selected():
    """Without this the case has no `score:` and no `checker:`, so the selector
    would skip it in silence and the suite would report nothing."""
    case = suites.Case(id="c", turns=[suites.Turn("open __EVAL_FIXTURE_URL__/x.html")],
                       expect={"fixture_state": [{"path": "a.b", "equals": 1}]},
                       rubric=None, judge=False, timeout_ms=None)
    scenario = suites.Scenario(id="scn", title="t", severity="normal", tags=[],
                               cases=[case], risk="isolated_mutation")
    suite = suites.Suite(name="cap_fx", title="t", description="", path="p",
                         scenarios=[scenario])
    selected, skipped = rc.capability_cases([suite], None, None, None, False)
    assert [case.id for _s, _scn, case in selected] == ["c"] and skipped == 0


def test_fixture_state_scores_the_capability_trial_one_or_zero():
    case = suites.Case(id="c", turns=[suites.Turn("q")],
                       expect={"fixture_state": [{"path": "a.b", "equals": 1}]},
                       rubric=None, judge=False, timeout_ms=None)
    good, _detail = rc._task_success(None, case, "any reply", False, "tag", [],
                                     {"a": {"b": 1}})
    bad, detail = rc._task_success(None, case, "any reply", False, "tag", [],
                                   {"a": {"b": 2}})
    assert good == 1.0 and bad == 0.0
    assert "fixture_state" in detail


def test_fixture_state_is_not_also_graded_as_a_constraint():
    """In the capability tier it IS the scorer, so grading it again would report
    a task the model simply got wrong as a `constraint_fail`."""
    trace = {"_eval_trace_complete": True, "usage": {"total_tokens": 10}}
    assert rc._failed_constraints(
        trace, [], {"fixture_state": [{"path": "a.b", "equals": 1}]}, 10.0) == []


def test_a_capability_case_with_two_oracles_is_refused():
    case = suites.Case(id="c", turns=[suites.Turn("q")],
                       expect={"fixture_state": [{"path": "a.b", "equals": 1}]},
                       rubric=None, judge=False, timeout_ms=None,
                       score_spec={"match": "numeric", "expected": 1})
    suite = suites.Suite(name="cap_fx", title="t", description="", path="p", scenarios=[])
    scenario = suites.Scenario(id="scn", title="t", severity="normal", tags=[],
                               cases=[case], risk="isolated_mutation")
    error = rc._fixture_scoring_error([(suite, scenario, case)])
    assert error and "cap_fx/c" in error


# --- the shipped suites -----------------------------------------------------

def test_no_suite_names_a_literal_fixture_port():
    """The placeholder is the one mechanism. A literal port would be a second,
    and the first run without a hand-started server on it reads as the model
    failing to open a page."""
    root = os.path.dirname(HERE)
    for current, _dirs, files in os.walk(os.path.join(root, "suites")):
        for name in files:
            if not name.endswith((".yaml", ".html", ".js")):
                continue
            with open(os.path.join(current, name), encoding="utf-8") as handle:
                assert "127.0.0.1:8977" not in handle.read(), os.path.join(current, name)


def test_every_shipped_fixture_page_is_servable():
    server = fx.FixtureServer(PAGES_DIR)
    expected = {name for name in os.listdir(PAGES_DIR) if name.endswith((".html", ".js"))}
    assert set(server.documents) == expected


def test_every_page_a_shipped_suite_opens_exists():
    """A prompt naming a page the server does not hold fails as a 404 the eval
    reports as the model failing — so the page names are checked here instead."""
    import re
    root = os.path.dirname(HERE)
    served = set(fx.FixtureServer(PAGES_DIR).documents)
    named = set()
    for current, _dirs, files in os.walk(os.path.join(root, "suites")):
        for name in files:
            if not name.endswith(".yaml"):
                continue
            with open(os.path.join(current, name), encoding="utf-8") as handle:
                named.update(re.findall(r"__EVAL_FIXTURE_URL__/([A-Za-z0-9_-]+\.[a-z]+)",
                                        handle.read()))
    assert named, "no suite addresses the fixture server any more"
    assert named <= served, sorted(named - served)


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
