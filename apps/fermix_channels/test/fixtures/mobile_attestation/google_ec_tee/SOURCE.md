# Google sample attestation chain (EC key, TEE)

A real key attestation chain recorded by Google from a phone, carried here so
`FermixChannels.Mobile.AttestationTest` can prove the KeyDescription reader
decodes a real extension (high-tag-number entries, the software-enforced
application id) and that a chain presenting the 2016 certificate of Google's
RSA attestation root validates against the pinned 2022 certificate of the
same key. Its attestation version is 3: it was written by Keymaster 3, before
KeyMint (version 100 and later), in the format KeyMint kept.

- Source: https://github.com/google/android-key-attestation
- Commit: f9846cd019289f1788cec65b062d9f81c0c4884c (2025-06-11)
- Path: `src/test/resources/der/algorithm_EC_SecurityLevel_TEE/cert0.der` to `cert3.der`, leaf first
- Licence: Apache License 2.0, copied beside these files as `LICENSE`
- Fetched: 2026-10-11

| File | SHA-256 |
|---|---|
| cert0.der | bf0d7c4e16403bab1e04d76e5880315369786dcdae4e452ee32f986df0e95b32 |
| cert1.der | e537905ef02c970052ff5b7a333294d25df41154457a89cd880bc603768e3579 |
| cert2.der | 230f39bfd49ea76a8aab2ee9e2cb7176bd4125eca640828930a27fa5c27033e1 |
| cert3.der | c1984a3ef45c1e2a918551de10603c86f7051b2249c4891cae3230eabd0c97d5 |

The leaf's key is P-256 and its attestation is Keymaster's, so the pairing
verifier refuses the chain at the key check, as it should: it is a sample of
the format, not a phone that can pair.
