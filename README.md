# Snck Chat

A production-oriented, username-first real-time chat platform with public chat, private DMs, friends, profiles, notifications, moderation, and a separate administrator system.

## Stack

Node.js 20+, Express 5, Socket.IO, PostgreSQL, Prisma, vanilla TypeScript-free browser client, Nginx, systemd.

## Important authentication model

Normal users use a username-first session. A username is not a strong secret: if a username already exists, a browser without the original session cannot impersonate it and must choose another username. Admin authentication is completely separate and uses a hashed password and its own session cookie.

## Quick Ubuntu install

On a clean Ubuntu LTS VPS:

```bash
sudo apt-get update
sudo apt-get install -y git
sudo git clone https://github.com/SnckBoy/Snck-chat.git /tmp/snck-chat
cd /tmp/snck-chat
sudo bash install.sh
```

The installer provides install, admin creation, update, repair, uninstall, and exit options.

## First admin

After installation:

```bash
cd /opt/snck-chat
sudo node src/create-admin.js
```

Then open `/admin/` in the browser.

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

The included Nginx configuration proxies HTTP and WebSocket traffic to `127.0.0.1:3000`. Point your DNS record at the VPS, then use your preferred ACME client (for example Certbot) to issue a certificate and set `COOKIE_SECURE=true` in `.env` after HTTPS is active.

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
