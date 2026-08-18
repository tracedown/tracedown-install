#!/usr/bin/env bash
# Tracedown installer — https://tracedown.dev
#
#   curl -fsSL https://tracedown.dev/install.sh | bash
#
# Interactive: prompts come from the terminal even when the script itself is
# piped in. Every prompt can be pre-answered with a TD_* environment variable
# (named next to each prompt) for unattended installs.
#
# This is the ENTRY script: shared helpers and the menu. Each mode lives in
# its own file under modes/ and is loaded on demand — from the local checkout
# when you run this from a clone, otherwise fetched from the same repository
# and branch this script came from (TD_BASE_URL overrides the source, e.g. to
# pin a commit).
#
# Modes:
#   1) Monolith     — the whole platform in one container, plus Postgres and
#                     Redis. The smallest real installation.
#   2) Full stack   — the per-service deployment from the published release
#                     artifacts (11 containers). Optionally installs the host
#                     nginx vhost for you.
#   3) Probe agent  — mint a bootstrap token on an existing full stack and
#                     connect an agent to it.
#   4) Kubernetes   — the monolith on a cluster: generates plain manifests and
#                     applies them only to a context you name exactly.
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

# ── mode loading ─────────────────────────────────────────────────────────────

BASE_URL="${TD_BASE_URL:-https://raw.githubusercontent.com/tracedown/tracedown-install/main}"

# Loads one mode file: from the directory this script lives in when that is a
# checkout (local development / forks), otherwise from ${BASE_URL}/modes/.
# Sourcing fetched code is the same trust decision as piping this script.
load_mode() {
  local name="$1" local_dir=""
  # Only trust a local checkout when this script itself is a real file on disk
  # — under `curl | bash` BASH_SOURCE is not a path, and the user's working
  # directory must never be sourced by accident.
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    local_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  fi
  if [ -n "$local_dir" ] && [ -f "$local_dir/modes/$name.sh" ]; then
    # shellcheck source=/dev/null
    . "$local_dir/modes/$name.sh"
  else
    say "Fetching the $name installer ..."
    # shellcheck source=/dev/null
    . <(curl -fsSL "${BASE_URL}/modes/${name}.sh") \
      || die "Could not load ${BASE_URL}/modes/${name}.sh"
  fi
}

# ── main ─────────────────────────────────────────────────────────────────────

printf '\n  Tracedown installer — self-hosted API monitoring\n  %s\n\n' "$DOCS"

need curl; need openssl

TD_MODE="${TD_MODE-}"
if [ -z "$TD_MODE" ]; then
  note "1) Monolith    — everything in one container + Postgres + Redis (smallest install)"
  note "2) Full stack  — the per-service deployment (11 containers, production shape)"
  note "3) Probe agent — connect an agent to an existing full stack"
  note "4) Kubernetes  — the monolith on a cluster (generates plain manifests)"
  printf '\n'
  prompt TD_MODE "Which one?" "1"
fi

# Docker is only a prerequisite for the docker-based modes.
if [ "$TD_MODE" != "4" ]; then
  need docker
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required ('docker compose', not 'docker-compose')."
  docker info >/dev/null 2>&1 || die "Docker is installed but not usable by this user (daemon down, or missing group membership)."
fi

case "$TD_MODE" in
  1) load_mode monolith;   install_monolith ;;
  2) load_mode full-stack; install_full ;;
  3) load_mode agent;      install_agent ;;
  4) load_mode k8s;        install_k8s ;;
  *) die "Unknown choice '$TD_MODE' (expected 1, 2, 3 or 4)." ;;
esac
