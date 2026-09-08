# Snck Chat

A production-oriented, username-first real-time chat platform with public chat, private DMs, friends, profiles, notifications, moderation, and a separate administrator system.

## Stack

Node.js 20+, Express 5, Socket.IO, PostgreSQL, Prisma, browser client, Nginx, systemd.

## Authentication

Normal users use a username-first session. A username is not a strong secret: an existing username can only continue from the browser session that created it; otherwise a new username is required. Admin authentication is completely separate and uses a hashed password and its own session cookie.

## One-command Ubuntu VPS installer

On a clean supported Ubuntu LTS VPS, run:

```bash
curl -fsSL https://raw.githubusercontent.com/SnckBoy/Snck-chat/main/install.sh -o /tmp/snck-install.sh && sudo bash /tmp/snck-install.sh install
```

The installer will:

1. Detect Ubuntu and required permissions.
2. Install Node.js, PostgreSQL, Nginx and required packages.
3. Create a dedicated `snckchat` service user.
4. Create/configure the PostgreSQL database.
5. Download Snck Chat.
6. Install production dependencies.
7. Generate the Prisma client and initial database migration.
8. Run migrations and seed the global conversation.
9. Configure systemd and Nginx.
10. Start and health-check the application.
11. Ask whether you want to create the first admin account.

The admin password is entered interactively and is never printed by the installer.

### Installer menu

You can also run the installer menu:

```bash
curl -fsSL https://raw.githubusercontent.com/SnckBoy/Snck-chat/main/install.sh -o /tmp/snck-install.sh && sudo bash /tmp/snck-install.sh
```

Options:

- `1` Install Website
- `2` Create Admin User
- `3` Update Website
- `4` Repair Installation
- `5` Uninstall
- `6` Exit

### Admin creation only

```bash
sudo bash /opt/snck-chat/install.sh admin
```

Or use the menu's **Create Admin User** option.

## Useful service commands

```bash
sudo systemctl status snck-chat
sudo systemctl restart snck-chat
sudo journalctl -u snck-chat -f
curl http://127.0.0.1:3000/api/health
```

## Development

```bash
cp .env.example .env
npm install
npx prisma generate
npx prisma db push
node prisma/seed.js
npm run dev
```

The app listens on port 3000 by default.

## Production domain / HTTPS

The included Nginx configuration proxies HTTP and WebSocket traffic to `127.0.0.1:3000`. Point your DNS record at the VPS, then use an ACME client such as Certbot to issue a certificate and set `COOKIE_SECURE=true` in `.env` after HTTPS is active.

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

Backend authorization is enforced for private conversations and administrative endpoints. Cookies are HttpOnly/SameSite, sessions are random tokens stored as SHA-256 hashes, admin passwords are bcrypt-hashed, requests are rate limited, Helmet supplies security headers, and message/user inputs are validated with Zod. Never commit `.env` or production credentials.

## Data and backups

PostgreSQL is the source of truth. Back up the database before upgrades and keep the backup outside the application directory. The uninstall option intentionally leaves application data in place unless you manually remove it.

## Verification

```bash
npm run check
npm test
```

For production, also verify the systemd service, Nginx configuration, `/api/health`, WebSocket reconnect behavior, and database connectivity after deployment.
