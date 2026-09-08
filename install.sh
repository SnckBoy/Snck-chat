#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
NODE_MAJOR=20
IS_CODESPACE="${CODESPACES:-false}"

# In Codespaces the repository is already mounted in GITHUB_WORKSPACE. On a VPS
# install into /opt/snck-chat unless SNCK_DIR is explicitly supplied.
if [[ -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then
  DEFAULT_DIR="$GITHUB_WORKSPACE"
else
  DEFAULT_DIR="/opt/snck-chat"
fi
APP_DIR="${SNCK_DIR:-$DEFAULT_DIR}"

log(){ printf '\n[SNCK] %s\n' "$*"; }
fail(){ echo "[SNCK] ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Run with sudo/root on a VPS."; }

check_os(){
  [[ -r /etc/os-release ]] || fail "Cannot detect operating system."
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "This installer supports Ubuntu."
  log "Detected Ubuntu ${VERSION_ID:-unknown}."
}

have_systemd(){ command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

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
      fail "Node.js ${NODE_MAJOR}+ is required. Install it or use a Node-based Codespace image."
    fi
  fi
  node -v
  npm -v
}

setup_user(){
  [[ "$IS_CODESPACE" == "true" ]] && return 0
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
}

start_postgres(){
  if have_systemd; then
    systemctl enable --now postgresql
  elif command -v pg_ctlcluster >/dev/null 2>&1; then
    # Codespaces/containers normally do not run systemd.
    local cluster
    cluster="$(pg_lsclusters -h 2>/dev/null | awk 'NR==1{print $1" "$2}')"
    if [[ -n "$cluster" ]]; then
      pg_ctlcluster ${cluster} start 2>/dev/null || true
    fi
  fi
  pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 || return 1
}

setup_db(){
  log "Configuring PostgreSQL..."
  if ! start_postgres; then
    if [[ -n "${DATABASE_URL:-}" ]]; then
      log "Using existing DATABASE_URL."
      return 0
    fi
    fail "PostgreSQL is not reachable. On Codespaces, start PostgreSQL or provide DATABASE_URL."
  fi

  DBPASS="${SNCK_DB_PASSWORD:-$(openssl rand -hex 32)}"
  if [[ $EUID -eq 0 ]]; then
    PSQL='sudo -u postgres psql'
    CREATEDB='sudo -u postgres createdb'
  else
    PSQL='sudo -u postgres psql'
    CREATEDB='sudo -u postgres createdb'
  fi
  $PSQL -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN CREATE ROLE snck LOGIN PASSWORD '${DBPASS}'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE snck WITH PASSWORD '${DBPASS}'; END \$\$;"
  if ! $PSQL -tAc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q 1; then
    $CREATEDB -O snck snck_chat
  fi
}

clone_or_use_repo(){
  if [[ -f "$APP_DIR/package.json" && -f "$APP_DIR/src/server.js" ]]; then
    log "Using existing workspace: $APP_DIR"
    return 0
  fi
  mkdir -p "$(dirname "$APP_DIR")"
  [[ ! -e "$APP_DIR" ]] || fail "$APP_DIR exists but does not contain a Snck Chat installation. Set SNCK_DIR to another directory."
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
  else
    log "Existing .env preserved."
  fi
}

load_env(){
  if [[ -f "$APP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$APP_DIR/.env"
    set +a
  fi
}

prepare_app(){
  clone_or_use_repo
  setup_db
  write_env
  load_env
  cd "$APP_DIR"
  log "Installing Node dependencies..."
  npm install
  npx prisma generate
  # The repository contains migrations. If a clean checkout somehow lacks one,
  # generate a baseline migration from the schema before deploying it.
  if [[ ! -d prisma/migrations || -z "$(find prisma/migrations -name '*.sql' -print -quit 2>/dev/null)" ]]; then
    mkdir -p prisma/migrations/0001_init
    npx prisma migrate diff --from-empty --to-schema-datamodel prisma/schema.prisma --script > prisma/migrations/0001_init/migration.sql
  fi
  npx prisma migrate deploy
  if [[ -f prisma/seed.sql ]]; then npx prisma db execute --file prisma/seed.sql; fi
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
  load_env
  local port="${PORT:-3000}"
  if have_systemd && [[ "$IS_CODESPACE" != "true" ]]; then
    systemctl is-active --quiet "$SERVICE" || { systemctl --no-pager --full status "$SERVICE"; fail "Snck Chat service failed to start."; }
  fi
  # Start a temporary health-check process in workspace mode.
  if [[ "$IS_CODESPACE" == "true" || ! -f "/etc/systemd/system/${SERVICE}.service" ]]; then
    local pid
    node src/server.js >/tmp/snck-chat-health.log 2>&1 & pid=$!
    trap 'kill "$pid" 2>/dev/null || true' RETURN
    sleep 2
    curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null || { cat /tmp/snck-chat-health.log; fail "Application health check failed."; }
    kill "$pid" 2>/dev/null || true
  else
    curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null || fail "Application health check failed."
    nginx -t >/dev/null || fail "Nginx configuration test failed."
  fi
  echo
  echo "========================================"
  echo "       SNCK CHAT IS READY"
  echo "========================================"
  echo "App directory: $APP_DIR"
  echo "Port: $port"
  if [[ "$IS_CODESPACE" == "true" ]]; then
    echo "Mode: GitHub Codespaces/workspace"
    echo "Run: npm start"
    echo "Forward port $port in the Codespaces Ports tab."
  else
    echo "Mode: Ubuntu VPS production"
    echo "Service: $SERVICE"
    echo "Public: http://YOUR_VPS_IP"
  fi
  echo "========================================"
}

install_app(){
  check_os
  if [[ "$IS_CODESPACE" != "true" ]]; then need_root; fi
  install_deps
  setup_user
  prepare_app

  if [[ "$IS_CODESPACE" == "true" ]]; then
    log "Codespace detected; skipping systemd/Nginx because Codespaces does not require VPS services."
    verify
    return 0
  fi

  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  write_service
  write_nginx
  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  nginx -t
  systemctl reload nginx
  verify
}

update_app(){
  if [[ "$IS_CODESPACE" != "true" ]]; then need_root; fi
  [[ -d "$APP_DIR/.git" ]] || fail "No Snck Chat installation found."
  cd "$APP_DIR"
  git pull --ff-only
  prepare_app
  if [[ "$IS_CODESPACE" == "true" ]]; then
    verify
  else
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    write_service
    write_nginx
    systemctl daemon-reload
    systemctl restart "$SERVICE"
    nginx -t && systemctl reload nginx
    verify
  fi
}

repair(){
  if [[ "$IS_CODESPACE" != "true" ]]; then need_root; fi
  [[ -d "$APP_DIR" ]] || fail "No Snck Chat installation found."
  prepare_app
  if [[ "$IS_CODESPACE" == "true" ]]; then
    verify
  else
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    write_service
    write_nginx
    systemctl daemon-reload
    systemctl restart "$SERVICE"
    nginx -t && systemctl reload nginx
    verify
  fi
}

create_admin(){
  if [[ "$IS_CODESPACE" != "true" ]]; then need_root; fi
  [[ -f "$APP_DIR/src/create-admin.js" ]] || fail "Install Snck Chat first."
  load_env
  cd "$APP_DIR"
  if [[ "$IS_CODESPACE" == "true" ]]; then
    node src/create-admin.js
  else
    sudo -u "$APP_USER" env NODE_ENV=production DATABASE_URL="$DATABASE_URL" node src/create-admin.js
  fi
}

uninstall_app(){
  if [[ "$IS_CODESPACE" != "true" ]]; then need_root; fi
  read -r -p 'Type UNINSTALL to continue: ' confirm
  [[ "$confirm" == "UNINSTALL" ]] || { echo "Cancelled."; return; }
  if [[ "$IS_CODESPACE" != "true" ]]; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}.service" "/etc/nginx/sites-enabled/${SERVICE}" "/etc/nginx/sites-available/${SERVICE}"
    systemctl daemon-reload
    nginx -t && systemctl reload nginx || true
  fi
  echo "Application files and database were preserved for safety at $APP_DIR."
}

first_install(){
  install_app
  echo
  read -r -p 'Create the first admin account now? [Y/n]: ' answer </dev/tty || answer=n
  if [[ ! "$answer" =~ ^[Nn]$ ]]; then create_admin; fi
}

menu(){
  while true; do
    echo
    echo "========================================"
    echo "          SNCK CHAT INSTALLER"
    echo "========================================"
    echo "1. Install Website"
    echo "2. Create Admin User"
    echo "3. Update Website"
    echo "4. Repair Installation"
    echo "5. Uninstall"
    echo "6. Exit"
    echo "========================================"
    read -r -p 'Select an option: ' choice </dev/tty
    case "$choice" in
      1) install_app ;;
      2) create_admin ;;
      3) update_app ;;
      4) repair ;;
      5) uninstall_app ;;
      6) exit 0 ;;
      *) echo 'Invalid option.' ;;
    esac
    read -r -p 'Press Enter to continue...' _ </dev/tty || true
  done
}

# IMPORTANT: no argument means INSTALL, so the exact curl command works.
case "${1:-install}" in
  install) first_install ;;
  admin) create_admin ;;
  update) update_app ;;
  repair) repair ;;
  uninstall) uninstall_app ;;
  menu) menu ;;
  *) echo "Usage: $0 [install|admin|update|repair|uninstall|menu]"; exit 2 ;;
esac
