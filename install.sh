#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR="${SNCK_DIR:-/opt/snck-chat}"
REPO_URL="https://github.com/SnckBoy/Snck-chat.git"
SERVICE="snck-chat"
need_root(){ [[ $EUID -eq 0 ]] || { echo 'Run as root: sudo bash install.sh'; exit 1; }; }
install_deps(){ apt-get update; apt-get install -y curl git nginx postgresql postgresql-contrib openssl ca-certificates; if ! command -v node >/dev/null || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 20 ]]; then curl -fsSL https://deb.nodesource.com/setup_20.x | bash -; apt-get install -y nodejs; fi; }
setup_db(){ systemctl enable --now postgresql; DBPASS="$(openssl rand -hex 24)"; sudo -u postgres psql -c "DO \$\$ BEGIN CREATE ROLE snck LOGIN PASSWORD '${DBPASS}'; EXCEPTION WHEN duplicate_object THEN ALTER ROLE snck WITH PASSWORD '${DBPASS}'; END \$\$;"; sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='snck_chat'" | grep -q 1 || sudo -u postgres createdb -O snck snck_chat; }
write_env(){ mkdir -p "$APP_DIR"; if [[ ! -f "$APP_DIR/.env" ]]; then cat > "$APP_DIR/.env" <<EOF
NODE_ENV=production
PORT=3000
DATABASE_URL=postgresql://snck:${DBPASS}@127.0.0.1:5432/snck_chat
COOKIE_SECURE=false
SESSION_DAYS=30
ADMIN_SESSION_DAYS=8
EOF
chmod 600 "$APP_DIR/.env"; fi; }
install_app(){ need_root; install_deps; if [[ -d "$APP_DIR/.git" ]]; then echo 'Existing installation detected; use Update or Repair.'; return; fi; setup_db; rm -rf "$APP_DIR"; git clone "$REPO_URL" "$APP_DIR"; write_env; cd "$APP_DIR"; npm ci; npx prisma generate; mkdir -p prisma/migrations/0001_init; npx prisma migrate diff --from-empty --to-schema-datamodel prisma/schema.prisma --script > prisma/migrations/0001_init/migration.sql; npx prisma migrate deploy; npx prisma db execute --file prisma/seed.sql; npm run check; npm run test; cat >/etc/systemd/system/$SERVICE.service <<EOF
[Unit]
Description=Snck Chat
After=network.target postgresql.service
[Service]
Type=simple
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=/usr/bin/node $APP_DIR/src/server.js
Restart=always
RestartSec=3
User=root
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$APP_DIR
[Install]
WantedBy=multi-user.target
EOF
cat >/etc/nginx/sites-available/$SERVICE <<EOF
server { listen 80; server_name _; client_max_body_size 10M; location / { proxy_pass http://127.0.0.1:3000; proxy_http_version 1.1; proxy_set_header Host \$host; proxy_set_header X-Real-IP \$remote_addr; proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for; proxy_set_header X-Forwarded-Proto \$scheme; proxy_set_header Upgrade \$http_upgrade; proxy_set_header Connection "upgrade"; } }
EOF
ln -sfn /etc/nginx/sites-available/$SERVICE /etc/nginx/sites-enabled/$SERVICE; rm -f /etc/nginx/sites-enabled/default; nginx -t; systemctl daemon-reload; systemctl enable --now $SERVICE; systemctl reload nginx; sleep 2; curl -fsS http://127.0.0.1:3000/api/health; echo; echo "Installation complete: $APP_DIR"; }
update_app(){ need_root; [[ -d "$APP_DIR/.git" ]]||{ echo 'No installation found.'; exit 1; }; cd "$APP_DIR"; git pull --ff-only; npm ci; npx prisma generate; npx prisma migrate deploy || npx prisma db push; systemctl restart $SERVICE; systemctl is-active --quiet $SERVICE; echo 'Update complete.'; }
repair(){ need_root; [[ -d "$APP_DIR/.git" ]]||{ echo 'No installation found.'; exit 1; }; cd "$APP_DIR"; npm ci; npx prisma generate; npx prisma migrate deploy || npx prisma db push; nginx -t; systemctl daemon-reload; systemctl restart $SERVICE; systemctl is-active --quiet $SERVICE; echo 'Repair complete.'; }
uninstall_app(){ need_root; read -r -p 'Type UNINSTALL to continue: ' x; [[ "$x" == UNINSTALL ]]||exit 0; systemctl disable --now $SERVICE 2>/dev/null||true; rm -f /etc/systemd/system/$SERVICE.service /etc/nginx/sites-enabled/$SERVICE /etc/nginx/sites-available/$SERVICE; systemctl daemon-reload; systemctl reload nginx 2>/dev/null||true; echo "Application files/data remain at $APP_DIR."; }
create_admin(){ need_root; [[ -d "$APP_DIR" ]]||{ echo 'Install the website first.'; exit 1; }; cd "$APP_DIR"; node src/create-admin.js; }
while true; do clear; cat <<'EOF'
========================================
          SNCK CHAT INSTALLER
========================================
1. Install Website
2. Create Admin User
3. Update Website
4. Repair Installation
5. Uninstall
6. Exit
========================================
EOF
read -r -p 'Select an option: ' choice; case "$choice" in 1)install_app;;2)create_admin;;3)update_app;;4)repair;;5)uninstall_app;;6)exit 0;;*)echo 'Invalid option.';;esac; read -r -p 'Press Enter to continue...' _; done
