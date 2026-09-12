const fs = require('node:fs');
const path = require('node:path');

// Compatibility launcher for production and GitHub Workspace deployments.
// It ensures the current source has open username-to-username DMs before
// starting the real server. Authentication, blocking, and conversation
// membership are still enforced by the backend.
const serverPath = path.join(__dirname, 'server.js');
if (!fs.existsSync(serverPath)) {
  console.error(`Snck Chat server not found: ${serverPath}`);
  process.exit(1);
}

let source = fs.readFileSync(serverPath, 'utf8');
const friendGate = "if(!await areFriends(req.user.id,userId))return res.status(403).json({error:'You must be friends before starting a DM'});";
if (source.includes(friendGate)) {
  source = source.replace(
    friendGate,
    "// Open DMs: any authenticated, non-blocked user may start a private conversation. Server-side membership checks protect every DM operation."
  );
  fs.writeFileSync(serverPath, source, { mode: 0o640 });
}

require(serverPath);
