const fs = require('node:fs');
const path = require('node:path');

// Keep the source compatible with existing deployments while enabling open DMs.
// The server still enforces authentication, blocking, and conversation membership.
const serverPath = path.join(__dirname, 'server.js');
if (fs.existsSync(serverPath)) {
  let source = fs.readFileSync(serverPath, 'utf8');
  const friendGate = "if(!await areFriends(req.user.id,userId))return res.status(403).json({error:'You must be friends before starting a DM'});";
  if (source.includes(friendGate)) {
    source = source.replace(
      friendGate,
      "// Open DMs: any authenticated, non-blocked user may start a private conversation. Server-side membership checks protect every DM operation."
    );
    fs.writeFileSync(serverPath, source);
  }
}

require('./server.js');
