#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
APP_DIR="${SNCK_DIR:-/opt/snck-chat}"
PORT_DEFAULT=3000
NODE_MAJOR=20
WORKSPACE_MODE=false

if [[ -t 1 ]]; then
  R=$'\033[0m'; B=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; MAGENTA=$'\033[35m'; WHITE=$'\033[97m'
else
  R=''; B=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; WHITE=''
fi

trap 'rc=$?; printf "%b\n" "${RED}✖ ERROR:${R} Installer failed at line $LINENO. Command: $BASH_COMMAND" >&2; exit "$rc"' ERR

banner(){
  clear 2>/dev/null || true
  printf '%b\n' \
    "${CYAN}${B}╔══════════════════════════════════════════════════════════╗${R}" \
    "${CYAN}${B}║${R}                 ${WHITE}${B}SNCK CHAT INSTALLER${R}                 ${CYAN}${B}║${R}" \
    "${CYAN}${B}║${R}       ${B}Production • Realtime • Ubuntu • Workspace${R}       ${CYAN}${B}║${R}" \
    "${CYAN}${B}╚══════════════════════════════════════════════════════════╝${R}"
}
line(){ printf '%b\n' "${CYAN}────────────────────────────────────────────────────────────${R}"; }
step(){ printf '\n%b\n' "${MAGENTA}${B}▶ $*${R}"; }
ok(){ printf '%b\n' "${GREEN}✔${R} $*"; }
warn(){ printf '%b\n' "${YELLOW}⚠${R} $*"; }
info(){ printf '%b\n' "${BLUE}◆${R} $*"; }
die(){ printf '%b\n' "${RED}✖ ERROR:${R} $*" >&2; exit 1; }

require_root(){ [[ ${EUID:-99} -eq 0 ]] || die "Run with sudo/root."; }
have_systemd(){ command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

check_os(){
  [[ -r /etc/os-release ]] || die "Cannot detect operating system."
  . /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die "This installer supports Ubuntu only."
  ok "Ubuntu ${VERSION_ID:-unknown} detected"
  if [[ "${CODESPACES:-}" == "true" && -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then
    WORKSPACE_MODE=true
    APP_DIR="${SNCK_DIR:-$GITHUB_WORKSPACE}"
    ok "GitHub Workspace/Codespaces mode"
  else
    WORKSPACE_MODE=false
    ok "Ubuntu VPS production mode"
  fi
}

install_deps(){
  step "Installing required dependencies"
  require_root
  local packages=(curl git openssl ca-certificates build-essential postgresql postgresql-contrib sudo)
  [[ "$WORKSPACE_MODE" == true ]] || packages+=(nginx)
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

  local node_bin="/usr/bin/node"
  local major=0
  if [[ -x "$node_bin" ]]; then
    major="$($node_bin -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
  fi
  [[ "$major" =~ ^[0-9]+$ ]] || major=0
  if (( major < NODE_MAJOR )); then
    info "Installing Node.js ${NODE_MAJOR}.x system-wide"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  fi
  [[ -x /usr/bin/node ]] || die "System Node.js is missing at /usr/bin/node."
  [[ -x /usr/bin/npm ]] || die "npm is missing at /usr/bin/npm."
  ok "Node $(/usr/bin/node --version) • npm $(/usr/bin/npm --version)"
}

setup_user(){
  [[ "$WORKSPACE_MODE" == true ]] && return 0
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
  ok "Service user ready: $APP_USER"
}

load_env(){
  if [[ -f "$APP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$APP_DIR/.env"
    set +a
  fi
}

start_postgres(){
  if have_systemd; then systemctl enable --now postgresql >/dev/null 2>&1 || true; fi
  for _ in {1..30}; do
    pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

sql_escape(){ printf '%s' "$1" | sed "s/'/''/g"; }

setup_db(){
  step "Configuring PostgreSQL"
  start_postgres || die "PostgreSQL is not reachable on 127.0.0.1:5432."
  load_env
  local dbpass="${SNCK_DB_PASSWORD:-}"
  if [[ -z "$dbpass" && -n "${DATABASE_URL:-}" ]]; then
    dbpass="$(printf '%s' "$DATABASE_URL" | sed -n 's#^postgresql://[^:]*:\([^@]*\)@.*#\1#p')"
  fi
  [[ -n "$dbpass" ]] || dbpass="$(openssl rand -hex 32)"
  DBPASS="$dbpass"
  local escaped; escaped="$(sql_escape "$DBPASS")"
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='snck'" | grep -q 1; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE snck WITH LOGIN PASSWORD '${escaped}';"
  else
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE snck WITH LOGIN PASSWORD '${escaped}';"
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q 1; then
    sudo -u postgres createdb -O snck snck_chat
  fi
  ok "Database ready: snck_chat"
}

clone_or_update(){
  cd / || die "Cannot access filesystem root."
  if [[ -f "$APP_DIR/package.json" && -f "$APP_DIR/src/server.js" ]]; then
    ok "Using existing source: $APP_DIR"
    if [[ -d "$APP_DIR/.git" ]]; then
      cd "$APP_DIR"
      info "Checking for latest Snck Chat fixes..."
      if git fetch --quiet origin main; then
        git reset --hard --quiet origin/main
        ok "Source updated from main"
      else
        warn "GitHub unavailable; continuing with existing source."
      fi
    fi
    return 0
  fi
  mkdir -p "$(dirname "$APP_DIR")"
  if [[ -e "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
    die "$APP_DIR exists and is not an empty Snck Chat directory. Set SNCK_DIR to another path."
  fi
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
  ok "Snck Chat source downloaded"
}

write_env(){
  mkdir -p "$APP_DIR"
  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
NODE_ENV=production
PORT=${SNCK_PORT:-$PORT_DEFAULT}
DATABASE_URL=postgresql://snck:${DBPASS}@127.0.0.1:5432/snck_chat
COOKIE_SECURE=${COOKIE_SECURE:-false}
SESSION_DAYS=30
ADMIN_SESSION_DAYS=8
EOF
    chmod 600 "$APP_DIR/.env"
    ok "Production .env generated"
  else
    load_env
    if [[ -z "${DATABASE_URL:-}" ]]; then
      printf '\nDATABASE_URL=postgresql://snck:%s@127.0.0.1:5432/snck_chat\n' "$DBPASS" >> "$APP_DIR/.env"
      ok "DATABASE_URL added to existing .env"
    fi
    grep -Eq '^PORT=' "$APP_DIR/.env" || printf 'PORT=%s\n' "${SNCK_PORT:-$PORT_DEFAULT}" >> "$APP_DIR/.env"
    grep -Eq '^NODE_ENV=' "$APP_DIR/.env" || printf 'NODE_ENV=production\n' >> "$APP_DIR/.env"
    grep -Eq '^SESSION_DAYS=' "$APP_DIR/.env" || printf 'SESSION_DAYS=30\n' >> "$APP_DIR/.env"
    grep -Eq '^ADMIN_SESSION_DAYS=' "$APP_DIR/.env" || printf 'ADMIN_SESSION_DAYS=8\n' >> "$APP_DIR/.env"
    chmod 600 "$APP_DIR/.env"
  fi
}

require_database_url(){ load_env; [[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL is missing from $APP_DIR/.env."; }

prepare_app(){
  setup_db
  write_env
  load_env
  require_database_url
  cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"
  step "Installing application dependencies"
  if [[ -f package-lock.json ]]; then
    /usr/bin/npm ci --include=dev
  else
    /usr/bin/npm install --include=dev
  fi
  step "Validating Prisma schema"
  /usr/bin/npx prisma format --schema "$APP_DIR/prisma/schema.prisma"
  /usr/bin/npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"
  step "Generating Prisma Client"
  /usr/bin/npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"
  step "Applying database schema"
  if [[ -d "$APP_DIR/prisma/migrations" ]] && find "$APP_DIR/prisma/migrations" -mindepth 1 -maxdepth 1 -type d -print -quit | grep -q .; then
    /usr/bin/npx prisma migrate deploy --schema "$APP_DIR/prisma/schema.prisma"
  else
    warn "No migrations found; synchronizing the Prisma schema with db push."
    /usr/bin/npx prisma db push --schema "$APP_DIR/prisma/schema.prisma" --skip-generate
  fi
  if [[ -f "$APP_DIR/prisma/seed.js" ]]; then
    step "Initializing database"
    DATABASE_URL="$DATABASE_URL" /usr/bin/node "$APP_DIR/prisma/seed.js"
  fi
  step "Running application checks"
  /usr/bin/npm run check
  /usr/bin/npm test
  ok "Application checks passed"
}

write_service(){
  [[ "$WORKSPACE_MODE" == true ]] && return 0
  local group; group="$(id -gn "$APP_USER")"
  load_env
  local port="${PORT:-$PORT_DEFAULT}"
  [[ -x /usr/bin/node ]] || die "Node executable is not available at /usr/bin/node."
  [[ -f "$APP_DIR/src/launcher.js" ]] || die "Application launcher is missing."
  [[ -f "$APP_DIR/src/server.js" ]] || die "Application server is missing."
  [[ -f "$APP_DIR/.env" ]] || die "Environment file is missing."
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Snck Chat real-time server
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${group}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${APP_DIR}/.env
Environment=NODE_ENV=production
Environment=PORT=${port}
ExecStart=/usr/bin/node ${APP_DIR}/src/launcher.js
Restart=on-failure
RestartSec=3
TimeoutStartSec=30
TimeoutStopSec=15
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
UMask=027

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload
  ok "systemd service configured"
}

write_nginx(){
  [[ "$WORKSPACE_MODE" == true ]] && return 0
  load_env
  local port="${PORT:-$PORT_DEFAULT}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid PORT: $port"
  (( port >= 1 && port <= 65535 )) || die "PORT must be between 1 and 65535."
  cat > /etc/nginx/sites-available/snck-chat <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 10M;
    location / {
        proxy_pass http://127.0.0.1:${port};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 75s;
        proxy_send_timeout 75s;
    }
}
EOF
  ln -sfn /etc/nginx/sites-available/snck-chat /etc/nginx/sites-enabled/snck-chat
  rm -f /etc/nginx/sites-enabled/default
}

start_service(){
  [[ "$WORKSPACE_MODE" == true ]] && return 0
  step "Starting Snck Chat service"
  systemctl reset-failed "$SERVICE" 2>/dev/null || true
  systemctl enable "$SERVICE" >/dev/null
  systemctl restart "$SERVICE"
  for _ in {1..30}; do
    if systemctl is-active --quiet "$SERVICE"; then
      ok "Snck Chat service is running"
      return 0
    fi
    sleep 1
  done
  warn "Snck Chat did not remain active. Showing the real service log:"
  journalctl -u "$SERVICE" -n 120 --no-pager || true
  systemctl --no-pager --full status "$SERVICE" || true
  die "Snck Chat service did not start."
}

health_check(){
  load_env
  require_database_url
  local port="${PORT:-$PORT_DEFAULT}"
  step "Running final health check"
  if [[ "$WORKSPACE_MODE" == true ]]; then
    ok "Workspace mode ready: run npm start"
    return 0
  fi
  local response=""
  for _ in {1..30}; do
    if response="$(curl -4fsS --max-time 3 "http://127.0.0.1:${port}/api/health" 2>/dev/null)" && [[ "$response" == *'"ok":true'* ]]; then
      ok "Health check passed"
      return 0
    fi
    sleep 1
  done
  warn "Health endpoint failed on 127.0.0.1:${port}."
  ss -ltnp 2>/dev/null | grep -E ":${port}\b" || true
  journalctl -u "$SERVICE" -n 120 --no-pager || true
  die "Application health check failed."
}

install_app(){
  check_os; require_root; cd /
  install_deps; setup_user; clone_or_update; prepare_app
  if [[ "$WORKSPACE_MODE" != true ]]; then
    load_env
    chown -R "$APP_USER:$(id -gn "$APP_USER")" "$APP_DIR"
    chmod 600 "$APP_DIR/.env"
    write_service
    write_nginx
    nginx -t
    start_service
    nginx -t
    systemctl reload nginx
  fi
  health_check
  ok "Snck Chat installation completed successfully."
}

create_admin(){
  check_os; require_root; cd /
  [[ -f "$APP_DIR/package.json" ]] || die "Snck Chat is not installed at $APP_DIR."
  load_env; require_database_url; cd "$APP_DIR"
  /usr/bin/npm install --include=dev >/dev/null
  /usr/bin/npx prisma generate --schema "$APP_DIR/prisma/schema.prisma" >/dev/null
  /usr/bin/node "$APP_DIR/src/create-admin.js"
}

update_app(){ install_app; }
repair_app(){ install_app; }

uninstall_app(){
  check_os; require_root; cd /
  if [[ "$WORKSPACE_MODE" != true ]]; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}.service" "/etc/nginx/sites-enabled/snck-chat" "/etc/nginx/sites-available/snck-chat"
    systemctl daemon-reload
    nginx -t && systemctl reload nginx || true
  fi
  warn "Application files and PostgreSQL database were preserved for safety."
  ok "Snck Chat service configuration removed."
}

menu(){
  while true; do
    banner
    printf '%b\n' \
      "  ${WHITE}1${R}  Install Website       ${BLUE}Full installation${R}" \
      "  ${WHITE}2${R}  Create Admin User     ${BLUE}Secure admin account${R}" \
      "  ${WHITE}3${R}  Update Website        ${BLUE}Latest code + schema${R}" \
      "  ${WHITE}4${R}  Repair Installation   ${BLUE}Dependencies + services${R}" \
      "  ${WHITE}5${R}  Uninstall             ${BLUE}Disable safely${R}" \
      "  ${WHITE}6${R}  Exit                  ${BLUE}Quit${R}"
    line
    read -r -p "  Select an option: " choice
    case "$choice" in
      1) install_app; read -r -p "Press Enter to return to menu..." _ ;;
      2) create_admin; read -r -p "Press Enter to return to menu..." _ ;;
      3) update_app; read -r -p "Press Enter to return to menu..." _ ;;
      4) repair_app; read -r -p "Press Enter to return to menu..." _ ;;
      5) uninstall_app; read -r -p "Press Enter to return to menu..." _ ;;
      6) exit 0 ;;
      *) warn "Invalid option. Choose 1-6."; sleep 1 ;;
    esac
  done
}

main(){
  case "${1:-menu}" in
    install) install_app ;;
    admin) create_admin ;;
    update) update_app ;;
    repair) repair_app ;;
    uninstall) uninstall_app ;;
    menu) menu ;;
    *) die "Usage: install.sh [install|admin|update|repair|uninstall|menu]" ;;
  esac
}

main "$@"
