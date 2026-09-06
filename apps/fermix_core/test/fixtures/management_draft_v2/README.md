# The macOS app's draft v2 management contract

These five files are **the application's**, not this repository's. They are a
byte-identical copy of

    fermix-macos:Apps/Fermix/Sources/FermixAppCore/Resources/Contracts/management-draft-v2/

together with that repository's `SOURCE.json`, which records the digest of each
one. The app authored them from the M34 native setup design while this engine
still published protocol 1, and it is built against them today.

**They are never this engine's truth.** The canonical contract is
`apps/fermix_core/priv/management/`, generated from and pinned to
`FermixCore.Management.Protocol` by `protocol_contract_test.exs`. Nothing in the
daemon reads this directory; only `draft_parity_test.exs` does, and only to
replay the app's frames through the live router and name every place the two
disagree.

## Why they are here

The app cannot delete its draft and re-vendor the engine's export until someone
has read both against each other. `divergences.json` beside this file is that
reading: one entry per method and field where the engine deliberately answers
something other than what the app drew, each with the reason. The parity test
asserts the found set and the recorded set are **equal**, so a new disagreement
fails the suite and a disagreement that has since been resolved fails it too
rather than lingering as folklore.

## Their expiry

When the app re-vendors (`verify_protocol_contract.sh --source`), it deletes its
draft and its `SOURCE.json` record in the same change. This copy, this README,
`divergences.json` and `draft_parity_test.exs` go with it: there is nothing left
to compare, and a parity test against a contract nobody ships is a test that can
only report on itself.

## Do not edit them

Edit them and the digests in `SOURCE.json` stop matching, which the parity test
fails on first. If the app changes its draft, re-copy all five and re-run the
parity test; the divergence list is the output, not the input.
