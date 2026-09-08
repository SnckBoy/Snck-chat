#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
NODE_MAJOR=20
DEFAULT_VPS_DIR="/opt/snck-chat"
IS_CODESPACE="${CODESPACES:-false}"
if [[ -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then DEFAULT_DIR="$GITHUB_WORKSPACE"; else DEFAULT_DIR="$DEFAULT_VPS_DIR"; fi
APP_DIR="${SNCK_DIR:-$DEFAULT_DIR}"

if [[ -t 1 ]]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'; WHITE=$'\033[97m'
else
  RESET=''; BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; WHITE=''
fi

banner(){
  clear 2>/dev/null || true
  printf '%b\n' "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
  printf '%b\n' "${CYAN}${BOLD}║${RESET}                 ${WHITE}${BOLD}SNCK CHAT INSTALLER${RESET}                 ${CYAN}${BOLD}║${RESET}"
  printf '%b\n' "${CYAN}${BOLD}║${RESET}        ${DIM}Production • Realtime • Ubuntu • Workspace${RESET}        ${CYAN}${BOLD}║${RESET}"
  printf '%b\n' "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
}
line(){ printf '%b\n' "${CYAN}────────────────────────────────────────────────────────────${RESET}"; }
step(){ printf '\n%b\n' "${MAGENTA}${BOLD}▶ $*${RESET}"; }
ok(){ printf '%b\n' "${GREEN}✔${RESET} $*"; }
warn(){ printf '%b\n' "${YELLOW}⚠${RESET} $*"; }
log(){ printf '%b\n' "${BLUE}◆${RESET} $*"; }
fail(){ printf '%b\n' "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Run with sudo/root on an Ubuntu VPS."; }
have_systemd(){ command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }

check_os(){
  [[ -r /etc/os-release ]] || fail "Cannot detect operating system."; . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "This installer supports Ubuntu only."
  ok "Ubuntu ${VERSION_ID:-unknown} detected"
  if [[ "$IS_CODESPACE" == "true" ]]; then ok "GitHub Codespaces/Workspace mode"; else ok "Ubuntu VPS production mode"; fi
}

install_deps(){
  step "Installing required dependencies"
  local packages=(curl git nginx postgresql postgresql-contrib openssl ca-certificates build-essential)
  if [[ "$IS_CODESPACE" != "true" ]]; then packages+=(sudo)
  fi
  if [[ $EUID -eq 0 ]]; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  elif command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "${packages[@]}"
  else
    for p in curl git openssl ca-certificates; do command -v "$p" >/dev/null 2>&1 || fail "$p is required."; done
  fi

  if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'Number(process.versions.node.split(".")[0])')" -lt "$NODE_MAJOR" ]]; then
    if [[ $EUID -eq 0 ]]; then
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
      DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
    elif command -v sudo >/dev/null 2>&1; then
      curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | sudo -E bash -
      DEBIAN_FRONTEND=noninteractive sudo apt-get install -y nodejs
    else
      fail "Node.js ${NODE_MAJOR}+ is required."
    fi
  fi
  ok "Node $(node -v) • npm $(npm -v)"
}

setup_user(){
  [[ "$IS_CODESPACE" == "true" ]] && return 0
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
  ok "Service user ready: $APP_USER"
}

start_postgres(){
  if have_systemd; then
    systemctl enable --now postgresql
  elif command -v pg_ctlcluster >/dev/null 2>&1; then
    local version; version="$(pg_lsclusters -h 2>/dev/null | awk 'NR==1{print $1}')"
    [[ -z "$version" ]] || pg_ctlcluster "$version" main start 2>/dev/null || true
  fi
  pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1
}

setup_db(){
  step "Configuring PostgreSQL"
  if [[ -n "${DATABASE_URL:-}" ]]; then
    if start_postgres 2>/dev/null; then
      log "Using configured DATABASE_URL with local PostgreSQL."
    else
      log "Using configured DATABASE_URL (external database)."
    fi
    return 0
  fi

  start_postgres || fail "PostgreSQL is not reachable."
  DBPASS="${SNCK_DB_PASSWORD:-$(openssl rand -hex 32)}"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN CREATE ROLE snck LOGIN PASSWORD '${DBPASS}'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE snck WITH LOGIN PASSWORD '${DBPASS}'; END \$\$;"
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
      log "Checking for latest Snck Chat fixes..."
      git fetch origin main
      git reset --hard origin/main
      git clean -fd -e .env
      ok "Source updated from main"
    fi
    return 0
  fi

  mkdir -p "$(dirname "$APP_DIR")"
  [[ ! -e "$APP_DIR" ]] || fail "$APP_DIR exists but is not a Snck Chat checkout. Set SNCK_DIR to another directory."
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
  [[ -n "${DATABASE_URL:-}" ]] || fail "DATABASE_URL is missing from $APP_DIR/.env."
}

prepare_app(){
  clone_or_update
  load_env
  setup_db
  write_env
  load_env
  require_database_url
  cd "$APP_DIR"

  step "Installing application dependencies"
  npm install
  ok "Dependencies installed"

  step "Validating Prisma schema"
  npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"
  ok "Prisma schema valid"

  step "Generating Prisma Client"
  npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"
  ok "Prisma Client generated"

  if [[ ! -d prisma/migrations || -z "$(find prisma/migrations -name '*.sql' -print -quit 2>/dev/null)" ]]; then
    mkdir -p prisma/migrations/0001_init
    npx prisma migrate diff --from-empty --to-schema-datamodel prisma/schema.prisma --script > prisma/migrations/0001_init/migration.sql
  fi

  step "Applying database migrations"
  npx prisma migrate deploy --schema "$APP_DIR/prisma/schema.prisma"
  ok "Database migrations applied"

  # Use PostgreSQL directly for the SQL seed. This avoids Prisma CLI db-execute
  # argument differences between Prisma 6.x releases.
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
        proxy_send_timeout 60s;
    }
}
EOF
  ln -sfn "/etc/nginx/sites-available/${SERVICE}" "/etc/nginx/sites-enabled/${SERVICE}"
  rm -f /etc/nginx/sites-enabled/default
  ok "Nginx + WebSocket proxy configured"
}

health_check(){
  load_env
  require_database_url
  local port="${PORT:-3000}"
  step "Running final health check"

  if [[ "$IS_CODESPACE" != "true" ]] && have_systemd; then
    systemctl is-active --quiet "$SERVICE" || { systemctl --no-pager --full status "$SERVICE"; fail "Snck Chat service failed to start."; }
    curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/health" >/dev/null || { journalctl -u "$SERVICE" -n 80 --no-pager; fail "Application health check failed."; }
    nginx -t >/dev/null || fail "Nginx configuration test failed."
  else
    local log_file="$(mktemp)" pid=""
    node src/server.js >"$log_file" 2>&1 & pid=$!
    sleep 2
    if ! curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/health" >/dev/null; then
      cat "$log_file"
      kill "$pid" 2>/dev/null || true
      rm -f "$log_file"
      fail "Application health check failed."
    fi
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rm -f "$log_file"
  fi
  ok "Health check passed"
}

install_app(){
  check_os
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  install_deps
  setup_user
  clone_or_update
  load_env
  setup_db
  write_env
  load_env
  require_database_url
  prepare_app

  if [[ "$IS_CODESPACE" == "true" ]]; then
    health_check
    print_ready
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
  health_check
  print_ready
}

update_app(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  [[ -d "$APP_DIR/.git" ]] || fail "No Snck Chat installation found at $APP_DIR."
  prepare_app
  if [[ "$IS_CODESPACE" != "true" ]]; then
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    chmod 600 "$APP_DIR/.env"
    write_service
    write_nginx
    systemctl daemon-reload
    systemctl restart "$SERVICE"
    nginx -t
    systemctl reload nginx
  fi
  health_check
  print_ready
}

repair(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  [[ -d "$APP_DIR" ]] || fail "No Snck Chat installation found at $APP_DIR."
  prepare_app
  if [[ "$IS_CODESPACE" != "true" ]]; then
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"
    chmod 600 "$APP_DIR/.env"
    write_service
    write_nginx
    systemctl daemon-reload
    systemctl restart "$SERVICE"
    nginx -t
    systemctl reload nginx
  fi
  health_check
  print_ready
}

create_admin(){
  [[ "$IS_CODESPACE" == "true" ]] || need_root
  [[ -f "$APP_DIR/src/create-admin.js" ]] || fail "Install Snck Chat first."
  load_env
  require_database_url
  cd "$APP_DIR"
  step "Creating administrator account"
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
    nginx -t >/dev/null 2>&1 && systemctl reload nginx || true
    userdel "$APP_USER" 2>/dev/null || true
  fi
  rm -rf "$APP_DIR"
  ok "Snck Chat application removed. Database was preserved."
}

print_ready(){
  load_env
  echo
  line
  printf '%b\n' "${GREEN}${BOLD}                    ✔ SNCK CHAT READY${RESET}"
  line
  printf '%b\n' "${CYAN}Directory:${RESET} $APP_DIR\n"
  printf '%b\n' "${CYAN}Port:${RESET}      ${PORT:-3000}"
  if [[ "$IS_CODESPACE" == "true" ]]; then
    printf '%b\n' "${CYAN}Mode:${RESET}      GitHub Workspace"
    printf '%b\n' "${CYAN}Start:${RESET}     npm start"
    printf '%b\n' "${CYAN}Next:${RESET}      Forward port ${PORT:-3000} in the Ports tab"
  else
    printf '%b\n' "${CYAN}Mode:${RESET}      Ubuntu VPS"
    printf '%b\n' "${CYAN}Service:${RESET}   $SERVICE"
    printf '%b\n' "${CYAN}Public:${RESET}    http://YOUR_VPS_IP"
  fi
  line
}

menu(){
  while true; do
    banner
    line
    printf '%b\n' "  ${GREEN}1${RESET}  Install Website       Full installation"
    printf '%b\n' "  ${BLUE}2${RESET}  Create Admin User     Secure admin account"
    printf '%b\n' "  ${MAGENTA}3${RESET}  Update Website        Latest code + migrations"
    printf '%b\n' "  ${YELLOW}4${RESET}  Repair Installation   Repair dependencies/services"
    printf '%b\n' "  ${RED}5${RESET}  Uninstall             Remove application safely"
    printf '%b\n' "  ${WHITE}6${RESET}  Exit                  Quit"
    line
    read -r -p '  Select an option: ' choice
    case "$choice" in
      1) install_app; read -r -p 'Press Enter to return to menu...' _ ;;
      2) create_admin; read -r -p 'Press Enter to return to menu...' _ ;;
      3) update_app; read -r -p 'Press Enter to return to menu...' _ ;;
      4) repair; read -r -p 'Press Enter to return to menu...' _ ;;
      5) uninstall_app; read -r -p 'Press Enter to return to menu...' _ ;;
      6) exit 0 ;;
      *) warn 'Invalid option. Choose 1-6.'; sleep 1 ;;
    esac
  done
}

main(){
  local command="${1:-menu}"
  case "$command" in
    install) install_app ;;
    menu) menu ;;
    admin|create-admin) create_admin ;;
    update) update_app ;;
    repair) repair ;;
    uninstall) uninstall_app ;;
    help|-h|--help)
      printf '%s\n' 'Snck Chat installer:' '  install       Install/update and start the application' '  menu          Open the interactive installer menu (default)' '  admin         Create an administrator account' '  update        Update the application' '  repair        Repair dependencies/database/services' '  uninstall     Remove application files/services' ;;
    *) fail "Unknown command: $command. Use: install, menu, admin, update, repair, uninstall" ;;
  esac
}

trap 'fail "Installer failed at line $LINENO. Command: $BASH_COMMAND"' ERR
main "$@"
