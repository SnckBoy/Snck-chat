# Snck Chat

A production-oriented, username-first real-time chat platform with public chat, private DMs, friends, profiles, notifications, moderation, and a separate administrator system.

## One-command Ubuntu VPS installer

The exact command below is the supported default. **No `install` argument is required**: when `install.sh` receives no argument, it performs the full installation and then offers to create the first administrator.

```bash
curl -fsSL https://raw.githubusercontent.com/SnckBoy/Snck-chat/main/install.sh -o /tmp/snck-install.sh && sudo bash /tmp/snck-install.sh
```

The installer detects Ubuntu, installs required dependencies, configures PostgreSQL, installs Snck Chat, runs Prisma migrations, configures systemd/Nginx, starts the application, performs a health check, and can create the first admin account.

It is safe to rerun: an existing `.env` is preserved and its configured `DATABASE_URL` is reused.

## Installer options

The same script supports:

```bash
sudo bash /tmp/snck-install.sh install
sudo bash /tmp/snck-install.sh admin
sudo bash /tmp/snck-install.sh update
sudo bash /tmp/snck-install.sh repair
sudo bash /tmp/snck-install.sh uninstall
sudo bash /tmp/snck-install.sh menu
```

The `menu` command provides:

1. Install Website
2. Create Admin User
3. Update Website
4. Repair Installation
5. Uninstall
6. Exit

## GitHub Codespaces / workspace

The installer detects `CODESPACES=true` and `GITHUB_WORKSPACE`. In a Codespace it uses the existing repository workspace, installs dependencies, runs migrations and health checks, and skips VPS-only systemd/Nginx setup. GitHub documents these Codespaces environment variables and the persistent workspace directory. citeturn0search0turn0search1

Run the same installer from the Codespace terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/SnckBoy/Snck-chat/main/install.sh -o /tmp/snck-install.sh && bash /tmp/snck-install.sh
```

For a Codespace, PostgreSQL must be available locally or through `DATABASE_URL`. After setup, run:

```bash
npm start
```

Then forward port `3000` in the Codespaces Ports panel.

## Admin account

During a fresh installation, the installer asks whether to create the first administrator. To create one later:

```bash
sudo bash /tmp/snck-install.sh admin
```

Or from the installed VPS directory:

```bash
cd /opt/snck-chat
sudo node src/create-admin.js
```

The admin password is hashed and is never printed after creation.

## Stack

- Node.js 20+
- Express
- Socket.IO
- PostgreSQL
- Prisma
- Nginx
- systemd on Ubuntu VPS

## Development

```bash
cp .env.example .env
npm install
npx prisma generate
npx prisma migrate deploy
node prisma/seed.js
npm start
```

The app listens on port `3000` by default.

## Production domain / HTTPS

The included Nginx configuration proxies HTTP and WebSocket traffic to `127.0.0.1:3000`. Point your DNS record at the VPS, issue an HTTPS certificate with your preferred ACME client, and set `COOKIE_SECURE=true` in `.env` after HTTPS is active.

## Useful service commands

```bash
sudo systemctl status snck-chat
sudo systemctl restart snck-chat
sudo journalctl -u snck-chat -f
curl http://127.0.0.1:3000/api/health
```

## API areas

- `/api/auth` username sessions
- `/api/users` profiles/search
- `/api/friends` friend requests and relationships
- `/api/conversations` DMs and message history
- `/api/messages` edits/deletes/reactions
- `/api/notifications` notifications
- `/api/reports` user reports
- `/api/admin` administrator operations
- `/api/health` health check

## Security

Backend authorization is enforced for private conversations and administrative endpoints. Cookies are HttpOnly/SameSite, sessions use random tokens stored as SHA-256 hashes, admin passwords are bcrypt-hashed, requests are rate limited, Helmet supplies security headers, and request data is validated with Zod. Never commit `.env` or production credentials.

## Data and backups

PostgreSQL is the source of truth. Back up the database before upgrades and keep the backup outside the application directory. The uninstall option intentionally preserves application files and database data for safety.

## Verification

```bash
npm run check
npm test
```

For production, also verify the systemd service, Nginx configuration, `/api/health`, WebSocket reconnect behavior, and database connectivity after deployment.
