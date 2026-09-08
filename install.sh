#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
NODE_MAJOR=20
DEFAULT_VPS_DIR="/opt/snck-chat"

if [[ -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then
  APP_DIR="${SNCK_DIR:-$GITHUB_WORKSPACE}"
  WORKSPACE_MODE=true
else
  APP_DIR="${SNCK_DIR:-$DEFAULT_VPS_DIR}"
  WORKSPACE_MODE=false
fi

if [[ -t 1 ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'; WHITE=$'\033[97m'
else
  RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; WHITE=''
fi

banner(){
  clear 2>/dev/null || true
  printf '%b\n' "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  printf '%b\n' "${CYAN}${BOLD}║${RESET}                 ${WHITE}${BOLD}SNCK CHAT INSTALLER${RESET}                 ${CYAN}${BOLD}║${RESET}"
  printf '%b\n' "${CYAN}${BOLD}║${RESET}       ${DIM}Production • Realtime • Ubuntu • Workspace${RESET}       ${CYAN}${BOLD}║${RESET}"
  printf '%b\n' "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
}
line(){ printf '%b\n' "${CYAN}────────────────────────────────────────────────────────────${RESET}"; }
step(){ printf '\n%b\n' "${MAGENTA}${BOLD}▶ $*${RESET}"; }
ok(){ printf '%b\n' "${GREEN}✔${RESET} $*"; }
warn(){ printf '%b\n' "${YELLOW}⚠${RESET} $*"; }
info(){ printf '%b\n' "${BLUE}◆${RESET} $*"; }
die(){ printf '%b\n' "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }
trap 'die "Installation stopped at line $LINENO. See the error above."' ERR

require_root(){ [[ $EUID -eq 0 ]] || die "Run with sudo/root on an Ubuntu VPS."; }
have_systemd(){ command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

check_os(){
  [[ -r /etc/os-release ]] || die "Cannot detect operating system."
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu only."
  ok "Ubuntu ${VERSION_ID:-unknown} detected"
  if [[ "$WORKSPACE_MODE" == true ]]; then ok "GitHub Workspace/Codespaces mode"; else ok "Ubuntu VPS production mode"; fi
}

install_deps(){
  step "Installing required dependencies"
  require_root
  local packages=(curl git openssl ca-certificates build-essential postgresql postgresql-contrib sudo)
  [[ "$WORKSPACE_MODE" == true ]] || packages+=(nginx)
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"

  local major=0
  if command -v node >/dev/null 2>&1; then major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"; fi
  if (( major < NODE_MAJOR )); then
    info "Installing Node.js ${NODE_MAJOR}.x"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  fi
  command -v node >/dev/null 2>&1 || die "Node.js installation failed."
  command -v npm >/dev/null 2>&1 || die "npm installation failed."
  ok "Node $(node -v) • npm $(npm -v)"
}

setup_user(){
  [[ "$WORKSPACE_MODE" == true ]] && return 0
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
  ok "Service user ready: $APP_USER"
}

start_postgres(){
  if have_systemd; then systemctl enable --now postgresql >/dev/null 2>&1 || true; fi
  pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1
}

setup_db(){
  step "Configuring PostgreSQL"
  if [[ -n "${DATABASE_URL:-}" ]]; then
    if start_postgres; then info "Using configured DATABASE_URL with local PostgreSQL."; else info "Using configured DATABASE_URL (external database)."; fi
    return 0
  fi
  start_postgres || die "PostgreSQL is not reachable."
  DBPASS="${SNCK_DB_PASSWORD:-$(openssl rand -hex 32)}"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -v snck_password="$DBPASS" <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'snck') THEN
    EXECUTE format('CREATE ROLE snck LOGIN PASSWORD %L', :'snck_password');
  ELSE
    EXECUTE format('ALTER ROLE snck WITH LOGIN PASSWORD %L', :'snck_password');
  END IF;
END
$$;
SQL
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q 1; then
    sudo -u postgres createdb -O snck snck_chat
  fi
  ok "Database ready: snck_chat"
}

clone_or_update(){
  if [[ -f "$APP_DIR/package.json" && -f "$APP_DIR/src/server.js" ]]; then
    ok "Using existing source: $APP_DIR"
    if [[ -d "$APP_DIR/.git" ]]; then
      cd "$APP_DIR"
      info "Checking for latest Snck Chat fixes..."
      git fetch --quiet origin main
      git reset --hard --quiet origin/main
      ok "Source updated from main"
    fi
    return 0
  fi
  mkdir -p "$(dirname "$APP_DIR")"
  if [[ -e "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then
    die "$APP_DIR exists and is not an empty Snck Chat directory. Use SNCK_DIR to choose another path."
  fi
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
  ok "Snck Chat source downloaded"
}

load_env(){
  if [[ -f "$APP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$APP_DIR/.env"
    set +a
  fi
}

write_env(){
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
    chmod 600 "$APP_DIR/.env"
    warn "Existing .env preserved"
  fi
}

require_database_url(){ [[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL is missing from $APP_DIR/.env."; }

prepare_app(){
  clone_or_update
  load_env
  setup_db
  write_env
  load_env
  require_database_url
  cd "$APP_DIR"

  step "Installing application dependencies"
  npm install --include=dev
  ok "Dependencies installed"

  step "Validating Prisma schema"
  npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"
  ok "Prisma schema valid"

  step "Generating Prisma Client"
  npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"
  ok "Prisma Client generated"

  # Do not call `prisma db execute` here. The installer uses the explicit
  # schema synchronization command below and PostgreSQL directly for seed SQL.
  step "Synchronizing database schema"
  npx prisma db push --schema "$APP_DIR/prisma/schema.prisma" --skip-generate
  ok "Database schema synchronized"

  if [[ -f "$APP_DIR/prisma/seed.sql" ]]; then
    step "Initializing global chat"
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$APP_DIR/prisma/seed.sql" >/dev/null
    ok "Global chat initialized"
  fi

  step "Running application checks"
  npm run check
  npm test
  ok "Application checks passed"
}

write_service(){
  [[ "$WORKSPACE_MODE" == true ]] && return 0
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
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null
  ok "systemd service configured"
}

write_nginx(){
  [[ "$WORKSPACE_MODE" == true ]] && return 0
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
        proxy_send_timeout 60s;
    }
}
EOF
  ln -sfn "/etc/nginx/sites-available/${SERVICE}" "/etc/nginx/sites-enabled/${SERVICE}"
  rm -f /etc/nginx/sites-enabled/default
  nginx -t >/dev/null
  ok "Nginx + WebSocket proxy configured"
}

health_check(){
  load_env
  require_database_url
  local port="${PORT:-3000}"
  step "Running final health check"
  if [[ "$WORKSPACE_MODE" == true ]]; then
    local logfile pid
    logfile="$(mktemp)"
    node "$APP_DIR/src/server.js" >"$logfile" 2>&1 & pid=$!
    sleep 3
    if ! curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/health" >/dev/null; then
      cat "$logfile"
      kill "$pid" 2>/dev/null || true
      rm -f "$logfile"
      die "Application health check failed."
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$logfile"
  else
    systemctl restart "$SERVICE"
    sleep 2
    if ! systemctl is-active --quiet "$SERVICE"; then
      journalctl -u "$SERVICE" -n 100 --no-pager
      die "Snck Chat service failed to start."
    fi
    if ! curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/health" >/dev/null; then
      journalctl -u "$SERVICE" -n 100 --no-pager
      die "Application health check failed."
    fi
    nginx -t >/dev/null
    systemctl reload nginx
  fi
  ok "Health check passed"
}

print_ready(){
  load_env
  echo
  line
  printf '%b\n' "${GREEN}${BOLD}                    ✔ SNCK CHAT READY${RESET}"
  line
  printf '%b\n' "${CYAN}Directory:${RESET} $APP_DIR"
  printf '%b\n' "${CYAN}Port:${RESET}      ${PORT:-3000}"
  if [[ "$WORKSPACE_MODE" == true ]]; then
    printf '%b\n' "${CYAN}Mode:${RESET}      GitHub Workspace/Codespaces"
    printf '%b\n' "${CYAN}Start:${RESET}     npm start"
    printf '%b\n' "${CYAN}Next:${RESET}      Forward port ${PORT:-3000}"
  else
    printf '%b\n' "${CYAN}Mode:${RESET}      Ubuntu VPS"
    printf '%b\n' "${CYAN}Service:${RESET}   $SERVICE"
    printf '%b\n' "${CYAN}Public:${RESET}    http://YOUR_VPS_IP"
  fi
  line
}

install_app(){
  check_os
  [[ "$WORKSPACE_MODE" == true ]] || require_root
  install_deps
  setup_user
  prepare_app
  if [[ "$WORKSPACE_MODE" != true ]]; then
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    chmod 600 "$APP_DIR/.env"
    write_service
    write_nginx
  fi
  health_check
  print_ready
}

update_app(){
  check_os
  [[ "$WORKSPACE_MODE" == true ]] || require_root
  [[ -d "$APP_DIR/.git" ]] || die "No Snck Chat Git installation found at $APP_DIR."
  clone_or_update
  load_env
  require_database_url
  prepare_app
  if [[ "$WORKSPACE_MODE" != true ]]; then
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    chmod 600 "$APP_DIR/.env"
    write_service
    write_nginx
  fi
  health_check
  print_ready
}

repair(){
  check_os
  [[ "$WORKSPACE_MODE" == true ]] || require_root
  [[ -d "$APP_DIR" ]] || die "No Snck Chat installation found at $APP_DIR."
  load_env
  prepare_app
  if [[ "$WORKSPACE_MODE" != true ]]; then
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    chmod 600 "$APP_DIR/.env"
    write_service
    write_nginx
  fi
  health_check
  print_ready
}

create_admin(){
  [[ "$WORKSPACE_MODE" == true ]] || require_root
  [[ -f "$APP_DIR/src/create-admin.js" ]] || die "Install Snck Chat first."
  load_env
  require_database_url
  cd "$APP_DIR"
  step "Creating administrator account"
  if [[ "$WORKSPACE_MODE" == true ]]; then
    env NODE_ENV=production DATABASE_URL="$DATABASE_URL" node src/create-admin.js
  else
    sudo -u "$APP_USER" env NODE_ENV=production DATABASE_URL="$DATABASE_URL" node src/create-admin.js
  fi
}

uninstall_app(){
  [[ "$WORKSPACE_MODE" == true ]] || require_root
  banner
  warn "This removes the Snck Chat application and service."
  read -r -p "Type REMOVE to continue: " confirm
  [[ "$confirm" == "REMOVE" ]] || { info "Uninstall cancelled."; return 0; }
  if [[ "$WORKSPACE_MODE" != true ]]; then
    systemctl disable --now "$SERVICE" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE}.service"
    rm -f "/etc/nginx/sites-enabled/${SERVICE}" "/etc/nginx/sites-available/${SERVICE}"
    systemctl daemon-reload
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    userdel "$APP_USER" 2>/dev/null || true
  fi
  rm -rf "$APP_DIR"
  ok "Snck Chat removed"
}

menu(){
  while true; do
    banner
    line
    printf '%b\n' "  ${WHITE}${BOLD}1${RESET}  Install Website       ${DIM}Full installation${RESET}"
    printf '%b\n' "  ${WHITE}${BOLD}2${RESET}  Create Admin User     ${DIM}Secure administrator${RESET}"
    printf '%b\n' "  ${WHITE}${BOLD}3${RESET}  Update Website        ${DIM}Latest code + schema${RESET}"
    printf '%b\n' "  ${WHITE}${BOLD}4${RESET}  Repair Installation   ${DIM}Repair dependencies${RESET}"
    printf '%b\n' "  ${WHITE}${BOLD}5${RESET}  Uninstall             ${DIM}Remove safely${RESET}"
    printf '%b\n' "  ${WHITE}${BOLD}6${RESET}  Exit                  ${DIM}Quit installer${RESET}"
    line
    read -r -p "  Select an option: " choice
    case "$choice" in
      1) install_app; read -r -p "Press Enter to return to menu..." _ ;;
      2) create_admin; read -r -p "Press Enter to return to menu..." _ ;;
      3) update_app; read -r -p "Press Enter to return to menu..." _ ;;
      4) repair; read -r -p "Press Enter to return to menu..." _ ;;
      5) uninstall_app; read -r -p "Press Enter to return to menu..." _ ;;
      6) exit 0 ;;
      *) warn "Invalid option. Choose 1-6."; sleep 1 ;;
    esac
  done
}

main(){
  case "${1:-menu}" in
    install) install_app ;;
    admin|create-admin) create_admin ;;
    update) update_app ;;
    repair) repair ;;
    uninstall) uninstall_app ;;
    menu) menu ;;
    *) die "Usage: $0 [menu|install|admin|update|repair|uninstall]" ;;
  esac
}

main "$@"
