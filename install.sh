#!/usr/bin/env bash
set -Eeuo pipefail
REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
APP_DIR="${SNCK_DIR:-/opt/snck-chat}"
NODE_MAJOR=20
if [[ -t 1 ]]; then R=$'\033[0m'; B=$'\033[1m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; CYAN=$'\033[36m'; MAGENTA=$'\033[35m'; WHITE=$'\033[97m'; else R=''; B=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; CYAN=''; MAGENTA=''; WHITE=''; fi
banner(){ clear 2>/dev/null || true; printf '%b\n' "${CYAN}${B}╔══════════════════════════════════════════════════════════╗${R}" "${CYAN}${B}║${R}                 ${WHITE}${B}SNCK CHAT INSTALLER${R}                 ${CYAN}${B}║${R}" "${CYAN}${B}║${R}       ${B}Production • Realtime • Ubuntu • Workspace${R}       ${CYAN}${B}║${R}" "${CYAN}${B}╚══════════════════════════════════════════════════════════╝${R}"; }
line(){ printf '%b\n' "${CYAN}────────────────────────────────────────────────────────────${R}"; }
step(){ printf '\n%b\n' "${MAGENTA}${B}▶ $*${R}"; }; ok(){ printf '%b\n' "${GREEN}✔${R} $*"; }; warn(){ printf '%b\n' "${YELLOW}⚠${R} $*"; }; info(){ printf '%b\n' "${BLUE}◆${R} $*"; }; die(){ printf '%b\n' "${RED}✖ ERROR:${R} $*" >&2; exit 1; }
trap 'rc=$?; printf "%b\n" "${RED}✖ ERROR:${R} Installer failed at line $LINENO. Command: $BASH_COMMAND" >&2; exit "$rc"' ERR
cd / || die "Cannot access filesystem root."
WORKSPACE_MODE=false
if [[ "${CODESPACES:-}" == "true" && -n "${GITHUB_WORKSPACE:-}" && -d "${GITHUB_WORKSPACE}" ]]; then APP_DIR="${SNCK_DIR:-$GITHUB_WORKSPACE}"; WORKSPACE_MODE=true; fi
require_root(){ [[ ${EUID:-99} -eq 0 ]] || die "Run with sudo/root on an Ubuntu VPS."; }
have_systemd(){ command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; }
check_os(){ [[ -r /etc/os-release ]] || die "Cannot detect operating system."; . /etc/os-release; [[ "${ID:-}" == ubuntu ]] || die "This installer supports Ubuntu only."; ok "Ubuntu ${VERSION_ID:-unknown} detected"; [[ "$WORKSPACE_MODE" == true ]] && ok "GitHub Workspace/Codespaces mode" || ok "Ubuntu VPS production mode"; }
install_deps(){
 step "Installing required dependencies"; require_root; local packages=(curl git openssl ca-certificates build-essential postgresql postgresql-contrib sudo); [[ "$WORKSPACE_MODE" == true ]] || packages+=(nginx); apt-get update; DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
 local major=0; if command -v node >/dev/null 2>&1; then major="$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"; fi; [[ "$major" =~ ^[0-9]+$ ]] || major=0
 if (( major < NODE_MAJOR )); then info "Installing Node.js ${NODE_MAJOR}.x"; curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash -; DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs; fi
 command -v node >/dev/null || die "Node.js installation failed."; command -v npm >/dev/null || die "npm installation failed."; local nv mv; nv="$(node --version)"; mv="$(npm --version)"; ok "Node $nv • npm $mv";
}
setup_user(){ [[ "$WORKSPACE_MODE" == true ]] && return 0; if ! id "$APP_USER" >/dev/null 2>&1; then useradd --system --create-home --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"; fi; ok "Service user ready: $APP_USER ($(id -gn "$APP_USER"))"; }
start_postgres(){ if have_systemd; then systemctl enable --now postgresql >/dev/null 2>&1 || true; fi; for _ in {1..30}; do pg_isready -h 127.0.0.1 -p 5432 >/dev/null 2>&1 && return 0; sleep 1; done; return 1; }
sql_escape(){ printf '%s' "$1" | sed "s/'/''/g"; }
setup_db(){
 step "Configuring PostgreSQL"; load_env || true; start_postgres || die "PostgreSQL is not reachable on 127.0.0.1:5432."
 if [[ -n "${SNCK_DB_PASSWORD:-}" ]]; then DBPASS="$SNCK_DB_PASSWORD"; elif [[ -n "${DATABASE_URL:-}" ]]; then DBPASS="$(printf '%s' "$DATABASE_URL" | sed -n 's#^postgresql://[^:]*:\([^@]*\)@.*#\1#p')"; [[ -n "$DBPASS" ]] || DBPASS="$(openssl rand -hex 32)"; else DBPASS="$(openssl rand -hex 32)"; fi
 local escaped; escaped="$(sql_escape "$DBPASS")"
 if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='snck'" | grep -q 1; then sudo -u postgres psql -v ON_ERROR_STOP=1 -c "ALTER ROLE snck WITH LOGIN PASSWORD '${escaped}';"; else sudo -u postgres psql -v ON_ERROR_STOP=1 -c "CREATE ROLE snck WITH LOGIN PASSWORD '${escaped}';"; fi
 if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q 1; then sudo -u postgres createdb -O snck snck_chat; fi; ok "Database ready: snck_chat";
}
clone_or_update(){
 cd / || die "Cannot access filesystem root."; if [[ -f "$APP_DIR/package.json" && -f "$APP_DIR/src/server.js" ]]; then ok "Using existing source: $APP_DIR"; if [[ -d "$APP_DIR/.git" ]]; then cd "$APP_DIR"; info "Checking for latest Snck Chat fixes..."; git fetch --quiet origin main && git reset --hard --quiet origin/main || warn "GitHub unavailable; continuing with existing source."; fi; return 0; fi
 mkdir -p "$(dirname "$APP_DIR")"; if [[ -e "$APP_DIR" && -n "$(ls -A "$APP_DIR" 2>/dev/null)" ]]; then die "$APP_DIR exists and is not an empty Snck Chat directory. Set SNCK_DIR to another path."; fi; git clone --depth 1 "$REPO_URL" "$APP_DIR" || die "Git clone failed."; ok "Snck Chat source downloaded";
}
load_env(){ [[ -f "$APP_DIR/.env" ]] || return 0; set -a; source "$APP_DIR/.env"; set +a; }
write_env(){
 mkdir -p "$APP_DIR"; if [[ ! -f "$APP_DIR/.env" ]]; then DBPASS="${DBPASS:-$(openssl rand -hex 32)}"; cat > "$APP_DIR/.env" <<EOF
NODE_ENV=production
PORT=${SNCK_PORT:-3000}
DATABASE_URL=postgresql://snck:${DBPASS}@127.0.0.1:5432/snck_chat
COOKIE_SECURE=${COOKIE_SECURE:-false}
SESSION_DAYS=30
ADMIN_SESSION_DAYS=8
EOF
 chmod 600 "$APP_DIR/.env"; ok "Production .env generated";
 else load_env; if [[ -z "${DATABASE_URL:-}" ]]; then DBPASS="${DBPASS:-${SNCK_DB_PASSWORD:-$(openssl rand -hex 32)}}"; printf '\nDATABASE_URL=postgresql://snck:%s@127.0.0.1:5432/snck_chat\n' "$DBPASS" >> "$APP_DIR/.env"; ok "DATABASE_URL added to existing .env"; fi; grep -Eq '^PORT=' "$APP_DIR/.env" || printf 'PORT=%s\n' "${SNCK_PORT:-3000}" >> "$APP_DIR/.env"; grep -Eq '^NODE_ENV=' "$APP_DIR/.env" || printf 'NODE_ENV=production\n' >> "$APP_DIR/.env"; chmod 600 "$APP_DIR/.env"; fi
}
require_database_url(){ load_env; [[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL is missing from $APP_DIR/.env."; }
prepare_app(){
 cd / || die "Cannot access filesystem root."; load_env; setup_db; write_env; load_env; require_database_url; cd "$APP_DIR" || die "Cannot access application directory: $APP_DIR"; step "Installing application dependencies"; npm install --include=dev; step "Validating Prisma schema"; npx prisma validate --schema "$APP_DIR/prisma/schema.prisma"; step "Generating Prisma Client"; npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"; step "Synchronizing database schema"; npx prisma db push --schema "$APP_DIR/prisma/schema.prisma" --skip-generate; if [[ -f "$APP_DIR/prisma/seed.js" ]]; then step "Initializing database"; DATABASE_URL="$DATABASE_URL" node "$APP_DIR/prisma/seed.js"; fi; step "Running application checks"; npm run check; npm test; ok "Application checks passed";
}
write_service(){
 [[ "$WORKSPACE_MODE" == true ]] && return 0; local group node_bin; group="$(id -gn "$APP_USER")"; node_bin="$(command -v node)"; load_env; local port="${PORT:-3000}"; cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=Snck Chat real-time server
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${group}
WorkingDirectory=${APP_DIR}
EnvironmentFile=-${APP_DIR}/.env
Environment=NODE_ENV=production
Environment=PORT=${port}
ExecStart=${node_bin} ${APP_DIR}/src/server.js
Restart=always
RestartSec=3
TimeoutStartSec=30
KillSignal=SIGTERM
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true
UMask=027

[Install]
WantedBy=multi-user.target
EOF
}
write_nginx(){ [[ "$WORKSPACE_MODE" == true ]] && return 0; load_env; local port="${PORT:-3000}"; [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid PORT in .env: $port"; (( port>=1 && port<=65535 )) || die "PORT must be between 1 and 65535."; cat > /etc/nginx/sites-available/snck-chat <<EOF
server {
 listen 80 default_server; listen [::]:80 default_server; server_name _; client_max_body_size 10M;
 location / { proxy_pass http://127.0.0.1:${port}; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; }
}
EOF
 ln -sfn /etc/nginx/sites-available/snck-chat /etc/nginx/sites-enabled/snck-chat; rm -f /etc/nginx/sites-enabled/default; }
start_service(){
 [[ "$WORKSPACE_MODE" == true ]] && return 0; step "Starting Snck Chat service"; load_env; local port="${PORT:-3000}"; systemctl daemon-reload; systemctl reset-failed "$SERVICE" 2>/dev/null || true; systemctl enable "$SERVICE" >/dev/null; systemctl stop "$SERVICE" 2>/dev/null || true
 if ss -ltn "sport = :${port}" 2>/dev/null | grep -q LISTEN; then warn "Port ${port} is already in use; checking for an old Snck Chat process."; local pids; pids="$(pgrep -f "${APP_DIR}/src/server.js" || true)"; if [[ -n "$pids" ]]; then kill $pids 2>/dev/null || true; sleep 2; fi; fi
 systemctl start "$SERVICE"
 for _ in {1..30}; do systemctl is-active --quiet "$SERVICE" && { ok "Snck Chat service is running"; return 0; }; sleep 1; done
 echo; warn "systemd could not keep the service running. Application log:"; journalctl -u "$SERVICE" -n 100 --no-pager || true; systemctl --no-pager --full status "$SERVICE" || true; die "Snck Chat service did not start. The service log above contains the runtime error."
}
health_check(){
 load_env; require_database_url; local port="${PORT:-3000}"; step "Running final health check";
 if [[ "$WORKSPACE_MODE" != true ]]; then
   local response=""; for _ in {1..30}; do
     if response="$(curl -4fsS --max-time 2 "http://127.0.0.1:${port}/api/health" 2>/dev/null)" && [[ "$response" == *'"ok":true'* ]]; then ok "Health check passed"; return 0; fi
     systemctl is-active --quiet "$SERVICE" || break; sleep 1;
   done
   warn "Health endpoint did not become ready on 127.0.0.1:${port}."; ss -ltnp 2>/dev/null | grep -E ":${port}\b" || true; journalctl -u "$SERVICE" -n 100 --no-pager || true; die "Application health check failed."
 else
   local log_file pid; log_file="$(mktemp)"; (cd "$APP_DIR" && node src/server.js) >"$log_file" 2>&1 & pid=$!; for _ in {1..30}; do if curl -4fsS --max-time 2 "http://127.0.0.1:${port}/api/health" 2>/dev/null | grep -q '"ok":true'; then ok "Health check passed"; kill "$pid" 2>/dev/null || true; rm -f "$log_file"; return 0; fi; if ! kill -0 "$pid" 2>/dev/null; then break; fi; sleep 1; done; cat "$log_file"; kill "$pid" 2>/dev/null || true; rm -f "$log_file"; die "Application health check failed.";
 fi
}
install_app(){ check_os; require_root; cd /; install_deps; setup_user; clone_or_update; prepare_app; if [[ "$WORKSPACE_MODE" != true ]]; then load_env; chown -R "$APP_USER:$(id -gn "$APP_USER")" "$APP_DIR"; chmod 600 "$APP_DIR/.env"; write_service; write_nginx; nginx -t; start_service; nginx -t; systemctl reload nginx; fi; health_check; }
create_admin(){ check_os; require_root; cd /; [[ -f "$APP_DIR/package.json" ]] || die "Snck Chat is not installed."; load_env; require_database_url; cd "$APP_DIR"; npm install --include=dev; npx prisma generate --schema "$APP_DIR/prisma/schema.prisma"; node src/create-admin.js; }
update_app(){ install_app; }
repair_app(){ install_app; }
uninstall_app(){ check_os; require_root; cd /; if [[ "$WORKSPACE_MODE" != true ]]; then systemctl disable --now "$SERVICE" 2>/dev/null || true; rm -f "/etc/systemd/system/${SERVICE}.service" /etc/nginx/sites-enabled/snck-chat /etc/nginx/sites-available/snck-chat; systemctl daemon-reload; nginx -t && systemctl reload nginx || true; fi; warn "Application files and database were preserved. Remove them manually if you want a full data wipe."; }
menu(){ while true; do banner; line; printf '%b\n' "  ${WHITE}${B}1${R}  Install Website       Full installation" "  ${WHITE}${B}2${R}  Create Admin User     Secure admin account" "  ${WHITE}${B}3${R}  Update Website        Latest code + migrations" "  ${WHITE}${B}4${R}  Repair Installation   Repair dependencies/services" "  ${WHITE}${B}5${R}  Uninstall             Disable safely" "  ${WHITE}${B}6${R}  Exit                  Quit"; line; read -r -p "  Select an option: " choice; case "$choice" in 1) install_app;; 2) create_admin;; 3) update_app;; 4) repair_app;; 5) uninstall_app;; 6) exit 0;; *) warn "Invalid option.";; esac; printf '\nPress Enter to continue... '; read -r; done; }
main(){ case "${1:-menu}" in install) install_app;; admin) create_admin;; update) update_app;; repair) repair_app;; uninstall) uninstall_app;; menu) menu;; *) die "Usage: $0 [install|admin|update|repair|uninstall|menu]";; esac; }
main "$@"
