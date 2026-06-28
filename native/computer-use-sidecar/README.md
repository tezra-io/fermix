# fermix-computer-use (native sidecar)

The native OS-driver helper for Fermix Computer Use. Fermix's
`ComputerUse.PortDriver` spawns this binary as a Port and talks to it over the
line-framed JSON protocol in
`apps/fermix_core/lib/fermix_core/computer_use/protocol.ex` (one request line in
on stdin, one response line out on stdout).

It is a standalone binary, **not** a Rustler NIF — it runs as a separate OS
process so a crash in native GUI code can't take down the BEAM, and so it can be
distributed/installed independently.

> **Status: v1, unverified.** It compiles against the crate APIs pinned in
> `Cargo.toml`; adjust if a crate's API has shifted on your first build. Screen
> capture + input injection require macOS TCC grants and must be verified on a
> real machine (see Permissions).

## Build (the dev loop)

```sh
cd native/computer-use-sidecar
cargo build --release
# → target/release/fermix-computer-use
```

## Local testing via `dev_local`

Fermix resolves the sidecar binary from a `dev_local` checkout before any
installed/catalog copy (`ComputerUse.SidecarInstaller.binary_path/0`). To run the
real feature from a local build:

1. Pick a dev folder and point config at it — in `$FERMIX_HOME/config.toml`:

   ```toml
   [fermix_core.plugins]
   dev_local = "/abs/path/to/dev-plugins"
   ```

2. Place the built binary at the host-target path (the `<os>-<arch>` string is
   `macos-aarch64`, `macos-x86_64`, `linux-x86_64`, or `linux-aarch64`):

   ```sh
   mkdir -p /abs/path/to/dev-plugins/computer-use-sidecar/bin/macos-aarch64
   cp target/release/fermix-computer-use \
      /abs/path/to/dev-plugins/computer-use-sidecar/bin/macos-aarch64/fermix-computer-use
   chmod 0755 /abs/path/to/dev-plugins/computer-use-sidecar/bin/macos-aarch64/fermix-computer-use
   ```

   (Optional: add a `plugin.json` next to `bin/` — `{"name":"computer-use-sidecar","version":"0.1.0-dev","plugin_api":2,"tools":[]}` — if you also want it to show as a loaded dev_local plugin in the registry. It is **not** required for the binary to be found.)

3. Restart the daemon, enable Computer Use, grant permissions (below). `ready?`
   then resolves this binary.

## Permissions (macOS)

The helper cannot capture the screen or inject input without two TCC grants the
user approves once in **System Settings → Privacy & Security**:

- **Screen Recording** — without it, capture silently returns wallpaper only.
- **Accessibility** — without it, synthetic mouse/keyboard events are silently
  dropped.

Both bind to the **code-signing identity** of the process that prompts, so a
stable signed identity matters across rebuilds.

## Production distribution

End users never build this. CI builds the per-target binaries, code-signs +
**notarizes** them (Apple notary, so Gatekeeper allows the spawn), cosign-signs
the tarballs, and either publishes them to a release (the daemon lazily
downloads + verifies + installs on enable — see the `computer-use-sidecar`
catalog entry in `apps/fermix_core/priv/plugins/index.json`) or bundles them in
the Fermix release package. The lazy-download path keeps the input-injecting
binary off disk until the user opts in.

## Protocol

One JSON object per line. Requests carry `action` plus its args; responses carry
`ok: true` (+ a screenshot payload for `screenshot`/post-action) or
`ok: false, error: "..."`. Actions: `screenshot`, `mouse_move`, `left_click`,
`right_click`, `double_click`, `left_click_drag`, `scroll`, `type`, `key`,
`wait`. Coordinates are pixels in the most recent screenshot's space; the sidecar
maps them to logical display points (Retina-aware). See `src/main.rs` and
`protocol.ex` for the exact shapes.
