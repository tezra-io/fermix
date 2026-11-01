#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pyyaml>=6,<7"]
# ///
"""The Cues screen eval: how the decision model that screens each item before the
filter model reads it scores a labelled set, in two question forms, at four bars.

  uv run bin/run_screen_eval.py --dry-run          validate the set, render every
                                                   request through the engine, plan
                                                   the calls; spends nothing
  uv run bin/run_screen_eval.py [--provider NAME]  the live run (make capability-screen)
  uv run bin/run_screen_eval.py --from-calls <run>/calls.jsonl
                                                   score a finished run again

The set (suites/capability/fixtures/cues/screen_set.yaml) holds watchers and, for each,
items labelled `should_screen_through` or `irrelevant`; its `labelling` key says how
the labels were decided. For each pair the engine half (bin/screen_eval.exs, run with
`mix run --no-start` in a temporary FERMIX_HOME that holds nothing and is removed
afterwards) builds the claim the filter builds and takes the screen's own request from
`Cues.Filter.Decision.request/1`:

  form A  the item and the question the screen sends today;
  form B  the same request with the numbered instructions taken out of the question
          (purpose, keywords and the owner's marked examples stay), built in the eval
          harness only, never in the engine.

Live, it asks each request on every decision model whose provider key is in this
shell's environment, through `Providers.DecisionModel.yes_no/4` (the screen's own HTTP
call): OPENAI_API_KEY (OpenAI, gpt-6-luna), OPENROUTER_API_KEY (OpenRouter, Jev),
VENICE_API_KEY (Venice, Jev). That is the path seed_capability_home.py documents for
its explicit mode: config/runtime.exs reads the variable at boot, so no key is ever on
disk, and this runner never reads the keychain and never prints a key. A provider with
no key is reported SKIPPED, never a zero and never a pass. It reports, per provider and
form, the recall on `should_screen_through` and the share of `irrelevant` items dropped
at bars 0.1, 0.2, 0.3 and 0.4 (an item goes through at a probability >= the bar, as
the screen decides), the same split by kind, the pairs only one form keeps (with an
exact McNemar p), and the incident item's probabilities.

Risk: `host_readonly` (the set declares it and the runner refuses any other). Every
item is invented, so no connected-account, file or screen data reaches a provider; the
one owner resource used is the provider key, spent as every capability turn spends the
scored model's key; nothing is written outside a temporary home and this run's report
directory, and no daemon runs. Every number comes from this run's own answers: no
trace is read, and a provider that answered fewer requests than the plan holds is
INVALID rather than scored on what it answered.
Cost: one short decision request per pair and form, so 2 x pairs calls per provider
with a key; --dry-run prints the count and an input-token estimate. The rate card
(evallib/pricing.py) does not price decision models, so no dollar figure is computed.

A provider that fails mid-run (an auth, quota or route failure, or a rate limit or
server error that survives two retries) is INVALID: its partial answers stay in
calls.jsonl and no rates are printed for it. A refused question or an item too large
for the provider (the screen's content failures) is counted as unscored, beside the
rates, and left out of their denominators.

Writes reports/screen/<run>/: requests.jsonl (dry run), calls.jsonl, results.json and
report.md.

Exit: 0 measured (or a valid dry run) · 2 the set or the selection is refused · 3
nothing measured: every provider skipped, or the engine helper failed · 4 a provider's
measurement is invalid.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import subprocess
import sys
import tempfile
from collections import Counter
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from evallib import safe_rm  # noqa: E402
from evallib.suites import RISK_LEVELS, UNCLASSIFIED_RISK  # noqa: E402

BENCH_DIR = os.path.dirname(HERE)
REPO_ROOT = os.path.dirname(BENCH_DIR)
SET_PATH = os.path.join(BENCH_DIR, "suites", "capability", "fixtures", "cues", "screen_set.yaml")
ENGINE_SCRIPT = os.path.join(HERE, "screen_eval.exs")
REPORTS_DIR = os.path.join(BENCH_DIR, "reports", "screen")

# DecisionModel's providers, in its catalog order, each with the variable
# config/runtime.exs reads its key from.
PROVIDERS = {"openai": "OPENAI_API_KEY", "openrouter": "OPENROUTER_API_KEY",
             "venice": "VENICE_API_KEY"}
FORMS = ("A", "B")
BARS = (0.1, 0.2, 0.3, 0.4)
THROUGH = "should_screen_through"
IRRELEVANT = "irrelevant"
KINDS = {THROUGH: ("wanted", "wanted_oblique", "fails_condition"),
         IRRELEVANT: ("keyword_decoy", "same_source_off_topic", "off_topic")}
RUN_RISK = "host_readonly"
# run_capability.py's _selection_policy_error refuses the same four.
REFUSED_RISKS = ("private_account_read", "external_write", "desktop_input", "destructive")
MIN_PAIRS = 60
# Cues.Watchers' own limits on what a watcher holds.
MAX_PURPOSE_CHARS = 200
MAX_INSTRUCTIONS = 20
MAX_INSTRUCTION_CHARS = 300
X_HANDLE = re.compile(r"^[A-Za-z0-9_]{1,15}$")
ID_RE = re.compile(r"^[a-z0-9_]+$")
RECEIVED_LAG = timedelta(seconds=5)
CHARS_PER_TOKEN = 4
# Bounds on the engine helper: a BEAM boot with a compile, then per provider (they run
# side by side) each call's three attempts of the 15 s decision timeout plus backoff.
BOOT_BOUND_S = 900
CALL_BOUND_S = 60
KEY_SHAPE = re.compile(r"\bsk-[A-Za-z0-9_\-*]{6,}")

TOP_KEYS = {"set", "title", "description", "risk", "labelling", "shared_items", "watchers"}
WATCHER_KEYS = {"id", "name", "subject", "purpose", "instructions", "listen_for", "examples",
                "items"}
ITEM_SHAPES = ("x", "feed", "raw")
ITEM_KEYS = {"source", "at", *ITEM_SHAPES}
PAIR_KEYS = {"id", "ref", "label", "kind", "incident", "why", *ITEM_KEYS}
EXAMPLE_KEYS = {"label", "note", *ITEM_KEYS}


class SetError(Exception):
    def __init__(self, problems: list[str]):
        self.problems = problems
        super().__init__(f"{len(problems)} problem(s) in the screen set")


class EngineError(Exception):
    pass


@dataclass(frozen=True)
class Watcher:
    id: str
    name: str
    purpose: str
    instructions: tuple[str, ...]
    listen_for: tuple[str, ...]
    examples: tuple[dict, ...]


@dataclass(frozen=True)
class Pair:
    id: str
    watcher: str
    item: dict
    label: str
    kind: str
    incident: bool


@dataclass(frozen=True)
class ScreenSet:
    name: str
    risk: str
    watchers: dict
    pairs: tuple


@dataclass(frozen=True)
class Provider:
    name: str
    env: str
    available: bool


# --- the set ------------------------------------------------------------------------

def load_set(path: str) -> ScreenSet:
    """The set at `path`, validated: SetError lists every problem found."""
    with open(path, encoding="utf-8") as fh:
        doc = yaml.safe_load(fh)
    problems: list[str] = []
    if not isinstance(doc, dict):
        raise SetError([f"{path}: not a mapping"])
    _unknown_keys(doc, TOP_KEYS, "set", problems)
    shared = _shared_items(doc.get("shared_items") or {}, problems)
    watchers: dict[str, Watcher] = {}
    pairs: list[Pair] = []
    used: set[str] = set()
    for index, raw in enumerate(doc.get("watchers") or []):
        loaded = _watcher(raw, index, shared, used, problems)
        if loaded is None:
            continue
        watcher, watcher_pairs = loaded
        if watcher.id in watchers:
            problems.append(f"watcher {watcher.id}: id used twice")
        watchers[watcher.id] = watcher
        pairs.extend(watcher_pairs)
    problems.extend(_set_level_problems(doc, shared, used, pairs))
    if problems:
        raise SetError(problems)
    risk = doc.get("risk", UNCLASSIFIED_RISK)
    return ScreenSet(name=doc["set"], risk=risk, watchers=watchers, pairs=tuple(pairs))


def _set_level_problems(doc: dict, shared: dict, used: set, pairs: list) -> list[str]:
    problems = []
    if not isinstance(doc.get("set"), str) or not doc.get("set"):
        problems.append("set: needs a name")
    if not doc.get("watchers"):
        problems.append("watchers: none")
    if len(pairs) < MIN_PAIRS:
        problems.append(f"the set has {len(pairs)} labelled pairs; it needs at least {MIN_PAIRS}")
    problems.extend(f"shared item {key}: no watcher uses it" for key in sorted(set(shared) - used))
    return problems


def _shared_items(raw: dict, problems: list[str]) -> dict:
    if not isinstance(raw, dict):
        problems.append("shared_items: must be a mapping")
        return {}
    shared = {}
    for key, spec in raw.items():
        item = engine_item(spec, f"shared item {key}", problems)
        if item is not None:
            shared[key] = item
    return shared


def _watcher(raw, index: int, shared: dict, used: set, problems: list[str]):
    where = f"watcher #{index + 1}"
    if not isinstance(raw, dict):
        problems.append(f"{where}: must be a mapping")
        return None
    _unknown_keys(raw, WATCHER_KEYS, where, problems)
    wid = raw.get("id")
    if not isinstance(wid, str) or not ID_RE.match(wid):
        problems.append(f"{where}: id must be lower_snake_case")
        return None
    where = f"watcher {wid}"
    for key in ("name", "subject", "purpose"):
        if not isinstance(raw.get(key), str) or not raw[key].strip():
            problems.append(f"{where}: {key} must be a non-empty string")
    if len(raw.get("purpose") or "") > MAX_PURPOSE_CHARS:
        problems.append(f"{where}: purpose is over {MAX_PURPOSE_CHARS} characters")
    instructions = _instructions(raw.get("instructions"), where, problems)
    listen_for = _strings(raw.get("listen_for"), f"{where}: listen_for", problems)
    examples = tuple(_example(e, f"{where} example #{i + 1}", problems)
                     for i, e in enumerate(raw.get("examples") or []))
    pairs = _pairs(raw.get("items"), wid, shared, used, problems)
    watcher = Watcher(id=wid, name=raw.get("name") or "", purpose=raw.get("purpose") or "",
                      instructions=instructions, listen_for=listen_for,
                      examples=tuple(e for e in examples if e is not None))
    return watcher, pairs


def _instructions(raw, where: str, problems: list[str]) -> tuple[str, ...]:
    texts = _strings(raw, f"{where}: instructions", problems)
    if len(texts) > MAX_INSTRUCTIONS:
        problems.append(f"{where}: more than {MAX_INSTRUCTIONS} instructions")
    problems.extend(f"{where}: instruction {n} is over {MAX_INSTRUCTION_CHARS} characters"
                    for n, text in enumerate(texts, 1) if len(text) > MAX_INSTRUCTION_CHARS)
    return texts


def _strings(raw, where: str, problems: list[str]) -> tuple[str, ...]:
    if not isinstance(raw, list) or not raw:
        problems.append(f"{where}: must be a non-empty list")
        return ()
    if not all(isinstance(s, str) and s.strip() for s in raw):
        problems.append(f"{where}: every entry must be a non-empty string")
        return ()
    return tuple(raw)


def _example(raw, where: str, problems: list[str]) -> dict | None:
    if not isinstance(raw, dict):
        problems.append(f"{where}: must be a mapping")
        return None
    _unknown_keys(raw, EXAMPLE_KEYS, where, problems)
    if raw.get("label") not in ("pass", "drop"):
        problems.append(f"{where}: label must be pass or drop")
    note = raw.get("note")
    if note is not None and not isinstance(note, str):
        problems.append(f"{where}: note must be a string")
    item = engine_item({k: v for k, v in raw.items() if k in ITEM_KEYS}, where, problems)
    return None if item is None else {"label": raw.get("label"), "note": note, "item": item}


def _pairs(raw, wid: str, shared: dict, used: set, problems: list[str]) -> list[Pair]:
    if not isinstance(raw, list) or not raw:
        problems.append(f"watcher {wid}: items must be a non-empty list")
        return []
    pairs = [p for p in (_pair(r, wid, shared, used, problems) for r in raw) if p is not None]
    ids = Counter(p.id for p in pairs)
    problems.extend(f"pair {pid}: id used twice" for pid, n in ids.items() if n > 1)
    labels = {p.label for p in pairs}
    problems.extend(f"watcher {wid}: has no {label} item" for label in KINDS if label not in labels)
    return pairs


def _pair(raw, wid: str, shared: dict, used: set, problems: list[str]) -> Pair | None:
    if not isinstance(raw, dict) or not isinstance(raw.get("id"), str) or not ID_RE.match(raw["id"]):
        problems.append(f"watcher {wid}: every item needs a lower_snake_case id")
        return None
    where = f"pair {wid}/{raw['id']}"
    _unknown_keys(raw, PAIR_KEYS, where, problems)
    label, kind = raw.get("label"), raw.get("kind")
    if label not in KINDS:
        problems.append(f"{where}: label must be {THROUGH} or {IRRELEVANT}")
    elif kind not in KINDS[label]:
        problems.append(f"{where}: kind of a {label} item must be one of {', '.join(KINDS[label])}")
    if not isinstance(raw.get("why"), str) or not raw["why"].strip():
        problems.append(f"{where}: why must say why the label holds")
    if not isinstance(raw.get("incident", False), bool):
        problems.append(f"{where}: incident must be true or false")
    item = _pair_item(raw, where, shared, used, problems)
    if item is None:
        return None
    return Pair(id=f"{wid}/{raw['id']}", watcher=wid, item=item, label=label, kind=kind,
                incident=raw.get("incident", False) is True)


def _pair_item(raw: dict, where: str, shared: dict, used: set, problems: list[str]):
    if "ref" not in raw:
        return engine_item({k: v for k, v in raw.items() if k in ITEM_KEYS}, where, problems)
    if any(k in raw for k in ITEM_KEYS):
        problems.append(f"{where}: a ref item takes no source, at, x, feed or raw of its own")
        return None
    if raw["ref"] not in shared:
        problems.append(f"{where}: ref {raw['ref']!r} names no shared item")
        return None
    used.add(raw["ref"])
    return shared[raw["ref"]]


def _unknown_keys(raw: dict, allowed: set, where: str, problems: list[str]) -> None:
    unknown = sorted(set(raw) - allowed)
    if unknown:
        problems.append(f"{where}: unknown key(s) {', '.join(unknown)}")


# --- one item as the engine takes it ----------------------------------------------

def engine_item(spec, where: str, problems: list[str]) -> dict | None:
    """The fields `Cues.Item.new/2` takes for one item, plus its source and its two
    times: `at` is when it happened, and it is received five seconds later."""
    if not isinstance(spec, dict):
        problems.append(f"{where}: must be a mapping")
        return None
    shapes = [k for k in ITEM_SHAPES if k in spec]
    if len(shapes) != 1:
        problems.append(f"{where}: give exactly one of x, feed or raw")
        return None
    at = _absolute_time(spec.get("at"), where, problems)
    source = spec.get("source")
    if not isinstance(source, str) or not source:
        problems.append(f"{where}: source must name the cue source")
    builder = {"x": _x_fields, "feed": _feed_fields, "raw": _raw_fields}[shapes[0]]
    fields = builder(spec[shapes[0]], at, where, problems)
    if fields is None or at is None or not source:
        return None
    return {**fields, "source_ref": source, "occurred_at": _iso(at),
            "received_at": _iso(at + RECEIVED_LAG)}


def _absolute_time(raw, where: str, problems: list[str]) -> datetime | None:
    try:
        at = datetime.fromisoformat(raw) if isinstance(raw, str) else None
    except ValueError:
        at = None
    if at is None or at.tzinfo is None:
        problems.append(f"{where}: at must be an absolute ISO 8601 time with its offset")
        return None
    return at.astimezone(timezone.utc)


def _iso(at: datetime) -> str:
    return at.strftime("%Y-%m-%dT%H:%M:%SZ")


def _numeric_id(*parts: str) -> str:
    digest = hashlib.sha256("\x1f".join(parts).encode()).hexdigest()
    return str(int(digest[:15], 16))


def _x_fields(raw, at, where: str, problems: list[str]) -> dict | None:
    """An X post as `Cues.XAccounts` reads it: the post with its author and url."""
    if not isinstance(raw, dict) or not all(isinstance(raw.get(k), str) and raw[k]
                                            for k in ("username", "name", "text")):
        problems.append(f"{where}: x needs username, name and text")
        return None
    if not X_HANDLE.match(raw["username"]):
        problems.append(f"{where}: {raw['username']!r} is not an X username")
        return None
    if at is None:
        return None
    author_id = _numeric_id("author", raw["username"])
    post_id = _numeric_id("post", raw["username"], raw["text"], _iso(at))
    data = {"id": post_id, "text": raw["text"],
            "created_at": at.strftime("%Y-%m-%dT%H:%M:%S.000Z"), "author_id": author_id,
            "edit_history_tweet_ids": [post_id],
            "author": {"id": author_id, "username": raw["username"], "name": raw["name"]},
            "url": f"https://x.com/{raw['username']}/status/{post_id}"}
    return {"item_id": post_id, "type": "x.post", "subject": author_id, "data": data,
            "title": None}


def _feed_fields(raw, _at, where: str, problems: list[str]) -> dict | None:
    """A feed entry as `Cues.FeedParser` reads it."""
    if not isinstance(raw, dict) or not all(isinstance(raw.get(k), str) and raw[k]
                                            for k in ("title", "link")):
        problems.append(f"{where}: feed needs title and link")
        return None
    data = {"title": raw["title"], "link": raw["link"], "summary": raw.get("summary"),
            "author": raw.get("author"), "categories": raw.get("categories") or []}
    return {"item_id": raw["link"], "type": "feed.item", "subject": None, "data": data,
            "title": raw["title"]}


def _raw_fields(raw, _at, where: str, problems: list[str]) -> dict | None:
    """Any other source's item: its type, optional subject and data, as sent."""
    if not isinstance(raw, dict) or not isinstance(raw.get("type"), str) \
            or not isinstance(raw.get("data"), dict):
        problems.append(f"{where}: raw needs type and a data mapping")
        return None
    item_id = "raw-" + hashlib.sha256(json.dumps(raw["data"], sort_keys=True).encode()).hexdigest()[:16]
    return {"item_id": item_id, "type": raw["type"], "subject": raw.get("subject"),
            "data": raw["data"], "title": None}


# --- policy and providers -----------------------------------------------------------

def risk_refusal(screen_set: ScreenSet) -> str | None:
    """Why this runner refuses the set's risk, or None. An absent risk is refused
    loudly here, where the suite runners would silently select nothing."""
    risk = screen_set.risk
    if risk == UNCLASSIFIED_RISK:
        return "the set declares no risk; every eval must (AGENTS.md)"
    if risk not in RISK_LEVELS:
        return f"the set's risk {risk!r} is not one of {', '.join(RISK_LEVELS)}"
    if risk in REFUSED_RISKS:
        return f"the screen runner refuses the high-impact risk {risk}, as the capability runner does"
    if risk != RUN_RISK:
        return f"the screen runner measures only {RUN_RISK} sets; this one is {risk}"
    return None


def plan_providers(selected: list[str] | None, environ) -> list[Provider]:
    """The providers this run asks, in catalog order: each available when its key's
    variable is set and non-blank. Only presence is read, never the value."""
    names = [name for name in PROVIDERS if not selected or name in selected]
    return [Provider(name=n, env=PROVIDERS[n], available=bool(environ.get(PROVIDERS[n], "").strip()))
            for n in names]


# --- the engine helper ----------------------------------------------------------------

def engine_plan(screen_set: ScreenSet, providers: list[str], run_id: str) -> dict:
    watchers = {w.id: {"name": w.name, "purpose": w.purpose, "listen_for": list(w.listen_for),
                       "instructions": list(w.instructions), "examples": list(w.examples)}
                for w in screen_set.watchers.values()}
    pairs = [{"pair": p.id, "watcher": p.watcher, "item": p.item} for p in screen_set.pairs]
    return {"run_id": run_id, "providers": providers, "watchers": watchers, "pairs": pairs}


def engine_env(environ, home: str, providers: list[str]) -> dict:
    """The helper's environment: this shell's, a temporary FERMIX_HOME, MIX_ENV dev, and
    only the keys of the providers it asks."""
    wanted = {PROVIDERS[p] for p in providers}
    env = {k: v for k, v in environ.items() if k not in PROVIDERS.values() or k in wanted}
    env["FERMIX_HOME"] = home
    env["MIX_ENV"] = "dev"
    return env


def _guard_home(home: str) -> None:
    real = os.path.realpath(home)
    user_home = os.path.realpath(os.path.expanduser("~"))
    if real == user_home or re.match(re.escape(user_home) + r"/\.fermix", real):
        raise EngineError(f"refusing to run the engine in {real}: not a temporary home")


def run_engine(mode: str, plan: dict, environ, timeout_s: int) -> list[dict]:
    """Runs bin/screen_eval.exs in a fresh temporary home and returns its JSON lines.
    The home is removed on every path."""
    home = tempfile.mkdtemp(prefix="fermix-screen-eval-")
    try:
        _guard_home(home)
        plan_path = os.path.join(home, "plan.json")
        out_path = os.path.join(home, "engine.jsonl")
        with open(plan_path, "w", encoding="utf-8") as fh:
            json.dump(plan, fh)
        argv = ["mix", "run", "--no-start", ENGINE_SCRIPT, mode, plan_path, out_path]
        try:
            proc = subprocess.run(argv, cwd=REPO_ROOT, env=engine_env(environ, home, plan["providers"]),
                                  stdout=sys.stderr, timeout=timeout_s, check=False)
        except subprocess.TimeoutExpired as exc:
            raise EngineError(f"the engine helper outlived its {timeout_s} s bound") from exc
        if proc.returncode != 0:
            raise EngineError(f"the engine helper exited {proc.returncode}; its output is above")
        return read_jsonl(out_path)
    finally:
        safe_rm.rm_rf(home, tempfile.gettempdir())


def read_jsonl(path: str) -> list[dict]:
    with open(path, encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def write_jsonl(path: str, records: list[dict]) -> None:
    with open(path, "w", encoding="utf-8") as fh:
        for record in records:
            fh.write(json.dumps(record, ensure_ascii=False) + "\n")


def redact(text: str, environ) -> str:
    """`text` with every provider key this shell holds, and anything shaped like one,
    replaced: a provider's error message can quote part of a key."""
    for var in PROVIDERS.values():
        value = environ.get(var, "").strip()
        if value:
            text = text.replace(value, "<redacted>")
    return KEY_SHAPE.sub("<redacted>", text)


def redact_record(record: dict, environ) -> dict:
    for key in ("error", "aborted"):
        if isinstance(record.get(key), dict) and isinstance(record[key].get("message"), str):
            record = {**record, key: {**record[key], "message": redact(record[key]["message"], environ)}}
    return record


# --- scoring (pure) ---------------------------------------------------------------------

@dataclass(frozen=True)
class Status:
    provider: str
    state: str           # measured | skipped | invalid
    reason: str
    models: tuple
    unscored: int


def provider_statuses(records: list[dict], expected_per_provider: int) -> dict[str, Status]:
    """Each provider's standing in a run, in catalog order: skipped (no key), invalid
    (it stopped, or answered fewer requests than the plan holds) or measured."""
    statuses = {}
    for name in PROVIDERS:
        mine = [r for r in records if r.get("provider") == name]
        if mine:
            statuses[name] = _status(name, mine, expected_per_provider)
    return statuses


def _status(name: str, mine: list[dict], expected: int) -> Status:
    skipped = [r["skipped"] for r in mine if "skipped" in r]
    if skipped:
        return Status(name, "skipped", skipped[0], (), 0)
    answers = [r for r in mine if "probability" in r or "error" in r]
    models = tuple(sorted({r["model"] for r in answers if r.get("model")}))
    unscored = sum(1 for r in answers if "error" in r)
    aborted = [r["aborted"] for r in mine if "aborted" in r]
    if aborted:
        reason = f"stopped after {len(answers)} of {expected} requests: " \
                 f"{aborted[0].get('kind')}: {aborted[0].get('message')}"
        return Status(name, "invalid", reason, models, unscored)
    if len(answers) != expected:
        return Status(name, "invalid", f"answered {len(answers)} of {expected} requests", models,
                      unscored)
    return Status(name, "measured", "", models, unscored)


def probabilities(records: list[dict]) -> dict[tuple[str, str], dict[str, float]]:
    """(provider, form) -> pair id -> probability, from the answered requests."""
    table: dict[tuple[str, str], dict[str, float]] = {}
    for r in records:
        if "probability" in r:
            table.setdefault((r["provider"], r["form"]), {})[r["pair"]] = float(r["probability"])
    return table


def rate(pairs, probs: dict[str, float], bar: float, label: str,
         kind: str | None = None) -> tuple[int, int]:
    """(hits, scored) over the pairs of `label` (and `kind`) that have a probability: a
    hit is a `should_screen_through` pair kept (p >= bar) or an `irrelevant` one dropped."""
    chosen = [p for p in pairs if p.label == label and (kind is None or p.kind == kind)
              and p.id in probs]
    if label == THROUGH:
        hits = sum(1 for p in chosen if probs[p.id] >= bar)
    else:
        hits = sum(1 for p in chosen if probs[p.id] < bar)
    return hits, len(chosen)


def discordant(pairs, probs_a: dict, probs_b: dict, bar: float, label: str) -> tuple[int, int]:
    """(only A, only B): pairs of `label` scored in both forms that one form gets right
    and the other does not, at `bar`."""
    def right(p, probs):
        return probs[p.id] >= bar if label == THROUGH else probs[p.id] < bar
    both = [p for p in pairs if p.label == label and p.id in probs_a and p.id in probs_b]
    only_a = sum(1 for p in both if right(p, probs_a) and not right(p, probs_b))
    only_b = sum(1 for p in both if right(p, probs_b) and not right(p, probs_a))
    return only_a, only_b


def mcnemar_p(only_a: int, only_b: int) -> float:
    """The exact two-sided McNemar p for a paired split of discordant pairs."""
    n = only_a + only_b
    if n == 0:
        return 1.0
    tail = sum(math.comb(n, i) for i in range(min(only_a, only_b) + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def score(screen_set: ScreenSet, records: list[dict]) -> dict:
    """Everything the report prints, as data (results.json holds it)."""
    expected = len(screen_set.pairs) * len(FORMS)
    statuses = provider_statuses(records, expected)
    probs = probabilities(records)
    measured = [n for n, s in statuses.items() if s.state == "measured"]
    pairs = screen_set.pairs
    return {
        "statuses": statuses,
        "rates": [_rate_row(pairs, probs.get((n, f), {}), n, f, bar)
                  for n in measured for f in FORMS for bar in BARS],
        "kinds": [_kind_row(pairs, probs.get((n, f), {}), n, f, label, kind)
                  for n in measured for f in FORMS
                  for label in KINDS for kind in KINDS[label]],
        "paired": [_paired_row(pairs, probs.get((n, "A"), {}), probs.get((n, "B"), {}), n, bar)
                   for n in measured for bar in BARS],
        "incident": [{"provider": n, "form": f,
                      "p": {p.id: probs.get((n, f), {}).get(p.id) for p in pairs if p.incident}}
                     for n in measured for f in FORMS],
        "probabilities": {f"{n}/{f}": probs.get((n, f), {}) for n in measured for f in FORMS},
        "tokens": _tokens(records, measured),
    }


def _rate_row(pairs, probs, provider, form, bar) -> dict:
    kept, through = rate(pairs, probs, bar, THROUGH)
    dropped, irrelevant = rate(pairs, probs, bar, IRRELEVANT)
    unscored = sum(1 for p in pairs if p.id not in probs)
    return {"provider": provider, "form": form, "bar": bar, "kept": kept, "through": through,
            "dropped": dropped, "irrelevant": irrelevant, "unscored": unscored}


def _kind_row(pairs, probs, provider, form, label, kind) -> dict:
    cells = [rate(pairs, probs, bar, label, kind) for bar in BARS]
    return {"provider": provider, "form": form, "label": label, "kind": kind,
            "n": cells[0][1], "hits": [hits for hits, _n in cells]}


def _paired_row(pairs, probs_a, probs_b, provider, bar) -> dict:
    t_a, t_b = discordant(pairs, probs_a, probs_b, bar, THROUGH)
    i_a, i_b = discordant(pairs, probs_a, probs_b, bar, IRRELEVANT)
    return {"provider": provider, "bar": bar, "kept_only_a": t_a, "kept_only_b": t_b,
            "kept_p": mcnemar_p(t_a, t_b), "dropped_only_a": i_a, "dropped_only_b": i_b,
            "dropped_p": mcnemar_p(i_a, i_b)}


def _tokens(records, measured) -> dict:
    totals: dict[str, dict[str, int]] = {}
    for r in records:
        if r.get("provider") in measured and isinstance(r.get("tokens"), dict):
            slot = totals.setdefault(f"{r['provider']}/{r['form']}", {})
            for key, value in r["tokens"].items():
                slot[key] = slot.get(key, 0) + int(value)
    return totals


# --- rendering ------------------------------------------------------------------------

def _pct(hits: int, n: int) -> str:
    return f"{hits}/{n} {100 * hits / n:5.1f}%" if n else "-"


def render(screen_set: ScreenSet, result: dict) -> str:
    lines = [_set_line(screen_set), "", "providers"]
    for status in result["statuses"].values():
        lines.append(_status_line(status))
    if not result["rates"]:
        return "\n".join(lines + ["", "no provider was measured: no rates to show"])
    lines += ["", "recall on should_screen_through, and irrelevant dropped, at each bar "
              "(an item goes through at p >= bar)",
              f"{'provider':<11} {'form':<4} {'bar':<4} {'recall':<16} {'irrelevant dropped':<18} unscored"]
    lines += [f"{r['provider']:<11} {r['form']:<4} {r['bar']:<4} {_pct(r['kept'], r['through']):<16} "
              f"{_pct(r['dropped'], r['irrelevant']):<18} {r['unscored']}" for r in result["rates"]]
    lines += ["", "by kind: the share kept (should_screen_through kinds) or dropped (irrelevant kinds)",
              f"{'provider':<11} {'form':<4} {'kind':<22} {'n':>3}  " + "  ".join(f"{b:>6}" for b in BARS)]
    lines += [f"{r['provider']:<11} {r['form']:<4} {r['kind']:<22} {r['n']:>3}  "
              + "  ".join(f"{(100 * h / r['n'] if r['n'] else 0):>5.0f}%" for h in r["hits"])
              for r in result["kinds"]]
    lines += ["", "A against B, pairs only one form gets right (exact McNemar p)",
              f"{'provider':<11} {'bar':<4} {'kept: only A':>12} {'only B':>7} {'p':>6}   "
              f"{'dropped: only A':>15} {'only B':>7} {'p':>6}"]
    lines += [f"{r['provider']:<11} {r['bar']:<4} {r['kept_only_a']:>12} {r['kept_only_b']:>7} "
              f"{r['kept_p']:>6.3f}   {r['dropped_only_a']:>15} {r['dropped_only_b']:>7} "
              f"{r['dropped_p']:>6.3f}" for r in result["paired"]]
    lines += _incident_lines(result["incident"])
    lines += _token_lines(result["tokens"])
    return "\n".join(lines)


def _set_line(screen_set: ScreenSet) -> str:
    by_label = Counter(p.label for p in screen_set.pairs)
    return (f"set {screen_set.name}: {len(screen_set.watchers)} watchers, {len(screen_set.pairs)} "
            f"pairs ({by_label[THROUGH]} {THROUGH}, {by_label[IRRELEVANT]} {IRRELEVANT}), "
            f"risk {screen_set.risk}")


def _status_line(status: Status) -> str:
    if status.state == "skipped":
        return f"  {status.provider:<11} SKIPPED   {status.reason}"
    models = ", ".join(status.models) or "no answer"
    detail = f"answered by {models}; unscored {status.unscored}"
    if status.state == "invalid":
        return f"  {status.provider:<11} INVALID   {status.reason} ({detail})"
    return f"  {status.provider:<11} measured  {detail}"


def _incident_lines(rows: list[dict]) -> list[str]:
    ids = sorted({pid for r in rows for pid in r["p"]})
    if not ids:
        return []
    lines = ["", "the incident item, on each watcher that holds it",
             f"{'provider':<11} {'form':<4} " + "  ".join(f"{pid:<28}" for pid in ids)]
    for r in rows:
        cells = [("-" if r["p"].get(pid) is None else f"{r['p'][pid]:.2f}") for pid in ids]
        lines.append(f"{r['provider']:<11} {r['form']:<4} " + "  ".join(f"{c:<28}" for c in cells))
    return lines


def _token_lines(tokens: dict) -> list[str]:
    if not tokens:
        return []
    lines = ["", "tokens the providers reported (the rate card does not price decision models)"]
    lines += [f"  {key:<16} " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items()))
              for key, counts in sorted(tokens.items())]
    return lines


def render_matrix(screen_set: ScreenSet, result: dict) -> str:
    """Every pair's probability under every measured provider and form (report.md)."""
    columns = list(result["probabilities"])
    header = "| pair | label | kind | " + " | ".join(columns) + " |"
    rows = [header, "|" + "---|" * (3 + len(columns))]
    for p in screen_set.pairs:
        cells = [result["probabilities"][c].get(p.id) for c in columns]
        rows.append(f"| {p.id} | {p.label} | {p.kind} | "
                    + " | ".join("-" if v is None else f"{v:.2f}" for v in cells) + " |")
    return "\n".join(rows)


# --- the three modes ------------------------------------------------------------------

def _exit_code(statuses: dict[str, Status]) -> int:
    if not statuses or all(s.state == "skipped" for s in statuses.values()):
        return 3
    if any(s.state == "invalid" for s in statuses.values()):
        return 4
    return 0


def report(screen_set: ScreenSet, records: list[dict], run_dir: str) -> int:
    result = score(screen_set, records)
    text = render(screen_set, result)
    print(text)
    os.makedirs(run_dir, exist_ok=True)
    serial = {**result, "statuses": {n: asdict(s) for n, s in result["statuses"].items()}}
    with open(os.path.join(run_dir, "results.json"), "w", encoding="utf-8") as fh:
        json.dump(serial, fh, indent=2)
    with open(os.path.join(run_dir, "report.md"), "w", encoding="utf-8") as fh:
        fh.write("```\n" + text + "\n```\n\n" + render_matrix(screen_set, result) + "\n")
    code = _exit_code(result["statuses"])
    if code == 3:
        print("\nevery provider was skipped: nothing was measured")
    print(f"\nwritten to {run_dir}")
    return code


def dry_run(screen_set: ScreenSet, providers: list[Provider], run_dir: str, environ) -> int:
    plan = engine_plan(screen_set, [], "dry")
    try:
        rendered = run_engine("render", plan, environ, BOOT_BOUND_S)
    except EngineError as exc:
        print(f"screen eval: {exc}", file=sys.stderr)
        return 3
    problem = _render_problem(screen_set, rendered)
    if problem:
        print(f"screen eval: {problem}", file=sys.stderr)
        return 3
    os.makedirs(run_dir, exist_ok=True)
    write_jsonl(os.path.join(run_dir, "requests.jsonl"), rendered)
    print("\n".join(_plan_lines(screen_set, providers, rendered, run_dir)))
    return 0


def _render_problem(screen_set: ScreenSet, rendered: list[dict]) -> str | None:
    got = {(r["pair"], r["form"]) for r in rendered}
    want = {(p.id, f) for p in screen_set.pairs for f in FORMS}
    if got != want:
        return f"the engine rendered {len(got)} requests; the plan holds {len(want)}"
    return None


def _plan_lines(screen_set, providers, rendered, run_dir) -> list[str]:
    kinds = Counter((p.label, p.kind) for p in screen_set.pairs)
    calls = len(screen_set.pairs) * len(FORMS)
    tokens = {f: _mean_tokens([r for r in rendered if r["form"] == f]) for f in FORMS}
    per_provider = sum(tokens[f] * len(screen_set.pairs) for f in FORMS)
    lines = [_set_line(screen_set) + ": valid"]
    lines += [f"  {label}: " + ", ".join(f"{k} {kinds[(label, k)]}" for k in KINDS[label])
              for label in KINDS]
    lines += [f"engine: rendered {len(rendered)} requests through Cues.Filter.Decision.request/1 "
              f"({len(screen_set.pairs)} pairs x forms {', '.join(FORMS)})",
              "  input per request, about: " + ", ".join(f"form {f} {tokens[f]} tokens" for f in FORMS),
              "providers:"]
    for p in providers:
        state = f"would ask {calls} requests ({p.env} is set)" if p.available \
            else f"SKIPPED: {p.env} not in the environment"
        lines.append(f"  {p.name:<11} {state}")
    available = [p for p in providers if p.available]
    lines += [f"plan: {calls * len(available)} decision requests, about "
              f"{per_provider * len(available)} input tokens in all; the rate card does not "
              "price decision models",
              f"requests written to {os.path.join(run_dir, 'requests.jsonl')}"]
    if not available:
        lines.append("a live run in this shell would exit 3: every provider would be skipped")
    return lines


def _mean_tokens(rendered: list[dict]) -> int:
    chars = [len(r["item"]) + len(r["instructions"]) + len(r["yes"]) + len(r["no"]) for r in rendered]
    return round(sum(chars) / len(chars) / CHARS_PER_TOKEN) if chars else 0


def live(screen_set: ScreenSet, providers: list[Provider], run_dir: str, environ) -> int:
    skipped = [{"provider": p.name, "skipped": f"{p.env} not in the environment"}
               for p in providers if not p.available]
    available = [p.name for p in providers if p.available]
    if not available:
        os.makedirs(run_dir, exist_ok=True)
        write_jsonl(os.path.join(run_dir, "calls.jsonl"), skipped)
        return report(screen_set, skipped, run_dir)
    calls = len(screen_set.pairs) * len(FORMS)
    print(f"asking {calls} decision requests on each of {', '.join(available)}", file=sys.stderr)
    plan = engine_plan(screen_set, available, os.path.basename(run_dir))
    try:
        answered = run_engine("call", plan, environ, BOOT_BOUND_S + calls * CALL_BOUND_S)
    except EngineError as exc:
        print(f"screen eval: {exc}", file=sys.stderr)
        return 3
    records = [redact_record(r, environ) for r in answered] + skipped
    os.makedirs(run_dir, exist_ok=True)
    write_jsonl(os.path.join(run_dir, "calls.jsonl"), records)
    return report(screen_set, records, run_dir)


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--set", default=SET_PATH, help="the labelled set (default: the shipped one)")
    parser.add_argument("--provider", action="append", choices=list(PROVIDERS),
                        help="ask only this provider (repeatable; default: every one with a key)")
    parser.add_argument("--dry-run", action="store_true",
                        help="validate the set, render every request through the engine, plan "
                             "the calls; spends nothing")
    parser.add_argument("--from-calls", metavar="CALLS_JSONL",
                        help="score a finished run's calls.jsonl again; asks nothing")
    parser.add_argument("--out", default=REPORTS_DIR, help="where run directories go")
    args = parser.parse_args(argv)
    if args.dry_run and args.from_calls:
        parser.error("--dry-run and --from-calls do not combine")
    return args


def main(argv=None, environ=None) -> int:
    environ = os.environ if environ is None else environ
    args = parse_args(argv)
    try:
        screen_set = load_set(args.set)
    except SetError as exc:
        print("screen eval: the set is refused:\n  " + "\n  ".join(exc.problems), file=sys.stderr)
        return 2
    refusal = risk_refusal(screen_set)
    if refusal:
        print(f"screen eval: {refusal}", file=sys.stderr)
        return 2
    run_dir = os.path.join(args.out, datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    if args.from_calls:
        return report(screen_set, read_jsonl(args.from_calls), run_dir)
    providers = plan_providers(args.provider, environ)
    if args.dry_run:
        return dry_run(screen_set, providers, run_dir, environ)
    return live(screen_set, providers, run_dir, environ)


if __name__ == "__main__":
    sys.exit(main())
