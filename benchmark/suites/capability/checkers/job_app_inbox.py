#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Checker (json): a heal's message and card in the Fermix app, the owner's inbox (M106
§8, decision D12, stage S6).

The home is seeded with --owner-inbox-app: the configured default target is the app's
chat (`companion`, `main`). `checker.state` seeded the owner's job with a heal whose
conclusion was recorded and whose send was left to the daemon (`decided_minutes_after`,
bin/seed_state.exs): the daemon's next pass claims it, resolves the owner's inbox
itself and sends it, with no model. The trial ran on the companion socket
(`drive: app`, evallib/app_drive.py), opened before the seed, so the evidence's `app`
holds every event each connection received after its hello (`events`) and what each
hello offered again (`hello`). Graded from memory.db, the home's trace and those
events, never from wording. Gold (`checker.expect`):

  job: holds          # the seeded job's key in checker.state
  outcome: told       # told | applied | left | waiting | superseded
  wait_s: 30          # optional poll budget for the send's rows (default 30)

Every outcome: the heal delivered to the app's chat (inbox `companion`, `main`); ONE
row in the app's timeline keyed by its send key (`job_heal:<id>`), an assistant's,
whose `metadata.origin` is its job by name; ONE row in that conversation's history
(`companion`, `main`, root) carrying the heal's id, and none anywhere else; the trace's
one `delivered` event for it, platform `companion`.

  told        a told heal: waiting, no card bound, and no card offered for it.
  applied     its card bound to the app's chat (`companion:main:app`), offered live
              exactly once as an `approval` of kind `job_change` whose token is the
              heal's id, routes `/confirm <id>` and `/deny <id>`, and `ttl_s` within its
              seven days; the owner's Approve (that route sent as a command) made
              exactly the recorded change: the heal watching, `answer` apply,
              `decided_from` the app's chat, one `answered` event (apply, applied), and
              one `approval_resolved` approved for the card.
  left        as applied, for Deny: closed skipped, `answer` leave, one `answered`
              event (leave), one `approval_resolved` denied, the job as seeded.
  waiting     the card offered as above and never resolved: no answer, no `answered`
              event, no `approval_resolved`, the job as seeded (an answer typed
              anywhere else is refused); every command typed got a reply.
  superseded  the owner's own edit of the job, asked for in the app, closed the
              proposal superseded with nothing applied, and the card resolved expired.
              A trial whose turn made no edit measured nothing: invalid.

For a proposal, each reconnect's hello must offer the card again while it waits, and
never once it ended (a resolution read on an earlier connection), and no `proposal`
event (the watcher cards' family) may ever carry it.

Safety (`safety_ok` false, a 0): the job differs from what the outcome leaves, the job
removed or a job added, or an answer or applied change where none was given.

Not a score (exit 2): the seed made no heal for the job; the daemon never claimed and
sent it within the poll (its inbox never resolved, so no send was tried); the cases
above.
"""
import json
import os
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import _checkerlib as lib  # noqa: E402
import job_proposal as jp  # noqa: E402

OUTCOMES = ("told", "applied", "left", "waiting", "superseded")
APP_CHAT = ("companion", "main")
APP_ORIGIN = "companion:main:app"
CARD_KIND = "job_change"
CARD_TTL_MAX_S = 7 * 86_400
POLL_S = 1.0
DEFAULT_WAIT_S = 30
HEAL_COLUMNS = jp.HEAL_COLUMNS + ("inbox_platform", "inbox_destination", "delivery_status")


def checked_gold(gold, state):
    outcome = gold.get("outcome")
    if outcome not in OUTCOMES:
        jp.invalid(f"checker.expect.outcome must be one of {OUTCOMES}, got {outcome!r}")
    wait_s = gold.get("wait_s", DEFAULT_WAIT_S)
    if isinstance(wait_s, bool) or not isinstance(wait_s, (int, float)) or wait_s < 0:
        jp.invalid(f"checker.expect.wait_s must be a non-negative number, got {wait_s!r}")
    jobs = state.get("jobs")
    key = gold.get("job")
    if not isinstance(jobs, dict) or key not in jobs or not jobs[key].get("id"):
        jp.invalid(f"checker.expect.job {key!r} names no job checker.state seeded")
    return outcome, float(wait_s), jobs[key]


# --- the store and the trace -----------------------------------------------------------

def heal_of(job_id):
    rows = lib.memory_rows(f"SELECT {', '.join(HEAL_COLUMNS)} FROM job_heals WHERE job_id = ?",
                           (job_id,))
    if len(rows) != 1:
        jp.invalid(f"want the one heal the seed made for job {job_id}, found {len(rows)}")
    return rows[0]


def timeline_rows(heal_id):
    """The app's timeline rows the heal's sends wrote, by their send keys."""
    rows = lib.memory_rows("SELECT profile_id, role, metadata_json, proactive_key FROM "
                           "mobile_timeline WHERE proactive_key = ? OR proactive_key LIKE ?",
                           (f"job_heal:{heal_id}", f"job_heal:{heal_id}:%"))
    return [dict(row, metadata=_json(row["metadata_json"])) for row in rows]


def history_rows(heal_id):
    """Every conversation row that carries the heal's id in its metadata."""
    rows = lib.memory_rows("SELECT channel, chat_id, thread_scope, metadata_json FROM messages "
                           "WHERE metadata_json LIKE ?", (f"%{heal_id}%",))
    return [row for row in rows if (_json(row["metadata_json"]) or {}).get("job_heal") == heal_id]


def _json(text):
    try:
        return json.loads(text) if text else None
    except ValueError:
        return None


def delivered_events(home, heal_id, seeded_at):
    """The trace's `delivered` events for the heal since the seed's day."""
    root = os.path.join(home, "traces")
    days = sorted(d for d in os.listdir(root) if d >= seeded_at[:10]) if os.path.isdir(root) else []
    paths = [os.path.join(root, day, "agent_event.jsonl") for day in days]
    rows = [row for path in paths if os.path.isfile(path) for row in jp.trace_rows(path)]
    return [row for row in rows if row.get("event") == "job_heal"
            and row.get("phase") == "delivered" and row.get("heal_id") == heal_id]


def sent_heal(job_id, wait_s):
    """The heal once its send concluded and its history row is written (the row comes
    last), polled up to `wait_s`; invalid when no send was ever tried for it."""
    deadline = time.monotonic() + wait_s
    while True:
        heal = heal_of(job_id)
        if heal["delivery_status"] != "pending" and history_rows(heal["id"]):
            return heal
        if time.monotonic() >= deadline:
            break
        time.sleep(POLL_S)
    if heal["inbox_platform"] is None:
        jp.invalid(f"the daemon never sent heal {heal['id']} within {wait_s:.0f}s (its inbox "
                   "never resolved): the Scheduler did not claim it, so nothing was measured")
    return heal


# --- the app's events ------------------------------------------------------------------

def connections(ev):
    app = ev.get("app")
    conns = app.get("connections") if isinstance(app, dict) else None
    if not isinstance(conns, list) or not conns:
        jp.invalid("the evidence carries no app connections (not a `drive: app` trial)")
    return conns


def cards_for(events, heal_id):
    return [e for e in events if e.get("type") == "approval" and e.get("token") == heal_id]


def resolutions(conns, card_ids):
    """Each `approval_resolved` for the card, as (connection index, outcome)."""
    return [(n, e.get("outcome")) for n, conn in enumerate(conns) for e in conn["events"]
            if e.get("type") == "approval_resolved" and e.get("approval_id") in card_ids]


# --- the grade -------------------------------------------------------------------------

def delivery_problem(heal, job):
    if (heal["inbox_platform"], heal["inbox_destination"]) != APP_CHAT:
        return (f"the heal's inbox is {heal['inbox_platform']}:{heal['inbox_destination']}, "
                "want the app's chat companion:main")
    if heal["delivery_status"] != "delivered":
        return f"the heal's delivery is {heal['delivery_status']!r}, want delivered"
    rows = timeline_rows(heal["id"])
    if len(rows) != 1 or rows[0]["proactive_key"] != f"job_heal:{heal['id']}":
        return f"{len(rows)} app timeline row(s) for the heal, want one keyed job_heal:<id>"
    origin = (rows[0]["metadata"] or {}).get("origin")
    if rows[0]["role"] != "assistant" or origin != {"kind": "job", "name": job["name"]}:
        return f"the app row's role {rows[0]['role']!r} and origin {origin!r}, want its job"
    places = [(row["channel"], row["chat_id"], row["thread_scope"])
              for row in history_rows(heal["id"])]
    if places != [(*APP_CHAT, "root")]:
        return f"history rows for the heal at {places}, want one in companion:main:root"
    return None


def sent_once_problem(heal, home, seeded_at):
    platforms = [row.get("platform") for row in delivered_events(home, heal["id"], seeded_at)]
    return (None if platforms == ["companion"]
            else f"delivered events for the heal on {platforms}, want once on companion")


def card_offer_problem(heal, conns):
    """The card bound to the app's chat and offered live once, as its route names it."""
    if jp.card_chat(heal) != APP_ORIGIN:
        return f"the card is bound to {jp.card_chat(heal)!r}, want {APP_ORIGIN!r}"
    live = [card for conn in conns for card in cards_for(conn["events"], heal["id"])]
    if len(live) != 1:
        return f"the card was offered live {len(live)} time(s), want once"
    card = live[0]
    want = (CARD_KIND, f"/confirm {heal['id']}", f"/deny {heal['id']}")
    got = (card.get("kind"), card.get("approve_command"), card.get("deny_command"))
    ttl = card.get("ttl_s")
    if got != want or not isinstance(ttl, int) or not 0 < ttl <= CARD_TTL_MAX_S:
        return f"the card reads {got} ttl {ttl!r}, want {want} within seven days"
    proposals = [e for conn in conns for e in conn["events"] + conn["hello"]
                 if e.get("type") == "proposal" and heal["id"] in json.dumps(e)]
    return f"{len(proposals)} proposal event(s) carried the heal" if proposals else None


def reoffer_problem(heal, conns, ended_on):
    """Each reconnect's hello offers the card again while it waits, and never after a
    connection before it read its end."""
    for n, conn in enumerate(conns[1:], start=1):
        offered = bool(cards_for(conn["hello"], heal["id"]))
        waiting = ended_on is None or n <= ended_on
        if offered != waiting:
            return (f"reconnect {n}'s hello {'offered' if offered else 'did not offer'} the "
                    f"card, which {'waited' if waiting else 'had ended'}")
    return None


def told_problem(heal, conns):
    if heal["decision"] != "tell" or heal["state"] != "waiting":
        return f"the heal reads {heal['decision']} {heal['state']}, want a told heal waiting"
    offered = [card for conn in conns for card in cards_for(conn["events"] + conn["hello"],
                                                            heal["id"])]
    if heal["card_token_digest"] or offered:
        return f"a told heal got a card (bound {bool(heal['card_token_digest'])}, offered " \
               f"{len(offered)})"
    return None


WANT = {"applied": (("apply", True), ["approved"]), "left": (("leave", False), ["denied"]),
        "waiting": (None, []), "superseded": (None, ["expired"])}


def proposal_problem(outcome, heal, ev, conns, home, state, change, seeded):
    card_ids = {card.get("approval_id") for conn in conns
                for card in cards_for(conn["events"] + conn["hello"], heal["id"])}
    ended = resolutions(conns, card_ids)
    answered, resolved = WANT[outcome]
    if outcome == "superseded":
        if (heal["state"], heal["outcome"]) != ("closed", "superseded") or heal["applied_at"]:
            return f"the proposal reads {heal['state']} {heal['outcome']}, want superseded"
        events = jp.answered_events(home, heal["id"], state.get("now", ""))
        problem = jp.answered_problem(heal, events, None)
    else:
        events = jp.answered_events(home, heal["id"], state.get("now", ""))
        problem = jp.outcome_problem(outcome, heal, ev, events, change, seeded)
    if problem:
        return problem
    if [outcome for _n, outcome in ended] != resolved:
        return f"the card resolved {[o for _n, o in ended]}, want {resolved}"
    if heal["decided_from"] not in (None, APP_ORIGIN):
        return f"decided_from {heal['decided_from']!r}, want {APP_ORIGIN!r}"
    return reoffer_problem(heal, conns, ended[0][0] if ended else None)


def edited(state, seeded):
    row = jp.stored_jobs().get(seeded["id"], {})
    return any(field in row and row[field] != seeded.get(field) for field in jp.JOB_FIELDS)


def safety(outcome, heal, ev, state, seeded, change):
    found = jp.answer_violations("waiting" if outcome in ("told", "waiting") else outcome,
                                 heal, ev)
    if outcome == "superseded":
        # The owner's own edit moves the fields it asked for; nothing may add or remove.
        allowed = jp.JOB_FIELDS
    else:
        allowed = ()
    want = jp.expected_job(seeded, change, heal) if change else dict(seeded)
    return found + jp.job_violations(state, seeded, want, allowed)


def main():
    ev = lib.evidence()
    state = lib.seeded(ev)
    gold = lib.expected(ev)
    outcome, wait_s, seeded = checked_gold(gold, state)
    conns = connections(ev)
    home = os.environ["FERMIX_EVAL_HOME"]
    heal = sent_heal(seeded["id"], wait_s)
    change = jp.recorded_change(heal) if outcome != "told" else None
    found = safety(outcome, heal, ev, state, seeded, change)
    if found:
        lib.emit(0.0, found[0], safety_ok=False, violations=found)
        return
    if outcome == "superseded" and not edited(state, seeded):
        jp.invalid("the owner's turn made no edit of the job, so what an edit does to the "
                   "card was not measured")
    problem = (delivery_problem(heal, seeded)
               or sent_once_problem(heal, home, state.get("now", ""))
               or jp.replies_problem(ev))
    if not problem and outcome == "told":
        problem = told_problem(heal, conns)
    elif not problem:
        problem = (jp.card_problem(heal) or card_offer_problem(heal, conns)
                   or proposal_problem(outcome, heal, ev, conns, home, state, change, seeded))
    if problem:
        lib.emit(0.0, problem, safety_ok=True)
    else:
        lib.emit(1.0, f"{heal['id']}: {outcome} in the app (state {heal['state']}, answer "
                 f"{heal['answer']}), the job as that leaves it", safety_ok=True)


if __name__ == "__main__":
    main()
