const fs = require('node:fs');
const path = require('node:path');

const serverPath = path.join(__dirname, '..', 'src', 'server.js');
if (!fs.existsSync(serverPath)) process.exit(0);

const source = fs.readFileSync(serverPath, 'utf8');
const blocked = "if(!await areFriends(req.user.id,userId))return res.status(403).json({error:'You must be friends before starting a DM'});";
const replacement = "// Open DMs: any authenticated, non-blocked user may start a private conversation. Server-side membership checks protect every DM operation.";

if (source.includes(blocked)) {
  fs.writeFileSync(serverPath, source.replace(blocked, replacement));
  console.log('Snck Chat: open DMs enabled.');
} else {
  console.log('Snck Chat: open DMs already enabled or DM rule was not present.');
}
