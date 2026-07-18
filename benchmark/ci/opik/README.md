# Pinned in-box Opik (CI eval boxes)

`docker-compose.yml` here is the Opik stack every disposable eval box runs
(Milestone 22 D3): self-hosted, no auth, only the frontend published on
`localhost:5173` — the one host:port both the eval harness
(`OPIK_BASE_URL` → `/api/v1/private/*`) and the `fermix_opik` exporter
(`FERMIX_OPIK_BASE_URL` → `/api`) speak to.

## Pin provenance

**Opik 2.0.27**, adapted from the operator's local stack (the exact versions
the harness runs against in development, proven green 2026-07-17) — itself an
adaptation of the upstream `comet-ml/opik` self-hosted compose. Every image is
`tag@sha256` pinned; a digest can't be silently republished.

CI-lean deltas vs a persistent local stack: no volumes (the box is disposable;
report artifacts are the durable record), no restart policies (a crash fails
the job loudly), `mem_limit` on every service (worst-case sum ≈ 9.3 GB on a
16 GB runner, leaving room for the BEAM daemon + build), and no external nginx
config volume (the frontend image generates its config from `NGINX_PORT` at
start).

## Bumping Opik

1. Pick the new release tag; update every `image:` to the new tag.
2. Resolve digests (`docker pull` then
   `docker image inspect IMAGE --format '{{index .RepoDigests 0}}'`) and
   re-pin `tag@sha256` for each service.
3. Re-derive the service topology against the new tag's upstream compose —
   services get added/renamed between releases (e.g. keeper folding into
   clickhouse, object-store changes).
4. Prove it: `workflow_dispatch` the `eval-box` workflow with
   `tier=regression` and confirm the run is green end-to-end. Bring-up is
   `up -d` + `../wait_opik.sh` (the exact API route the harness preflights) —
   deliberately not compose `--wait`, which fails on the exit-0 one-shot init
   container (docker/compose#10596).
5. Ship the bump as its own reviewed diff.

Never float to `:latest` — an Opik API-shape change would break the harness
read side and the exporter write side in different ways at different times.
