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
FROM alpine:3.24 AS app

RUN apk add --no-cache libstdc++ openssl ncurses-libs libgcc

ENV LANG=C.UTF-8 \
    PHX_SERVER=true

WORKDIR /app

RUN adduser -D -h /app live_quiz
COPY --from=builder --chown=live_quiz:live_quiz /app/_build/prod/rel/live_quiz ./
USER live_quiz

EXPOSE 4000

CMD ["bin/live_quiz", "start"]
