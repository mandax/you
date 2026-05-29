# =============================================================================
# You IAM — Dockerfile (multi-stage, production)
#
# Builds an Elixir release containing only the compiled binary, ERTS,
# and runtime config — no source code leaks into the final image.
#
# Usage:
#   docker build -t you:latest .
#
#   docker run -d \
#     -e DATABASE_PATH=/data/you/prod.db \
#     -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
#     -e PHX_HOST=you.example.com \
#     -v you-data:/data/you \
#     -p 4000:4000 \
#     you:latest
#
#   # Run migrations
#   docker exec <container> bin/migrate
#
#   # Bootstrap admin
#   docker exec <container> bin/you eval 'You.Release.bootstrap_admin("admin@example.com", "password")'
# =============================================================================

# ---- Build stage ----
FROM hexpm/elixir:1.19.5-erlang-29.0.1-alpine-3.21 AS builder

RUN apk add --no-cache build-base git

WORKDIR /app

# Install Hex + Rebar (cached)
RUN mix local.hex --force && mix local.rebar --force

# Fetch dependencies (cached by mix.exs/mix.lock checksum)
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Copy the rest of the application
COPY lib lib
COPY priv priv
COPY config config
COPY rel rel

# Compile and build the release
RUN MIX_ENV=prod mix compile
RUN MIX_ENV=prod mix phx.digest
RUN MIX_ENV=prod mix release

# ---- Runtime stage ----
FROM alpine:3.21 AS runtime

# Runtime dependencies: SQLite (backup/restore), libstdc++ (ERTS), ncurses, bash, openssl
RUN apk add --no-cache \
  bash \
  libstdc++ \
  ncurses-libs \
  sqlite \
  openssl

# Create data and log directories
RUN mkdir -p /data/you /var/log/you

# Copy only the release artifact — no source code
COPY --from=builder /app/_build/prod/rel/you /app

WORKDIR /app

EXPOSE 4000

ENV PORT=4000
ENV PHX_SERVER=true

ENTRYPOINT ["/app/bin/you"]
CMD ["start"]
