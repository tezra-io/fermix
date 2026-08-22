# Fermix management socket protocol

The wire contract between the Fermix daemon and the Fermix macOS application.

**Source of truth:** `FermixCore.Management.Protocol`
(`lib/fermix_core/management/protocol.ex`). This file, `protocol.schema.json`,
and `fixtures/*.jsonl` are the machine-readable export of that module.
`protocol_contract_test.exs` asserts they never drift from it. A downstream
consumer (`fermix-macos`) **vendors the schema and fixtures pinned by checksum**
rather than hand-copying the shapes — that is the single coordination point
across the two independently-released repos.

## Transport

- **Socket:** a Unix-domain stream socket at `$FERMIX_HOME/daemon.sock`
  (default `~/.fermix/daemon.sock`), mode `0600`, owned by the daemon. There is
  no per-request authentication; the trust boundary is the socket file's mode
  and ownership.
- **Framing:** Erlang `{:packet, 4}` — one big-endian 32-bit byte length
  followed by exactly that many bytes of UTF-8 JSON. A frame arrives whole or
  not at all, so a decode failure means malformed JSON, never truncation.
- **Frame ceiling:** `max_frame_bytes` = `4194304` (4 MiB), enforced on both
  ends via `{:packet_size, ...}`. A client rejects an oversized request before
  sending it rather than failing on an opaque `emsgsize`.
- **Exchange:** one request, one response, then the daemon closes the
  connection. There are no server-initiated frames and no streaming; Doctor runs
  and log pages are polled, which is why `doctor.start` returns immediately with
  a session id instead of holding the request open.

## Versioning

The protocol is versioned by a single integer, `protocol_version`, carried on
every request. The daemon accepts the inclusive range `{minimum, maximum}`. The
range is an **N/N-1 window**: `maximum` is the current version and `minimum` is
the previous one (or the same value when only one version has ever existed), so
a daemon that has moved to `N+1` still serves an app speaking `N` for one
release.

Current values (see the schema's `x-protocol-version` /
`x-supported-version-range`):

| Field | Value |
|---|---|
| `protocol_version` (app declares) | `1` |
| daemon `minimum_version` | `1` |
| daemon `maximum_version` | `1` |

`hello` returns the same range, so a client learns the window without having to
provoke an error.

## Request envelope

```json
{
  "request_id": "req-1",
  "protocol_version": 1,
  "method": "hello",
  "params": {}
}
```

- `request_id` — required, `^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`. Echoed on
  every response; a client that receives a different id must discard the frame.
- `protocol_version` — required integer, negotiated against the window above.
- `method` — required, from the catalog below.
- `params` — optional object, defaulting to `{}`.

Unknown top-level fields are refused with `invalid_request`, naming the field.
Every method declares its own parameter set: input-free methods refuse any
params at all, and params-carrying methods refuse an unknown key rather than
ignoring it.

## Response envelope

A response carries **exactly one** of `result` or `error`, never both and never
neither.

```json
{ "request_id": "req-1", "result": { } }
```

```json
{
  "request_id": "req-1",
  "error": {
    "code": "unknown_session",
    "message": "The Doctor session is not retained by this daemon.",
    "details": { "session_id": "doctor:9Fj2mQ" }
  }
}
```

`code` is from the stable catalog below, `message` is a fixed operator-facing
sentence owned by the daemon, and `details` is a bounded object of public
scalars. No `inspect(reason)` output, internal term, filesystem path, or Setup
token ever crosses this boundary. `request_id` is `null` only when the request
was so malformed that no valid id could be recovered from it.

## v0 compatibility window

The daemon also serves the historical **unversioned** control protocol as v0 for
one migration release — that is what `fermix stop`, mobile pairing, and the
remaining introspection verbs (`health`, `agents`, `capabilities`, `skills`,
`plugins`, `observability`) speak today. Classification is structural and has no
fallback:

1. A frame carrying **either** `request_id` or `protocol_version` is an
   attempted v1 request. If it is not a valid one it is refused with a v1 error
   envelope and **never** retried as v0.
2. A frame carrying neither marker, with a string `method`, is v0.
3. Anything else — non-object JSON, undecodable bytes, a v0 frame without a
   `method` — is refused as an invalid v0 request.

New application code sends v1 only and never retries through v0. A v0 method is
deleted, not deprecated in place, when its verb moves onto v1: `status` and
`overview` were removed when `fermix status` moved onto `hello` plus
`overview.get`, and a daemon asked for either now answers the ordinary v0
`unknown method` reply.

## Direction of an unsupported version

A version outside the window is refused before routing, with the range attached
so the app can tell the user which component to update without re-deriving it:

- `client_too_old` — the app declared a version below the daemon's floor →
  **update the app**.
- `daemon_too_old` — the app declared a version above the daemon's ceiling →
  **update Fermix**.

Both carry `details: {"minimum_version": N, "maximum_version": M}`.

## Rollout / rollback order

Because the daemon and the app ship from separate repos on independent cadences,
a version bump must land in a fixed order so the two are never mutually
unintelligible:

1. **Daemon first.** Ship a daemon that *adds* support for `N+1` while keeping
   `N` (the N/N-1 window). Never remove support for a version a released app
   still requires.
2. **App second.** Only after that daemon is released, ship an app that speaks
   `N+1`. An app must never require a version the released daemon lacks.
3. **Rollback** is the reverse: roll the app back to `N` before dropping `N`
   from the daemon.

## Method catalog

| `method` | Params | Result |
|---|---|---|
| `hello` | none | Supported range, method catalog, immutable engine identity, PID, and the loopback Setup endpoint. |
| `overview.get` | none | Typed projection of readiness, health, daemon, provider, channels, memory, jobs, agents, realtime, and capability counts. |
| `setup.session.create` | none | A one-use Setup URL and its absolute expiry. The durable token is never returned. |
| `doctor.start` | `scope` (`local` \| `network`, default `local`) | A session view; the run continues in the background. |
| `doctor.get` | `session_id` | The session view with the checks that have landed so far. |
| `doctor.cancel` | `session_id` | The terminal session view. Cancelling a finished session is a no-op, not an error. |
| `logs.query` | `limit`, `level`, `subsystem`, `search`, `direction`, `cursor` | A bounded page of redacted entries plus the opaque cursor for the next page in the same direction. |
| `lifecycle.prepare` | none | `lease_id` and the relative `ttl_ms` of the single drain window. |
| `lifecycle.commit` | `lease_id` | Runs the daemon's shutdown path and answers before the VM stops. |
| `lifecycle.cancel` | `lease_id` | Releases the window with the daemon untouched. |
| `diagnostics.build` | none | A bounded, field-allowlisted, scrubbed diagnostic object for user-selected export. |

Notes that the shapes alone do not carry:

- A **Doctor session** is the only management operation that is a *run*: it has
  its own session id, a whole-run budget (`local` 10000 ms, `network` 30000 ms),
  and cancellation. At most 2 sessions run concurrently (`busy` beyond that) and
  at most 8 finished sessions are retained, none older than 300000 ms.
- A **check status** is one of `passed`, `warning`, `failed`, `not_applicable`,
  `unavailable`, `skipped`, `cancelled`, `timed_out`. `not_applicable` means
  this distribution does not have the check (the two distribution rows under
  `macos_app`); `unavailable` means the check itself could not answer. A session
  `summary` carries one count per status.
- A **prepared daemon auto-resumes.** The drain lease is finite: if the app
  crashes or the machine reboots between prepare and commit, the lease expires
  and the daemon keeps serving.
- **`lifecycle.prepare` quiesces nothing.** It takes the single-flight window
  and nothing else: in-flight agent turns and tool runs continue, and new work
  is still accepted. `busy` means another lease is open, never "this daemon has
  work in flight". A client that must not interrupt work has to establish that
  itself before committing.
- **`ttl_ms` is relative, deliberately.** The expiry timer runs on monotonic
  time, which is frozen across sleep and never stepped by NTP, so a wall-clock
  deadline would disagree with it. Clients start their own timer on receipt.
- A **log cursor** is opaque and carries the rotation fingerprint it was minted
  against. After the log set rotates the cursor answers `cursor_expired` rather
  than silently returning a different window.
- **`subsystem`** matches a leading `[tag]` the log message itself wrote; the
  engine's on-disk log format carries no module or subsystem field, so a line
  without such a tag is excluded whenever a subsystem filter is supplied.

## Error codes

| `code` | Meaning |
|---|---|
| `invalid_request` | The envelope is malformed. `details.field` names the offending field. |
| `invalid_params` | The parameters are malformed, unknown, or oversized for this method. |
| `method_not_found` | The method is not in this daemon's catalog. |
| `client_too_old` | The declared version is below the daemon's floor. |
| `daemon_too_old` | The declared version is above the daemon's ceiling. |
| `internal_error` | The daemon failed to complete the request. Details are always empty. |
| `unavailable` | The named capability could not answer. `details.capability` names it. |
| `busy` | Another operation of this kind is already running. |
| `lease_expired` | The lifecycle lease's window elapsed and the daemon resumed. |
| `unknown_lease` | The lease was never issued by this daemon, or was already consumed. |
| `unknown_session` | The Doctor session is not retained by this daemon. |
| `cursor_expired` | The log cursor predates a rotation and cannot be resumed. |

`lease_expired` and `unknown_lease` are deliberately distinct: the first lets
the app tell the operator the transaction timed out, the second says the id was
never valid here. The elapsed memory is bounded, so an ancient id honestly
degrades to `unknown_lease`.

## Bounds

Every bound is published in the schema's `x-limits` and pinned to
`FermixCore.Management.Protocol.limits/0`.

| Bound | Value | Applies to |
|---|---|---|
| `max_frame_bytes` | `4194304` | One transport frame, request or response. |
| `max_params_bytes` | `65536` | The encoded `params` object. |
| `max_result_bytes` | `1048576` | The encoded `result` object. |
| `max_error_details_bytes` | `4096` | The encoded `error.details` object. |
| `max_json_depth` | `6` | Nesting depth of `params`, `result`, and `error.details`. |
| `max_json_collection_items` | `500` | Items in any one array or keys in any one object. |

Operation-specific bounds, owned by the operation rather than the envelope: a
`logs.query` page defaults to 200 entries and is capped at 500 entries and
262144 encoded bytes, with a 256-character search and a 64-character subsystem;
a `diagnostics.build` object carries at most 500 log entries.

## Vendoring into `fermix-macos`

The macOS repository must not hand-copy these shapes. It vendors
`protocol.schema.json` and `fixtures/*.jsonl` with a checksum pin and runs its
own client tests against the same golden frames the daemon is tested against.

- `fixtures/requests.jsonl` — one well-formed v1 request per method, plus
  parameter variants. Each record declares the classification the daemon owes
  it.
- `fixtures/success.jsonl` — one full success envelope per method.
- `fixtures/errors.jsonl` — one full error envelope per published code,
  including the fixed `message` text.
- `fixtures/compatibility.jsonl` — the v0 window and the negotiation matrix: v0
  requests, partial-marker rejects that must never fall through to v0, and both
  `client_too_old` and `daemon_too_old`.

Re-vendor whenever `protocol_version` changes, a method or error code is added,
or a bound moves. The daemon ships first; see *Rollout / rollback order*.
