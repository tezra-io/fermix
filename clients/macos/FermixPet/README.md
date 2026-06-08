# FermixPet

FermixPet is the source-build macOS companion for Fermix Realtime voice.

V1 posture:

- Build locally from source with Xcode or `swift build`.
- The app connects only to the local Fermix daemon socket. By default that is
  `~/.fermix/realtime.sock`; set `FERMIX_HOME` or `FERMIX_REALTIME_SOCKET` for
  dev homes such as `~/.fermix-dev`.
- The OpenAI API key stays in the Fermix daemon. Realtime voice requires a real
  OpenAI **Platform** API key (`sk-...`, with billing/Realtime access) configured
  in the daemon — a ChatGPT/Codex OAuth login does **not** authorize Realtime.
- Capture starts only after the user opens a local call. While the call is
  open, the mic streams continuously and OpenAI server VAD owns turn
  boundaries. There is no always-listening mode when no call is open.
- Transcript persistence is controlled by Fermix setup, not by this client.
- The visible pet is a transparent mascot surface; controls appear on hover.

Install the app:

```sh
cd clients/macos/FermixPet
./script/build_and_run.sh install
open "$HOME/Applications/FermixPet.app"
```

When testing against a dev daemon:

```sh
FERMIX_HOME=$HOME/.fermix-dev ./script/build_and_run.sh
```

Use the script instead of `swift run FermixPet` for normal GUI testing. It
builds with SwiftPM under `~/Library/Caches/io.tezra.FermixPet`, stages a
proper `.app` bundle, and installs to `~/Applications/FermixPet.app` when run
with `install`. Dock, Quit, microphone permissions, and app identity use the
FermixPet bundle metadata.

On first listen, macOS should prompt for microphone access. If it was denied
previously, enable `FermixPet` in System Settings -> Privacy & Security ->
Microphone, or reset the prompt with:

```sh
tccutil reset Microphone io.tezra.FermixPet
```

Close the app by right-clicking the pet and choosing `Quit FermixPet`.

If the pet flickers to `listening` and immediately drops back to idle/offline,
or the mic indicator seems stuck, the daemon usually can't open the Realtime
session — most often an invalid or missing OpenAI Platform API key. Check it
with:

```sh
fermix voice status
```

A `setup_required` status (or `invalid_api_key` in `~/.fermix/logs/fermix.log`)
means the key is the problem, not the app. Rebuilding/reinstalling the app
changes its ad-hoc code signature, so macOS may re-prompt for microphone
access — re-grant it, or run the `tccutil reset` command above.

For early shared builds, ad-hoc signing is acceptable. If Gatekeeper quarantines
a local build, remove quarantine before launching:

```sh
xattr -dr com.apple.quarantine FermixPet.app
```

Developer ID signing and notarization are release-packaging work outside the
first local validation milestone.
