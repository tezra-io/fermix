"""Write side of the Opik REST API for the capability eval.

`opik.py` reads traces; this writes the eval's verdicts back so they live next to
the traces the daemon already exported. Endpoints + shapes verified against the
live self-hosted build (localhost:5173, no auth) on 2026-06-28:

    POST   {base}/datasets                         {name, description}      -> 201
    DELETE {base}/datasets/{id}                                              -> 204
    GET    {base}/datasets?name=NAME                                         -> {content:[...]}
    PUT    {base}/datasets/items                    {dataset_name, items:[{id, source, data}]}
    POST   {base}/experiments                       {id, name, dataset_name} -> 201
    POST   {base}/experiments/delete               {ids:[...]}              -> 204
    POST   {base}/experiments/items                {experiment_items:[{id, experiment_id,
                                                     dataset_item_id, trace_id}]} -> 204
    PUT    {base}/traces/feedback-scores           {scores:[{id, name, value, source, reason?}]}
    POST   {base}/traces/{id}/feedback-scores/delete {name}                  -> 204

Linking an ALREADY-EXISTING trace by `trace_id` into an experiment item is the
load-bearing capability (finding #1) and returns 204 — no trace re-send. Scores
are plain REST, so no Python SDK is required. This module is pure transport: the
sweep decides what to score and where.
"""

from __future__ import annotations

import hashlib
import json
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class OpikWriteError(Exception):
    pass


# Fixed namespace + a forced version-7 nibble make ids DETERMINISTIC (so re-runs
# upsert instead of duplicating) while satisfying Opik's "must be UUIDv7" check.
def stable_id(text: str) -> str:
    b = bytearray(hashlib.sha256(text.encode("utf-8")).digest()[:16])
    b[6] = (b[6] & 0x0F) | 0x70      # version 7
    b[8] = (b[8] & 0x3F) | 0x80      # RFC-4122 variant
    return str(uuid.UUID(bytes=bytes(b)))


def uuid7() -> str:
    """Time-ordered v7 (non-deterministic) for one-off ids."""
    ms = int(time.time() * 1000)
    rand = uuid.uuid4().int & ((1 << 74) - 1)
    val = ((ms & ((1 << 48) - 1)) << 80) | (0x7 << 76) | (((rand >> 64) & 0xFFF) << 64) \
        | (0b10 << 62) | (rand & ((1 << 62) - 1))
    return str(uuid.UUID(int=val))


class ExperimentWriter:
    def __init__(self, base_url: str, timeout_s: float = 10.0,
                 api_key: str | None = None, workspace: str | None = None):
        self.base = base_url.rstrip("/")
        self.timeout = timeout_s
        self.api_key = api_key or None
        self.workspace = workspace or None

    def _request(self, method: str, path: str, body: dict | None = None) -> tuple[int, object]:
        data = json.dumps(body).encode() if body is not None else None
        headers = {"Content-Type": "application/json", "Accept": "application/json"}
        # Hosted Opik (Comet cloud) auth; a local unauthenticated Opik adds none.
        if self.api_key:
            headers["authorization"] = self.api_key
        if self.workspace:
            headers["Comet-Workspace"] = self.workspace
        req = urllib.request.Request(self.base + path, data=data, method=method,
                                     headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                raw = resp.read().decode(errors="replace")
                return resp.status, (json.loads(raw) if raw.strip() else {})
        except urllib.error.HTTPError as exc:
            return exc.code, exc.read().decode(errors="replace")[:400]
        except OSError as exc:
            # OSError covers URLError (connect phase) AND a read-phase
            # socket.timeout — which is TimeoutError (an OSError, NOT a URLError)
            # since Python 3.10. Catching only URLError would let a read timeout
            # escape raw, past callers' `except OpikWriteError`.
            raise OpikWriteError(f"{method} {path}: {exc}") from exc

    def _expect(self, method: str, path: str, body: dict | None, ok: tuple[int, ...]) -> object:
        status, payload = self._request(method, path, body)
        if status not in ok:
            raise OpikWriteError(f"{method} {path}: HTTP {status}: {payload!r}")
        return payload

    # --- datasets -------------------------------------------------------------

    def create_dataset(self, name: str, description: str = "") -> None:
        """Idempotent: 201 on create, 409 if it already exists (both fine)."""
        self._expect("POST", "/datasets", {"name": name, "description": description}, (201, 409))

    def dataset_id(self, name: str) -> str | None:
        payload = self._expect("GET", f"/datasets?name={urllib.parse.quote(name)}&size=1", None, (200,))
        content = payload.get("content", []) if isinstance(payload, dict) else []
        return content[0]["id"] if content else None

    def upsert_dataset_item(self, dataset_name: str, item_id: str, data: dict) -> None:
        self._expect("PUT", "/datasets/items",
                     {"dataset_name": dataset_name,
                      "items": [{"id": item_id, "source": "sdk", "data": data}]},
                     (204,))

    def delete_dataset(self, dataset_id: str) -> None:
        self._expect("DELETE", f"/datasets/{dataset_id}", None, (204,))

    # --- experiments ----------------------------------------------------------

    def create_experiment(self, experiment_id: str, name: str, dataset_name: str,
                          metadata: dict | None = None) -> None:
        body = {"id": experiment_id, "name": name, "dataset_name": dataset_name}
        if metadata:
            body["metadata"] = metadata
        self._expect("POST", "/experiments", body, (201, 409))

    def link_trace(self, experiment_id: str, dataset_item_id: str, trace_id: str,
                   item_id: str | None = None) -> None:
        """Attach an already-existing trace to an experiment (the finding-#1 path).
        Do NOT pass a `trace`/`evaluate_task_result` payload — that would duplicate
        the trace the daemon already exported."""
        self._expect("POST", "/experiments/items",
                     {"experiment_items": [{"id": item_id or uuid7(),
                                            "experiment_id": experiment_id,
                                            "dataset_item_id": dataset_item_id,
                                            "trace_id": trace_id}]},
                     (204,))

    def delete_experiment(self, experiment_id: str) -> None:
        self._expect("POST", "/experiments/delete", {"ids": [experiment_id]}, (204,))

    # --- feedback scores ------------------------------------------------------

    def put_feedback_scores(self, scores: list[dict], project_name: str) -> None:
        """Batch-attach scores to existing traces. Each: {id (trace uuid), name,
        value, source, reason?}. Opik caps a batch; chunk at 1000.

        `project_name` is REQUIRED and stamped onto every score: the batch
        endpoint returns 204 but SILENTLY DROPS scores that omit it (verified
        2026-06-28). Passing it here makes that misuse impossible."""
        stamped = [{**s, "project_name": project_name} for s in scores]
        for start in range(0, len(stamped), 1000):
            self._expect("PUT", "/traces/feedback-scores",
                         {"scores": stamped[start:start + 1000]}, (204,))

    def delete_feedback_score(self, trace_id: str, name: str) -> None:
        self._expect("POST", f"/traces/{trace_id}/feedback-scores/delete", {"name": name}, (204,))
