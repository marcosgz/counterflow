# Multi-stage build: compile a mix release in the builder stage, copy the
# self-contained tarball into a tiny runtime image. Two-stage keeps the
# final image at ~70MB instead of ~1GB.

ARG ELIXIR_VERSION=1.19.5
ARG OTP_VERSION=28.5
ARG DEBIAN_VERSION=bookworm-20250630-slim

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ── builder ──────────────────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y && \
    apt-get install -y build-essential git curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Hex + Rebar
RUN mix local.hex --force && mix local.rebar --force

ENV MIX_ENV="prod"

# Dependencies first (better layer caching)
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mkdir config

COPY config/config.exs config/${MIX_ENV}.exs config/
RUN mix deps.compile

# App source
COPY priv priv
COPY lib lib
COPY assets assets

# Asset pipeline (esbuild + tailwind)
RUN mix assets.deploy

# Compile + assemble
RUN mix compile
COPY config/runtime.exs config/
COPY rel rel
RUN mix release

# ── runtime ──────────────────────────────────────────────────
FROM ${RUNNER_IMAGE} AS runner

RUN apt-get update -y && \
    apt-get install -y libstdc++6 openssl libncurses5 locales ca-certificates curl && \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# UTF-8 locale
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 LANGUAGE=en_US:en LC_ALL=en_US.UTF-8

WORKDIR /app
RUN useradd --create-home --shell /bin/bash counterflow && \
    chown counterflow:counterflow /app
USER counterflow

COPY --from=builder --chown=counterflow:counterflow /app/_build/prod/rel/counterflow ./

ENV HOME=/app

# Healthcheck — the Phoenix endpoint must respond on /
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD curl -f http://localhost:4000/login || exit 1

EXPOSE 4000

CMD ["/app/bin/server"]
