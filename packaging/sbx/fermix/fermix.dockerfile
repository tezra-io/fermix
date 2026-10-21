# syntax=docker/dockerfile:1.7
# Content for the `fermix` workload kit: the sbx shell template plus the signed
# Fermix release package, the Caddy binary the provider relay runs, and the
# kit's scripts under /usr/lib/fermix/sandbox.

# The base floats on purpose, as the other kits here do, so a nightly rebuild
# picks up template fixes. The Fermix version is pinned by the kit's
# `args.version`, handed in as FERMIX_VERSION.
ARG BASE_IMAGE=docker/sandbox-templates:shell

# cosign only checks the downloads in the fetch stage and never reaches the
# kit's content. v2.5.2 is the version Fermix's release workflow signs with.
FROM ghcr.io/sigstore/cosign/cosign:v2.5.2@sha256:23d07b53d59a1233e1ab5e7d082cf4182fc90067d2f86a662ba3003215cb0c95 AS cosign

FROM ${BASE_IMAGE} AS fetch
ARG FERMIX_VERSION
ARG TARGETARCH
USER root
COPY --from=cosign /ko-app/cosign /usr/local/bin/cosign
COPY files/build/fetch-verified.sh /usr/local/bin/fetch-verified.sh
RUN sh /usr/local/bin/fetch-verified.sh "${FERMIX_VERSION}" "${TARGETARCH}" /out

FROM ${BASE_IMAGE}
# Re-declared inside the stage: an ARG defined before the first FROM is visible
# only to FROM lines.
ARG BASE_IMAGE
ARG FERMIX_VERSION
USER root

# The package depends on nothing, so dpkg installs it without an apt index.
COPY --from=fetch /out/fermix.deb /tmp/fermix.deb
RUN dpkg -i /tmp/fermix.deb && rm /tmp/fermix.deb

# The provide is a claim about content, so the build re-reads the installed
# package's version and fails on a mismatch.
RUN installed="$(dpkg-query -W -f='${Version}' fermix)" && \
    if [ "$installed" != "${FERMIX_VERSION}" ]; then \
      echo "the kit pins Fermix ${FERMIX_VERSION}, but ${installed} is installed" >&2; exit 1; \
    fi

# Root-owned like the scripts beside it: the tarball's own owner would
# otherwise ride along from the fetch stage.
COPY --from=fetch --chown=root:root --chmod=0755 /out/caddy /usr/lib/fermix/sandbox/caddy
COPY --chmod=0755 files/sandbox/fermix-sandbox-boot files/sandbox/fermix-sandbox-loop files/sandbox/fermix-sandbox-relay files/sandbox/fermix-sandbox-session /usr/lib/fermix/sandbox/
COPY --chmod=0644 files/sandbox/fermix-relay.Caddyfile /usr/lib/fermix/sandbox/

# sbx reads `flavor` as the agent's name; inherited, it would name the base
# template. `base` records what this content was built on.
LABEL com.docker.sandboxes.flavor="fermix"
LABEL com.docker.sandboxes.base="${BASE_IMAGE}"

USER agent
# sbx runs this per session: headless it follows the daemon log, and the kit's
# `lifecycle@1` interactive tail (--shell) opens a login shell instead.
ENTRYPOINT ["/usr/lib/fermix/sandbox/fermix-sandbox-session"]
