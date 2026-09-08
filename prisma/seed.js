const { PrismaClient } = require('@prisma/client');
const prisma = new PrismaClient();
(async()=>{
  const c=await prisma.conversation.upsert({where:{id:'global'},update:{type:'GLOBAL'},create:{id:'global',type:'GLOBAL'}});
  await prisma.siteSetting.upsert({where:{key:'site'},create:{key:'site',value:{name:'Snck Chat',description:'A modern real-time community chat'}},update:{}});
  console.log(`Global conversation ready: ${c.id}`);
  await prisma.$disconnect();
})().catch(async e=>{console.error(e);await prisma.$disconnect();process.exit(1)});
