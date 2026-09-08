#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
NODE_MAJOR=20
IS_CODESPACE="${CODESPACES:-false}"

if [[ -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then DEFAULT_DIR="$GITHUB_WORKSPACE"; else DEFAULT_DIR="/opt/snck-chat"; fi
APP_DIR="${SNCK_DIR:-$DEFAULT_DIR}"

# Premium terminal colors. Automatically disabled when stdout is not a TTY.
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
  if [[ -f "$APP_DIR/package.json" && -f "$APP_DIR/src/server.js" ]]; then ok "Using existing source: $APP_DIR"; return 0; fi
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
  else warn "Existing .env preserved"; fi
}

load_env(){ if [[ -f "$APP_DIR/.env" ]]; then set -a; source "$APP_DIR/.env"; set +a; fi; }

prepare_app(){
  clone_or_use_repo
  load_env
  setup_db
  write_env
  load_env
  cd "$APP_DIR"
  step "Installing application dependencies"
  npm install
  npx prisma generate
  if [[ ! -d prisma/migrations || -z "$(find prisma/migrations -name '*.sql' -print -quit 2>/dev/null)" ]]; then
    mkdir -p prisma/migrations/0001_init
    npx prisma migrate diff --from-empty --to-schema-datamodel prisma/schema.prisma --script > prisma/migrations/0001_init/migration.sql
  fi
  npx prisma migrate deploy
  [[ ! -f prisma/seed.sql ]] || npx prisma db execute --file prisma/seed.sql
  npm run check
  ok "Database migrations and application checks passed"
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
  load_env; local port="${PORT:-3000}"
  step "Running final health check"
  if have_systemd && [[ "$IS_CODESPACE" != "true" ]]; then
    systemctl is-active --quiet "$SERVICE" || { systemctl --no-pager --full status "$SERVICE"; fail "Snck Chat service failed to start."; }
    curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null || fail "Application health check failed."
    nginx -t >/dev/null || fail "Nginx configuration test failed."
  else
    node src/server.js >/tmp/snck-chat-health.log 2>&1 & local pid=$!
    sleep 2
    if ! curl -fsS "http://127.0.0.1:${port}/api/health" >/dev/null; then cat /tmp/snck-chat-health.log; kill "$pid" 2>/dev/null || true; fail "Application health check failed."; fi
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
  install_deps; setup_user; prepare_app
  if [[ "$IS_CODESPACE" == "true" ]]; then
    warn "Workspace mode: systemd/Nginx are skipped; GitHub will forward port 3000."
  else
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    write_service; write_nginx
    systemctl daemon-reload; systemctl enable --now "$SERVICE"
    nginx -t; systemctl reload nginx
  fi
  verify
}

update_app(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  [[ -d "$APP_DIR/.git" ]] || fail "No Snck Chat installation found at $APP_DIR."
  cd "$APP_DIR"; step "Updating Snck Chat"; git pull --ff-only; prepare_app
  if [[ "$IS_CODESPACE" != "true" ]]; then chown -R "$APP_USER:$APP_USER" "$APP_DIR"; write_service; write_nginx; systemctl daemon-reload; systemctl restart "$SERVICE"; nginx -t && systemctl reload nginx; fi
  verify; ok "Update complete"
}

repair(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  [[ -d "$APP_DIR" ]] || fail "No Snck Chat installation found."
  prepare_app
  if [[ "$IS_CODESPACE" != "true" ]]; then chown -R "$APP_USER:$APP_USER" "$APP_DIR"; write_service; write_nginx; systemctl daemon-reload; systemctl restart "$SERVICE"; nginx -t && systemctl reload nginx; fi
  verify; ok "Repair complete"
}

create_admin(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  [[ -f "$APP_DIR/src/create-admin.js" ]] || fail "Install Snck Chat first."
  load_env; cd "$APP_DIR"
  if [[ "$IS_CODESPACE" == "true" ]]; then node src/create-admin.js; else sudo -u "$APP_USER" env NODE_ENV=production DATABASE_URL="$DATABASE_URL" node src/create-admin.js; fi
}

uninstall_app(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  read -r -p 'Type UNINSTALL to continue: ' confirm
  [[ "$confirm" == "UNINSTALL" ]] || { warn "Cancelled."; return; }
  if [[ "$IS_CODESPACE" != "true" ]]; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}.service" "/etc/nginx/sites-enabled/${SERVICE}" "/etc/nginx/sites-available/${SERVICE}"
    systemctl daemon-reload; nginx -t && systemctl reload nginx || true
  fi
  warn "Application files and database preserved at $APP_DIR for safety."
  ok "Uninstall completed"
}

first_install(){
  install_app
  echo; line; printf '%b\n' "${YELLOW}${BOLD}ADMIN SETUP${RESET}"
  read -r -p 'Create admin account now? [Y/n]: ' answer </dev/tty || answer=n
  if [[ ! "$answer" =~ ^[Nn]$ ]]; then create_admin; else warn "Skipped. Use option 2 later."; fi
}

menu(){
  while true; do
    banner
    echo
    printf '%b\n' "${DIM}Environment: ${RESET}${BOLD}$([[ "$IS_CODESPACE" == "true" ]] && echo 'GitHub Workspace' || echo 'Ubuntu VPS')${RESET}"
    printf '%b\n\n' "${DIM}Install path: $APP_DIR${RESET}"
    printf '%b\n' "  ${CYAN}${BOLD}1${RESET}  ${WHITE}${BOLD}Install Website${RESET}       ${DIM}Full installation${RESET}"
    printf '%b\n' "  ${CYAN}${BOLD}2${RESET}  ${WHITE}${BOLD}Create Admin User${RESET}     ${DIM}Secure admin account${RESET}"
    printf '%b\n' "  ${CYAN}${BOLD}3${RESET}  ${WHITE}${BOLD}Update Website${RESET}        ${DIM}Latest code + migrations${RESET}"
    printf '%b\n' "  ${CYAN}${BOLD}4${RESET}  ${WHITE}${BOLD}Repair Installation${RESET}  ${DIM}Repair dependencies/services${RESET}"
    printf '%b\n' "  ${CYAN}${BOLD}5${RESET}  ${WHITE}${BOLD}Uninstall${RESET}             ${DIM}Disable safely${RESET}"
    printf '%b\n' "  ${CYAN}${BOLD}6${RESET}  ${WHITE}${BOLD}Exit${RESET}                  ${DIM}Quit${RESET}"
    echo; line
    read -r -p '  Select an option [1-6]: ' choice </dev/tty
    echo
    case "$choice" in
      1) install_app;; 2) create_admin;; 3) update_app;; 4) repair;; 5) uninstall_app;; 6) exit 0;; *) warn "Invalid option. Choose 1-6.";;
    esac
    echo; read -r -p '  Press Enter to return to menu...' _ </dev/tty || true
  done
}

# Exact one-command installer defaults to a full installation + optional admin creation.
# Add "menu" when you specifically want the interactive management menu.
case "${1:-install}" in
  install) first_install;;
  admin) create_admin;;
  update) update_app;;
  repair) repair;;
  uninstall) uninstall_app;;
  menu) menu;;
  *) printf '%b\n' "${RED}Usage:${RESET} $0 [install|admin|update|repair|uninstall|menu]"; exit 2;;
esac
