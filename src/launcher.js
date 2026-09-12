// Snck Chat production entrypoint.
// Keep this file intentionally small so systemd and GitHub Workspace use the
// exact same application entrypoint without rewriting source files at runtime.
const fs = require('node:fs');
const path = require('node:path');

const serverPath = path.join(__dirname, 'server.js');
if (!fs.existsSync(serverPath)) {
  console.error(`Snck Chat server not found: ${serverPath}`);
  process.exit(1);
}

require(serverPath);
