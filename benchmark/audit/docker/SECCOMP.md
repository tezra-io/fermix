Docker seccomp profile vendored verbatim from Microsoft Playwright:
https://github.com/microsoft/playwright/blob/main/utils/docker/seccomp_profile.json
Git blob: fddc05fb520affb145404e6f6f647ca96af8087d
SHA-256: cc3e61cabda6bbc1e53e54d27ba4d55a9d3be829b6dd1a596f4a7b31b1cc7849
Playwright is licensed under Apache-2.0: https://github.com/microsoft/playwright/blob/main/LICENSE
The profile preserves Docker's default-deny policy and allows clone, setns, and unshare for Chromium's sandbox.

`seccomp_audit.json` derives from that profile by appending exactly one rule:
`{"names": ["chroot"], "action": "SCMP_ACT_ALLOW", "args": []}`.
SHA-256: b92c943ef4ab081a0fd6ce9fd553f9d8e1775ce64420243190694fa4811aa880.
This is needed for Chromium's user-namespace sandbox. The container drops all
capabilities and uses no-new-privileges; kernel capability checks still apply.
