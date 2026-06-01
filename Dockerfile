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
FROM hexpm/elixir:1.19.5-erlang-28.5.0.1-alpine-3.21.7 AS builder

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
FROM alpine:3.21.7 AS runtime

# Runtime dependencies: SQLite (backup/restore), libstdc++ (ERTS), ncurses, bash, openssl
RUN apk add --no-cache \
  bash \
  libstdc++ \
  ncurses-libs \
  sqlite \
  openssl \
  curl \
  ca-certificates

# Create non-root user (UID 10001 to avoid conflicts with host UIDs)
RUN addgroup -g 10001 you && \
    adduser -D -u 10001 -G you you

# Create data and log directories with world-writable perms
# (these are typically volume mounts; 777 ensures any UID can write)
RUN mkdir -p /data/you /var/log/you && \
    chmod 777 /data/you /var/log/you

# Copy only the release artifact — no source code
COPY --from=builder /app/_build/prod/rel/you /app
RUN chown -R you:you /app

WORKDIR /app

EXPOSE 4000

ENV PORT=4000
ENV PHX_SERVER=true

HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD pgrep -f "beam.smp" > /dev/null || exit 1

USER you

ENTRYPOINT ["/app/bin/you"]
CMD ["start"]
