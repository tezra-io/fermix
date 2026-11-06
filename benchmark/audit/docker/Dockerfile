FROM elixir:1.19.5-otp-28@sha256:d170fadffd75b36146ff40b6e8d5cc881c59d136ae5a2c34a1b394ec33b6cffa
ENV DEBIAN_FRONTEND=noninteractive MIX_ENV=dev HOME=/home/audit FERMIX_HOME=/home/audit/fermix FERMIX_BROWSER_HEADLESS=1
RUN apt-get update && apt-get install -y --no-install-recommends chromium python3 git build-essential ca-certificates && rm -rf /var/lib/apt/lists/*
RUN useradd -m -u 10001 audit && mkdir -p /src /home/audit/fermix && chown audit:audit /src /home/audit/fermix
WORKDIR /src
COPY --chown=audit:audit . /src/
USER audit
RUN mix local.hex --force && mix local.rebar --force && mix deps.get && mix compile --warnings-as-errors
CMD ["mix", "fermix.dev", "--no-web", "--no-realtime"]
