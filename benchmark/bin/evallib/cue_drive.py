"""`drive: cue` — the capability runner as a program pushing cues (M60 §16).

A cue case has no user turn. The runner posts the case's CloudEvents to the eval
daemon's door (`POST http://127.0.0.1:<door_port>/cues/v1/<source>`, the source's
bearer token), then reads what became of them from the eval home's memory.db,
opened read-only: the cue rows, their deliveries, the filter calls, the task runs
and the mandate calls. It waits until every delivery is terminal and every run has
settled, bounded by the case's `timeout_ms`; what is still moving then is reported
as incomplete, never graded.

The door port and the tokens come from `eval-fixtures/cues.json`
(seed_capability_home.py), the watchers from `eval-fixtures/cue_watchers.json`
(seed_cues.exs). Every event carries a per-trial id and, unless the case names
one, a per-trial subject, so a trial never waits behind another trial's item
(a delivery waits for older live deliveries of its subject).
"""

from __future__ import annotations

import copy
import hashlib
import json
import os
import sqlite3
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field

MANIFEST = os.path.join("eval-fixtures", "cues.json")
WATCHERS = os.path.join("eval-fixtures", "cue_watchers.json")
TERMINAL_STATES = ("acked", "dropped", "exhausted", "expired")
RUN_DONE = ("ok", "error", "timeout")
EVENT_SOURCE = "fermix.eval"
CONTENT_TYPE = "application/cloudevents+json"
MAX_POSTS = 10
MAX_REPEAT = 10
POST_TIMEOUT_S = 10.0
POLL_S = 2.0
# A case's `cue:` map and each post's keys (validated by evallib.suites).
SPEC_KEYS = {"source", "posts"}
POST_KEYS = {"type", "subject", "data", "repeat", "after"}
AFTER_VALUES = ("settled",)
PLACEHOLDERS = ("{token}", "{trial}", "{n}", "{ws}")


UNSEEDED = ("the eval home was not seeded with --cues (FERMIX_CAP_SEED_ARGS=--cues "
            "capability-daemon.sh up runs seed_capability_home.py --cues and seed_cues.exs)")


class CueDriveError(Exception):
    """The harness could not drive the case (no manifest, door unreachable, an event
    the door refused). An evaluator failure: the trial is invalid, never a zero."""


@dataclass
class Episode:
    """What one cue trial posted and what became of it."""
    source: str
    posts: list[dict]
    rows: dict = field(default_factory=dict)
    complete: bool = False
    detail: str = ""


# --- the case's spec ----------------------------------------------------------------

def spec_problems(spec, where: str) -> list[str]:
    """Why a case's `cue:` map cannot be driven, as load-time problems."""
    if not isinstance(spec, dict):
        return [f"{where}: `cue` must be a map with `source` and `posts`"]
    problems = [f"{where}: unknown cue key `{key}` (allowed: {sorted(SPEC_KEYS)})"
                for key in spec if key not in SPEC_KEYS]
    source = spec.get("source")
    if not isinstance(source, str) or not source:
        problems.append(f"{where}: `cue.source` must name a local_push source of the eval home")
    posts = spec.get("posts")
    if not isinstance(posts, list) or not posts:
        return problems + [f"{where}: `cue.posts` must be a non-empty list"]
    for index, post in enumerate(posts):
        problems += _post_problems(post, index, f"{where}.posts[{index}]")
    if not problems and expanded_count(spec) > MAX_POSTS:
        problems.append(f"{where}: at most {MAX_POSTS} events per case, repeats included")
    return problems


def _post_problems(post, index: int, where: str) -> list[str]:
    if not isinstance(post, dict):
        return [f"{where}: must be a map"]
    problems = [f"{where}: unknown key `{key}` (allowed: {sorted(POST_KEYS)})"
                for key in post if key not in POST_KEYS]
    if not isinstance(post.get("type"), str) or not post["type"]:
        problems.append(f"{where}: `type` must be a non-empty string")
    subject = post.get("subject")
    if subject is not None and (not isinstance(subject, str) or "{trial}" not in subject):
        # A fixed subject would make this trial wait behind an earlier trial's
        # item still live under it.
        problems.append(f"{where}: a `subject` must carry {{trial}}, so trials never share one")
    if "data" in post and not isinstance(post["data"], (dict, str)):
        problems.append(f"{where}: `data` must be a map or a string")
    repeat = post.get("repeat", 1)
    if isinstance(repeat, bool) or not isinstance(repeat, int) or not 1 <= repeat <= MAX_REPEAT:
        problems.append(f"{where}: `repeat` must be 1 to {MAX_REPEAT}")
    after = post.get("after")
    if after is not None and (after not in AFTER_VALUES or index == 0):
        problems.append(f"{where}: `after` may only be `settled`, and not on the first post")
    return problems


def expanded_count(spec: dict) -> int:
    return sum(post.get("repeat", 1) for post in spec["posts"])


def turn_texts(spec: dict) -> list[str]:
    """One line per declared post, the case's turns: what reports, `--estimate` and
    the task hash read (a change to a post changes the task)."""
    return [json.dumps({"source": spec["source"], **post}, sort_keys=True)
            for post in spec["posts"]]


# --- the home ----------------------------------------------------------------------

def load_manifest(home: str) -> dict:
    """The door port, the source tokens and the seeded watchers, or a refusal that
    names the seeding step that did not run."""
    try:
        with open(os.path.join(home, MANIFEST), encoding="utf-8") as fh:
            manifest = json.load(fh)
        with open(os.path.join(home, WATCHERS), encoding="utf-8") as fh:
            watchers = json.load(fh)
    except (OSError, ValueError) as exc:
        raise CueDriveError(UNSEEDED) from exc
    return {**manifest, "watchers": watchers.get("watchers", {}),
            "mandates": watchers.get("mandates", {})}


def home_problem(home: str) -> str | None:
    """Why this eval home cannot run a suite that `requires: [cues]`, or None."""
    try:
        load_manifest(home)
    except CueDriveError as exc:
        return str(exc)
    return None


def missing_source(manifest: dict, source: str) -> str | None:
    """Why a case on `source` cannot run in this home, or None. A source seeded
    without its watcher (the mandate sources without --cue-mandates) is missing."""
    if source not in manifest.get("sources", {}):
        return f"the eval home has no cue source {source} (seed_capability_home.py --cue-mandates?)"
    if not any(w.get("source") == source for w in manifest.get("watchers", {}).values()):
        return f"no watcher listens to {source} in the eval home (seed_cues.exs)"
    return None


# --- events ------------------------------------------------------------------------

def item_id(source: str, event_id: str) -> str:
    """The cue's identity the daemon derives from a CloudEvent: `ce_` and the SHA-256 of
    the canonical JSON pair `[source, id]` (Cues.CloudEvents). The harness's own ids
    are ASCII, where Python's compact JSON is the canonical form."""
    canonical = json.dumps([source, event_id], separators=(",", ":"), ensure_ascii=False)
    return "ce_" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def render(value, values: dict):
    """`value` with every placeholder replaced, at any depth."""
    if isinstance(value, str):
        for key, replacement in values.items():
            value = value.replace(key, replacement)
        return value
    if isinstance(value, list):
        return [render(item, values) for item in value]
    if isinstance(value, dict):
        return {key: render(item, values) for key, item in value.items()}
    return value


def events(spec: dict, token: str, trial: str, ws: str) -> list[dict]:
    """The CloudEvents of one trial, in posting order, each with the post it came from."""
    out = []
    for post in spec["posts"]:
        for _copy in range(post.get("repeat", 1)):
            n = len(out)
            values = {"{token}": token, "{trial}": trial, "{n}": str(n), "{ws}": ws}
            event = {"specversion": "1.0", "id": f"{trial}-{n}", "source": EVENT_SOURCE,
                     "type": post["type"],
                     "subject": render(post.get("subject") or "{trial}-{n}", values)}
            if "data" in post:
                event["data"] = render(copy.deepcopy(post["data"]), values)
            out.append({"index": n, "after": post.get("after"), "event": event,
                        "item_id": item_id(EVENT_SOURCE, event["id"])})
    return out


def http_post(port: int, source: str, token: str, event: dict) -> tuple[int, dict]:
    """One local-push request. A door that does not answer is a CueDriveError."""
    request = urllib.request.Request(
        f"http://127.0.0.1:{port}/cues/v1/{source}", method="POST",
        data=json.dumps(event).encode("utf-8"),
        headers={"Content-Type": CONTENT_TYPE, "Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=POST_TIMEOUT_S) as response:
            return response.status, json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as exc:
        body = exc.read()
        try:
            return exc.code, json.loads(body or b"{}")
        except ValueError:
            return exc.code, {"error": body[:200].decode("utf-8", "replace")}
    except (urllib.error.URLError, OSError) as exc:
        raise CueDriveError(f"the door on 127.0.0.1:{port} did not answer: {exc}") from exc


def accepted(status: int, body: dict) -> str | None:
    """None when the door accepted the one event, else what it said."""
    results = body.get("results") if isinstance(body, dict) else None
    if status == 200 and isinstance(results, list) and len(results) == 1:
        item = results[0]
        if item.get("status") == "accepted":
            return None
        return f"{item.get('status')}: {item.get('reason', '')}".strip(": ")
    return f"HTTP {status}: {(body or {}).get('error', body)}"


# --- driving -----------------------------------------------------------------------

def drive(home: str, spec: dict, token: str, trial: str, ws: str, timeout_s: float,
          post=http_post, clock=time.monotonic, sleep=time.sleep,
          poll_s: float = POLL_S) -> Episode:
    """Post the trial's events in order (waiting for the earlier ones to settle first
    where a post says `after: settled`), then wait for everything to settle."""
    manifest = load_manifest(home)
    source = spec["source"]
    problem = missing_source(manifest, source)
    if problem:
        raise CueDriveError(problem)
    port, secret = manifest["door_port"], manifest["sources"][source]["token"]
    db = os.path.join(home, "memory.db")
    deadline = clock() + timeout_s
    planned = events(spec, token, trial, ws)
    episode = Episode(source=source, posts=[])
    for entry in planned:
        if entry["after"] == "settled" and not _wait(db, episode, deadline, clock, sleep, poll_s):
            return _incomplete(db, episode, "an earlier post had not settled before the next")
        refusal = accepted(*post(port, source, secret, entry["event"]))
        if refusal:
            raise CueDriveError(f"the door did not accept event {entry['index']}: {refusal}")
        episode.posts.append({k: entry[k] for k in ("index", "item_id")}
                             | {"event_id": entry["event"]["id"],
                                "subject": entry["event"]["subject"]})
    if not _wait(db, episode, deadline, clock, sleep, poll_s):
        return _incomplete(db, episode, f"not settled within {timeout_s:.0f} s")
    episode.complete = True
    return episode


def _wait(db: str, episode: Episode, deadline: float, clock, sleep, poll_s: float) -> bool:
    """Poll until every posted item settled, or the deadline. Bounded by the deadline."""
    while True:
        episode.rows = collect(db, episode.source, [p["item_id"] for p in episode.posts])
        if settled(episode):
            return True
        remaining = deadline - clock()
        if remaining <= 0:
            return False
        sleep(min(poll_s, remaining))


def _incomplete(db: str, episode: Episode, detail: str) -> Episode:
    episode.rows = collect(db, episode.source, [p["item_id"] for p in episode.posts])
    episode.detail = f"{detail}: {describe(episode)}"
    return episode


def settled(episode: Episode) -> bool:
    """Every posted item has its cue row, every delivery is terminal, every run done."""
    rows = episode.rows
    if len(rows.get("cues", [])) < len(episode.posts):
        return False
    if any(d["state"] not in TERMINAL_STATES for d in rows.get("deliveries", [])):
        return False
    return all(run["status"] in RUN_DONE for run in rows.get("runs", []))


def describe(episode: Episode) -> str:
    rows = episode.rows
    states = sorted(f"{d['id']}:{d['state']}" for d in rows.get("deliveries", []))
    runs = sorted(f"{r['id']}:{r['status']}" for r in rows.get("runs", []))
    return (f"{len(rows.get('cues', []))}/{len(episode.posts)} cues, deliveries "
            f"{states or 'none'}, runs {runs or 'none'}")


# --- reading the rows --------------------------------------------------------------

_CUES = "SELECT id, item_id, subject, received_at FROM cues WHERE source_ref = ? AND item_id IN ({})"
_DELIVERIES = (
    "SELECT d.id, d.cue_id, d.watcher_id, w.name AS watcher, d.state, d.outcome, "
    "d.decision_reason, d.filter_attempts, d.task_attempts, d.filter_call_id, "
    "d.claimed_run_id, d.received_at, d.settled_at FROM cue_deliveries d "
    "LEFT JOIN cue_watchers w ON w.id = d.watcher_id WHERE d.cue_id IN ({}) ORDER BY d.id")
_FILTER_CALLS = (
    "SELECT id, watcher_id, delivery_id, started_at, finished_at, result, session_id "
    "FROM cue_filter_calls WHERE delivery_id IN ({}) ORDER BY started_at, id")
_RUNS = (
    "SELECT id, job_id, session_id, status, cue_delivery_id, final_response, error, "
    "tools_started_at, created_at, started_at, completed_at FROM job_runs "
    "WHERE trigger = 'cue' AND cue_delivery_id IN ({}) ORDER BY created_at, id")
_MANDATE_CALLS = (
    "SELECT id, run_id, mandate, tool, args_json, decision, reason, validator, "
    "proposal_id, result_status, delivery_id, finished_at FROM cue_mandate_calls "
    "WHERE run_id IN ({}) ORDER BY created_at, id")


def collect(db: str, source: str, item_ids: list[str]) -> dict:
    """Every row the trial's items left, read-only. A missing database (the daemon has
    not made it) reads as nothing yet."""
    empty = {"cues": [], "deliveries": [], "filter_calls": [], "runs": [],
             "mandate_calls": []}
    if not item_ids or not os.path.isfile(db):
        return empty
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=5.0)
    try:
        conn.row_factory = sqlite3.Row
        cues = _select(conn, _CUES, [source], item_ids)
        deliveries = _select(conn, _DELIVERIES, [], [c["id"] for c in cues])
        delivery_ids = [d["id"] for d in deliveries]
        runs = _select(conn, _RUNS, [], delivery_ids)
        return {"cues": cues, "deliveries": deliveries,
                "filter_calls": _select(conn, _FILTER_CALLS, [], delivery_ids),
                "runs": runs,
                "mandate_calls": _select(conn, _MANDATE_CALLS, [], [r["id"] for r in runs])}
    finally:
        conn.close()


def _select(conn, sql: str, head: list, ids: list) -> list[dict]:
    if not ids:
        return []
    marks = ",".join("?" for _ in ids)
    return [dict(row) for row in conn.execute(sql.format(marks), [*head, *ids])]
