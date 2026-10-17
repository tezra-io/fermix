> [!NOTE]
> <strong>Experimental: Sandbox Kit v3</strong>
>
> This kit uses the experimental [Sandbox Kit specification](https://github.com/docker/sandbox-kit-spec), specifically [v3](https://github.com/docker/sandbox-kit-spec/blob/main/docs/spec/SPEC-v3.md). The format and runtime behavior may change before v3 is stable, and running a v3 kit needs an `sbx` release candidate or nightly until v3 reaches a stable `sbx` release.

# fermix

A workload kit (`kind: workload`) for [Fermix](https://fermix.ai), a personal
AI daemon: agents, tools, memory and chat channels in one supervised process.
The kit sets Fermix up headless on the sandbox's first boot and keeps
`fermix run` up from then on. The provider key stays with Docker: Fermix
inside the sandbox holds only the placeholder the sandbox hands it, and the
sandbox's credential proxy writes the real key into each provider request.

The tag is the Fermix release the kit installs: `docker.io/sbx/fermix:0.16.0`
is Fermix 0.16.0.

## Usage

Store a key for the provider Fermix uses first, then run the kit:

```console
sbx secret set anthropic
sbx run docker.io/sbx/fermix:latest
```

Anthropic is the default. For OpenAI or xAI, store that provider's key and
pass the provider as a kit arg:

```console
sbx secret set openai
sbx run docker.io/sbx/fermix:latest --kit-arg provider=openai
```

In Docker's cloud, store the key with `sbx --cloud secret set <provider>` and
run the sandbox detached, so Fermix keeps running with no terminal attached:

```console
sbx --cloud run -d --name fermix --cpus 1 --memory 2g --ttl 24h --on-timeout stop \
  docker.io/sbx/fermix:latest
```

Or from a git URL targeting this repo:

```console
sbx run "git+https://github.com/docker/sbx-kits-contrib.git#dir=fermix"
```

Or from a local clone:

```console
sbx run ./fermix .
```

An attached session waits for the daemon to answer, prints `fermix status`
and opens a login shell. Talk to Fermix with `fermix ask "..."`, and change
its model, provider or channels with `fermix settings` and `fermix setup`.
From outside, `sbx exec <sandbox> -- fermix ask "..."` does the same. A
session with no terminal follows the daemon log instead.

## How the first boot works

`fermix-sandbox-boot`, a background startup hook, runs once per boot:

- On the first boot it runs `fermix setup` headless: the provider the kit arg
  names, that provider's placeholder key from the sandbox, a file secret store
  in the agent's home, and no service manager. Setup does not probe the key,
  because the key here is always a placeholder; the first turn reports a
  missing secret. Claude runs on Haiku 5.5, a fraction of the cost of Fermix's
  Sonnet default; OpenAI and xAI take Fermix's own default model. Change it
  any time with `fermix settings`.
- Only a setup that ended well is marked done, so a failed setup runs again on
  the next boot. The boot log is `~/.fermix-sandbox-boot.log`.
- Every boot then hands over to `fermix-sandbox-loop`, which keeps
  `fermix run` up with the rule of Fermix's own systemd unit: a restart five
  seconds after every exit, and a stop after the fifth. A sandbox has no
  service manager to do this. A cloud stop is a pause, so a boot that finds
  Fermix already running leaves it to its loop.

## How the provider relay works

Fermix is an Erlang/OTP application, and Erlang/OTP refuses the certificate
the sandbox's credential proxy presents: the proxy's intermediate CA has a
commonName of 94 characters, and the X.520 upper bound that OTP's certificate
decoder enforces is 64. Every Erlang TLS connection through the proxy fails,
so Fermix cannot use the proxy directly.

The kit closes that gap with a relay on loopback. `fermix-sandbox-relay`, a
second startup hook, keeps [Caddy](https://caddyserver.com) up with
`fermix-relay.Caddyfile`: one plain-HTTP port per provider, bound to
127.0.0.1 only (18080 Anthropic, 18081 OpenAI, 18082 xAI). Each port
forwards to its provider over HTTPS through `HTTPS_PROXY`, the credential
proxy, which writes the stored key into the request. Setup points every
provider's `base_url` at its port, all three whichever provider comes first,
so a later `fermix settings primary <provider>` finds its relay ready.

The relay hook is the only one given `HTTPS_PROXY`, and the boot hook gets only
the three placeholder keys. Without `HTTPS_PROXY`, which the sandbox sets only
once a provider secret exists, the relay refuses to start rather than send the
placeholder to the provider as it is.

OpenAI behind a relay `base_url` uses Chat Completions rather than the
Responses API, which Fermix uses only for `https://api.openai.com`.

## Network policy

The runtime allow list is the three providers, `html.duckduckgo.com` for web
search, the Telegram, Discord, Slack and WhatsApp hosts with their attachment
hosts, and GitHub for release and plugin downloads. Nothing runs in the
install phase.

Fermix's web fetch tool can reach only those hosts. To let it read other
sites, allow them for one sandbox with `sbx policy allow network`.

## What does not work in a sandbox

- **Voice, image generation and xAI speech-to-text.** They call their
  provider hosts directly, not through the relay, so they get no key.
- **The browser tool.** The shell template has no Chromium.
- **Chat channel tokens are not provider keys.** A Telegram, Discord, Slack or
  WhatsApp token you add with `fermix settings` is stored in the sandbox's
  file store; the credential proxy cannot inject a token that travels in the
  URL path, as Telegram's does.

## Contents

The recipe installs the signed Fermix release package for the pinned version
and the Caddy binary, both downloaded and checked in a build stage that the
kit does not ship: the Fermix package against its sha256 sidecar and its
cosign signature from Fermix's release workflow, and Caddy's tarball against
the sha512 line of its release's cosign-signed checksums file. The build fails
if the installed package is not the pinned version. The scripts and the Caddy
configuration live in `/usr/lib/fermix/sandbox`.

## Cleanup

Fermix's settings, memory and file secret store live in the sandbox, so
removing the sandbox removes them:

```console
sbx rm fermix
```
