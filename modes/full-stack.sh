#!/usr/bin/env bash
# Tracedown installer — "full-stack" mode. Sourced by install.sh, which provides the
# shared helpers (prompt, say, confirm_dir, prompt_email, ...) and the TD_*
# environment contract. Not runnable on its own.

install_full() {
  say "Full stack: the per-service deployment from published release artifacts."

  prompt TD_DIR      "Install directory"             "$HOME/tracedown"
  prompt TD_VERSION  "Backend version (or 'latest')" "latest"
  prompt TD_APP_URL  "Public base URL (what users' browsers will reach)" "https://tracedown.example.com"
  prompt_admin
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
      -e "s|^#SINGLE_ORG_MODE=.*|SINGLE_ORG_MODE=true|" \
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
    # Every line above is a sed against a template fetched from the release, so
    # a renamed or reworded key would silently leave the setting commented out
    # and the install would come up with no account and no explanation. The
    # bootstrap trio is the set that has no recovery path, so assert it landed.
    local missing="" key
    for key in SINGLE_ORG_MODE DEMO_USER_EMAIL DEMO_USER_PASSWORD; do
      grep -q "^${key}=." .env || missing="$missing $key"
    done
    [ -z "$missing" ] || die "The v${tag} .env template did not accept:${missing}. Set them by hand in $(pwd)/.env before starting — nothing else can create the first user."

    chmod 600 .env
    note "PLATFORM_AES_KEY is permanent — back .env up separately from the database."
  else
    note "Reusing existing .env"
    grep -q '^SINGLE_ORG_MODE=' .env || warn \
      "This .env has no SINGLE_ORG_MODE. If no account exists yet, uncomment SINGLE_ORG_MODE=true (with real DEMO_USER_* values) before starting — nothing else can create the first user."
  fi

  say "Starting (docker compose up -d) — first start downloads the release artifacts ..."
  docker compose up -d
  # /health, not /ping: /ping is static liveness and answers long before the
  # migrator has finished and the pools are up. /health is readiness and 503s
  # until the gateway can actually serve.
  wait_for_ping "http://127.0.0.1:20714/health" 300 || true

  offer_host_nginx "$TD_APP_URL"

  say "Done — what remains:"
  report_first_login "$TD_APP_URL" "$(pwd)/.env"
  if [ "${HOST_CONF_INSTALLED:-no}" != "yes" ]; then
    note "- Expose it: copy nginx.conf or apache.conf from $(pwd) into your web"
    note "  server, adjust server_name and the frontend-dist path, add TLS"
    note "  (certbot), reload. The stack itself binds 127.0.0.1 only."
  else
    note "- Add TLS: certbot --nginx (or install your internal certificates)."
  fi
  note "- Connect a probe agent — nothing probes without one:"
  note "    curl -fsSL ${DOCS}/install.sh | bash    (choose option 3)"
  note "Docs: ${DOCS}/install/deploy/"
}

# Offers to install the stack's nginx vhost on THIS host: fills in server_name
# and the frontend path, writes tracedown.conf into the nginx config tree,
# tests, reloads. Skipped silently when nginx isn't installed here (the stack
# may be fronted from another machine). TD_NGINX_ROOT overrides /etc/nginx for
# tests.
offer_host_nginx() {
  local app_url="$1" server_name conf_root confdir target sudo_cmd=""
  command -v nginx >/dev/null 2>&1 || { note "(nginx not found on this host — skipping the vhost offer.)"; return 0; }

  prompt TD_HOST_CONF "nginx is installed here. Write and enable the Tracedown vhost now? (yes/no)" "yes"
  case "$TD_HOST_CONF" in y|yes|Y|YES) ;; *) return 0 ;; esac

  server_name="$(printf '%s' "$app_url" | sed -E 's|^https?://||; s|/.*$||')"
  prompt TD_SERVER_NAME "server_name for the vhost" "$server_name"

  conf_root="${TD_NGINX_ROOT:-/etc/nginx}"
  if [ -d "$conf_root/sites-available" ]; then
    target="$conf_root/sites-available/tracedown.conf"
  else
    target="$conf_root/conf.d/tracedown.conf"
  fi
  [ -w "$(dirname "$target")" ] || sudo_cmd="sudo"
  [ -z "$sudo_cmd" ] || command -v sudo >/dev/null 2>&1 || { warn "Need root to write $target — copy nginx.conf manually."; return 0; }

  say "Writing $target ..."
  sed -e "s|server_name .*;|server_name ${TD_SERVER_NAME};|" \
      -e "s|root /opt/tracedown/deploy/frontend-dist;|root $(pwd)/frontend-dist;|" \
      nginx.conf | $sudo_cmd tee "$target" > /dev/null
  if [ -d "$conf_root/sites-available" ] && [ -d "$conf_root/sites-enabled" ]; then
    $sudo_cmd ln -sf "$target" "$conf_root/sites-enabled/tracedown.conf"
  fi

  if [ -n "${TD_NGINX_ROOT:-}" ]; then
    note "(custom TD_NGINX_ROOT — skipping nginx -t / reload)"
  elif $sudo_cmd nginx -t; then
    $sudo_cmd systemctl reload nginx 2>/dev/null || $sudo_cmd nginx -s reload
    say "nginx reloaded — http://${TD_SERVER_NAME}/ serves the stack (HTTP only; add TLS next)."
    HOST_CONF_INSTALLED=yes
  else
    warn "nginx -t failed — the vhost was written to $target but NOT reloaded. Fix and reload manually."
  fi
}

