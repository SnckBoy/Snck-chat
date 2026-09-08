#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
NODE_MAJOR=20
IS_CODESPACE="${CODESPACES:-false}"

if [[ -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then DEFAULT_DIR="$GITHUB_WORKSPACE"; else DEFAULT_DIR="/opt/snck-chat"; fi
APP_DIR="${SNCK_DIR:-$DEFAULT_DIR}"

log(){ printf '\n[SNCK] %s\n' "$*"; }
fail(){ echo "[SNCK] ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Run with sudo/root on a VPS."; }
have_systemd(){ command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

check_os(){
  [[ -r /etc/os-release ]] || fail "Cannot detect operating system."; . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "This installer supports Ubuntu."
  log "Detected Ubuntu ${VERSION_ID:-unknown}."
}

install_deps(){
  log "Installing system dependencies..."
  if [[ $EUID -eq 0 ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl git nginx postgresql postgresql-contrib openssl ca-certificates build-essential
  elif command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y curl git openssl ca-certificates build-essential postgresql postgresql-contrib
  else
    command -v curl >/dev/null || fail "curl is required."
    command -v git >/dev/null || fail "git is required."
    command -v openssl >/dev/null || fail "openssl is required."
  fi
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt "$NODE_MAJOR" ]]; then
    if [[ $EUID -eq 0 ]]; then
      curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -
      DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    elif command -v sudo >/dev/null 2>&1; then
      curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -
      DEBIAN_FRONTEND=noninteractive sudo apt-get install -y nodejs
    else
      fail "Node.js ${NODE_MAJOR}+ is required."
    fi
  fi
  node -v; npm -v
}

setup_user(){
  [[ "$IS_CODESPACE" == "true" ]] && return 0
  if ! id "$APP_USER" >/dev/null 2>&1; then useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"; fi
}

start_postgres(){
  if have_systemd; then systemctl enable --now postgresql
  elif command -v pg_ctlcluster >/dev/null 2>&1; then
    local cluster; cluster="$(pg_lsclusters -h 2>/dev/null | awk 'NR==1{print $1" "$2}')"
    [[ -z "$cluster" ]] || pg_ctlcluster ${cluster} start 2>/dev/null || true
  fi
  pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1
}

setup_db(){
  log "Configuring PostgreSQL..."
  if [[ -n "${DATABASE_URL:-}" ]]; then
    if start_postgres; then log "Using existing DATABASE_URL."; return 0; fi
    log "Using externally configured DATABASE_URL."; return 0
  fi
  start_postgres || fail "PostgreSQL is not reachable. On Codespaces, provide DATABASE_URL or install/start PostgreSQL."
  DBPASS="${SNCK_DB_PASSWORD:-$(openssl rand -hex 32)}"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN CREATE ROLE snck LOGIN PASSWORD '${DBPASS}'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE snck WITH PASSWORD '${DBPASS}'; END \$\$;"
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q 1; then sudo -u postgres createdb -O snck snck_chat; fi
}

clone_or_use_repo(){
  if [[ -f "$APP_DIR/package.json" && -f "$APP_DIR/src/server.js" ]]; then log "Using existing workspace: $APP_DIR"; return 0; fi
  mkdir -p "$(dirname "$APP_DIR")"
  [[ ! -e "$APP_DIR" ]] || fail "$APP_DIR exists but is not a Snck Chat checkout. Set SNCK_DIR to another directory."
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
}

write_env(){
  mkdir -p "$APP_DIR"
  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
NODE_ENV=production
PORT=${SNCK_PORT:-3000}
DATABASE_URL=${DATABASE_URL:-postgresql://snck:${DBPASS}@127.0.0.1:5432/snck_chat}
COOKIE_SECURE=${COOKIE_SECURE:-false}
SESSION_DAYS=30
ADMIN_SESSION_DAYS=8
EOF
    chmod 600 "$APP_DIR/.env"
  else log "Existing .env preserved."; fi
}

load_env(){
  if [[ -f "$APP_DIR/.env" ]]; then set -a; source "$APP_DIR/.env"; set +a; fi
}

prepare_app(){
  clone_or_use_repo
  # Load existing configuration before touching PostgreSQL so rerunning the
  # installer never rotates the DB password behind the existing .env file.
  load_env
  setup_db
  write_env
  load_env
  cd "$APP_DIR"
  log "Installing Node dependencies..."
  npm install
  npx prisma generate
  if [[ ! -d prisma/migrations || -z "$(find prisma/migrations -name '*.sql' -print -quit 2>/dev/null)" ]]; then
    mkdir -p prisma/migrations/0001_init
    npx prisma migrate diff --from-empty --to-schema-datamodel prisma/schema.prisma --script > prisma/migrations/0001_init/migration.sql
  fi
  npx prisma migrate deploy
  [[ ! -f prisma/seed.sql ]] || npx prisma db execute --file prisma/seed.sql
  npm run check
}

write_service(){
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Snck Chat
After=network-online.target postgresql.service
Wants=network-online.target
[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
ExecStart=/usr/bin/node ${APP_DIR}/src/server.js
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${APP_DIR}
[Install]
WantedBy=multi-user.target
EOF
}

write_nginx(){
  command -v nginx >/dev/null 2>&1 || return 0
  cat > "/etc/nginx/sites-available/${SERVICE}" <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 10M;
    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 60s;
    }
}
EOF
  ln -sfn "/etc/nginx/sites-available/${SERVICE}" "/etc/nginx/sites-enabled/${SERVICE}"
  rm -f /etc/nginx/sites-enabled/default
}

verify(){
  load_env; local port="${PORT:-3000}"
  if have_systemd && [[ "$IS_CODESPACE" != "true" ]]; then
    systemctl is-active --quiet "$SERVICE" || { systemctl --no-pager --full status "$SERVICE"; fail "Snck Chat service failed to start."; }
    curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null || fail "Application health check failed."
    nginx -t >/dev/null || fail "Nginx configuration test failed."
  else
    log "Verifying application in workspace mode..."
    node src/server.js >/tmp/snck-chat-health.log 2>&1 & local pid=$!
    sleep 2
    if ! curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null; then cat /tmp/snck-chat-health.log; kill "$pid" 2>/dev/null || true; fail "Application health check failed."; fi
    kill "$pid" 2>/dev/null || true
  fi
  echo; echo "========================================"; echo "       SNCK CHAT IS READY"; echo "========================================"
  echo "App directory: $APP_DIR"; echo "Port: $port"
  if [[ "$IS_CODESPACE" == "true" ]]; then
    echo "Mode: GitHub Codespaces/workspace"; echo "Run: npm start"; echo "Forward port $port in the Ports tab."
  else echo "Mode: Ubuntu VPS production"; echo "Service: $SERVICE"; echo "Public: http://YOUR_VPS_IP"; fi
  echo "========================================"
}

install_app(){
  check_os; [[ "$IS_CODESPACE" == "true" ]] || need_root; install_deps; setup_user; prepare_app
  if [[ "$IS_CODESPACE" == "true" ]]; then log "Codespace detected; skipping systemd/Nginx."; verify; return; fi
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  write_service; write_nginx; systemctl daemon-reload; systemctl enable --now "$SERVICE"; nginx -t; systemctl reload nginx; verify
}

update_app(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root; [[ -d "$APP_DIR/.git" ]] || fail "No Snck Chat installation found."; cd "$APP_DIR"; git pull --ff-only; prepare_app
  if [[ "$IS_CODESPACE" == "true" ]]; then verify; else chown -R "$APP_USER:$APP_USER" "$APP_DIR"; write_service; write_nginx; systemctl daemon-reload; systemctl restart "$SERVICE"; nginx -t && systemctl reload nginx; verify; fi
}

repair(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root; [[ -d "$APP_DIR" ]] || fail "No Snck Chat installation found."; prepare_app
  if [[ "$IS_CODESPACE" == "true" ]]; then verify; else chown -R "$APP_USER:$APP_USER" "$APP_DIR"; write_service; write_nginx; systemctl daemon-reload; systemctl restart "$SERVICE"; nginx -t && systemctl reload nginx; verify; fi
}

create_admin(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root; [[ -f "$APP_DIR/src/create-admin.js" ]] || fail "Install Snck Chat first."; load_env; cd "$APP_DIR"
  if [[ "$IS_CODESPACE" == "true" ]]; then node src/create-admin.js; else sudo -u "$APP_USER" env NODE_ENV=production DATABASE_URL="$DATABASE_URL" node src/create-admin.js; fi
}

uninstall_app(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root; read -r -p 'Type UNINSTALL to continue: ' confirm; [[ "$confirm" == "UNINSTALL" ]] || { echo "Cancelled."; return; }
  if [[ "$IS_CODESPACE" != "true" ]]; then systemctl disable --now "$SERVICE" 2>/dev/null || true; rm -f "/etc/systemd/system/${SERVICE}.service" "/etc/nginx/sites-enabled/${SERVICE}" "/etc/nginx/sites-available/${SERVICE}"; systemctl daemon-reload; nginx -t && systemctl reload nginx || true; fi
  echo "Application files and database were preserved for safety at $APP_DIR."
}

first_install(){ install_app; echo; read -r -p 'Create the first admin account now? [Y/n]: ' answer </dev/tty || answer=n; if [[ ! "$answer" =~ ^[Nn]$ ]]; then create_admin; fi; }

menu(){
  while true; do
    echo; echo "========================================"; echo "          SNCK CHAT INSTALLER"; echo "========================================"; echo "1. Install Website"; echo "2. Create Admin User"; echo "3. Update Website"; echo "4. Repair Installation"; echo "5. Uninstall"; echo "6. Exit"; echo "========================================"
    read -r -p 'Select an option: ' choice </dev/tty
    case "$choice" in 1) install_app;; 2) create_admin;; 3) update_app;; 4) repair;; 5) uninstall_app;; 6) exit 0;; *) echo 'Invalid option.';; esac
    read -r -p 'Press Enter to continue...' _ </dev/tty || true
  done
}

# No argument intentionally means INSTALL, allowing the exact one-command URL:
# curl -fsSL .../install.sh -o /tmp/snck-install.sh && sudo bash /tmp/snck-install.sh
case "${1:-install}" in install) first_install;; admin) create_admin;; update) update_app;; repair) repair;; uninstall) uninstall_app;; menu) menu;; *) echo "Usage: $0 [install|admin|update|repair|uninstall|menu]"; exit 2;; esac
