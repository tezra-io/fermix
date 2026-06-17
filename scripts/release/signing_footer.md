### Verifying signatures

Each binary is signed with [cosign](https://docs.sigstore.dev/cosign/overview/) using GitHub Actions OIDC keyless signing. Verify a download with:

```bash
cosign verify-blob \
  --certificate fermix_<target>.pem \
  --signature  fermix_<target>.sig \
  --certificate-identity-regexp "https://github.com/__REPO__/.github/workflows/release.yml@.*" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  fermix_<target>
```

The `releases.json` artifact lists every binary's URL, sha256, and signature URLs.
