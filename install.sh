#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
NODE_MAJOR=20
IS_CODESPACE="${CODESPACES:-false}"

if [[ -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then DEFAULT_DIR="$GITHUB_WORKSPACE"; else DEFAULT_DIR="/opt/snck-chat"; fi
APP_DIR="${SNCK_DIR:-$DEFAULT_DIR}"

if [[ -t 1 ]]; then
  RESET='\033[0m'; BOLD='\033[1m'; DIM='\033[2m';
  RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BLUE='\033[34m';
  MAGENTA='\033[35m'; CYAN='\033[36m'; WHITE='\033[97m';
else
  RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; WHITE=''
fi

banner(){
  clear 2>/dev/null || true
  printf '%b\n' "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  printf '%b\n' "${CYAN}${BOLD}║${RESET}              ${WHITE}${BOLD}SNCK CHAT INSTALLER${RESET}              ${CYAN}${BOLD}║${RESET}"
  printf '%b\n' "${CYAN}${BOLD}║${RESET}       ${DIM}Production • Realtime • Ubuntu • Workspace${RESET}       ${CYAN}${BOLD}║${RESET}"
  printf '%b\n' "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
}
line(){ printf '%b\n' "${CYAN}────────────────────────────────────────────────────────────${RESET}"; }
log(){ printf '%b\n' "${BLUE}◆${RESET} $*"; }
ok(){ printf '%b\n' "${GREEN}✔${RESET} $*"; }
warn(){ printf '%b\n' "${YELLOW}⚠${RESET} $*"; }
fail(){ printf '%b\n' "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }
step(){ printf '\n%b\n' "${MAGENTA}${BOLD}▶ $*${RESET}"; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Run with sudo/root on an Ubuntu VPS."; }
have_systemd(){ command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

check_os(){
  [[ -r /etc/os-release ]] || fail "Cannot detect operating system."; . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "This installer supports Ubuntu."
  ok "Ubuntu ${VERSION_ID:-unknown} detected"
  if [[ "$IS_CODESPACE" == "true" ]]; then ok "GitHub Codespaces/Workspace detected"; else ok "Ubuntu VPS production mode"; fi
}

install_deps(){
  step "Installing required dependencies"
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
    if [[ $EUID -eq 0 ]]; then curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - && DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    elif command -v sudo >/dev/null 2>&1; then curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash - && DEBIAN_FRONTEND=noninteractive sudo apt-get install -y nodejs
    else fail "Node.js ${NODE_MAJOR}+ is required."; fi
  fi
  ok "Node $(node -v) • npm $(npm -v)"
}

setup_user(){
  [[ "$IS_CODESPACE" == "true" ]] && return 0
  if ! id "$APP_USER" >/dev/null 2>&1; then useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"; fi
  ok "Service user ready: $APP_USER"
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
  step "Configuring PostgreSQL"
  if [[ -n "${DATABASE_URL:-}" ]]; then
    if start_postgres; then log "Using configured DATABASE_URL with local PostgreSQL."; else log "Using external DATABASE_URL."; fi
    return 0
  fi
  start_postgres || fail "PostgreSQL is not reachable. Set DATABASE_URL for a hosted database."
  DBPASS="${SNCK_DB_PASSWORD:-$(openssl rand -hex 32)}"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN CREATE ROLE snck LOGIN PASSWORD '${DBPASS}'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE snck WITH PASSWORD '${DBPASS}'; END \$\$;"
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q 1; then sudo -u postgres createdb -O snck snck_chat; fi
  ok "Database ready: snck_chat"
}

clone_or_use_repo(){
  if [[ -f "$APP_DIR/package.json" && -f "$APP_DIR/src/server.js" ]]; then
    ok "Using existing source: $APP_DIR"
    if [[ -d "$APP_DIR/.git" ]]; then
      cd "$APP_DIR"
      log "Checking for latest Snck Chat fixes..."
      git pull --ff-only origin main || fail "Existing checkout has local changes or cannot be updated automatically. Resolve Git changes first."
      ok "Source updated from main"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$APP_DIR")"
  [[ ! -e "$APP_DIR" ]] || fail "$APP_DIR exists but is not a Snck Chat checkout. Use SNCK_DIR to choose another directory."
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
  ok "Snck Chat source downloaded"
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
    ok "Production .env generated"
  else
    warn "Existing .env preserved"
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

require_database_url(){
  [[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL is missing from $APP_DIR/.env. The installer cannot continue safely without it."
}

prepare_app(){
  clone_or_use_repo
  # On a fresh install there is no .env yet, so create/configure the database first.
  load_env
  setup_db
  write_env
  load_env
  require_database_url
  cd "$APP_DIR"

  step "Installing application dependencies"
  npm install

  # Prisma must always receive a valid schema and DATABASE_URL.
  export DATABASE_URL
  npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"

  if [[ ! -d prisma/migrations || -z "$(find prisma/migrations -name '*.sql' -print -quit 2>/dev/null)" ]]; then
    mkdir -p prisma/migrations/0001_init
    npx prisma migrate diff --from-empty --to-schema-datamodel prisma/schema.prisma --script > prisma/migrations/0001_init/migration.sql
  fi

  npx prisma migrate deploy --schema "$APP_DIR/prisma/schema.prisma"

  # prisma db execute requires --schema (or --url) with Prisma 6.
  # The seed is idempotent, so it is safe on install/update/repair.
  if [[ -f prisma/seed.sql ]]; then
    npx prisma db execute --schema "$APP_DIR/prisma/schema.prisma" --file "$APP_DIR/prisma/seed.sql"
  fi

  npm run check
  ok "Database migrations, seed and application checks passed"
}

write_service(){
  [[ "$IS_CODESPACE" == "true" ]] && return 0
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
  ok "systemd service configured"
}

write_nginx(){
  [[ "$IS_CODESPACE" == "true" ]] && return 0
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
  ok "Nginx + WebSocket proxy configured"
}

verify(){
  load_env
  require_database_url
  local port="${PORT:-3000}"
  step "Running final health check"

  if have_systemd && [[ "$IS_CODESPACE" != "true" ]]; then
    systemctl is-active --quiet "$SERVICE" || { systemctl --no-pager --full status "$SERVICE"; fail "Snck Chat service failed to start."; }
    curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null || fail "Application health check failed. Check: journalctl -u ${SERVICE} -n 100 --no-pager"
    nginx -t >/dev/null || fail "Nginx configuration test failed."
  else
    node src/server.js >/tmp/snck-chat-health.log 2>&1 & local pid=$!
    sleep 2
    if ! curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null; then
      cat /tmp/snck-chat-health.log
      kill "$pid" 2>/dev/null || true
      fail "Application health check failed."
    fi
    kill "$pid" 2>/dev/null || true
  fi

  echo
  line
  printf '%b\n' "${GREEN}${BOLD}                 ✔ SNCK CHAT READY${RESET}"
  line
  printf '%b\n' "${CYAN}Directory:${RESET} $APP_DIR"
  printf '%b\n' "${CYAN}Port:${RESET}      $port"
  if [[ "$IS_CODESPACE" == "true" ]]; then
    printf '%b\n' "${CYAN}Mode:${RESET}      GitHub Workspace"
    printf '%b\n' "${CYAN}Start:${RESET}     npm start"
    printf '%b\n' "${CYAN}Next:${RESET}      Forward port $port in the Ports tab"
  else
    printf '%b\n' "${CYAN}Mode:${RESET}      Ubuntu VPS"
    printf '%b\n' "${CYAN}Service:${RESET}   $SERVICE"
    printf '%b\n' "${CYAN}Public:${RESET}    http://YOUR_VPS_IP"
  fi
  line
}

install_app(){
  check_os
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  install_deps
  setup_user
  prepare_app

  if [[ "$IS_CODESPACE" == "true" ]]; then
    log "Codespace detected; skipping systemd/Nginx."
    verify
    return
  fi

  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  chmod 600 "$APP_DIR/.env"
  write_service
  write_nginx
  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  nginx -t
  systemctl reload nginx
  verify
}

update_app(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  [[ -d "$APP_DIR/.git" ]] || fail "No Snck Chat installation found."
  cd "$APP_DIR"
  git pull --ff-only origin main || fail "Could not update source. Resolve local Git changes first."
  prepare_app

  if [[ "$IS_CODESPACE" == "true" ]]; then
    verify
  else
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    chmod 600 "$APP_DIR/.env"
    write_service
    write_nginx
    systemctl daemon-reload
    systemctl restart "$SERVICE"
    nginx -t
    systemctl reload nginx
    verify
  fi
}

repair(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  [[ -d "$APP_DIR" ]] || fail "No Snck Chat installation found."
  prepare_app

  if [[ "$IS_CODESPACE" == "true" ]]; then
    verify
  else
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    chmod 600 "$APP_DIR/.env"
    write_service
    write_nginx
    systemctl daemon-reload
    systemctl restart "$SERVICE"
    nginx -t
    systemctl reload nginx
    verify
  fi
}

create_admin(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  [[ -f "$APP_DIR/src/create-admin.js" ]] || fail "Install Snck Chat first."
  load_env
  require_database_url
  cd "$APP_DIR"
  if [[ "$IS_CODESPACE" == "true" ]]; then
    env NODE_ENV=production DATABASE_URL="$DATABASE_URL" node src/create-admin.js
  else
    sudo -u "$APP_USER" env NODE_ENV=production DATABASE_URL="$DATABASE_URL" node src/create-admin.js
  fi
}

uninstall_app(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
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
  banner
  install_app
  echo
  read -r -p 'Create the first admin account now? [Y/n]: ' answer </dev/tty || answer=n
  if [[ ! "$answer" =~ ^[Nn]$ ]]; then create_admin; fi
}

menu(){
  while true; do
    banner
    printf '%b\n' "${WHITE}${BOLD}  1${RESET}  Install Website       ${DIM}Full installation${RESET}"
    printf '%b\n' "${WHITE}${BOLD}  2${RESET}  Create Admin User     ${DIM}Secure admin account${RESET}"
    printf '%b\n' "${WHITE}${BOLD}  3${RESET}  Update Website        ${DIM}Latest code + migrations${RESET}"
    printf '%b\n' "${WHITE}${BOLD}  4${RESET}  Repair Installation   ${DIM}Repair dependencies/services${RESET}"
    printf '%b\n' "${WHITE}${BOLD}  5${RESET}  Uninstall             ${DIM}Disable safely${RESET}"
    printf '%b\n' "${WHITE}${BOLD}  6${RESET}  Exit                  ${DIM}Quit${RESET}"
    line
    read -r -p '  Select an option: ' choice </dev/tty
    case "$choice" in
      1) install_app;;
      2) create_admin;;
      3) update_app;;
      4) repair;;
      5) uninstall_app;;
      6) exit 0;;
      *) warn 'Invalid option. Choose 1-6.';;
    esac
    echo
    read -r -p '  Press Enter to continue...' _ </dev/tty || true
  done
}

# No argument means INSTALL, so this exact one-command installer works:
# curl -fsSL https://raw.githubusercontent.com/SnckBoy/Snck-chat/main/install.sh -o /tmp/snck-install.sh && sudo bash /tmp/snck-install.sh
case "${1:-install}" in
  install) first_install;;
  admin) create_admin;;
  update) update_app;;
  repair) repair;;
  uninstall) uninstall_app;;
  menu) menu;;
  *) fail "Usage: $0 [install|admin|update|repair|uninstall|menu]";;
esac
