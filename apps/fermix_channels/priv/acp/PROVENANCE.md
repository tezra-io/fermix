# Vendored Agent Client Protocol (ACP) contract

These files are **vendored upstream artifacts**, downloaded verbatim from the
Agent Client Protocol release that Fermix's ACP agent surface implements. They
are never hand-edited: re-vendoring means downloading a new release's assets and
updating this file's tag, date, and checksums in the same change.

They pin the wire contract that `FermixChannels.Channels.Acp.Wire` speaks.
`test/fermix_channels/channels/acp/contract_test.exs` reads them and fails if the
codec's method table or advertised schema version drifts from what is vendored
here.

## Release

| Field | Value |
|---|---|
| Upstream repo | `agentclientprotocol/agent-client-protocol` |
| Release tag | `schema-v1.20.0` |
| Wire protocol version | `1` (integer, `initialize.protocolVersion`) |
| Downloaded | 2026-07-31 |

## Files

| File | Source URL | sha256 |
|---|---|---|
| `schema.json` | https://github.com/agentclientprotocol/agent-client-protocol/releases/download/schema-v1.20.0/schema.json | `92c1dfcda10dd47e99127500a3763da2b471f9ac61e12b9bf0430c32cf953796` |
| `meta.json` | https://github.com/agentclientprotocol/agent-client-protocol/releases/download/schema-v1.20.0/meta.json | `e0bf36f8123b2544b499174197fdc371ec49a1b4572a35114513d56492741599` |

Verify with:

```sh
shasum -a 256 apps/fermix_channels/priv/acp/schema.json apps/fermix_channels/priv/acp/meta.json
```

## What each file carries

- `schema.json` — the full JSON Schema for every ACP request, response, and
  notification payload (`$defs`, 142 definitions), including `SessionUpdate` and
  `StopReason`.
- `meta.json` — the method-name table: `agentMethods` (client → agent),
  `clientMethods` (agent → client), and `protocolMethods` (`$/cancel_request`).
  This is the upstream source that `Wire.known_methods/0` is pinned against.

## Scope of the pin

The contract test pins **structure, not full JSON-Schema validation**: it asserts
the vendored files parse, that every method Fermix dispatches on exists upstream,
that the definitions the surface depends on are present, and that the version
string here matches `Wire.schema_version/0`. Validating every frame against the
schema would require a JSON-Schema library; Fermix's ACP surface deliberately
carries no new dependencies (see `docs/design/MILESTONE_29_ACP_AGENT_SURFACE.md`
§4, "Dependencies").
