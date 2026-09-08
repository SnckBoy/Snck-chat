const path = require('node:path');
const crypto = require('node:crypto');
const http = require('node:http');
const express = require('express');
const cookieParser = require('cookie-parser');
const helmet = require('helmet');
const compression = require('compression');
const morgan = require('morgan');
const rateLimit = require('express-rate-limit');
const bcrypt = require('bcryptjs');
const { z } = require('zod');
const { Server } = require('socket.io');
const { PrismaClient } = require('@prisma/client');

const prisma = new PrismaClient();
const app = express();
const httpServer = http.createServer(app);
const io = new Server(httpServer, { cors: { origin: false }, maxHttpBufferSize: 1e6 });
const PORT = Number(process.env.PORT || 3000);
const SESSION_DAYS = Number(process.env.SESSION_DAYS || 30);
const ADMIN_SESSION_DAYS = Number(process.env.ADMIN_SESSION_DAYS || 8);
const COOKIE_SECURE = process.env.COOKIE_SECURE === 'true';
const SESSION_COOKIE = 'snck_session';
const ADMIN_COOKIE = 'snck_admin';
const USERNAME = /^[a-zA-Z0-9_]{3,24}$/;
const MESSAGE_MAX = 4000;

app.disable('x-powered-by');
app.use(helmet({ contentSecurityPolicy: false }));
app.use(compression());
app.use(express.json({ limit: '1mb' }));
app.use(cookieParser());
if (process.env.NODE_ENV !== 'test') app.use(morgan('combined'));
const authLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 30, standardHeaders: 'draft-8', legacyHeaders: false });
const messageLimiter = rateLimit({ windowMs: 10 * 1000, limit: 20, standardHeaders: 'draft-8', legacyHeaders: false });
const adminLimiter = rateLimit({ windowMs: 15 * 60 * 1000, limit: 8, standardHeaders: 'draft-8', legacyHeaders: false });

function hashToken(token) { return crypto.createHash('sha256').update(token).digest('hex'); }
function newToken() { return crypto.randomBytes(48).toString('base64url'); }
function safeUser(u) { return { id: u.id, username: u.username, displayName: u.displayName, avatarUrl: u.avatarUrl, bio: u.bio, status: u.status, disabled: u.disabled, createdAt: u.createdAt }; }
function safeMessage(m) { return { id: m.id, conversationId: m.conversationId, author: safeUser(m.author), content: m.deletedAt ? '' : m.content, deleted: !!m.deletedAt, editedAt: m.editedAt, createdAt: m.createdAt, replyToId: m.replyToId, reactions: m.reactions || [] }; }
function parse(schema, value) { const r = schema.safeParse(value); if (!r.success) { const e = new Error('Invalid request'); e.status = 400; throw e; } return r.data; }
function setCookie(res, name, token, maxAge) { res.cookie(name, token, { httpOnly: true, sameSite: 'lax', secure: COOKIE_SECURE, maxAge }); }
function clearCookie(res, name) { res.clearCookie(name, { httpOnly: true, sameSite: 'lax', secure: COOKIE_SECURE }); }

async function currentUser(req) {
  const raw = req.cookies[SESSION_COOKIE]; if (!raw) return null;
  const s = await prisma.session.findUnique({ where: { tokenHash: hashToken(raw) }, include: { user: true } });
  if (!s || s.expiresAt < new Date() || s.user.disabled) return null;
  return s.user;
}
async function requireUser(req, res, next) { try { const u = await currentUser(req); if (!u) return res.status(401).json({ error: 'Authentication required' }); req.user = u; next(); } catch (e) { next(e); } }
async function currentAdmin(req) {
  const raw = req.cookies[ADMIN_COOKIE]; if (!raw) return null;
  const s = await prisma.adminSession.findUnique({ where: { tokenHash: hashToken(raw) }, include: { admin: true } });
  if (!s || s.expiresAt < new Date() || s.admin.disabled) return null;
  return s.admin;
}
async function requireAdmin(req, res, next) { try { const a = await currentAdmin(req); if (!a) return res.status(401).json({ error: 'Administrator authentication required' }); req.admin = a; next(); } catch (e) { next(e); } }
async function audit(adminId, action, targetType, targetId, metadata) { await prisma.auditLog.create({ data: { adminId, action, targetType, targetId, metadata } }); }
async function notify(userId, type, data) { const n = await prisma.notification.create({ data: { userId, type, payload: data } }); io.to(`user:${userId}`).emit('notification:new', n); return n; }
async function areFriends(a, b) { const [x,y] = a < b ? [a,b] : [b,a]; return !!await prisma.friendship.findUnique({ where: { userAId_userBId: { userAId:x, userBId:y } } }); }
async function isBlocked(a,b) { return !!await prisma.block.findFirst({ where: { OR:[{blockerId:a,blockedId:b},{blockerId:b,blockedId:a}] } }); }
async function canAccessConversation(userId, conversationId) { if (conversationId === 'global') return true; const m = await prisma.conversationMember.findUnique({ where: { conversationId_userId: { conversationId, userId } } }); return !!m; }
async function ensureGlobalConversation() { return prisma.conversation.upsert({ where: { id: 'global' }, update: {}, create: { id: 'global', type: 'GLOBAL' } }); }
async function ensureGlobalMember(userId) { await ensureGlobalConversation(); await prisma.conversationMember.upsert({ where: { conversationId_userId: { conversationId: 'global', userId } }, update: {}, create: { conversationId: 'global', userId } }); }

app.get('/api/health', (_req,res)=>res.json({ ok:true, service:'snck-chat', time:new Date().toISOString() }));

app.post('/api/auth/username', authLimiter, async (req,res,next)=>{ try {
  const { username } = parse(z.object({ username:z.string().trim().min(3).max(24) }), req.body);
  if (!USERNAME.test(username)) return res.status(400).json({ error:'Username must be 3-24 characters using letters, numbers, or underscores.' });
  const normalized = username.toLowerCase();
  let u = await prisma.user.findUnique({ where:{ username:normalized } });
  const existingSession = await currentUser(req);
  if (u) {
    if (!existingSession || existingSession.id !== u.id) return res.status(409).json({ error:'That username already exists. Continue from the device/session where it was created, or choose another username.' });
    await ensureGlobalMember(u.id);
  } else {
    u = await prisma.user.create({ data:{ username:normalized, displayName:username } });
    await ensureGlobalMember(u.id);
    const token = newToken(); await prisma.session.create({ data:{ tokenHash:hashToken(token), userId:u.id, expiresAt:new Date(Date.now()+SESSION_DAYS*86400000) } }); setCookie(res, SESSION_COOKIE, token, SESSION_DAYS*86400000);
  }
  if (!res.headersSent) res.json({ user:safeUser(u) });
} catch(e){ next(e); } });

app.post('/api/auth/logout', requireUser, async (req,res,next)=>{ try { const raw=req.cookies[SESSION_COOKIE]; if(raw) await prisma.session.deleteMany({where:{tokenHash:hashToken(raw)}}); clearCookie(res,SESSION_COOKIE); res.json({ok:true}); } catch(e){next(e);} });
app.get('/api/me', requireUser, async(req,res,next)=>{try{res.json({user:safeUser(req.user)})}catch(e){next(e)}});

app.get('/api/users/search', requireUser, async(req,res,next)=>{try{const q=String(req.query.q||'').trim().toLowerCase(); if(q.length<1)return res.json({users:[]}); const users=await prisma.user.findMany({where:{username:{contains:q},disabled:false},take:20,orderBy:{username:'asc'}});res.json({users:users.map(safeUser)});}catch(e){next(e)}});
app.get('/api/users/:id', requireUser, async(req,res,next)=>{try{const u=await prisma.user.findUnique({where:{id:req.params.id},include:{profile:true}});if(!u||u.disabled)return res.status(404).json({error:'User not found'});res.json({user:{...safeUser(u),...(u.profile||{})}})}catch(e){next(e)}});

app.post('/api/friends/request/:userId', requireUser, async(req,res,next)=>{try{if(req.user.id===req.params.userId)return res.status(400).json({error:'Cannot add yourself'});if(await isBlocked(req.user.id,req.params.userId))return res.status(403).json({error:'User is blocked'});const target=await prisma.user.findUnique({where:{id:req.params.userId}});if(!target||target.disabled)return res.status(404).json({error:'User not found'});if(await areFriends(req.user.id,target.id))return res.status(409).json({error:'Already friends'});const reverse=await prisma.friendRequest.findUnique({where:{requesterId_recipientId:{requesterId:target.id,recipientId:req.user.id}}});if(reverse&&reverse.status==='PENDING')return res.status(409).json({error:'This user already sent you a request'});const fr=await prisma.friendRequest.upsert({where:{requesterId_recipientId:{requesterId:req.user.id,recipientId:target.id}},create:{requesterId:req.user.id,recipientId:target.id},update:{status:'PENDING'}});await notify(target.id,'friend_request',{requestId:fr.id,userId:req.user.id});res.json({request:fr});}catch(e){next(e)}});
app.post('/api/friends/request/:id/accept', requireUser, async(req,res,next)=>{try{const fr=await prisma.friendRequest.findUnique({where:{id:req.params.id}});if(!fr||fr.recipientId!==req.user.id||fr.status!=='PENDING')return res.status(404).json({error:'Request not found'});await prisma.$transaction([prisma.friendRequest.update({where:{id:fr.id},data:{status:'ACCEPTED'}}),prisma.friendship.create({data:{userAId:fr.requesterId,userBId:fr.recipientId}})]);await notify(fr.requesterId,'friend_accepted',{userId:req.user.id});res.json({ok:true});}catch(e){next(e)}});
app.post('/api/friends/request/:id/reject', requireUser, async(req,res,next)=>{try{const fr=await prisma.friendRequest.findUnique({where:{id:req.params.id}});if(!fr||fr.recipientId!==req.user.id||fr.status!=='PENDING')return res.status(404).json({error:'Request not found'});await prisma.friendRequest.update({where:{id:fr.id},data:{status:'REJECTED'}});res.json({ok:true});}catch(e){next(e)}});
app.get('/api/friends', requireUser, async(req,res,next)=>{try{const [a,b,requests]=await Promise.all([prisma.friendship.findMany({where:{userAId:req.user.id},include:{userB:{include:{profile:true}}}}),prisma.friendship.findMany({where:{userBId:req.user.id},include:{userA:{include:{profile:true}}}}),prisma.friendRequest.findMany({where:{recipientId:req.user.id,status:'PENDING'},include:{requester:{include:{profile:true}}},orderBy:{createdAt:'desc'}})]);res.json({friends:[...a.map(x=>safeUser(x.userB)),...b.map(x=>safeUser(x.userA))],requests});}catch(e){next(e)}});

app.post('/api/block/:userId', requireUser, async(req,res,next)=>{try{if(req.user.id===req.params.userId)return res.status(400).json({error:'Cannot block yourself'});await prisma.block.upsert({where:{blockerId_blockedId:{blockerId:req.user.id,blockedId:req.params.userId}},create:{blockerId:req.user.id,blockedId:req.params.userId},update:{}});res.json({ok:true});}catch(e){next(e)}});
app.delete('/api/block/:userId', requireUser, async(req,res,next)=>{try{await prisma.block.deleteMany({where:{blockerId:req.user.id,blockedId:req.params.userId}});res.json({ok:true});}catch(e){next(e)}});

app.get('/api/conversations/global/messages', requireUser, async(req,res,next)=>{try{await ensureGlobalMember(req.user.id);const before=req.query.before?new Date(String(req.query.before)):new Date(Date.now()+1000);const messages=await prisma.message.findMany({where:{conversationId:'global',createdAt:{lt:before}},include:{author:{include:{profile:true}},reactions:true},orderBy:{createdAt:'desc'},take:50});res.json({messages:messages.reverse().map(safeMessage),hasMore:messages.length===50});}catch(e){next(e)}});

app.post('/api/messages', requireUser, messageLimiter, async(req,res,next)=>{try{const body=parse(z.object({conversationId:z.string().min(1).max(100),content:z.string().trim().min(1).max(MESSAGE_MAX),replyToId:z.string().optional()}),req.body);if(!(await canAccessConversation(req.user.id,body.conversationId)))return res.status(403).json({error:'Not a member of this conversation'});if(body.conversationId!=='global'){const members=await prisma.conversationMember.findMany({where:{conversationId:body.conversationId}});for(const m of members)if(await isBlocked(req.user.id,m.userId))return res.status(403).json({error:'Messaging is unavailable'});}const msg=await prisma.message.create({data:{conversationId:body.conversationId,userId:req.user.id,content:body.content,replyToId:body.replyToId||null},include:{author:{include:{profile:true}},reactions:true}});const out=safeMessage(msg);io.to(`conversation:${body.conversationId}`).emit('message:new',out);res.status(201).json({message:out});}catch(e){next(e)}});
app.patch('/api/messages/:id', requireUser, async(req,res,next)=>{try{const {content}=parse(z.object({content:z.string().trim().min(1).max(MESSAGE_MAX)}),req.body);const msg=await prisma.message.findUnique({where:{id:req.params.id}});if(!msg||msg.userId!==req.user.id)return res.status(404).json({error:'Message not found'});const updated=await prisma.message.update({where:{id:msg.id},data:{content},include:{author:{include:{profile:true}},reactions:true}});io.to(`conversation:${msg.conversationId}`).emit('message:updated',safeMessage(updated));res.json({message:safeMessage(updated)});}catch(e){next(e)}});
app.delete('/api/messages/:id', requireUser, async(req,res,next)=>{try{const msg=await prisma.message.findUnique({where:{id:req.params.id}});if(!msg||msg.userId!==req.user.id)return res.status(404).json({error:'Message not found'});await prisma.message.update({where:{id:msg.id},data:{deletedAt:new Date()}});io.to(`conversation:${msg.conversationId}`).emit('message:deleted',{id:msg.id,conversationId:msg.conversationId});res.json({ok:true});}catch(e){next(e)}});

app.use(express.static(path.join(__dirname,'..','public')));
app.get('*',(_req,res)=>res.sendFile(path.join(__dirname,'..','public','index.html')));
app.use((err,_req,res,_next)=>{console.error(err);res.status(err.status||500).json({error:err.status?err.message:'Internal server error'});});

io.use(async(socket,next)=>{try{const cookie=socket.handshake.headers.cookie||'';const match=cookie.match(new RegExp(`${SESSION_COOKIE}=([^;]+)`));if(!match)return next(new Error('Authentication required'));const s=await prisma.session.findUnique({where:{tokenHash:hashToken(match[1])},include:{user:true}});if(!s||s.expiresAt<new Date()||s.user.disabled)return next(new Error('Authentication required'));socket.user=s.user;next();}catch(e){next(e);}});
io.on('connection',socket=>{socket.join(`user:${socket.user.id}`);socket.join('conversation:global');socket.on('conversation:join',async id=>{try{if(await canAccessConversation(socket.user.id,String(id)))socket.join(`conversation:${id}`);}catch{}});socket.on('typing',async({conversationId,typing})=>{if(await canAccessConversation(socket.user.id,String(conversationId)))socket.to(`conversation:${conversationId}`).emit('typing',{userId:socket.user.id,username:socket.user.username,typing:!!typing});});});

async function shutdown(){await prisma.$disconnect();httpServer.close(()=>process.exit(0));}
process.on('SIGTERM',shutdown);process.on('SIGINT',shutdown);
if(require.main===module)httpServer.listen(PORT,'127.0.0.1',()=>console.log(`Snck Chat listening on 127.0.0.1:${PORT}`));
module.exports={app,httpServer,prisma};
