#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pytest>=8", "pyyaml>=6,<7"]
# ///
"""Tests for the Cues screen eval (run_screen_eval.py): the shipped set and the set
validation, the item shapes the engine takes, provider selection from the
environment, and the scoring and report over fixed fake probabilities. Pure and
temp-dir only: no engine, no network, no key. Run: `uv run bin/test_screen_eval.py`."""
from __future__ import annotations

import json
import os
import sys
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import pytest  # noqa: E402
import yaml  # noqa: E402

import run_screen_eval as screen  # noqa: E402
from run_screen_eval import IRRELEVANT, THROUGH, Pair, ScreenSet  # noqa: E402

# --- the shipped set ----------------------------------------------------------------


def test_the_shipped_set_is_valid_runnable_and_big_enough_to_show_a_recall_gap():
    shipped = screen.load_set(screen.SET_PATH)
    assert screen.risk_refusal(shipped) is None
    assert shipped.risk == "host_readonly"
    assert len(shipped.pairs) >= 60
    kinds = Counter(p.kind for p in shipped.pairs)
    assert all(kinds[k] >= 5 for label in screen.KINDS for k in screen.KINDS[label]), kinds


def test_the_shipped_incident_item_is_one_item_on_two_watchers():
    shipped = screen.load_set(screen.SET_PATH)
    incident = [p for p in shipped.pairs if p.incident]
    assert {p.watcher for p in incident} == {"lumen_resets", "lumen_plans"}
    assert incident[0].item == incident[1].item
    assert incident[0].item["data"]["text"] == "lumen reset is on its way. enjoy."
    assert {p.label for p in incident} == {THROUGH}


# --- set validation -----------------------------------------------------------------


def _item(n: int, label: str = THROUGH, kind: str | None = None, **extra) -> dict:
    kind = kind or screen.KINDS[label][0]
    return {"id": f"item_{n}", "source": "feed-a", "at": "2026-10-28T09:00:00Z",
            "feed": {"title": f"Title {n}", "link": f"https://feed.example/{n}"},
            "label": label, "kind": kind, "why": "because", **extra}


def _doc(**top) -> dict:
    doc = {"set": "spec_set", "title": "Spec", "risk": "host_readonly",
           "watchers": [{"id": "w_one", "name": "w-one", "subject": "s", "purpose": "A purpose.",
                         "instructions": ["Pass only one thing."], "listen_for": ["thing"],
                         "items": [_item(1), _item(2, IRRELEVANT)]}]}
    doc.update(top)
    return doc


def _write(tmp_path, doc) -> str:
    path = tmp_path / "set.yaml"
    path.write_text(yaml.safe_dump(doc, allow_unicode=True), encoding="utf-8")
    return str(path)


@pytest.fixture(autouse=True)
def _small_sets(monkeypatch):
    monkeypatch.setattr(screen, "MIN_PAIRS", 2)


def _problems(tmp_path, doc) -> list[str]:
    with pytest.raises(screen.SetError) as exc:
        screen.load_set(_write(tmp_path, doc))
    return exc.value.problems


def test_a_minimal_set_loads(tmp_path):
    loaded = screen.load_set(_write(tmp_path, _doc()))
    assert [p.id for p in loaded.pairs] == ["w_one/item_1", "w_one/item_2"]
    assert loaded.watchers["w_one"].instructions == ("Pass only one thing.",)


@pytest.mark.parametrize("risk, words", [
    (None, "declares no risk"),
    ("private_account_read", "refuses the high-impact risk"),
    ("isolated_mutation", "measures only host_readonly"),
    ("somewhere", "is not one of"),
])
def test_a_risk_other_than_host_readonly_is_refused_loudly(tmp_path, risk, words):
    doc = _doc()
    if risk is None:
        del doc["risk"]
    else:
        doc["risk"] = risk
    assert words in screen.risk_refusal(screen.load_set(_write(tmp_path, doc)))


def test_a_set_without_risk_never_runs(tmp_path, capsys):
    doc = _doc()
    del doc["risk"]
    assert screen.main(["--set", _write(tmp_path, doc), "--dry-run"], environ={}) == 2
    assert "declares no risk" in capsys.readouterr().err


@pytest.mark.parametrize("mutate, words", [
    (lambda d: d["watchers"][0]["items"][0].update(kind="keyword_decoy"), "kind of a should_screen"),
    (lambda d: d["watchers"][0]["items"][0].update(label="maybe"), "label must be"),
    (lambda d: d["watchers"][0]["items"][0].update(at="2026-10-28T09:00:00"), "absolute ISO 8601"),
    (lambda d: d["watchers"][0]["items"][0].update(why=""), "why must say"),
    (lambda d: d["watchers"][0]["items"][1].update(label=THROUGH, kind="wanted"), "has no irrelevant"),
    (lambda d: d["watchers"][0]["items"][0].update(colour="red"), "unknown key(s) colour"),
    (lambda d: d["watchers"][0]["items"].append(_item(1)), "id used twice"),
    (lambda d: d["watchers"][0].update(purpose="x" * 201), "over 200 characters"),
    (lambda d: d["watchers"][0]["items"][0].update(
        x={"username": "far_too_long_a_handle", "name": "N", "text": "t"}), "exactly one of"),
])
def test_a_bad_pair_or_watcher_is_named(tmp_path, mutate, words):
    doc = _doc()
    mutate(doc)
    assert any(words in problem for problem in _problems(tmp_path, doc))


def test_a_ref_must_name_a_used_shared_item(tmp_path):
    doc = _doc(shared_items={"spare": {"source": "feed-a", "at": "2026-10-28T09:00:00Z",
                                       "feed": {"title": "T", "link": "https://feed.example/s"}}})
    doc["watchers"][0]["items"].append({"id": "item_3", "ref": "missing", "label": THROUGH,
                                        "kind": "wanted", "why": "w"})
    problems = _problems(tmp_path, doc)
    assert any("names no shared item" in p for p in problems)
    assert any("shared item spare: no watcher uses it" in p for p in problems)


def test_a_set_too_small_to_measure_is_refused(tmp_path, monkeypatch):
    monkeypatch.setattr(screen, "MIN_PAIRS", 60)
    assert any("needs at least 60" in p for p in _problems(tmp_path, _doc()))


# --- the item as the engine takes it --------------------------------------------------


def test_an_x_post_is_shaped_as_the_x_source_reads_it():
    problems: list[str] = []
    item = screen.engine_item({"source": "x-a", "at": "2026-10-30T21:14:05+02:00",
                               "x": {"username": "ada_q", "name": "Ada Q", "text": "hello"}},
                              "spec", problems)
    assert problems == []
    assert item["type"] == "x.post"
    assert item["subject"] == item["data"]["author_id"] == item["data"]["author"]["id"]
    assert item["data"]["author"]["username"] == "ada_q"
    assert item["data"]["url"] == f"https://x.com/ada_q/status/{item['item_id']}"
    assert item["occurred_at"] == "2026-10-30T19:14:05Z"
    assert item["received_at"] == "2026-10-30T19:14:10Z"
    assert item["source_ref"] == "x-a" and item["title"] is None


def test_a_feed_entry_and_a_raw_item_keep_their_fields():
    problems: list[str] = []
    feed = screen.engine_item({"source": "f", "at": "2026-10-30T10:00:00Z",
                               "feed": {"title": "T", "link": "https://f.example/1", "summary": "S"}},
                              "feed", problems)
    raw = screen.engine_item({"source": "r", "at": "2026-10-30T10:00:00Z",
                              "raw": {"type": "release", "data": {"action": "published"}}},
                             "raw", problems)
    assert problems == []
    assert (feed["type"], feed["title"], feed["item_id"]) == ("feed.item", "T", "https://f.example/1")
    assert feed["data"] == {"title": "T", "link": "https://f.example/1", "summary": "S",
                            "author": None, "categories": []}
    assert (raw["type"], raw["data"], raw["subject"]) == ("release", {"action": "published"}, None)


# --- providers from the environment ----------------------------------------------------


def test_a_provider_is_available_only_when_its_key_variable_is_set_and_not_blank():
    providers = screen.plan_providers(None, {"OPENAI_API_KEY": "sk-x", "VENICE_API_KEY": "  "})
    assert [(p.name, p.available) for p in providers] == [
        ("openai", True), ("openrouter", False), ("venice", False)]
    assert [p.name for p in screen.plan_providers(["venice"], {})] == ["venice"]


def test_the_engine_gets_a_temp_home_dev_env_and_only_the_keys_it_asks_with():
    env = screen.engine_env({"OPENAI_API_KEY": "a", "OPENROUTER_API_KEY": "b", "PATH": "/bin",
                             "MIX_ENV": "test", "FERMIX_HOME": "/elsewhere"}, "/tmp/h", ["openai"])
    assert env == {"OPENAI_API_KEY": "a", "PATH": "/bin", "MIX_ENV": "dev", "FERMIX_HOME": "/tmp/h"}


def test_every_provider_skipped_spends_nothing_and_exits_3(tmp_path, capsys, monkeypatch):
    monkeypatch.setattr(screen, "run_engine", lambda *a, **k: pytest.fail("the engine ran"))
    code = screen.main(["--out", str(tmp_path)], environ={})
    out = capsys.readouterr().out
    assert code == 3
    assert out.count("SKIPPED") == 3
    assert "every provider was skipped: nothing was measured" in out


def test_a_key_never_reaches_the_record_or_the_screen():
    environ = {"OPENROUTER_API_KEY": "sk-or-v1-secretsecret"}
    record = {"provider": "openrouter", "aborted": {
        "kind": "auth", "message": "bad key sk-or-v1-secretsecret and sk-proj-****abcd"}}
    redacted = screen.redact_record(record, environ)
    assert "secret" not in json.dumps(redacted) and "abcd" not in json.dumps(redacted)
    assert redacted["aborted"]["message"] == "bad key <redacted> and <redacted>"


# --- scoring ------------------------------------------------------------------------

PAIRS = (
    Pair("w/t1", "w", {}, THROUGH, "wanted", False),
    Pair("w/t2", "w", {}, THROUGH, "wanted_oblique", True),
    Pair("w/t3", "w", {}, THROUGH, "fails_condition", False),
    Pair("w/i1", "w", {}, IRRELEVANT, "keyword_decoy", False),
    Pair("w/i2", "w", {}, IRRELEVANT, "off_topic", False),
)
FIXTURE_SET = ScreenSet(name="fixture", risk="host_readonly", watchers={"w": None}, pairs=PAIRS)
# t2 sits exactly on 0.3 under A: the screen keeps an item at p >= the bar.
PROBS = {"A": {"t1": 0.9, "t2": 0.3, "t3": 0.05, "i1": 0.35, "i2": 0.02},
         "B": {"t1": 0.95, "t2": 0.45, "t3": 0.5, "i1": 0.15, "i2": 0.3}}


def _records(provider="openai", probs=PROBS, model="gpt-6-luna-2026-10"):
    return [{"provider": provider, "form": form, "pair": f"w/{pid}", "probability": p,
             "model": model, "tokens": {"prompt": 100, "completion": 1}}
            for form, by_pair in probs.items() for pid, p in by_pair.items()]


def _skipped(*names):
    return [{"provider": n, "skipped": f"{screen.PROVIDERS[n]} not in the environment"} for n in names]


def test_fake_probabilities_give_the_right_table():
    result = screen.score(FIXTURE_SET, _records() + _skipped("openrouter", "venice"))
    got = {(r["form"], r["bar"]): (r["kept"], r["through"], r["dropped"], r["irrelevant"])
           for r in result["rates"]}
    assert got == {
        ("A", 0.1): (2, 3, 1, 2), ("A", 0.2): (2, 3, 1, 2),
        ("A", 0.3): (2, 3, 1, 2), ("A", 0.4): (1, 3, 2, 2),
        ("B", 0.1): (3, 3, 0, 2), ("B", 0.2): (3, 3, 1, 2),
        ("B", 0.3): (3, 3, 1, 2), ("B", 0.4): (3, 3, 2, 2),
    }
    assert [s.state for s in result["statuses"].values()] == ["measured", "skipped", "skipped"]


def test_the_kind_split_and_the_paired_view_follow_the_same_bars():
    result = screen.score(FIXTURE_SET, _records())
    kinds = {(r["form"], r["kind"]): r["hits"] for r in result["kinds"]}
    assert kinds[("A", "wanted_oblique")] == [1, 1, 1, 0]
    assert kinds[("A", "fails_condition")] == [0, 0, 0, 0]
    assert kinds[("B", "keyword_decoy")] == [0, 1, 1, 1]
    at_03 = next(r for r in result["paired"] if r["bar"] == 0.3)
    assert (at_03["kept_only_a"], at_03["kept_only_b"]) == (0, 1)
    assert (at_03["dropped_only_a"], at_03["dropped_only_b"]) == (1, 1)
    assert result["incident"][0]["p"] == {"w/t2": 0.3}
    assert result["tokens"]["openai/A"] == {"prompt": 500, "completion": 5}


def test_a_content_failure_is_unscored_and_left_out_of_the_denominators():
    records = _records()
    records = [r for r in records if not (r["form"] == "A" and r["pair"] == "w/t1")]
    records.append({"provider": "openai", "form": "A", "pair": "w/t1",
                    "error": {"kind": "refused", "message": "refused to judge this"}})
    result = screen.score(FIXTURE_SET, records)
    row = next(r for r in result["rates"] if r["form"] == "A" and r["bar"] == 0.3)
    assert (row["kept"], row["through"], row["unscored"]) == (1, 2, 1)
    assert result["statuses"]["openai"].state == "measured"
    assert result["statuses"]["openai"].unscored == 1


@pytest.mark.parametrize("cut, words", [
    ({"provider": "openai", "aborted": {"kind": "auth", "message": "Incorrect key"}},
     "stopped after 7 of 10 requests: auth: Incorrect key"),
    (None, "answered 7 of 10 requests"),
])
def test_a_provider_that_did_not_finish_is_invalid_never_a_score(cut, words):
    records = _records()[:7] + ([cut] if cut else []) + _records("venice", model="jev-7")
    result = screen.score(FIXTURE_SET, records)
    assert result["statuses"]["openai"].state == "invalid"
    assert words in result["statuses"]["openai"].reason
    assert {r["provider"] for r in result["rates"]} == {"venice"}
    assert screen._exit_code(result["statuses"]) == 4


@pytest.mark.parametrize("only_a, only_b, p", [(0, 0, 1.0), (0, 6, 0.03125), (1, 6, 0.125),
                                               (3, 3, 1.0)])
def test_the_exact_mcnemar_p(only_a, only_b, p):
    assert screen.mcnemar_p(only_a, only_b) == pytest.approx(p)


def test_the_report_prints_the_table_and_writes_its_files(tmp_path, capsys):
    code = screen.report(FIXTURE_SET, _records() + _skipped("venice"), str(tmp_path / "run"))
    out = capsys.readouterr().out
    assert code == 0
    assert "openai      A    0.3  2/3  66.7%       1/2  50.0%         0" in out
    assert "venice      SKIPPED   VENICE_API_KEY not in the environment" in out
    assert "openai      measured  answered by gpt-6-luna-2026-10; unscored 0" in out
    saved = json.loads((tmp_path / "run" / "results.json").read_text())
    assert saved["statuses"]["venice"]["state"] == "skipped"
    assert "| w/t2 | should_screen_through | wanted_oblique | 0.30 | 0.45 |" in \
        (tmp_path / "run" / "report.md").read_text()


def test_a_finished_run_scores_again_from_its_calls(tmp_path, capsys):
    calls = tmp_path / "calls.jsonl"
    screen.write_jsonl(str(calls), _skipped("openai", "openrouter", "venice"))
    assert screen.main(["--from-calls", str(calls), "--out", str(tmp_path)], environ={}) == 3
    assert capsys.readouterr().out.count("SKIPPED") == 3


def test_a_dry_run_render_must_cover_every_pair_in_both_forms():
    rendered = [{"pair": p.id, "form": f} for p in PAIRS for f in screen.FORMS]
    assert screen._render_problem(FIXTURE_SET, rendered) is None
    assert "rendered 9 requests" in screen._render_problem(FIXTURE_SET, rendered[:-1])


if __name__ == "__main__":
    sys.exit(pytest.main([__file__, "-q"]))
