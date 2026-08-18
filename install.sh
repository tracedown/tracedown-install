#!/usr/bin/env bash
# Tracedown installer — https://tracedown.dev
#
#   curl -fsSL https://tracedown.dev/install.sh | bash
#
# Interactive: prompts come from the terminal even when the script itself is
# piped in. Every prompt can be pre-answered with a TD_* environment variable
# (named next to each prompt below) for unattended installs.
#
# Three things it can do:
#   1) Monolith     — the whole platform in one container, plus Postgres and
#                     Redis. The smallest real installation.
#   2) Full stack   — the per-service deployment from the published release
#                     artifacts (the docker/deploy stack: 11 containers).
#   3) Probe agent  — mint a bootstrap token on an existing full stack and
#                     connect an agent to it.
#
# Everything lands in a directory you choose; nothing outside it is touched
# apart from Docker resources. Re-running is safe: it refuses to clobber an
# existing installation without asking.

set -euo pipefail

BACKEND_REPO="tracedown/tracedown-core-backend"
AGENT_IMAGE_DEFAULT="tracedown/tracedown-probe-agent:latest"
DOCS="https://tracedown.dev"

# ── console helpers ──────────────────────────────────────────────────────────

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

# Prompts must reach the terminal even under `curl | bash` (stdin is the
# script). Pre-answered prompts (TD_* env) never need a terminal at all.
if [ -t 0 ]; then TTY=/dev/stdin; elif [ -e /dev/tty ]; then TTY=/dev/tty; else TTY=""; fi

# prompt VAR "question" "default"
prompt() {
  local var="$1" q="$2" def="${3-}" cur val
  cur="$(eval "printf '%s' \"\${$var-}\"")"
  if [ -n "$cur" ]; then return 0; fi          # pre-answered via environment
  [ -n "$TTY" ] || die "No terminal for prompts — pre-answer with $var=... (see script header)."
  if [ -n "$def" ]; then
    printf '%s [%s]: ' "$q" "$def" > /dev/tty 2>/dev/null || printf '%s [%s]: ' "$q" "$def"
  else
    printf '%s: ' "$q" > /dev/tty 2>/dev/null || printf '%s: ' "$q"
  fi
  IFS= read -r val < "$TTY"
  eval "$var=\"\${val:-\$def}\""
}

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required. Install it and re-run."; }

hex32() { openssl rand -hex 32; }
b64secret() { openssl rand -base64 48 | tr -d '\n'; }

latest_backend_version() {
  curl -fsSL "https://api.github.com/repos/${BACKEND_REPO}/releases/latest" \
    | grep -o '"tag_name": *"v[^"]*"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/'
}

wait_for_ping() { # wait_for_ping <url> <seconds>
  local url="$1" budget="$2" waited=0
  say "Waiting for the stack to come up (${url}) ..."
  until curl -fsS -o /dev/null "$url" 2>/dev/null; do
    sleep 3; waited=$((waited + 3))
    if [ "$waited" -ge "$budget" ]; then
      warn "Not healthy after ${budget}s. It may still be starting — check: docker compose ps / docker compose logs"
      return 1
    fi
  done
  say "Healthy."
}

# Email decides the security posture: with a real provider the stack runs
# DEPLOYMENT_ENV=production (startup guards armed); without one it must not
# claim production — the platform (correctly) refuses console mail there.
# Sets: TD_EMAIL_MODE (smtp|none) and, for smtp, the TD_SMTP_* answers.
prompt_email() {
  prompt TD_EMAIL_MODE "Email delivery — 'smtp' now, or 'none' for now (mail stays in logs)" "none"
  case "$TD_EMAIL_MODE" in
    smtp)
      prompt TD_SMTP_HOST "SMTP host" ""
      [ -n "$TD_SMTP_HOST" ] || die "SMTP host is required for smtp mode."
      prompt TD_SMTP_PORT     "SMTP port"     "587"
      prompt TD_SMTP_USERNAME "SMTP username" ""
      prompt TD_SMTP_PASSWORD "SMTP password" ""
      prompt TD_EMAIL_FROM    "From address"  "notifications@$(printf '%s' "$TD_SMTP_HOST" | sed 's/^smtp\.//')"
      ;;
    none) ;;
    *) die "Unknown email mode '$TD_EMAIL_MODE' (expected smtp or none)." ;;
  esac
}

confirm_dir() { # confirm_dir <path>
  if [ -e "$1" ] && [ -n "$(ls -A "$1" 2>/dev/null)" ]; then
    local go=""
    TD_OVERWRITE="${TD_OVERWRITE-}"
    if [ -n "$TD_OVERWRITE" ]; then go="$TD_OVERWRITE"; else
      prompt go "Directory $1 is not empty. Continue and reuse it? (yes/no)" "no"
    fi
    case "$go" in y|yes|Y|YES) ;; *) die "Aborted — choose another directory." ;; esac
  fi
  mkdir -p "$1"
}

# ── mode 1: monolith ─────────────────────────────────────────────────────────

install_monolith() {
  say "Monolith: the whole platform in one container, plus Postgres and Redis."

  prompt TD_DIR      "Install directory"                        "$HOME/tracedown"
  prompt TD_VERSION  "Backend version (or 'latest')"            "latest"
  prompt TD_GATEWAY_PORT  "Gateway port (dashboard + API)"      "20714"
  prompt TD_REALTIME_PORT "WebSocket port"                      "20870"
  prompt TD_DEMO_EMAIL    "Admin login email"                   "admin@tracedown.dev"
  prompt TD_DEMO_PASSWORD "Admin login password"                "Down2trace!"
  prompt_email

  [ "$TD_VERSION" = "latest" ] && TD_VERSION="$(latest_backend_version)"
  [ -n "$TD_VERSION" ] || die "Could not resolve the latest release."
  confirm_dir "$TD_DIR"; cd "$TD_DIR"

  say "Fetching tracedown-monolith ${TD_VERSION} ..."
  curl -fsSL -o monolith.jar \
    "https://github.com/${BACKEND_REPO}/releases/download/v${TD_VERSION}/tracedown-monolith-${TD_VERSION}-all.jar"

  if [ ! -f .env ]; then
    say "Generating secrets (.env) ..."
    cat > .env <<ENV
# Generated by install.sh — keep this file safe.
# PLATFORM_AES_KEY is permanent: it encrypts stored secrets and cannot be
# rotated; losing it orphans that data. Back it up separately from the database.
PLATFORM_AES_KEY=$(hex32)
JWT_SECRET=$(b64secret)
DB_PASSWORD=$(openssl rand -hex 16)
GATEWAY_PORT=${TD_GATEWAY_PORT}
REALTIME_PORT=${TD_REALTIME_PORT}
DEMO_USER_EMAIL=${TD_DEMO_EMAIL}
DEMO_USER_PASSWORD=${TD_DEMO_PASSWORD}
ENV
    if [ "$TD_EMAIL_MODE" = "smtp" ]; then
      cat >> .env <<ENV
DEPLOYMENT_ENV=production
EMAIL_PROVIDER=smtp
EMAIL_FROM_ADDRESS=${TD_EMAIL_FROM}
SMTP_HOST=${TD_SMTP_HOST}
SMTP_PORT=${TD_SMTP_PORT}
SMTP_USERNAME=${TD_SMTP_USERNAME}
SMTP_PASSWORD=${TD_SMTP_PASSWORD}
EMAIL_SMTP_HOST=${TD_SMTP_HOST}
EMAIL_SMTP_PORT=${TD_SMTP_PORT}
EMAIL_SMTP_USERNAME=${TD_SMTP_USERNAME}
EMAIL_SMTP_PASSWORD=${TD_SMTP_PASSWORD}
ENV
    else
      cat >> .env <<'ENV'
# No email provider yet: mail stays in the container logs, and the stack runs
# WITHOUT the production startup guards (the platform refuses console mail in
# production). Before real users: configure SMTP here and set
# DEPLOYMENT_ENV=production, then `docker compose up -d`.
EMAIL_PROVIDER=console
ENV
    fi
    chmod 600 .env
  else
    note "Reusing existing .env"
  fi

  cat > docker-compose.yml <<'YML'
# Tracedown monolith — generated by install.sh. `docker compose up -d` here.
name: tracedown-monolith

services:
  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: tracedown
      POSTGRES_USER: tracedown
      POSTGRES_PASSWORD: ${DB_PASSWORD}
    volumes: [pgdata:/var/lib/postgresql/data]
    restart: unless-stopped

  redis:
    image: redis:7-alpine
    command: ["redis-server", "--appendonly", "yes"]
    volumes: [redisdata:/data]
    restart: unless-stopped

  monolith:
    image: eclipse-temurin:17-jre
    command: ["java", "-jar", "/tracedown/monolith.jar"]
    volumes:
      - ./monolith.jar:/tracedown/monolith.jar:ro
      - bodies:/data/bodies
    environment:
      DATABASE_URL: jdbc:postgresql://postgres:5432/tracedown
      DATABASE_USER: tracedown
      DATABASE_PASSWORD: ${DB_PASSWORD}
      REDIS_A_URL: redis://redis:6379
      PLATFORM_AES_KEY: ${PLATFORM_AES_KEY}
      JWT_SECRET: ${JWT_SECRET}
      # Everything below passes through from .env — edit there, `up -d` again.
      DEPLOYMENT_ENV: ${DEPLOYMENT_ENV:-}
      EMAIL_PROVIDER: ${EMAIL_PROVIDER:-console}
      EMAIL_FROM_ADDRESS: ${EMAIL_FROM_ADDRESS:-}
      SMTP_HOST: ${SMTP_HOST:-}
      SMTP_PORT: ${SMTP_PORT:-587}
      SMTP_USERNAME: ${SMTP_USERNAME:-}
      SMTP_PASSWORD: ${SMTP_PASSWORD:-}
      EMAIL_SMTP_HOST: ${EMAIL_SMTP_HOST:-}
      EMAIL_SMTP_PORT: ${EMAIL_SMTP_PORT:-587}
      EMAIL_SMTP_USERNAME: ${EMAIL_SMTP_USERNAME:-}
      EMAIL_SMTP_PASSWORD: ${EMAIL_SMTP_PASSWORD:-}
      WS_URL: ${WS_URL:-}
      APP_URL: ${APP_URL:-}
      STORAGE_FILESYSTEM_ROOT: /data/bodies
      DEMO_USER_EMAIL: ${DEMO_USER_EMAIL}
      DEMO_USER_PASSWORD: ${DEMO_USER_PASSWORD}
    ports:
      - "127.0.0.1:${GATEWAY_PORT}:20714"
      - "127.0.0.1:${REALTIME_PORT}:20870"
    depends_on: [postgres, redis]
    restart: unless-stopped

volumes:
  pgdata:
  redisdata:
  bodies:
YML

  say "Starting (docker compose up -d) ..."
  docker compose up -d
  wait_for_ping "http://127.0.0.1:${TD_GATEWAY_PORT}/ping" 180 || true

  say "Done."
  note "Dashboard:  http://127.0.0.1:${TD_GATEWAY_PORT}  (log in as ${TD_DEMO_EMAIL})"
  note "Both ports bind 127.0.0.1 only — put your web server in front for the"
  note "network: proxy / to ${TD_GATEWAY_PORT} and /ws (WebSocket) to ${TD_REALTIME_PORT},"
  note "and set WS_URL=/ws in .env so the dashboard connects same-origin."
  note "Docs: ${DOCS}/install/monolith/"
}

# ── mode 2: full per-service stack ───────────────────────────────────────────

install_full() {
  say "Full stack: the per-service deployment from published release artifacts."

  prompt TD_DIR      "Install directory"             "$HOME/tracedown"
  prompt TD_VERSION  "Backend version (or 'latest')" "latest"
  prompt TD_APP_URL  "Public base URL (what users' browsers will reach)" "https://tracedown.example.com"
  prompt TD_DEMO_EMAIL    "Admin login email"        "admin@tracedown.dev"
  prompt TD_DEMO_PASSWORD "Admin login password"     ""
  [ -n "$TD_DEMO_PASSWORD" ] || die "An admin password is required for the production stack."
  prompt_email

  local tag="$TD_VERSION"
  [ "$tag" = "latest" ] && tag="$(latest_backend_version)"
  [ -n "$tag" ] || die "Could not resolve the latest release."
  confirm_dir "$TD_DIR"; cd "$TD_DIR"

  say "Fetching the deploy stack for v${tag} ..."
  curl -fsSL "https://codeload.github.com/${BACKEND_REPO}/tar.gz/refs/tags/v${tag}" -o /tmp/td-src.tgz
  tar -xzf /tmp/td-src.tgz --strip-components=1 \
    "tracedown-core-backend-${tag}/docker/deploy" \
    "tracedown-core-backend-${tag}/scripts" 2>/dev/null \
    || tar -xzf /tmp/td-src.tgz --strip-components=1 --wildcards "*/docker/deploy/*" "*/scripts/*"
  rm -f /tmp/td-src.tgz
  cd docker/deploy

  if [ ! -f .env ]; then
    say "Generating .env from the template (real secrets, production guard armed) ..."
    cp .env.example .env
    sed -i \
      -e "s|^DB_PASSWORD=.*|DB_PASSWORD=$(openssl rand -hex 16)|" \
      -e "s|^#PLATFORM_AES_KEY=.*|PLATFORM_AES_KEY=$(hex32)|" \
      -e "s|^#JWT_SECRET=.*|JWT_SECRET=$(b64secret)|" \
      -e "s|^APP_URL=.*|APP_URL=${TD_APP_URL}|" \
      -e "s|^#DEMO_USER_EMAIL=.*|DEMO_USER_EMAIL=${TD_DEMO_EMAIL}|" \
      -e "s|^#DEMO_USER_PASSWORD=.*|DEMO_USER_PASSWORD=${TD_DEMO_PASSWORD}|" \
      -e "s|^BACKEND_VERSION=.*|BACKEND_VERSION=${tag}|" \
      .env
    if [ "$TD_EMAIL_MODE" = "smtp" ]; then
      sed -i \
        -e "s|^#EMAIL_PROVIDER=.*|EMAIL_PROVIDER=smtp|" \
        -e "s|^#EMAIL_FROM_ADDRESS=.*|EMAIL_FROM_ADDRESS=${TD_EMAIL_FROM}|" \
        -e "s|^#SMTP_HOST=.*|SMTP_HOST=${TD_SMTP_HOST}|" \
        -e "s|^#SMTP_PORT=.*|SMTP_PORT=${TD_SMTP_PORT}|" \
        -e "s|^#SMTP_USERNAME=.*|SMTP_USERNAME=${TD_SMTP_USERNAME}|" \
        -e "s|^#SMTP_PASSWORD=.*|SMTP_PASSWORD=${TD_SMTP_PASSWORD}|" \
        -e "s|^#EMAIL_SMTP_HOST=.*|EMAIL_SMTP_HOST=${TD_SMTP_HOST}|" \
        -e "s|^#EMAIL_SMTP_PORT=.*|EMAIL_SMTP_PORT=${TD_SMTP_PORT}|" \
        -e "s|^#EMAIL_SMTP_USERNAME=.*|EMAIL_SMTP_USERNAME=${TD_SMTP_USERNAME}|" \
        -e "s|^#EMAIL_SMTP_PASSWORD=.*|EMAIL_SMTP_PASSWORD=${TD_SMTP_PASSWORD}|" \
        .env
    else
      # Without a mail provider the stack must not claim production — the
      # platform (correctly) refuses console mail there. Guards re-arm when
      # SMTP is configured and this is set back to production.
      sed -i -e "s|^DEPLOYMENT_ENV=production|DEPLOYMENT_ENV=dev|" .env
      warn "No email provider: mail stays in the logs and the production startup"
      warn "guards are NOT armed. Configure SMTP in .env and set"
      warn "DEPLOYMENT_ENV=production before real users."
    fi
    chmod 600 .env
    note "PLATFORM_AES_KEY is permanent — back .env up separately from the database."
  else
    note "Reusing existing .env"
  fi

  say "Starting (docker compose up -d) — first start downloads the release artifacts ..."
  docker compose up -d
  wait_for_ping "http://127.0.0.1:20714/ping" 300 || true

  say "Done — two steps remain:"
  note "1. Expose it: copy nginx.conf or apache.conf from $(pwd) into your web"
  note "   server, adjust server_name and the frontend-dist path, add TLS"
  note "   (certbot), reload. The stack itself binds 127.0.0.1 only."
  note "2. Connect a probe agent — nothing probes without one:"
  note "     curl -fsSL ${DOCS}/install.sh | bash    (choose option 3)"
  note "Docs: ${DOCS}/install/deploy/"
}

# ── mode 3: probe agent ──────────────────────────────────────────────────────

install_agent() {
  say "Probe agent: mint a bootstrap token on an existing full stack and connect an agent."
  note "(For the monolith this step does not exist — it probes in-process.)"

  prompt TD_DIR   "Directory of the full-stack installation" "$HOME/tracedown"
  prompt TD_SLUG  "Agent slug (its permanent identity, e.g. eu-1)" "agent-1"
  prompt TD_AGENT_IMAGE "Agent image" "$AGENT_IMAGE_DEFAULT"

  local deploy="$TD_DIR/docker/deploy"
  [ -f "$deploy/docker-compose.yml" ] || die "No full-stack installation found at $deploy (run option 2 first)."
  cd "$deploy"

  docker compose ps tracedown-gateway >/dev/null 2>&1 || die "The stack is not running — docker compose up -d first."

  say "Minting a one-time bootstrap token for '${TD_SLUG}' ..."
  local out token
  out="$(docker compose exec -T tracedown-gateway java -jar /artifacts/api-gateway.jar --agent-bootstrap "$TD_SLUG")"
  token="$(printf '%s\n' "$out" | grep -oE '[0-9a-f]{48,}' | head -1)"
  [ -n "$token" ] || die "Could not mint a token. Gateway output: $out"

  say "Starting the agent (image ${TD_AGENT_IMAGE}) ..."
  docker rm -f "tracedown-agent-${TD_SLUG}" >/dev/null 2>&1 || true
  docker run -d \
    --name "tracedown-agent-${TD_SLUG}" \
    --hostname "$TD_SLUG" \
    --network tracedown_tracedown-net --network-alias "$TD_SLUG" \
    -v tracedown_tracedown-bodies:/data/bodies \
    -e PROBE_AGENT_BOOTSTRAP_TOKEN="$token" \
    -e PROBE_AGENT_SCHEDULER_URL=http://tracedown-gateway:20714 \
    -e PROBE_AGENT_PORT=8443 \
    -e PROBE_AGENT_STORAGE_BACKEND=filesystem \
    -e PROBE_AGENT_STORAGE_DIR=/data/bodies \
    --restart unless-stopped \
    "$TD_AGENT_IMAGE" >/dev/null

  say "Agent '${TD_SLUG}' started."
  note "It enrolls over mutual TLS and reports healthy after its first health"
  note "challenge (about a minute). Watch: docker logs -f tracedown-agent-${TD_SLUG}"
  note "Docs: ${DOCS}/install/agents/"
}

# ── main ─────────────────────────────────────────────────────────────────────

printf '\n  Tracedown installer — self-hosted API monitoring\n  %s\n\n' "$DOCS"

need curl; need docker; need openssl
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required ('docker compose', not 'docker-compose')."
docker info >/dev/null 2>&1 || die "Docker is installed but not usable by this user (daemon down, or missing group membership)."

TD_MODE="${TD_MODE-}"
if [ -z "$TD_MODE" ]; then
  note "1) Monolith    — everything in one container + Postgres + Redis (smallest install)"
  note "2) Full stack  — the per-service deployment (11 containers, production shape)"
  note "3) Probe agent — connect an agent to an existing full stack"
  printf '\n'
  prompt TD_MODE "Which one?" "1"
fi

case "$TD_MODE" in
  1) install_monolith ;;
  2) install_full ;;
  3) install_agent ;;
  *) die "Unknown choice '$TD_MODE' (expected 1, 2 or 3)." ;;
esac
