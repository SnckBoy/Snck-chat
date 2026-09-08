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
async function notify(userId, type, data) { const n = await prisma.notification.create({ data: { userId, type, data } }); io.to(`user:${userId}`).emit('notification:new', n); return n; }
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
  }
  const token = newToken();
  await prisma.session.create({ data:{ tokenHash:hashToken(token), userId:u.id, expiresAt:new Date(Date.now()+SESSION_DAYS*86400000) } });
  if (existingSession) await prisma.session.deleteMany({ where:{ userId:u.id, tokenHash:{ not:hashToken(token) } } });
  setCookie(res, SESSION_COOKIE, token, SESSION_DAYS*86400000);
  res.json({ user:safeUser(u) });
} catch(e){next(e);} });

app.post('/api/auth/logout', requireUser, async (req,res,next)=>{ try { const raw=req.cookies[SESSION_COOKIE]; if(raw) await prisma.session.deleteMany({where:{tokenHash:hashToken(raw)}}); clearCookie(res,SESSION_COOKIE); res.json({ok:true}); }catch(e){next(e);} });
app.get('/api/auth/me', async (req,res,next)=>{ try { const u=await currentUser(req); res.json({user:u?safeUser(u):null}); }catch(e){next(e);} });

app.get('/api/users/search', requireUser, async (req,res,next)=>{ try { const q=String(req.query.q||'').trim().toLowerCase(); if(q.length<2) return res.json({users:[]}); const users=await prisma.user.findMany({where:{username:{contains:q},disabled:false,id:{not:req.user.id}},select:{id:true,username:true,displayName:true,avatarUrl:true,bio:true,status:true},take:20,orderBy:{username:'asc'}}); res.json({users}); }catch(e){next(e);} });
app.get('/api/users/:id', requireUser, async(req,res,next)=>{try{const u=await prisma.user.findUnique({where:{id:req.params.id}});if(!u||u.disabled)return res.status(404).json({error:'User not found'});res.json({user:safeUser(u)});}catch(e){next(e);}});
app.patch('/api/users/me', requireUser, async(req,res,next)=>{try{const d=parse(z.object({displayName:z.string().trim().min(1).max(40).optional(),bio:z.string().max(280).optional(),avatarUrl:z.string().url().max(1000).nullable().optional(),status:z.enum(['online','idle','busy','offline']).optional(),username:z.string().trim().min(3).max(24).optional()}),req.body);if(d.username&&d.username.toLowerCase()!==req.user.username){if(!USERNAME.test(d.username))return res.status(400).json({error:'Invalid username'});const exists=await prisma.user.findUnique({where:{username:d.username.toLowerCase()}});if(exists)return res.status(409).json({error:'Username already taken'});d.username=d.username.toLowerCase();}const u=await prisma.user.update({where:{id:req.user.id},data:d});res.json({user:safeUser(u)});}catch(e){next(e);}});

app.get('/api/friends', requireUser, async(req,res,next)=>{try{const rows=await prisma.friendship.findMany({where:{OR:[{userAId:req.user.id},{userBId:req.user.id}]},include:{userA:true,userB:true},orderBy:{createdAt:'desc'}});res.json({friends:rows.map(x=>safeUser(x.userAId===req.user.id?x.userB:x.userA))});}catch(e){next(e);}});
app.get('/api/friends/requests', requireUser, async(req,res,next)=>{try{const rows=await prisma.friendRequest.findMany({where:{OR:[{senderId:req.user.id,status:'pending'},{receiverId:req.user.id,status:'pending'}]},include:{sender:true,receiver:true},orderBy:{createdAt:'desc'}});res.json({requests:rows.map(x=>({...x,sender:safeUser(x.sender),receiver:safeUser(x.receiver)}))});}catch(e){next(e);}});
app.post('/api/friends/request', requireUser, async(req,res,next)=>{try{const {userId}=parse(z.object({userId:z.string()}),req.body);if(userId===req.user.id)return res.status(400).json({error:'You cannot add yourself'});const target=await prisma.user.findUnique({where:{id:userId}});if(!target||target.disabled)return res.status(404).json({error:'User not found'});if(await isBlocked(req.user.id,userId))return res.status(403).json({error:'Blocked users cannot be added'});if(await areFriends(req.user.id,userId))return res.status(409).json({error:'Already friends'});const reverse=await prisma.friendRequest.findUnique({where:{senderId_receiverId:{senderId:userId,receiverId:req.user.id}}});if(reverse&&reverse.status==='pending')return res.status(409).json({error:'This user already sent you a request'});const fr=await prisma.friendRequest.upsert({where:{senderId_receiverId:{senderId:req.user.id,receiverId:userId}},update:{status:'pending'},create:{senderId:req.user.id,receiverId:userId}});await notify(userId,'friend_request',{requestId:fr.id,userId:req.user.id,username:req.user.username});res.json({request:fr});}catch(e){next(e);}});
app.post('/api/friends/request/:id/accept', requireUser, async(req,res,next)=>{try{const fr=await prisma.friendRequest.findUnique({where:{id:req.params.id}});if(!fr||fr.receiverId!==req.user.id||fr.status!=='pending')return res.status(404).json({error:'Request not found'});const [a,b]=fr.senderId<fr.receiverId?[fr.senderId,fr.receiverId]:[fr.receiverId,fr.senderId];await prisma.$transaction([prisma.friendRequest.update({where:{id:fr.id},data:{status:'accepted'}}),prisma.friendship.create({data:{userAId:a,userBId:b}})]);await notify(fr.senderId,'friend_accepted',{userId:req.user.id});io.to(`user:${fr.senderId}`).emit('friends:changed');io.to(`user:${req.user.id}`).emit('friends:changed');res.json({ok:true});}catch(e){next(e);}});
app.post('/api/friends/request/:id/reject', requireUser, async(req,res,next)=>{try{const fr=await prisma.friendRequest.findUnique({where:{id:req.params.id}});if(!fr||fr.receiverId!==req.user.id||fr.status!=='pending')return res.status(404).json({error:'Request not found'});await prisma.friendRequest.update({where:{id:fr.id},data:{status:'rejected'}});res.json({ok:true});}catch(e){next(e);}});
app.delete('/api/friends/:userId', requireUser, async(req,res,next)=>{try{const [a,b]=req.user.id<req.params.userId?[req.user.id,req.params.userId]:[req.params.userId,req.user.id];await prisma.friendship.deleteMany({where:{userAId:a,userBId:b}});res.json({ok:true});}catch(e){next(e);}});
app.post('/api/blocks', requireUser, async(req,res,next)=>{try{const {userId}=parse(z.object({userId:z.string()}),req.body);if(userId===req.user.id)return res.status(400).json({error:'Invalid user'});await prisma.block.upsert({where:{blockerId_blockedId:{blockerId:req.user.id,blockedId:userId}},update:{},create:{blockerId:req.user.id,blockedId:userId}});const [a,b]=req.user.id<userId?[req.user.id,userId]:[userId,req.user.id];await prisma.friendship.deleteMany({where:{userAId:a,userBId:b}});res.json({ok:true});}catch(e){next(e);}});
app.delete('/api/blocks/:userId', requireUser, async(req,res,next)=>{try{await prisma.block.deleteMany({where:{blockerId:req.user.id,blockedId:req.params.userId}});res.json({ok:true});}catch(e){next(e);}});

app.get('/api/conversations', requireUser, async(req,res,next)=>{try{const rows=await prisma.conversation.findMany({where:{members:{some:{userId:req.user.id}}},include:{members:{include:{user:true}},messages:{orderBy:{createdAt:'desc'},take:1,include:{author:true,reactions:true}}},orderBy:{createdAt:'desc'}});res.json({conversations:rows.map(c=>({id:c.id,type:c.type,members:c.members.map(m=>safeUser(m.user)),lastMessage:c.messages[0]?safeMessage(c.messages[0]):null}))});}catch(e){next(e);}});
app.post('/api/conversations/dm', requireUser, async(req,res,next)=>{try{const {userId}=parse(z.object({userId:z.string()}),req.body);if(userId===req.user.id)return res.status(400).json({error:'Invalid recipient'});if(await isBlocked(req.user.id,userId))return res.status(403).json({error:'Cannot message this user'});if(!await areFriends(req.user.id,userId))return res.status(403).json({error:'You must be friends before starting a DM'});const existing=await prisma.conversation.findFirst({where:{type:'DM',AND:[{members:{some:{userId:req.user.id}}},{members:{some:{userId:userId}}}]},include:{members:{include:{user:true}}}});if(existing)return res.json({conversation:{id:existing.id,members:existing.members.map(m=>safeUser(m.user))}});const c=await prisma.conversation.create({data:{type:'DM',members:{create:[{userId:req.user.id},{userId}]}}});res.json({conversation:{id:c.id,members:[safeUser(req.user),safeUser(await prisma.user.findUnique({where:{id:userId}}))]}});}catch(e){next(e);}});
app.get('/api/conversations/:id/messages', requireUser, async(req,res,next)=>{try{if(!(await canAccessConversation(req.user.id,req.params.id)))return res.status(403).json({error:'Forbidden'});const limit=Math.min(Number(req.query.limit)||50,100);const before=req.query.before?new Date(String(req.query.before)):undefined;const rows=await prisma.message.findMany({where:{conversationId:req.params.id,...before?{createdAt:{lt:before}}:{}},include:{author:true,reactions:{include:{user:{select:{id:true,username:true}}}},replyTo:{include:{author:true}}},orderBy:{createdAt:'desc'},take:limit});res.json({messages:rows.reverse().map(safeMessage),hasMore:rows.length===limit});}catch(e){next(e);}});
app.post('/api/conversations/:id/messages', requireUser, messageLimiter, async(req,res,next)=>{try{if(!(await canAccessConversation(req.user.id,req.params.id)))return res.status(403).json({error:'Forbidden'});const d=parse(z.object({content:z.string().trim().min(1).max(MESSAGE_MAX),replyToId:z.string().nullable().optional()}),req.body);if(d.replyToId){const reply=await prisma.message.findFirst({where:{id:d.replyToId,conversationId:req.params.id}});if(!reply)return res.status(400).json({error:'Invalid reply target'});}const m=await prisma.message.create({data:{conversationId:req.params.id,authorId:req.user.id,content:d.content,replyToId:d.replyToId||null},include:{author:true,reactions:true}});const out=safeMessage(m);io.to(`conversation:${req.params.id}`).emit('message:new',out);const members=await prisma.conversationMember.findMany({where:{conversationId:req.params.id,userId:{not:req.user.id}}});for(const x of members)await notify(x.userId,'new_dm',{conversationId:req.params.id,messageId:m.id,from:req.user.username});res.status(201).json({message:out});}catch(e){next(e);}});

app.get('/api/global/messages', requireUser, async(req,res,next)=>{try{await ensureGlobalMember(req.user.id);const limit=Math.min(Number(req.query.limit)||50,100);const before=req.query.before?new Date(String(req.query.before)):undefined;const rows=await prisma.message.findMany({where:{conversationId:'global',...before?{createdAt:{lt:before}}:{}},include:{author:true,reactions:{include:{user:{select:{id:true,username:true}}}},replyTo:{include:{author:true}}},orderBy:{createdAt:'desc'},take:limit});res.json({messages:rows.reverse().map(safeMessage),hasMore:rows.length===limit});}catch(e){next(e);}});
app.post('/api/global/messages', requireUser, messageLimiter, async(req,res,next)=>{try{await ensureGlobalMember(req.user.id);const d=parse(z.object({content:z.string().trim().min(1).max(MESSAGE_MAX),replyToId:z.string().nullable().optional()}),req.body);if(d.replyToId){const reply=await prisma.message.findFirst({where:{id:d.replyToId,conversationId:'global'}});if(!reply)return res.status(400).json({error:'Invalid reply target'});}const m=await prisma.message.create({data:{conversationId:'global',authorId:req.user.id,content:d.content,replyToId:d.replyToId||null},include:{author:true,reactions:true}});const out=safeMessage(m);io.to('conversation:global').emit('message:new',out);res.status(201).json({message:out});}catch(e){next(e);}});
app.patch('/api/messages/:id', requireUser, async(req,res,next)=>{try{const d=parse(z.object({content:z.string().trim().min(1).max(MESSAGE_MAX)}),req.body);const m=await prisma.message.findUnique({where:{id:req.params.id}});if(!m||m.authorId!==req.user.id||!(await canAccessConversation(req.user.id,m.conversationId)))return res.status(404).json({error:'Message not found'});const updated=await prisma.message.update({where:{id:m.id},data:{content:d.content,editedAt:new Date()},include:{author:true,reactions:true}});io.to(`conversation:${m.conversationId}`).emit('message:edited',safeMessage(updated));res.json({message:safeMessage(updated)});}catch(e){next(e);}});
app.delete('/api/messages/:id', requireUser, async(req,res,next)=>{try{const m=await prisma.message.findUnique({where:{id:req.params.id}});if(!m||m.authorId!==req.user.id||!(await canAccessConversation(req.user.id,m.conversationId)))return res.status(404).json({error:'Message not found'});const updated=await prisma.message.update({where:{id:m.id},data:{deletedAt:new Date(),content:''},include:{author:true,reactions:true}});io.to(`conversation:${m.conversationId}`).emit('message:deleted',{id:m.id,conversationId:m.conversationId});res.json({ok:true});}catch(e){next(e);}});
app.post('/api/messages/:id/reactions', requireUser, async(req,res,next)=>{try{const {emoji}=parse(z.object({emoji:z.string().min(1).max(16)}),req.body);const m=await prisma.message.findUnique({where:{id:req.params.id}});if(!m||!(await canAccessConversation(req.user.id,m.conversationId)))return res.status(404).json({error:'Message not found'});const key={messageId:m.id,userId:req.user.id,emoji};const exists=await prisma.messageReaction.findUnique({where:{messageId_userId_emoji:key}});if(exists)await prisma.messageReaction.delete({where:{id:exists.id}});else await prisma.messageReaction.create({data:key});const reactions=await prisma.messageReaction.findMany({where:{messageId:m.id},include:{user:{select:{id:true,username:true}}}});io.to(`conversation:${m.conversationId}`).emit('message:reactions',{messageId:m.id,reactions});res.json({reactions});}catch(e){next(e);}});

app.post('/api/reports', requireUser, async(req,res,next)=>{try{const d=parse(z.object({targetType:z.enum(['user','message','profile']),targetId:z.string(),reason:z.string().trim().min(3).max(500)}),req.body);const r=await prisma.report.create({data:{reporterId:req.user.id,targetType:d.targetType,targetId:d.targetId,reason:d.reason}});res.status(201).json({report:{id:r.id,status:r.status}});}catch(e){next(e);}});
app.get('/api/notifications',requireUser,async(req,res,next)=>{try{const n=await prisma.notification.findMany({where:{userId:req.user.id},orderBy:{createdAt:'desc'},take:50});res.json({notifications:n,unread:n.filter(x=>!x.readAt).length});}catch(e){next(e);}});
app.post('/api/notifications/read',requireUser,async(req,res,next)=>{try{await prisma.notification.updateMany({where:{userId:req.user.id,readAt:null},data:{readAt:new Date()}});res.json({ok:true});}catch(e){next(e);}});

app.post('/api/admin/login',adminLimiter,async(req,res,next)=>{try{const d=parse(z.object({username:z.string().min(1).max(64),password:z.string().min(1).max(256)}),req.body);const a=await prisma.adminUser.findUnique({where:{username:d.username.toLowerCase()}});if(!a||a.disabled||!(await bcrypt.compare(d.password,a.passwordHash)))return res.status(401).json({error:'Invalid administrator credentials'});const token=newToken();await prisma.adminSession.create({data:{tokenHash:hashToken(token),adminId:a.id,expiresAt:new Date(Date.now()+ADMIN_SESSION_DAYS*86400000)}});setCookie(res,ADMIN_COOKIE,token,ADMIN_SESSION_DAYS*86400000);await audit(a.id,'admin_login',null,null,{});res.json({admin:{id:a.id,username:a.username}});}catch(e){next(e);}});
app.post('/api/admin/logout',requireAdmin,async(req,res,next)=>{try{const raw=req.cookies[ADMIN_COOKIE];if(raw)await prisma.adminSession.deleteMany({where:{tokenHash:hashToken(raw)}});clearCookie(res,ADMIN_COOKIE);res.json({ok:true});}catch(e){next(e);}});
app.get('/api/admin/me',async(req,res,next)=>{try{const a=await currentAdmin(req);res.json({admin:a?{id:a.id,username:a.username}:null});}catch(e){next(e);}});
app.get('/api/admin/stats',requireAdmin,async(req,res,next)=>{try{const [users,messages,reports,openReports]=await Promise.all([prisma.user.count(),prisma.message.count(),prisma.report.count(),prisma.report.count({where:{status:'open'}})]);res.json({users,messages,reports,openReports});}catch(e){next(e);}});
app.get('/api/admin/users',requireAdmin,async(req,res,next)=>{try{const q=String(req.query.q||'').trim().toLowerCase();const users=await prisma.user.findMany({where:q?{username:{contains:q}}:{},orderBy:{createdAt:'desc'},take:100});res.json({users:users.map(safeUser)});}catch(e){next(e);}});
app.patch('/api/admin/users/:id',requireAdmin,async(req,res,next)=>{try{const d=parse(z.object({disabled:z.boolean().optional(),username:z.string().min(3).max(24).optional()}),req.body);if(d.username&&!USERNAME.test(d.username))return res.status(400).json({error:'Invalid username'});const u=await prisma.user.update({where:{id:req.params.id},data:{...d,username:d.username?.toLowerCase()}});if(d.disabled)await prisma.session.deleteMany({where:{userId:u.id}});await audit(req.admin.id,d.disabled?'user_disabled':'user_updated','user',u.id,d);res.json({user:safeUser(u)});}catch(e){next(e);}});
app.delete('/api/admin/users/:id',requireAdmin,async(req,res,next)=>{try{if(req.params.id===req.admin.id)return res.status(400).json({error:'Invalid target'});await prisma.user.delete({where:{id:req.params.id}});await audit(req.admin.id,'user_deleted','user',req.params.id,{});res.json({ok:true});}catch(e){next(e);}});
app.get('/api/admin/reports',requireAdmin,async(req,res,next)=>{try{const rows=await prisma.report.findMany({include:{reporter:true},orderBy:{createdAt:'desc'},take:100});res.json({reports:rows.map(r=>({...r,reporter:safeUser(r.reporter)}))});}catch(e){next(e);}});
app.patch('/api/admin/reports/:id',requireAdmin,async(req,res,next)=>{try{const d=parse(z.object({status:z.enum(['open','resolved','rejected']),note:z.string().max(1000).optional()}),req.body);const r=await prisma.report.update({where:{id:req.params.id},data:{...d,resolvedAt:d.status==='open'?null:new Date()}});await audit(req.admin.id,'report_updated','report',r.id,d);res.json({report:r});}catch(e){next(e);}});
app.get('/api/admin/messages',requireAdmin,async(req,res,next)=>{try{const q=String(req.query.q||'').trim();const rows=await prisma.message.findMany({where:q?{content:{contains:q,mode:'insensitive'}}:{},include:{author:true},orderBy:{createdAt:'desc'},take:100});res.json({messages:rows.map(safeMessage)});}catch(e){next(e);}});
app.delete('/api/admin/messages/:id',requireAdmin,async(req,res,next)=>{try{const m=await prisma.message.findUnique({where:{id:req.params.id}});if(!m)return res.status(404).json({error:'Message not found'});await prisma.message.update({where:{id:m.id},data:{deletedAt:new Date(),content:''}});io.to(`conversation:${m.conversationId}`).emit('message:deleted',{id:m.id,conversationId:m.conversationId});await audit(req.admin.id,'message_deleted','message',m.id,{});res.json({ok:true});}catch(e){next(e);}});
app.get('/api/admin/audit-logs',requireAdmin,async(req,res,next)=>{try{const logs=await prisma.auditLog.findMany({orderBy:{createdAt:'desc'},take:200});res.json({logs});}catch(e){next(e);}});
app.get('/api/admin/settings',requireAdmin,async(req,res,next)=>{try{const rows=await prisma.siteSetting.findMany();res.json({settings:Object.fromEntries(rows.map(x=>[x.key,x.value]))});}catch(e){next(e);}});
app.put('/api/admin/settings',requireAdmin,async(req,res,next)=>{try{const d=parse(z.record(z.string(),z.any()),req.body);for(const [key,value] of Object.entries(d))await prisma.siteSetting.upsert({where:{key},create:{key,value},update:{value}});await audit(req.admin.id,'settings_updated','settings',null,d);res.json({ok:true});}catch(e){next(e);}});
app.get('/api/admin/conversations/:id/messages',requireAdmin,async(req,res,next)=>{try{const rows=await prisma.message.findMany({where:{conversationId:req.params.id},include:{author:true},orderBy:{createdAt:'asc'},take:500});await audit(req.admin.id,'private_chat_access','conversation',req.params.id,{count:rows.length});res.json({messages:rows.map(safeMessage)});}catch(e){next(e);}});

io.use(async(socket,next)=>{try{const raw=socket.handshake.headers.cookie?.split(';').map(x=>x.trim()).find(x=>x.startsWith(`${SESSION_COOKIE}=`))?.split('=')[1];if(!raw)return next(new Error('Unauthorized'));const s=await prisma.session.findUnique({where:{tokenHash:hashToken(raw)},include:{user:true}});if(!s||s.expiresAt<new Date()||s.user.disabled)return next(new Error('Unauthorized'));socket.user=s.user;next();}catch(e){next(e);}});
io.on('connection',socket=>{const u=socket.user;socket.join(`user:${u.id}`);socket.join('global');socket.emit('presence:self',{user:safeUser(u)});socket.on('conversation:join',async(id,ack)=>{try{if(id==='global'){await ensureGlobalMember(u.id);socket.join('conversation:global');ack?.({ok:true});return;}if(await canAccessConversation(u.id,id)){socket.join(`conversation:${id}`);ack?.({ok:true});}else ack?.({ok:false,error:'Forbidden'});}catch{ack?.({ok:false,error:'Server error'});}});socket.on('global:join',()=>socket.join('global'));socket.on('typing',async({conversationId,isTyping}={})=>{if(await canAccessConversation(u.id,conversationId))socket.to(`conversation:${conversationId}`).emit('typing',{conversationId,user:safeUser(u),isTyping:!!isTyping});});socket.on('global:typing',({isTyping}={})=>socket.to('global').emit('global:typing',{user:safeUser(u),isTyping:!!isTyping}));socket.on('presence:set',async(status)=>{const allowed=['online','idle','busy','offline'];if(allowed.includes(status)){await prisma.user.update({where:{id:u.id},data:{status}});socket.broadcast.emit('presence:update',{userId:u.id,status});}});socket.on('disconnect',()=>socket.broadcast.emit('presence:update',{userId:u.id,status:'offline'}));});

app.use(express.static(path.join(__dirname,'../public'),{extensions:['html']}));
app.get('*',(req,res)=>{if(req.path.startsWith('/api/'))return res.status(404).json({error:'Not found'});res.sendFile(path.join(__dirname,'../public/index.html'));});
app.use((err,req,res,_next)=>{console.error(err);res.status(err.status||500).json({error:err.status?err.message:'Internal server error'});});

httpServer.listen(PORT,()=>console.log(`Snck Chat listening on ${PORT}`));
process.on('SIGTERM',async()=>{await prisma.$disconnect();httpServer.close(()=>process.exit(0));});