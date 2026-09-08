const readline = require('node:readline');
const bcrypt = require('bcryptjs');
const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient();

function ask(question, hidden = false) {
  if (!hidden || !process.stdin.isTTY) {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
    return new Promise(resolve => rl.question(question, answer => { rl.close(); resolve(answer); }));
  }
  return new Promise((resolve, reject) => {
    const stdin = process.stdin;
    const oldRaw = stdin.isRaw;
    process.stdout.write(question);
    stdin.setRawMode(true);
    stdin.resume();
    let value = '';
    const cleanup = () => { stdin.off('data', onData); stdin.setRawMode(oldRaw ?? false); stdin.pause(); };
    const onData = chunk => {
      const key = chunk.toString('utf8');
      if (key === '\u0003') { cleanup(); reject(new Error('Canceled.')); return; }
      if (key === '\r' || key === '\n') { process.stdout.write('\n'); cleanup(); resolve(value); return; }
      if (key === '\u007f' || key === '\b') { if (value.length) value = value.slice(0, -1); return; }
      if (key >= ' ' && key !== '\u001b') value += key;
    };
    stdin.on('data', onData);
  });
}

async function main() {
  const username = (await ask('Admin username: ')).trim().toLowerCase();
  const password = await ask('Admin password: ', true);
  const confirm = await ask('Confirm password: ', true);
  if (!/^[a-z0-9_]{3,32}$/.test(username)) throw new Error('Username must be 3-32 letters, numbers, or underscores.');
  if (password.length < 10 || password !== confirm) throw new Error('Passwords must match and be at least 10 characters.');
  const passwordHash = await bcrypt.hash(password, 12);
  await prisma.adminUser.upsert({ where: { username }, create: { username, passwordHash }, update: { passwordHash, disabled: false } });
  console.log('Administrator created successfully.');
}

main().catch(err => { console.error(`\n${err.message}`); process.exitCode = 1; }).finally(() => prisma.$disconnect());
