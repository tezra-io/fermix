# FermixPet

FermixPet is the source-build macOS companion for Fermix Realtime voice.

V1 posture:

- Build locally from source with Xcode or `swift build`.
- The app connects only to the local Fermix daemon socket. By default that is
  `~/.fermix/realtime.sock`; set `FERMIX_HOME` or `FERMIX_REALTIME_SOCKET` for
  dev homes such as `~/.fermix-dev`.
- The OpenAI API key stays in the Fermix daemon.
- Capture is click-to-talk or click-toggle only. There is no always-listening mode.
- Transcript persistence is controlled by Fermix setup, not by this client.
- The visible pet is a transparent mascot surface; controls appear on hover.

Run from source:

```sh
cd clients/macos/FermixPet
swift run FermixPet
```

When testing against a dev daemon:

```sh
FERMIX_HOME=/Users/sujshe/.fermix-dev swift run FermixPet
```

On first listen, macOS should prompt for microphone access. If it was denied
previously, enable `FermixPet` in System Settings -> Privacy & Security ->
Microphone, or reset the prompt with:

```sh
tccutil reset Microphone io.tezra.FermixPet
```

Close the source-run app from the hover `xmark` button, or right-click the pet
and choose `Quit FermixPet`. `Ctrl-C` in the launch terminal still works.

For early shared builds, ad-hoc signing is acceptable. If Gatekeeper quarantines
a local build, remove quarantine before launching:

```sh
xattr -dr com.apple.quarantine FermixPet.app
```

Developer ID signing and notarization are release-packaging work outside the
first local validation milestone.
