# --- dev: source is mounted from the host, code and assets reload in place -----
# Comes first on purpose: `docker build .` with no --target must keep producing
# the production image, which is the last stage of this file.
FROM hexpm/elixir:1.20.3-erlang-29.0.5-alpine-3.24.1 AS dev

# MIX_ENV fica sem valor de propósito: o Mix assume `dev` sozinho e `mix test`
# assume `test`, então `docker compose exec app mix test` funciona sem prefixo.

WORKDIR /app

# inotify-tools backs the file watchers; the others build the native deps.
RUN apk add --no-cache build-base git inotify-tools
RUN mix local.hex --force && mix local.rebar --force

EXPOSE 4000

CMD ["mix", "phx.server"]

# --- builder: compiles assets and assembles the Elixir release -----------------
FROM hexpm/elixir:1.20.3-erlang-29.0.5-alpine-3.24.1 AS builder

ENV MIX_ENV=prod

WORKDIR /app

RUN apk add --no-cache build-base git
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod && mix deps.compile

COPY config config
COPY priv priv
COPY assets assets
COPY lib lib

# Compile first: Phoenix 1.8 writes colocated hooks and CSS into _build during
# compilation, and the asset pipeline imports them.
RUN mix compile
RUN mix assets.deploy
RUN mix release

# --- runtime: no Elixir, no source code ---------------------------------------
FROM python:3-alpine AS app

# `ca-certificates` is what makes a verified TLS connection to an SMTP provider
# possible at all: without a trust store, `verify_peer` has nothing to verify
# against and the alternative is accepting any certificate (R07).
RUN apk add --no-cache libstdc++ openssl ncurses-libs libgcc ca-certificates

ENV LANG=C.UTF-8 \
    PHX_SERVER=true

WORKDIR /app

RUN adduser -D -h /app live_quiz
COPY --from=builder --chown=live_quiz:live_quiz /app/_build/prod/rel/live_quiz ./
USER live_quiz

EXPOSE 4000

CMD ["bin/live_quiz", "start"]
