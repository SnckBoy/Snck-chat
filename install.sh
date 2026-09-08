#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
NODE_MAJOR=20
DEFAULT_VPS_DIR="/opt/snck-chat"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || { printf 'Cannot determine the installer directory.\n' >&2; exit 1; }
if [[ -f "$SCRIPT_DIR/package.json" && -f "$SCRIPT_DIR/src/server.js" && -f "$SCRIPT_DIR/prisma/schema.prisma" ]]; then BUNDLE_DIR="$SCRIPT_DIR"; else BUNDLE_DIR=""; fi
cd / 2>/dev/null || true
if [[ "${CODESPACES:-}" == "true" && -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then APP_DIR="${SNCK_DIR:-$GITHUB_WORKSPACE}"; WORKSPACE_MODE=true; else APP_DIR="${SNCK_DIR:-$DEFAULT_VPS_DIR}"; WORKSPACE_MODE=false; fi
if [[ -t 1 ]]; then RESET=$'\033[0m'; BOLD=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; MAGENTA=$'\033[35m'; CYAN=$'\033[36m'; WHITE=$'\033[97m'; else RESET=''; BOLD=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; WHITE=''; fi
banner(){ clear 2>/dev/null || true; printf '%b\n' "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"; printf '%b\n' "${CYAN}${BOLD}║${RESET}                 ${WHITE}${BOLD}SNCK CHAT INSTALLER${RESET}                 ${CYAN}${BOLD}║${RESET}"; printf '%b\n' "${CYAN}${BOLD}║${RESET}       ${BOLD}Production • Realtime • Ubuntu • Workspace${RESET}       ${CYAN}${BOLD}║${RESET}"; printf '%b\n' "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"; }
line(){ printf '%b\n' "${CYAN}────────────────────────────────────────────────────────────${RESET}"; }
step(){ printf '\n%b\n' "${MAGENTA}${BOLD}▶ $*${RESET}"; }
ok(){ printf '%b\n' "${GREEN}✔${RESET} $*"; }
warn(){ printf '%b\n' "${YELLOW}⚠${RESET} $*"; }
info(){ printf '%b\n' "${BLUE}◆${RESET} $*"; }
die(){ printf '%b\n' "${RED}✖ ERROR:${RESET} $*" >&2; exit 1; }
trap 'rc=$?; printf "%b\n" "${RED}✖ ERROR:${RESET} Installer failed at line $LINENO. Command: $BASH_COMMAND" >&2; exit "$rc"' ERR
require_root(){ [[ $EUID -eq 0 ]] || die "Run with sudo/root on an Ubuntu VPS."; }
have_systemd(){ command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }
check_os(){ [[ -r /etc/os-release ]] || die "Cannot detect operating system."; . /etc/os-release; [[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu only."; ok "Ubuntu ${VERSION_ID:-unknown} detected"; if [[ "$WORKSPACE_MODE" == true ]]; then ok "GitHub Workspace/Codespaces mode"; else ok "Ubuntu VPS production mode"; fi; }
install_deps(){ step "Installing required dependencies"; require_root; local packages=(curl git openssl ca-certificates build-essential postgresql postgresql-contrib sudo); [[ "$WORKSPACE_MODE" == true ]] || packages+=(nginx); apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"; local major=0; if command -v node >/dev/null 2>&1; then major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"; fi; if (( major < NODE_MAJOR )); then info "Installing Node.js ${NODE_MAJOR}.x"; curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs; fi; command -v node >/dev/null 2>&1 || die "Node.js installation failed."; command -v npm >/dev/null 2>&1 || die "npm installation failed."; local node_version npm_version; node_version="$(node -v)"; npm_version="$(npm -v)"; [[ -n "$node_version" && -n "$npm_version" ]] || die "Node.js/npm version check returned an empty value."; ok "Node $node_version • npm $npm_version"; }
setup_user(){ [[ "$WORKSPACE_MODE" == true ]] && return 0; if ! id "$APP_USER" >/dev/null 2>&1; then useradd --system --no-create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"; fi; ok "Service user ready: $APP_USER"; }
start_postgres(){ if have_systemd; then systemctl enable --now postgresql >/dev/null 2>&1 || true; fi; for attempt in {1..30}; do pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
setup_db(){ step "Configuring PostgreSQL"; if [[ -n "${DATABASE_URL:-}" ]]; then if start_postgres; then info "Using configured DATABASE_URL with local PostgreSQL."; else info "Using configured DATABASE_URL (external database)."; fi; return 0; fi; start_postgres || die "PostgreSQL is not reachable."; DBPASS="${SNCK_DB_PASSWORD:-$(openssl rand -hex 32)}"; if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='snck'" | grep -q 1; then sudo -u postgres psql -v ON_ERROR_STOP=1 -v snck_password="$DBPASS" -c "ALTER ROLE snck WITH LOGIN PASSWORD :'snck_password';"; else sudo -u postgres psql -v ON_ERROR_STOP=1 -v snck_password="$DBPASS" -c "CREATE ROLE snck LOGIN PASSWORD :'snck_password';"; fi; if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q 1; then sudo -u postgres createdb -O snck snck_chat; fi; ok "Database ready: snck_chat"; }
clone_or_update(){ cd / || die "Cannot access filesystem root."; if [[ -f "$APP_DIR/package.json" && -f "$APP_DIR/src/server.js" ]]; then ok "Using existing source: $APP_DIR"; if [[ -d "$APP_DIR/.git" ]]; then cd "$APP_DIR"; info "Checking for latest Snck Chat fixes..."; git fetch --quiet origin main && git reset --hard --quiet origin/main || warn "Could not update from GitHub; continuing with existing source."; fi; return 0; fi; mkdir -p "$(dirname "$APP_DIR")"; if [[ -e "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then die "$APP_DIR exists and is not an empty Snck Chat directory. Use SNCK_DIR to choose another path."; fi; if [[ -n "$BUNDLE_DIR" && "$BUNDLE_DIR" != "$APP_DIR" ]]; then mkdir -p "$APP_DIR"; cp -a "$BUNDLE_DIR/." "$APP_DIR/"; ok "Using bundled Snck Chat source from $BUNDLE_DIR"; return 0; fi; git clone --depth 1 "$REPO_URL" "$APP_DIR"; ok "Snck Chat source downloaded"; }
load_env(){ if [[ -f "$APP_DIR/.env" ]]; then set -a; source "$APP_DIR/.env"; set +a; fi; }
write_env(){ if [[ ! -f "$APP_DIR/.env" ]]; then cat > "$APP_DIR/.env" <<EOF
NODE_ENV=production
PORT=${SNCK_PORT:-3000}
DATABASE_URL=${DATABASE_URL:-postgresql://snck:${DBPASS}@127.0.0.1:5432/snck_chat}
COOKIE_SECURE=${COOKIE_SECURE:-false}
SESSION_DAYS=30
ADMIN_SESSION_DAYS=8
EOF
chmod 600 "$APP_DIR/.env"; ok "Production .env generated"; else chmod 600 "$APP_DIR/.env"; warn "Existing .env preserved"; fi; }
require_database_url(){ [[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL is missing from $APP_DIR/.env."; }
prepare_app(){ load_env; setup_db; write_env; load_env; require_database_url; cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"; step "Installing application dependencies"; npm install --include=dev; step "Validating Prisma schema"; npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"; step "Generating Prisma Client"; npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"; step "Synchronizing database schema"; npx prisma db push --schema "$APP_DIR/prisma/schema.prisma" --skip-generate; if [[ -f "$APP_DIR/prisma/seed.js" ]]; then step "Initializing global chat"; node "$APP_DIR/prisma/seed.js"; fi; step "Running application checks"; npm run check; npm test; ok "Application checks passed"; }
write_service(){ [[ "$WORKSPACE_MODE" == true ]] && return 0; cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
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
write_nginx(){ [[ "$WORKSPACE_MODE" == true ]] && return 0; load_env; local port="${PORT:-3000}"; cat > /etc/nginx/sites-available/snck-chat <<EOF
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
ln -sfn /etc/nginx/sites-available/snck-chat /etc/nginx/sites-enabled/snck-chat; rm -f /etc/nginx/sites-enabled/default; }
health_check(){ load_env; require_database_url; local port="${PORT:-3000}"; step "Running final health check"; if [[ "$WORKSPACE_MODE" != true ]] && have_systemd; then systemctl is-active --quiet "$SERVICE" || { systemctl --no-pager --full status "$SERVICE"; die "Snck Chat service failed to start."; }; curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/health" >/dev/null || { journalctl -u "$SERVICE" -n 80 --no-pager; die "Application health check failed."; }; else local log_file pid; log_file="$(mktemp)"; (cd "$APP_DIR" && node src/server.js) >"$log_file" 2>&1 & pid=$!; sleep 2; if ! curl -fsS --max-time 10 "http://127.0.0.1:${port}/api/health" >/dev/null; then cat "$log_file"; kill "$pid" 2>/dev/null || true; rm -f "$log_file"; die "Application health check failed."; fi; kill "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; rm -f "$log_file"; fi; ok "Health check passed"; }
print_ready(){ load_env; echo; line; printf '%b\n' "${GREEN}${BOLD}                    ✔ SNCK CHAT READY${RESET}"; line; printf '%b\n' "${CYAN}Directory:${RESET} $APP_DIR"; printf '%b\n' "${CYAN}Port:${RESET}      ${PORT:-3000}"; if [[ "$WORKSPACE_MODE" == true ]]; then printf '%b\n' "${CYAN}Mode:${RESET}      GitHub Workspace"; printf '%b\n' "${CYAN}Start:${RESET}     npm start"; printf '%b\n' "${CYAN}Next:${RESET}      Forward port ${PORT:-3000} in the Ports tab"; else printf '%b\n' "${CYAN}Mode:${RESET}      Ubuntu VPS"; printf '%b\n' "${CYAN}Service:${RESET}   $SERVICE"; printf '%b\n' "${CYAN}Public:${RESET}    http://YOUR_VPS_IP"; fi; line; }
install_app(){ check_os; [[ "$WORKSPACE_MODE" == true ]] || require_root; cd / || die "Cannot access filesystem root."; install_deps; setup_user; clone_or_update; prepare_app; if [[ "$WORKSPACE_MODE" != true ]]; then chown -R "$APP_USER:$APP_USER" "$APP_DIR"; chmod 600 "$APP_DIR/.env"; write_service; write_nginx; systemctl daemon-reload; systemctl enable --now "$SERVICE"; nginx -t; systemctl reload nginx; fi; health_check; print_ready; }
create_admin(){ check_os; [[ "$WORKSPACE_MODE" == true ]] || require_root; cd / || die "Cannot access filesystem root."; clone_or_update; load_env; require_database_url; cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"; npm install --include=dev; npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"; node src/create-admin.js; }
update_app(){ check_os; [[ "$WORKSPACE_MODE" == true ]] || require_root; cd / || die "Cannot access filesystem root."; clone_or_update; load_env; require_database_url; cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"; npm install --include=dev; npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"; npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"; npx prisma db push --schema "$APP_DIR/prisma/schema.prisma" --skip-generate; npm run check; npm test; if [[ "$WORKSPACE_MODE" != true ]]; then chown -R "$APP_USER:$APP_USER" "$APP_DIR"; systemctl restart "$SERVICE"; nginx -t; systemctl reload nginx; fi; health_check; print_ready; }
repair_app(){ check_os; [[ "$WORKSPACE_MODE" == true ]] || require_root; cd / || die "Cannot access filesystem root."; clone_or_update; load_env; require_database_url; cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"; npm install --include=dev; npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"; npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"; npx prisma db push --schema "$APP_DIR/prisma/schema.prisma" --skip-generate; npm run check; npm test; if [[ "$WORKSPACE_MODE" != true ]]; then chown -R "$APP_USER:$APP_USER" "$APP_DIR"; write_service; write_nginx; systemctl daemon-reload; systemctl enable --now "$SERVICE"; nginx -t; systemctl reload nginx; fi; health_check; print_ready; }
uninstall_app(){ check_os; require_root; if have_systemd; then systemctl disable --now "$SERVICE" 2>/dev/null || true; fi; rm -f "/etc/systemd/system/${SERVICE}.service"; if command -v nginx >/dev/null 2>&1; then rm -f /etc/nginx/sites-enabled/snck-chat /etc/nginx/sites-available/snck-chat; nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true; fi; systemctl daemon-reload 2>/dev/null || true; if [[ -d "$APP_DIR" ]]; then read -r -p "Delete application directory $APP_DIR? [y/N]: " ans; [[ "$ans" =~ ^[Yy]$ ]] && rm -rf -- "$APP_DIR"; fi; ok "Snck Chat service configuration removed"; }
menu(){ while true; do banner; line; printf '%b\n' "  ${GREEN}1${RESET}  Install Website       ${BOLD}Full installation${RESET}"; printf '%b\n' "  ${GREEN}2${RESET}  Create Admin User     ${BOLD}Secure admin account${RESET}"; printf '%b\n' "  ${GREEN}3${RESET}  Update Website        ${BOLD}Latest code + database${RESET}"; printf '%b\n' "  ${GREEN}4${RESET}  Repair Installation   ${BOLD}Repair dependencies/services${RESET}"; printf '%b\n' "  ${GREEN}5${RESET}  Uninstall             ${BOLD}Disable safely${RESET}"; printf '%b\n' "  ${GREEN}6${RESET}  Exit                  ${BOLD}Quit${RESET}"; line; read -r -p "  Select an option: " choice; case "$choice" in 1) install_app; read -r -p "Press Enter to continue..." _ ;; 2) create_admin; read -r -p "Press Enter to continue..." _ ;; 3) update_app; read -r -p "Press Enter to continue..." _ ;; 4) repair_app; read -r -p "Press Enter to continue..." _ ;; 5) uninstall_app; read -r -p "Press Enter to continue..." _ ;; 6) exit 0 ;; *) warn "Invalid option. Choose 1-6."; sleep 1 ;; esac; done; }
case "${1:-install}" in install) install_app ;; admin) create_admin ;; update) update_app ;; repair) repair_app ;; uninstall) uninstall_app ;; menu) menu ;; *) die "Unknown command '$1'. Use: install, admin, update, repair, uninstall, or menu." ;; esac
