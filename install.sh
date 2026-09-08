#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
APP_DIR="${SNCK_DIR:-/opt/snck-chat}"
NODE_MAJOR=20

if [[ -t 1 ]]; then
  R=$'\033[0m'; B=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; MAGENTA=$'\033[35m'; WHITE=$'\033[97m'
else
  R=''; B=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; WHITE=''
fi

banner(){ clear 2>/dev/null || true; printf '%b\n' "${CYAN}${B}╔══════════════════════════════════════════════════════════╗${R}" "${CYAN}${B}║${R}                 ${WHITE}${B}SNCK CHAT INSTALLER${R}                 ${CYAN}${B}║${R}" "${CYAN}${B}║${R}       ${B}Production • Realtime • Ubuntu • Workspace${R}       ${CYAN}${B}║${R}" "${CYAN}${B}╚══════════════════════════════════════════════════════════╝${R}"; }
line(){ printf '%b\n' "${CYAN}────────────────────────────────────────────────────────────${R}"; }
step(){ printf '\n%b\n' "${MAGENTA}${B}▶ $*${R}"; }
ok(){ printf '%b\n' "${GREEN}✔${R} $*"; }
warn(){ printf '%b\n' "${YELLOW}⚠${R} $*"; }
info(){ printf '%b\n' "${BLUE}◆${R} $*"; }
die(){ printf '%b\n' "${RED}✖ ERROR:${R} $*" >&2; exit 1; }
trap 'rc=$?; printf "%b\n" "${RED}✖ ERROR:${R} Installer failed at line $LINENO. Command: $BASH_COMMAND" >&2; exit "$rc"' ERR

# Always recover from a deleted launch directory before doing any filesystem work.
cd / || exit 1

WORKSPACE_MODE=false
if [[ "${CODESPACES:-}" == "true" && -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then
  APP_DIR="${SNCK_DIR:-$GITHUB_WORKSPACE}"
  WORKSPACE_MODE=true
fi

require_root(){ [[ ${EUID:-99} -eq 0 ]] || die "Run with sudo/root on an Ubuntu VPS."; }
have_systemd(){ command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }
check_os(){
  [[ -r /etc/os-release ]] || die "Cannot detect operating system."
  . /etc/os-release
  [[ "${ID:-}" == ubuntu ]] || die "This installer supports Ubuntu only."
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
  if command -v node >/dev/null 2>&1; then major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || printf '0')"; fi
  [[ "$major" =~ ^[0-9]+$ ]] || major=0
  if (( major < NODE_MAJOR )); then
    info "Installing Node.js ${NODE_MAJOR}.x"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  fi
  command -v node >/dev/null 2>&1 || die "Node.js installation failed."
  command -v npm >/dev/null 2>&1 || die "npm installation failed."
  local node_version npm_version
  node_version="$(node --version)" || die "Node.js version check failed."
  npm_version="$(npm --version)" || die "npm version check failed."
  [[ -n "$node_version" && -n "$npm_version" ]] || die "Node.js/npm version check returned an empty value."
  ok "Node $node_version • npm $npm_version"
}

setup_user(){
  [[ "$WORKSPACE_MODE" == true ]] && return 0
  if ! id "$APP_USER" >/dev/null 2>&1; then useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"; fi
  ok "Service user ready: $APP_USER"
}

start_postgres(){
  if have_systemd; then systemctl enable --now postgresql >/dev/null 2>&1 || true; fi
  for _ in {1..30}; do pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

sql_escape(){ printf '%s' "$1" | sed "s/'/''/g"; }

setup_db(){
  step "Configuring PostgreSQL"
  if [[ -n "${DATABASE_URL:-}" ]]; then info "Using configured DATABASE_URL."; return 0; fi
  start_postgres || die "PostgreSQL is not reachable on 127.0.0.1:5432."
  DBPASS="${SNCK_DB_PASSWORD:-$(openssl rand -hex 32)}"
  local escaped
  escaped="$(sql_escape "$DBPASS")"
  # Avoid psql's :'variable' syntax because it can fail depending on command/quoting context.
  if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='snck'" | grep -q '1'; then
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE snck WITH LOGIN PASSWORD '${escaped}';"
  else
    sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE snck WITH LOGIN PASSWORD '${escaped}';"
  fi
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q '1'; then sudo -u postgres createdb -O snck snck_chat; fi
  ok "Database ready: snck_chat"
}

clone_or_update(){
  cd / || die "Cannot access filesystem root."
  if [[ -f "$APP_DIR/package.json" && -f "$APP_DIR/src/server.js" ]]; then
    ok "Using existing source: $APP_DIR"
    if [[ -d "$APP_DIR/.git" ]]; then
      cd "$APP_DIR"
      info "Checking for latest Snck Chat fixes..."
      if git fetch --quiet origin main; then git reset --hard --quiet origin/main || die "Could not update the existing source."; ok "Source updated from main"; else warn "Could not contact GitHub; continuing with existing source."; fi
    fi
    return 0
  fi
  mkdir -p "$(dirname "$APP_DIR")"
  if [[ -e "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then die "$APP_DIR exists and is not an empty Snck Chat directory. Set SNCK_DIR to another path."; fi
  git clone --depth 1 "$REPO_URL" "$APP_DIR" || die "Git clone failed."
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
    return
  fi
  if ! grep -Eq '^DATABASE_URL=' "$APP_DIR/.env"; then
    [[ -n "${DBPASS:-}" ]] || DBPASS="${SNCK_DB_PASSWORD:-$(openssl rand -hex 32)}"
    printf '\nDATABASE_URL=postgresql://snck:%s@127.0.0.1:5432/snck_chat\n' "$DBPASS" >> "$APP_DIR/.env"
    ok "DATABASE_URL added to existing .env"
  fi
  if ! grep -Eq '^PORT=' "$APP_DIR/.env"; then printf 'PORT=%s\n' "${SNCK_PORT:-3000}" >> "$APP_DIR/.env"; fi
  if ! grep -Eq '^NODE_ENV=' "$APP_DIR/.env"; then printf 'NODE_ENV=production\n' >> "$APP_DIR/.env"; fi
  chmod 600 "$APP_DIR/.env"
  warn "Existing .env preserved and repaired where required"
}

require_database_url(){ load_env; [[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL is missing from $APP_DIR/.env and could not be created."; }

prepare_app(){
  cd / || die "Cannot access filesystem root."
  load_env
  setup_db
  write_env
  load_env
  require_database_url
  cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"
  step "Installing application dependencies"
  npm install --include=dev
  step "Validating Prisma schema"
  npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"
  step "Generating Prisma Client"
  npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"
  step "Synchronizing database schema"
  npx prisma db push --schema "$APP_DIR/prisma/schema.prisma" --skip-generate
  if [[ -f "$APP_DIR/prisma/seed.js" ]]; then step "Initializing database"; node "$APP_DIR/prisma/seed.js"; fi
  step "Running application checks"
  npm run check
  npm test
  ok "Application checks passed"
}

write_service(){
  [[ "$WORKSPACE_MODE" == true ]] && return 0
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Snck Chat real-time server
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
  [[ "$WORKSPACE_MODE" == true ]] && return 0
  load_env
  local port="${PORT:-3000}"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid PORT in .env: $port"
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
    }
}
EOF
  ln -sfn /etc/nginx/sites-available/snck-chat /etc/nginx/sites-enabled/snck-chat
  rm -f /etc/nginx/sites-enabled/default
}

health_check(){
  load_env; require_database_url
  local port="${PORT:-3000}"
  step "Running final health check"
  if [[ "$WORKSPACE_MODE" != true ]] && have_systemd; then
    systemctl is-active --quiet "$SERVICE" || { systemctl --no-pager --full status "$SERVICE"; die "Snck Chat service failed to start."; }
    curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/health" >/dev/null || { journalctl -u "$SERVICE" -n 80 --no-pager; die "Application health check failed."; }
  else
    local log_file pid
    log_file="$(mktemp)"
    (cd "$APP_DIR" && node src/server.js) >"$log_file" 2>&1 & pid=$!
    sleep 2
    if ! curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/health" >/dev/null; then cat "$log_file"; kill "$pid" 2>/dev/null || true; rm -f "$log_file"; die "Application health check failed."; fi
    kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$log_file"
  fi
  ok "Health check passed"
}

print_ready(){
  load_env; echo; line
  printf '%b\n' "${GREEN}${B}                    ✔ SNCK CHAT READY${R}"; line
  printf '%b\n' "${CYAN}Directory:${R} $APP_DIR" "${CYAN}Port:${R}      ${PORT:-3000}"
  if [[ "$WORKSPACE_MODE" == true ]]; then printf '%b\n' "${CYAN}Mode:${R}      GitHub Workspace" "${CYAN}Start:${R}     npm start" "${CYAN}Next:${R}      Forward port ${PORT:-3000} in the Ports tab"; else printf '%b\n' "${CYAN}Mode:${R}      Ubuntu VPS" "${CYAN}Service:${R}   $SERVICE" "${CYAN}Public:${R}    http://YOUR_VPS_IP"; fi
  line
}

install_app(){
  check_os; require_root; cd / || die "Cannot access filesystem root."; install_deps; setup_user; clone_or_update; prepare_app
  if [[ "$WORKSPACE_MODE" != true ]]; then
    chown -R "$APP_USER:$APP_USER" "$APP_DIR"; chmod 600 "$APP_DIR/.env"; write_service; write_nginx; nginx -t
    systemctl daemon-reload; systemctl enable --now "$SERVICE"; systemctl is-active --quiet "$SERVICE" || die "Snck Chat service did not start."; nginx -t; systemctl reload nginx
  fi
  health_check; print_ready
}

create_admin(){
  check_os; require_root; cd / || die "Cannot access filesystem root."; clone_or_update; load_env; require_database_url; cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"; npm install --include=dev; npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"; node src/create-admin.js
}

update_app(){
  check_os; require_root; cd / || die "Cannot access filesystem root."; clone_or_update; load_env; require_database_url; cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"; npm install --include=dev; npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"; npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"; npx prisma db push --schema "$APP_DIR/prisma/schema.prisma" --skip-generate; npm run check; npm test
  if [[ "$WORKSPACE_MODE" != true ]]; then chown -R "$APP_USER:$APP_USER" "$APP_DIR"; write_service; write_nginx; nginx -t; systemctl daemon-reload; systemctl restart "$SERVICE"; systemctl is-active --quiet "$SERVICE" || die "Snck Chat service failed after update."; systemctl reload nginx; fi
  health_check; print_ready
}

repair_app(){
  check_os; require_root; cd / || die "Cannot access filesystem root."
  if [[ ! -d "$APP_DIR" ]]; then mkdir -p "$APP_DIR"; fi
  clone_or_update; load_env
  if [[ -z "${DATABASE_URL:-}" ]]; then setup_db; write_env; load_env; fi
  require_database_url
  cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"
  npm install --include=dev
  npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"
  npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"
  npx prisma db push --schema "$APP_DIR/prisma/schema.prisma" --skip-generate
  [[ -f "$APP_DIR/prisma/seed.js" ]] && node "$APP_DIR/prisma/seed.js"
  npm run check; npm test
  if [[ "$WORKSPACE_MODE" != true ]]; then chown -R "$APP_USER:$APP_USER" "$APP_DIR"; write_service; write_nginx; nginx -t; systemctl daemon-reload; systemctl enable --now "$SERVICE"; systemctl is-active --quiet "$SERVICE" || die "Snck Chat service failed during repair."; systemctl reload nginx; fi
  health_check; print_ready
}

uninstall_app(){
  check_os; require_root
  if have_systemd; then systemctl disable --now "$SERVICE" 2>/dev/null || true; fi
  rm -f "/etc/systemd/system/${SERVICE}.service"
  if command -v nginx >/dev/null 2>&1; then rm -f /etc/nginx/sites-enabled/snck-chat /etc/nginx/sites-available/snck-chat; nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true; fi
  systemctl daemon-reload 2>/dev/null || true
  if [[ -d "$APP_DIR" ]]; then read -r -p "Delete application directory $APP_DIR? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && rm -rf "$APP_DIR" && ok "Application directory removed" || info "Application files preserved"; fi
  ok "Snck Chat service configuration removed"
}

menu(){
  while true; do
    banner; line
    printf '%b\n' "  ${CYAN}${B}1${R}  Install Website       Full installation" "  ${CYAN}${B}2${R}  Create Admin User     Secure admin account" "  ${CYAN}${B}3${R}  Update Website        Latest code + database" "  ${CYAN}${B}4${R}  Repair Installation   Repair app/services" "  ${CYAN}${B}5${R}  Uninstall             Remove service safely" "  ${CYAN}${B}6${R}  Exit"
    line
    read -r -p "  Select an option: " choice
    case "$choice" in
      1) install_app; read -r -p $'\nPress Enter to return to menu...' _ ;;
      2) create_admin; read -r -p $'\nPress Enter to return to menu...' _ ;;
      3) update_app; read -r -p $'\nPress Enter to return to menu...' _ ;;
      4) repair_app; read -r -p $'\nPress Enter to return to menu...' _ ;;
      5) uninstall_app; read -r -p $'\nPress Enter to return to menu...' _ ;;
      6|q|Q) exit 0 ;;
      *) warn "Invalid option. Choose 1-6."; sleep 1 ;;
    esac
  done
}

main(){
  local action="${1:-install}"
  case "$action" in
    install) install_app ;;
    admin|create-admin) create_admin ;;
    update) update_app ;;
    repair) repair_app ;;
    uninstall) uninstall_app ;;
    menu) menu ;;
    *) banner; printf '\nUsage: %s [install|admin|update|repair|uninstall|menu]\n' "$0"; exit 2 ;;
  esac
}

main "$@"
