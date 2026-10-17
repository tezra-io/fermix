# The Fermix kit image (M64): the sbx shell template plus the signed release
# package and the Caddy binary that fetch_packages.sh verified, for the
# architecture being built.
# The sbx shell template, pinned; move the digest on purpose.
FROM docker/sandbox-templates:shell@sha256:c66aa9c0212bb710089cc356501f8bde8989e02a7071bf1c6be0893be1c30adf

ARG TARGETARCH
USER root
COPY fermix_${TARGETARCH}.deb /tmp/fermix.deb
RUN apt-get install -y --no-install-recommends /tmp/fermix.deb && rm /tmp/fermix.deb
COPY --chmod=0755 fermix-sandbox-boot fermix-sandbox-loop fermix-sandbox-relay fermix-sandbox-session /usr/lib/fermix/sandbox/
COPY --chmod=0755 caddy_${TARGETARCH} /usr/lib/fermix/sandbox/caddy
COPY --chmod=0644 fermix-relay.Caddyfile /usr/lib/fermix/sandbox/

USER agent

# sbx runs this per session: headless it follows the daemon log, and the
# kit's `interactive: [--shell]` tail opens a login shell instead.
ENTRYPOINT ["/usr/lib/fermix/sandbox/fermix-sandbox-session"]
CMD []
