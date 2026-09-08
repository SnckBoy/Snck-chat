INSERT INTO "Conversation" ("id","type","createdAt") VALUES ('global','GLOBAL',NOW()) ON CONFLICT ("id") DO UPDATE SET "type"='GLOBAL';
INSERT INTO "ConversationMember" ("id","conversationId","userId","joinedAt") SELECT 'global-' || u."id",'global',u."id",NOW() FROM "User" u ON CONFLICT ("conversationId","userId") DO NOTHING;
CREATE OR REPLACE FUNCTION snck_add_global_member() RETURNS trigger AS $$ BEGIN INSERT INTO "ConversationMember" ("id","conversationId","userId","joinedAt") VALUES ('global-' || NEW."id",'global',NEW."id",NOW()) ON CONFLICT ("conversationId","userId") DO NOTHING; RETURN NEW; END; $$ LANGUAGE plpgsql;
DROP TRIGGER IF EXISTS snck_user_global_member ON "User";
CREATE TRIGGER snck_user_global_member AFTER INSERT ON "User" FOR EACH ROW EXECUTE FUNCTION snck_add_global_member();
