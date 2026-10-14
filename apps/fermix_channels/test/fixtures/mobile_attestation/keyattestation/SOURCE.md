# Real phones' attestation chains from Google's keyattestation library

Chains recorded from real phones, with the values Google's library decoded
from each (`.json`), carried here so `FermixChannels.Mobile.AttestationTest`
proves the pairing verifier against chains it did not make: each passes the
chain check against the pinned roots in
`fermix_core/priv/mobile/attestation_roots.json` and decodes to what its
`.json` records, then is refused at the key check, since its key is EC P-256,
not the X25519 key a pairing attests. The two `invalid/` chains are Google's
samples of encodings its own parser accepts.

- Source: https://github.com/android/keyattestation
- Commit: 3f550f94a9e3c010dda7cdcad8bca764cd76d4f4
- Paths: `testdata/` + each path below, kept as it is there; PEM chains are leaf first
- Licence: Apache License 2.0, copied beside these files as `LICENSE`
- Fetched: 2026-10-11

| File | What it is | SHA-256 |
|---|---|---|
| `caiman/sdk36/TEE_EC_RKP.pem` | a Pixel 9 Pro, attestation version 400, TEE, remotely provisioned (five certificates, the RKP device certificate valid 2025-09-24 to 2025-10-03), to the 2019 certificate of Google's RSA root | 6194cd75cea7bb635d898be13cb72880771f7192f90fa9507279c95c86a395ec |
| `caiman/sdk36/TEE_EC_RKP.json` | its decoded values | e57a296d341c74a37ec51c96a0cbd08748172c21b355c4023b3f4ccdd3b6f2cb |
| `frankel/sdk37/TEE_EC_2026.pem` | attestation version 500, TEE, remotely provisioned (five certificates, the device certificate valid 2026-09-02 to 2026-09-15), to Key Attestation CA1 | 3c9c036500a6d3e07907ebd418b5bd4c4dbf61e62abec63dae7198050ed9a54e |
| `frankel/sdk37/TEE_EC_2026.json` | its decoded values | bd20ec9fc7ed78a137be7c81443adf57aaddfc7a974d3255e53b013962240116 |
| `invalid/malformed_rot_device_locked.pem` | attestation version 3 (Keymaster), `deviceLocked` written as BOOLEAN `0x01` instead of DER's `0xFF`; read as true, as Google's verifier reads it | 24e848f2f6e0800fbc3cf4aba1a8d8353bb2180377a2b45ac97354d0991c8975 |
| `invalid/tags_not_in_ascending_order.pem` | attestation version 300, the hardware-enforced list giving tag 2 before tag 1; read by tag, as Google's default verifier reads it. Its leaf was edited after it was signed, so its signature does not verify (openssl agrees, and Google's CLI test expects it to fail): the chain is refused with `invalid_signature` | 1c197efacf1e0ca712ca5bf6d697930a5b9fb05ac7744053afcb8522890a16a3 |
| `LICENSE` | the repository's licence | cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30 |
