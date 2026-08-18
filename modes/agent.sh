#!/usr/bin/env bash
# Tracedown installer — "agent" mode. Sourced by install.sh, which provides the
# shared helpers (prompt, say, confirm_dir, prompt_email, ...) and the TD_*
# environment contract. Not runnable on its own.

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

