# Fermix Connect contract

The wire contract between a Fermix installation (the `x` channel) and Fermix
Connect, the hosted service that watches the shared X account's mentions,
routes each one to the person's own Fermix and publishes the one reply
(MILESTONE_63_SHARED_X_HANDLE, design §9). The engine owns this contract:
installed engines are the side that cannot change after release, so Connect
keeps answering every version a released engine speaks. `fermix-connect`
vendors this folder byte for byte and checks it in CI, the way `fermix-macos`
vendors `priv/management`.

**Source of truth:** this file, `protocol.schema.json` and `fixtures/*.jsonl`.
`FermixChannels.X.Assignment` verifies assignments against it; the contract test
holds every fixture to the schema.

Protocol version: **1**. One number for the whole contract: the HTTP enrollment
calls, the socket frames and the signed assignment.

## 1. What each side holds

| Side | Holds | Never holds |
|---|---|---|
| Installation | its Ed25519 instance key (`FERMIX_HOME/x/instance_key`, mode 0600), its pairing record (`FERMIX_HOME/x/pairing.json`, mode 0600), its durable `x_assignments` rows | the bot account's grant, any other tenant's data, a publish path |
| Connect | the bot grant, tenants (one per verified X identity), instances and their public keys, interactions and assignments, the assignment-signing key | an installation's private key, its memory, its tools, its model keys |

Identifiers are strings. X ids are decimal strings. Times are RFC 3339 UTC with
a `Z` suffix. Binary values (keys, signatures, nonces) are base64url without
padding. Generations are positive integers that only ever grow.

### The instance key

A raw 32-byte Ed25519 seed, created on the first `x.pair.start` and never
rotated in place (unpair deletes it; the next pairing makes a new one). Its
public key is published at enrollment. `key_id` is `"k" <> first 16 hex
characters of SHA-256(public key)`. The fingerprint is the full SHA-256 of the
public key as 16 groups of four hex characters, the shape `mobile.status`
already uses; `x.status`, Doctor and Connect's account page show it so an
owner can tell installations apart and revoke one, and pairing never asks
anyone to compare it (§2).

### The pairing record (`pairing.json`)

Written once the key proof is accepted, replaced on nothing, deleted on unpair.
It is not a setting: editing it grants nothing (design §14.2, ID-12), because
every value in it is checked against Connect's own state on every connection
and every assignment.

```json
{
  "version": 1,
  "origin": "https://connect.fermix.ai",
  "instance_id": "ins_7f3c2a9e1b4d",
  "tenant_id": "1234567890",
  "handle": "@sujeeth",
  "key_id": "k3f9a1c2e7b4d05a8",
  "key_generation": 1,
  "tenant_generation": 1,
  "connect_key_id": "c2026a",
  "connect_public_key": "<base64url Ed25519 public key>",
  "paired_at": "2026-10-16T05:00:00Z"
}
```

`origin` is the audience every signature names; a record is valid for exactly
one origin. `tenant_id` is the owner's numeric X id (D3: the tenant is the
verified X identity). `connect_public_key` verifies assignments; a Connect key
rotation is a new pairing (deferred).

## 2. Enrollment (HTTPS, before a socket exists)

Pairing is the shape of a native app's sign-in: an OAuth 2.0 authorization
request with PKCE (RFC 7636) whose redirect is the installation's own loopback
(RFC 8252 §7.3), with Connect as the authorization server and its own Sign in
with X behind it. The installation opens the enrollment, sends the owner to
Connect in a browser, takes the authorization code back on `127.0.0.1`, and
proves its key with that code. Nothing polls Connect, and nothing asks the
owner to compare a fingerprint: a code reaches only the machine that opened
the enrollment, and a proof needs the verifier that machine holds and the key
it enrolled, so a link opened by anyone else binds nothing.

Every call is `application/json`; every error is
`{"error": {"code": "<snake_case>", "sentence": "<one sentence>"}}` with the
HTTP status it belongs to, and the sentence never says whether an id exists.
The installation follows no redirect: the origin is the audience every
signature names.

| Call | Body | Answer |
|---|---|---|
| `POST /v1/enrollments` | `{protocol_version, public_key, key_id, label}` | `201 {enrollment_id, confirm_url, expires_at}` |
| `POST /v1/enrollments/{enrollment_id}/prove` | `{code, code_verifier, signature}` | `200 {instance_id, tenant_id, handle, key_generation, tenant_generation, connect_key_id, connect_public_key}` |
| `DELETE /v1/instances/{instance_id}` | none; signed headers (§2.4) | `204` |

`label` is how the confirmation page names the installation: 1 to 64
characters with no control characters and no space at either end. Connect
trims it and counts graphemes; the schema bounds code points, which are never
fewer, so a label within the schema is within Connect's bound. A label
Connect cannot take answers `400 invalid_request`.

`confirm_url` is `<origin>/confirm/<token>` with no query: a one-use token
that is not the enrollment id, good for the enrollment's ten minutes. The
enrollment id is never shown in a browser.

The error codes Connect answers today (the set is open: a new code is
additive, and an installation reads one it does not know as Connect refusing
the call):

| Status and code | Call | Meaning |
|---|---|---|
| `400 invalid_request` | any | A field is missing or in the wrong shape, the `key_id` is not the `public_key`'s, or the `label` is out of bounds. |
| `400 unsupported_version` | `POST /v1/enrollments` | Connect does not speak the `protocol_version`. |
| `400 proof_rejected` | `POST /v1/enrollments/{enrollment_id}/prove` | A well-formed proof Connect does not accept: the enrollment is not awaiting a proof, the `code` is not its unspent one, the `code_verifier` does not hash to the challenge the browser carried, or the signature does not verify. After five rejected proofs the enrollment expires. A body with a missing or malformed field is `400 invalid_request`, as on any call, and counts as nothing. |
| `409 already_active` | `POST /v1/enrollments/{enrollment_id}/prove` | A second proof for an enrollment that is already active. |
| `409 tenant_already_paired` | `POST /v1/enrollments/{enrollment_id}/prove` | The X account already has a paired installation; the enrollment ends `denied`. |
| `409 key_already_paired` | `POST /v1/enrollments/{enrollment_id}/prove` | This key is already active for another instance; the enrollment ends `denied`. |
| `401 unauthorized` | `DELETE /v1/instances/{instance_id}` | The signature does not verify. |
| `401 stale_request` | `DELETE /v1/instances/{instance_id}` | The timestamp is more than 60 seconds from Connect's clock (§2.4). |
| `404 unknown_instance` | `DELETE /v1/instances/{instance_id}` | No active instance under that id: it never existed or was revoked (§2.4). |
| `429 rate_limited` | `POST /v1/enrollments` | Too many enrollments opened from this source address in ten minutes, or too many live at once. No other HTTP call is rate limited. |
| `500 internal_error` | any | Connect could not complete the call. |

### 2.1 The authorization request

The installation binds a listener on `127.0.0.1` on a port of its choosing
and opens, in the owner's browser, `confirm_url` with these query parameters
(RFC 6749 §4.1.1):

| Parameter | Value |
|---|---|
| `response_type` | `code` |
| `client_id` | the enrollment's `key_id` |
| `redirect_uri` | `http://127.0.0.1:<port>/callback`: that scheme, that host literally, any port from 1 to 65535, that path, nothing else |
| `scope` | empty; Connect ignores it |
| `code_challenge` | `BASE64URL(SHA-256(code_verifier))`, 43 characters of `A-Z a-z 0-9 - _` |
| `code_challenge_method` | `S256` |
| `state` | 16 to 128 characters of `A-Z a-z 0-9 - _`, chosen by the installation for this attempt |

`code_verifier` is 43 to 128 characters of `A-Z a-z 0-9 - . _ ~` that the
installation keeps and never sends to a browser. A confirm page reached
without these parameters, with any of them malformed, or with a `client_id`
that is not the enrollment's `key_id`, says the link is incomplete and
decides nothing.

In the browser the owner signs in with X (Connect's own PKCE sign-in, which
returns to the same address, query included) and sees the consent page: the
installation's label, the signed-in account and the consent text. Then:

- **Approve**: Connect records the request's `code_challenge`, `redirect_uri`
  and `state` on the enrollment, binds the signed-in tenant, mints a one-use
  `code` (32 random bytes, base64url, 43 characters), moves the enrollment to
  `awaiting_proof`, and answers `303 See Other` to
  `<redirect_uri>?code=<code>&state=<state>`.
- **Deny**: the enrollment ends `denied` and Connect answers `303 See Other`
  to `<redirect_uri>?error=access_denied&state=<state>`.
- A token already used or expired shows Connect's own "no longer valid" page
  and redirects nowhere, since no redirect address is trusted for it.

The installation's listener accepts one `GET` on `/callback` whose `Host` is
its own and whose `state` is this attempt's, answers the browser with a page
of its own, and closes. On a machine whose browser is elsewhere the redirect
fails to load; the owner then pastes the address the browser ended on into
their Fermix, which reads it by the same rules. The code is single-use and
expires with the enrollment.

### 2.2 The proof

`POST /v1/enrollments/{enrollment_id}/prove` carries the `code` the browser
delivered, the `code_verifier` it was minted against, and `signature`:
Ed25519 over the UTF-8 bytes of

```
fermix-connect-enroll|<origin>|<enrollment_id>|<code>
```

where `origin` is the scheme and host the installation dialed (no path, no
trailing slash). Connect accepts the proof when the enrollment is
`awaiting_proof`, the `code` is its unspent one, the verifier hashes to the
recorded challenge and the signature verifies under the enrolled public key;
it then activates the instance and answers the pairing record's fields. Any
other well-formed proof is `400 proof_rejected`; a malformed body is
`400 invalid_request` and spends nothing. Neither half alone claims a machine: the
browser approval binds the tenant and issues the code, the proof binds the
key (design §5.2 steps 3–5, ID-10).

### 2.3 States

Connect keeps each enrollment as `awaiting_confirmation` (the owner has not
decided in the browser) → `awaiting_proof` (approved; the code is out) →
`active` (the proof was accepted) | `expired` | `denied`. The installation
never reads them: it learns the outcome from its loopback, from the proof's
answer, or from its own ten-minute clock, which is the enrollment's lifetime.
A finished enrollment is forgotten five minutes after it expires.

### 2.4 Signed requests

`DELETE /v1/instances/{instance_id}` carries

```
X-Fermix-Instance: <instance_id>
X-Fermix-Key-Id: <key_id>
X-Fermix-Timestamp: <RFC 3339 UTC>
X-Fermix-Signature: <base64url Ed25519 over "fermix-connect-request|<origin>|DELETE|/v1/instances/<instance_id>|<timestamp>">
```

A timestamp more than 60 seconds from Connect's clock is `401 stale_request`.
An unknown or revoked instance is `404 unknown_instance`. Unpairing cancels the
instance's pending assignments and closes its socket.

## 3. The socket

`GET /v1/connect`, upgraded to a WebSocket with the headers

```
X-Fermix-Instance: <instance_id>
X-Fermix-Key-Id: <key_id>
Sec-WebSocket-Protocol: fermix-connect.v1
```

No secret travels in the upgrade. Frames are UTF-8 JSON text frames, one
object per frame, with a `t` field. Liveness is the WebSocket protocol's own
ping and pong; there is no JSON ping. Connect closes the socket `4400` on a
client frame over the session's `max_result_bytes`, a binary frame, a frame
that is not a JSON object of a known `t` with its required fields, or a frame
out of order (a second `hello`, a `start` before its `receipt`). The
installation never closes over a frame's size: an assignment over its caps is
a `rejected` receipt, `over_cap` (§4). `4400` is Connect's verdict on a frame,
`over_cap` the installation's on a token.

### 3.1 Authentication

Server, first frame: `{"t": "challenge", "nonce": "<base64url 32 bytes>"}`.

Client, within five seconds, its only frame before `ready`:

```json
{"t": "hello", "protocol_version": 1, "signature": "<base64url>", "capabilities": {"final_only": true, "max_result_bytes": 16384}}
```

`signature` is Ed25519 over the UTF-8 bytes of

```
fermix-connect-session|<origin>|<instance_id>|<nonce>|<protocol_version>
```

Server: `{"t": "ready", "session_ttl_s": 900, "max_assignment_bytes": 32768, "max_result_bytes": 16384}`,
or a close. The session ends at `session_ttl_s`; the client reconnects and
authenticates again, with jitter. A revoked or unpaired instance is closed at
once (`4401`).

`ready` names the session's caps, which hold until the socket closes: an
assignment whose JWS is over `max_assignment_bytes` is answered `over_cap`
(§4), and a client frame over `max_result_bytes` is closed `4400`. `hello`'s
`capabilities` are the installation's declaration: `final_only` must be
`true` (Connect closes `4401` otherwise, as for an unknown version), and
`max_result_bytes` is the largest result frame the installation sends, which
Connect does not read in version 1. Until `ready` the installation assumes the
schema's caps.

### 3.2 Frames, server to client

| `t` | Fields | Meaning |
|---|---|---|
| `assignment` | `jws` | One assignment, as a compact JWS (§4). Resent on every connection until a `receipt` names it. |
| `start_ok` | `assignment_id`, `attempt`, `deadline_at` | The execution-start grant: the attempt number (1, 2, …) and the wall clock by which the result is due. |
| `start_refused` | `assignment_id`, `reason` | No attempt: `expired`, `cancelled`, `suppressed`, `stale_generation`, `unknown_assignment`, `already_settled`. Terminal for the installation. |
| `result_ack` | `assignment_id`, `attempt` | The result is Connect's responsibility now. |
| `result_rejected` | `assignment_id`, `attempt`, `reason` | `conflict` (a different result for a settled attempt), `too_long`, `invalid`, `stale_attempt`, `unknown_assignment`. Terminal. |
| `cancel` | `assignment_id`, `reason` | Stop the attempt if it runs; `expired`, `suppressed`, `unlinked`, `revoked`, `operator`. |

### 3.3 Frames, client to server

| `t` | Fields | Meaning |
|---|---|---|
| `receipt` | `assignment_id`, `outcome` (`accepted` \| `rejected`), `reason?` | Durable local responsibility (`accepted`), or a verification failure Connect settles as rejected instead of resending (`rejected` with `reason`: `bad_signature`, `wrong_instance`, `stale_generation`, `expired`, `malformed`, `over_cap`). ACK means stored, never finished. Idempotent. |
| `start` | `assignment_id` | Asks for the execution-start grant. Sent once the installation can run the turn now (one X turn at a time). |
| `result` | `assignment_id`, `attempt`, `request_sha256`, `decision`, `public_text?`, `result_sha256` | The one terminal result of an attempt (§5). Resent on every connection until `result_ack` or `result_rejected`. |
| `cancel_ack` | `assignment_id` | The cancel was seen; the attempt is stopped or was never started. |

### 3.4 Close codes

`4400` malformed frame or cap exceeded (§3), `4401` authentication failed or
instance revoked, `4408` hello not received in time, `4409` a second socket
for the same instance replaced this one, `4429` rate limited (more client
frames in a short window than Connect admits), `1012` Connect is restarting
or the session reached `session_ttl_s` (reconnect with jitter).

## 4. The assignment

A compact JWS, `alg` `EdDSA` (Ed25519), `kid` = `connect_key_id`. The verifier
pins the algorithm and matches `kid` to its pairing record; it never reads an
algorithm, key or key URL from the token. The payload:

```json
{
  "protocol_version": 1,
  "assignment_id": "as_01j9x3k2m4n5p6q7",
  "interaction_id": "ix_01j9x3k2m4n5p6q7",
  "tenant_id": "1234567890",
  "tenant_generation": 1,
  "instance_id": "ins_7f3c2a9e1b4d",
  "key_generation": 1,
  "bot_user_id": "1987654321",
  "requester_x_user_id": "1234567890",
  "invoking_post_id": "1845000000000000001",
  "conversation_id": "1844999999999999990",
  "request_text": "@FermixAI explain this",
  "request_sha256": "<hex SHA-256 of request_text>",
  "context": {
    "posts": [
      {"id": "1844999999999999990", "author_id": "1122334455", "author_handle": "@alice", "role": "parent", "text": "…", "created_at": "2026-10-16T04:58:00Z"},
      {"id": "1845000000000000001", "author_id": "1234567890", "author_handle": "@sujeeth", "role": "invoking", "text": "@FermixAI explain this", "created_at": "2026-10-16T04:59:00Z"}
    ],
    "truncated": false
  },
  "issued_at": "2026-10-16T05:00:00Z",
  "expires_at": "2026-10-16T05:15:00Z"
}
```

`role` is one of `invoking`, `parent`, `ancestor`, `quoted`. A post that could
not be read is present with `"missing": true` and no `text`, so the model is
told what it is not seeing. At most 8 posts and 12,000 characters of text; the
whole JWS at most `max_assignment_bytes`.

The installation accepts an assignment only when every check holds, in this
order, and answers the first that fails with a `receipt` of `rejected` and the
reason beside it:

1. The JWS is three base64url segments whose header is a JSON object
   (`malformed`), and its `kid` is the record's `connect_key_id`
   (`bad_signature`).
2. The signature verifies with `connect_public_key`, the algorithm pinned to
   `EdDSA`: a token naming another `alg` does not verify (`bad_signature`).
3. `protocol_version` is 1 and the claims have the schema's shape
   (`malformed`).
4. `instance_id` and `tenant_id` equal the record's (`wrong_instance`), and so
   do `tenant_generation` and `key_generation` (`stale_generation`).
5. `expires_at` is in the future and `issued_at` at most 60 seconds in the
   future of the installation's clock (`expired`).
6. `request_sha256` is the SHA-256 of `request_text` (`malformed`).
7. The context is within its caps (posts and characters, above) and the whole
   JWS within the session's `max_assignment_bytes` (`over_cap`).

A correctly signed assignment for another instance is therefore
`wrong_instance`. Nothing in the payload names a policy, a tool, a path or a
prompt: the execution profile is the channel's own constant (I5).

## 5. The result

```json
{"t": "result", "assignment_id": "as_01j9x3k2m4n5p6q7", "attempt": 1, "request_sha256": "<hex>", "decision": "public_reply", "public_text": "…", "result_sha256": "<hex>"}
```

`decision` is `public_reply` (with `public_text`), `private_only`, `no_reply`
or `failed` (the others carry no `public_text`). `result_sha256` is the hex
SHA-256 of the UTF-8 bytes of `decision <> "\n" <> public_text` (an absent
`public_text` is the empty string), so a resend is recognised and a different
body for a settled attempt is a `conflict`. The installation never names the
publishing account, the reply parent or any other target: Connect takes those
from its own interaction row (I8). `public_text` is at most 280 weighted
characters as X counts them; Connect rejects a longer one as `too_long` and the
installation reports the attempt as failed. One result per attempt; a turn that
produced nothing is `no_reply`; a turn that failed or was stopped is `failed`.

## 6. Durability on the installation

One table, `x_assignments`, in `memory.db`: the verified assignment as
received, its status (`accepted`, `running`, `completed`, `failed`,
`cancelled`, `expired`), the attempt and the boot epoch it ran under, the
result and whether Connect acknowledged it. The receipt is sent after the row
is committed (I7). At boot: `accepted` rows ask for a start again; `running`
rows of an earlier boot died with it and are settled as `failed`; `completed`
rows not yet acknowledged are resent. A result for an attempt Connect has
settled is a `conflict`, and the row keeps its own record of what it sent.

## 7. Versioning

The schema closes (`additionalProperties: false`) everything the installation
sends, everything a signature covers, the pairing record and the proof answer
that seeds it: `enrollmentCreateRequest`, `authorizationRequest`,
`proveRequest`, `proveAnswer`, `pairingRecord`, the client frames (`hello`
with its `capabilities`, `receipt`, `start`, `result`, `cancel_ack`),
`jwsHeader`, and
`assignmentPayload` with its `context` and `contextPost`. A new field on a
closed object is a new `protocol_version`. The installation refuses one where
it reads a closed object (the proof answer, the pairing record, an
assignment's claims); Connect ignores one on a client frame rather than
closing the socket, and never stores or forwards it.

Every other server answer and server frame is open (`enrollmentCreateAnswer`,
`authorizationCallback`, `httpError`, and the frames `challenge`, `ready`,
`assignment`, `start_ok`, `start_refused`, `result_ack`, `result_rejected`,
`cancel`): Connect may add an optional field
within a version, and an installation ignores a field it does not know. A
change to a signed claim, a frame's required fields or a close code is a new
`protocol_version`, declared in `hello`; Connect answers every version a
released engine speaks and refuses an unknown one with `4401`. Fixtures under `fixtures/` are recorded from the real
Connect once one runs; until then they are the contract's own examples and are
marked so (`"source": "contract_example"` on every line).
