#!/usr/bin/env bash
set -Eeuo pipefail

APP_DIR="${SNCK_DIR:-/opt/snck-chat}"
REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
APP_USER="snckchat"
NODE_MAJOR=20

log(){ printf '\n[SNCK] %s\n' "$*"; }
fail(){ echo "[SNCK] ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || fail "Run with sudo/root."; }

check_os(){
  [[ -r /etc/os-release ]] || fail "Cannot detect operating system."
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || fail "This installer supports Ubuntu LTS."
  log "Detected Ubuntu ${VERSION_ID:-unknown}."
}

install_deps(){
  log "Installing system dependencies..."
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y curl git nginx postgresql postgresql-contrib openssl ca-certificates build-essential
  if ! command -v node >/dev/null 2>&1 || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt "$NODE_MAJOR" ]]; then
    curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash -
    DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs
  fi
  node -v
  npm -v
}

setup_user(){
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
}

setup_db(){
  log "Configuring PostgreSQL..."
  systemctl enable --now postgresql
  DBPASS="$(openssl rand -hex 32)"
  sudo -u postgres psql -v ON_ERROR_STOP=1 -c "DO \$\$ BEGIN CREATE ROLE snck LOGIN PASSWORD '${DBPASS}'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE snck WITH PASSWORD '${DBPASS}'; END \$\$;"
  if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q 1; then
    sudo -u postgres createdb -O snck snck_chat
  fi
}

write_env(){
  mkdir -p "$APP_DIR"
  if [[ ! -f "$APP_DIR/.env" ]]; then
    cat > "$APP_DIR/.env" <<EOF
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://snck:${DBPASS}@127.0.0.1:5432/snck_chat
COOKIE_SECURE=false
SESSION_DAYS=30
ADMIN_SESSION_DAYS=8
EOF
    chmod 600 "$APP_DIR/.env"
  else
    log "Existing .env preserved."
  fi
}

install_app(){
  need_root; check_os; install_deps; setup_user
  if [[ -d "$APP_DIR/.git" ]]; then
    log "Existing installation detected. Running update instead."
    update_app
    return
  fi
  setup_db
  rm -rf "$APP_DIR"
  git clone --depth 1 "$REPO_URL" "$APP_DIR"
  write_env
  cd "$APP_DIR"
  log "Installing Node dependencies..."
  npm install --omit=dev
  log "Generating Prisma client and production migration..."
  npx prisma generate
  mkdir -p prisma/migrations/0001_init
  if [[ ! -s prisma/migrations/0001_init/migration.sql ]]; then
    npx prisma migrate diff --from-empty --to-schema-datamodel prisma/schema.prisma --script > prisma/migrations/0001_init/migration.sql
  fi
  npx prisma migrate deploy
  if [[ -f prisma/seed.sql ]]; then npx prisma db execute --file prisma/seed.sql; fi
  npm run check
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  write_service
  write_nginx
  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  nginx -t
  systemctl reload nginx
  verify
  log "Installation complete."
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
  systemctl is-active --quiet "$SERVICE" || { systemctl --no-pager --full status "$SERVICE"; fail "Snck Chat service failed to start."; }
  curl -fsS http://127.0.0.1:3000/api/health >/dev/null || fail "Application health check failed."
  nginx -t >/dev/null || fail "Nginx configuration test failed."
  echo
  echo "========================================"
  echo "       SNCK CHAT IS RUNNING"
  echo "========================================"
  echo "Local: http://127.0.0.1:3000"
  echo "Public: http://YOUR_VPS_IP"
  echo "App directory: $APP_DIR"
  echo "Service: $SERVICE"
  echo "========================================"
}

update_app(){
  need_root
  [[ -d "$APP_DIR/.git" ]] || fail "No Snck Chat installation found."
  cd "$APP_DIR"
  git pull --ff-only
  npm install --omit=dev
  npx prisma generate
  npx prisma migrate deploy
  if [[ -f prisma/seed.sql ]]; then npx prisma db execute --file prisma/seed.sql; fi
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  write_service
  write_nginx
  systemctl daemon-reload
  systemctl enable --now "$SERVICE"
  nginx -t && systemctl reload nginx
  verify
  log "Update complete."
}

repair(){
  need_root
  [[ -d "$APP_DIR/.git" ]] || fail "No Snck Chat installation found."
  cd "$APP_DIR"
  npm install --omit=dev
  npx prisma generate
  npx prisma migrate deploy
  chown -R "$APP_USER:$APP_USER" "$APP_DIR"
  write_service
  write_nginx
  systemctl daemon-reload
  systemctl restart "$SERVICE"
  nginx -t && systemctl reload nginx
  verify
  log "Repair complete."
}

create_admin(){
  need_root
  [[ -f "$APP_DIR/src/create-admin.js" ]] || fail "Install Snck Chat first."
  cd "$APP_DIR"
  sudo -u "$APP_USER" env NODE_ENV=production node src/create-admin.js
}

uninstall_app(){
  need_root
  read -r -p 'Type UNINSTALL to continue: ' confirm
  [[ "$confirm" == "UNINSTALL" ]] || { echo "Cancelled."; return; }
  systemctl disable --now "$SERVICE" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service" "/etc/nginx/sites-enabled/${SERVICE}" "/etc/nginx/sites-available/${SERVICE}"
  systemctl daemon-reload
  nginx -t && systemctl reload nginx || true
  echo "Application files and database were preserved at $APP_DIR for safety."
  echo "Remove them manually only if you are certain: rm -rf $APP_DIR"
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

case "${1:-menu}" in
  install) first_install ;;
  admin) create_admin ;;
  update) update_app ;;
  repair) repair ;;
  uninstall) uninstall_app ;;
  menu) menu ;;
  *) echo "Usage: $0 [install|admin|update|repair|uninstall|menu]"; exit 2 ;;
esac
