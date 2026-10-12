-- =============================================================================
-- Wassel (واصل) v1: roles, constraints, triggers, grants (Production Master)
--
--   A. Role bootstrap : run ONCE by infra as a superuser:
--        psql -v owner_pw='...' -v app_pw='...' -f this-file.sql   (section A only)
--   B. Post-migration : append to the FIRST Prisma migration
--        (generate with `prisma migrate dev --create-only`, paste B, then apply).
--        Runs as cc_owner via directUrl.
--   C. RLS hardening  : NOT APPLIED IN v1. Do not run. Kept here so the design is
--        reviewed now and needs no table restructuring later.
--        Gate: must be applied before a second tenant is activated.
--   D. Verification   : first-run test checklist and integrity gates.
--
-- Identifiers use Prisma default names, hence the quoting.
-- NOT RUN against a database when written; treat as a reviewed draft.
-- =============================================================================


-- ---------- A. ROLE BOOTSTRAP (superuser, once) ------------------------------

CREATE ROLE cc_owner LOGIN PASSWORD :'owner_pw'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
CREATE ROLE cc_app LOGIN PASSWORD :'app_pw'
  NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

CREATE DATABASE cc OWNER cc_owner;

-- CHANGED: Item 1 - Create dedicated shadow database for `prisma migrate dev`.
-- cc_owner has NOCREATEDB, preventing Prisma from creating dynamic shadow DBs on the fly.
CREATE DATABASE cc_shadow OWNER cc_owner;

\connect cc

-- CHANGED: Item 2 - Transfer public schema ownership to cc_owner.
-- In PostgreSQL < 15, the default owner of public is postgres, and in PostgreSQL 15+ the public
-- CREATE grant is revoked from PUBLIC. Assigning ownership of public to cc_owner ensures cc_owner
-- can create tables and manage schema objects even after REVOKE ALL ON SCHEMA public FROM PUBLIC.
ALTER SCHEMA public OWNER TO cc_owner;

REVOKE ALL ON DATABASE cc FROM PUBLIC;
GRANT CONNECT ON DATABASE cc TO cc_app;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO cc_app;

-- No ALTER DEFAULT PRIVILEGES on purpose: a table added without an explicit
-- grant fails closed (permission denied in tests) instead of being silently open.
-- A CI test asserts the privilege matrix for cc_app.


-- ---------- B. POST-MIGRATION (append to first migration, runs as cc_owner) --

-- B0. Required Extensions -----------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- B1. Integrity checks ---------------------------------------------------------

ALTER TABLE "Tenant"
  ADD CONSTRAINT tenant_slug_format
    CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,62}$'),
  ADD CONSTRAINT tenant_prefix_format
    CHECK ("trackingPrefix" ~ '^[A-Z]{2,4}$');

ALTER TABLE "User"
  ADD CONSTRAINT user_email_normalized
    CHECK (email = lower(btrim(email)));

ALTER TABLE "PlatformAdmin"
  ADD CONSTRAINT platform_admin_email_normalized
    CHECK (email = lower(btrim(email)));

ALTER TABLE "Category"
  ADD CONSTRAINT category_key_format
    CHECK ("key" ~ '^[a-z0-9_]{1,32}$');

ALTER TABLE "ReportDraft"
  ADD CONSTRAINT draft_location_pair
    CHECK (("latitude" IS NULL) = ("longitude" IS NULL)),
  ADD CONSTRAINT draft_location_range
    CHECK ("latitude" BETWEEN -90 AND 90 AND "longitude" BETWEEN -180 AND 180);

ALTER TABLE "Report"
  -- {PREFIX}-{6 chars}; alphabet excludes 0, 1, I, L, O
  ADD CONSTRAINT report_tracking_code_format
    CHECK ("trackingCode" ~ '^[A-Z]{2,4}-[2-9A-HJKMNP-Z]{6}$'),
  ADD CONSTRAINT report_description_not_blank
    CHECK (char_length(btrim("description")) > 0),
  ADD CONSTRAINT report_location_pair
    CHECK (("latitude" IS NULL) = ("longitude" IS NULL)),
  ADD CONSTRAINT report_has_location_consistent
    CHECK ("hasLocation" = ("latitude" IS NOT NULL)),
  ADD CONSTRAINT report_location_range
    CHECK ("latitude" BETWEEN -90 AND 90 AND "longitude" BETWEEN -180 AND 180),
  -- keeps the average-resolution-time number honest; reopen/undo MUST reset resolvedAt = NULL
  ADD CONSTRAINT report_resolved_at_matches_status
    CHECK (("status" = 'RESOLVED') = ("resolvedAt" IS NOT NULL)),
  ADD CONSTRAINT report_rejection_has_message
    CHECK ("status" <> 'REJECTED' OR btrim(coalesce("citizenMessage", '')) <> '');

-- CHANGED: Item 3 - Integrity checks for ReportEvent: valid actorType, actorUserId required for USER actor,
-- and status change events must have both fromStatus and toStatus populated.
ALTER TABLE "ReportEvent"
  ADD CONSTRAINT report_event_actor_type_valid
    CHECK ("actorType" IN ('CITIZEN', 'USER', 'SYSTEM')),
  ADD CONSTRAINT report_event_user_actor_has_id
    CHECK (("actorType" = 'USER') = ("actorUserId" IS NOT NULL)),
  ADD CONSTRAINT report_event_status_changed_has_statuses
    CHECK ("type" <> 'STATUS_CHANGED' OR ("fromStatus" IS NOT NULL AND "toStatus" IS NOT NULL));

-- CHANGED: Item 3 - Integrity check for AuditEvent: citizens can never be audit event actors.
ALTER TABLE "AuditEvent"
  ADD CONSTRAINT audit_event_actor_not_citizen
    CHECK ("actorType" <> 'CITIZEN');


-- B2. Partial indexes (Prisma cannot declare these) ----------------------------

-- at most one ACTIVE draft per conversation
CREATE UNIQUE INDEX "ReportDraft_one_active_per_conversation"
  ON "ReportDraft" ("tenantId", "conversationId")
  WHERE "status" = 'ACTIVE';

-- draft expiry sweep
CREATE INDEX "ReportDraft_active_expiry"
  ON "ReportDraft" ("tenantId", "expiresAt")
  WHERE "status" = 'ACTIVE';

-- outbox poller
CREATE INDEX "Notification_due"
  ON "Notification" ("tenantId", "nextAttemptAt")
  WHERE "status" = 'PENDING';

-- inbox re-enqueue sweeper (rows inserted but never enqueued)
CREATE INDEX "InboxMessage_unprocessed"
  ON "InboxMessage" ("tenantId", "receivedAt")
  WHERE "status" = 'RECEIVED';


-- B3. Append-only tables -------------------------------------------------------
-- Belt and braces: the trigger blocks UPDATE/DELETE for every role (including the
-- owner); B4 also revokes the privileges from cc_app. A deliberate erasure
-- procedure must run as cc_owner, disable the trigger inside a transaction, and
-- write an AuditEvent.

CREATE FUNCTION cc_forbid_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION '% is append-only', TG_TABLE_NAME;
END
$$;

CREATE TRIGGER report_event_append_only
  BEFORE UPDATE OR DELETE ON "ReportEvent"
  FOR EACH ROW EXECUTE FUNCTION cc_forbid_mutation();

CREATE TRIGGER audit_event_append_only
  BEFORE UPDATE OR DELETE ON "AuditEvent"
  FOR EACH ROW EXECUTE FUNCTION cc_forbid_mutation();


-- B4. Grants for the runtime role ---------------------------------------------
-- Explicit per table. Every future migration that adds a table must add its grant.

-- never deleted by the app (deactivate / close instead)
GRANT SELECT, INSERT, UPDATE ON
  "Tenant", "TenantChannel", "User", "PlatformAdmin",
  "Category", "Contact", "Report", "Notification"
  TO cc_app;

-- operational data with retention or cleanup jobs
GRANT SELECT, INSERT, UPDATE, DELETE ON
  "UserSession", "PlatformAdminSession",
  "Conversation", "ReportDraft", "Attachment", "InboxMessage"
  TO cc_app;

-- append-only
GRANT SELECT, INSERT ON "ReportEvent", "AuditEvent" TO cc_app;

-- cc_app has no access to "_prisma_migrations" (not granted).


-- -----------------------------------------------------------------------------
-- CHANGED: Item 4 & 5 - PDPL (Law 151/2020) Consent & Erasure Procedure and Blind Index
-- -----------------------------------------------------------------------------
-- BLIND INDEX SPECIFICATION (Item 5):
--  * HMAC Input: HMAC_SHA256(secret_key, tenantId || ':' || normalized_e164_phone)
--    Scoped with `tenantId` prefix so phone hashes are distinct across tenants even
--    for the same citizen, preventing cross-tenant tracking if a database dump leaks.
--  * Key Rotation Conflict Resolution:
--    We retain `@@unique([tenantId, phoneHash])` and do NOT include `keyVersion` in the unique index.
--    Justification: Including `keyVersion` allows the same citizen to be inserted multiple times
--    under different key versions, creating duplicate contact records. Key rotation is handled
--    via an online re-hash script: during key rotation, the lookup computes hashes with both current
--    and retired keys, while a background job re-encrypts `phoneEnc` and updates `phoneHash` in place.
--
-- RIGHT-TO-ERASURE / ANONYMIZATION PROCEDURE (Item 4):
-- When a citizen exercises their legal Right to Erasure under Egyptian PDPL (Law 151/2020):
-- 1. Session Context:
--    The erasure script runs via directUrl as `cc_owner`. If RLS is enabled (Section C),
--    it MUST first set the tenant context:
--      SELECT set_config('app.tenant_id', '<target_tenant_id>', true);
-- 2. Contact Anonymization:
--    Within a transaction, update the target Contact:
--      UPDATE "Contact"
--         SET "phoneEnc"     = gen_random_bytes(48),   -- overwrite encrypted phone with random bytes
--             "phoneHash"    = encode(gen_random_bytes(32), 'hex'), -- overwrite HMAC blind index
--             "anonymizedAt" = clock_timestamp()
--       WHERE "id" = '<contact_id>' AND "tenantId" = '<target_tenant_id>';
-- 3. Comprehensive Data Scrub (Reports, Drafts, Inbound Messages & Attachments):
--    a. Redact Report free text, address, and coordinates:
--      UPDATE "Report"
--         SET "description"  = '[تم حذف البيانات الشخصية بموجب قانون حماية البيانات الشخصية ١٥١ لسنة ٢٠٢٠]',
--             "addressText"  = NULL,
--             "latitude"     = NULL,
--             "longitude"    = NULL,
--             "hasLocation"  = false
--       WHERE "contactId" = '<contact_id>' AND "tenantId" = '<target_tenant_id>';
--    b. Scrub unsubmitted / active drafts:
--      UPDATE "ReportDraft"
--         SET "description"  = '[تم الحذف]',
--             "latitude"     = NULL,
--             "longitude"    = NULL,
--             "stepContext"  = '{}'
--       WHERE "tenantId" = '<target_tenant_id>'
--         AND "conversationId" IN (SELECT "id" FROM "Conversation" WHERE "contactId" = '<contact_id>');
--    c. Scrub raw inbound messages (InboxMessage):
--      UPDATE "InboxMessage"
--         SET "normalized" = '{"redacted": true}'
--       WHERE "tenantId" = '<target_tenant_id>'
--         AND "chatwootConversationId" IN (SELECT "chatwootConversationId" FROM "Conversation" WHERE "contactId" = '<contact_id>');
--    d. Mark physical attachments as PURGED in DB:
--      UPDATE "Attachment"
--         SET "status" = 'PURGED', "objectKey" = NULL, "providerMediaRef" = NULL
--       WHERE "tenantId" = '<target_tenant_id>'
--         AND "draftId" IN (SELECT "id" FROM "ReportDraft" WHERE "conversationId" IN (SELECT "id" FROM "Conversation" WHERE "contactId" = '<contact_id>'));
-- 4. Audit Trail:
--    Insert an AuditEvent recording the legal compliance action (logged as SYSTEM or authorized USER):
--      INSERT INTO "AuditEvent" ("id", "tenantId", "actorType", "actorId", "action", "targetType", "targetId", "meta", "createdAt")
--      VALUES (gen_random_uuid(), '<target_tenant_id>', 'SYSTEM', '<operator_user_id>', 'contact.erased_pdpl', 'Contact', '<contact_id>', '{"legalBasis":"Law 151/2020"}', clock_timestamp());
-- 5. Mandatory External & Unstructured Data Purges:
--    - Chatwoot: Invoke Chatwoot API (`DELETE /api/v1/accounts/{acc}/contacts/{chatwootContactId}`)
--      to delete the conversation history and customer profile.
--    - Object Storage: Permanently delete all photos in S3/MinIO
--      (`s3://bucket/tenants/{tenantId}/drafts/{draftId}/*`).
--    - Replay Log on Restore: Documented in runbook; upon restoring from any older backup,
--      re-play erasure audit records to re-anonymize contacts before opening production traffic.
-- -----------------------------------------------------------------------------


-- ---------- C. RLS HARDENING: NOT APPLIED IN v1 -------------------------------
-- Everything below is commented out on purpose.
--
-- App side (single choke point, the tenant-scoped repository):
--   await prisma.$transaction(async (tx) => {
--     await tx.$executeRaw`SELECT set_config('app.tenant_id', ${tenantId}, true)`;
--     return work(tx);   // true = transaction-local, same effect as SET LOCAL
--   });
--
-- CHANGED: Item 7 - FORCE ROW LEVEL SECURITY side effect:
-- FORCE ROW LEVEL SECURITY ensures policies apply to table owners (cc_owner) as well as cc_app.
-- As a result, database seeders, maintenance backfills, and the PDPL erasure procedure must
-- explicitly invoke `SELECT set_config('app.tenant_id', ...)` before accessing tenant tables.
--
-- C1. Helper: NULL when unset, so a missing context returns zero rows (fail closed).
--
-- CREATE FUNCTION cc_current_tenant() RETURNS uuid
-- LANGUAGE sql STABLE AS
--   $$ SELECT NULLIF(current_setting('app.tenant_id', true), '')::uuid $$;
--
-- C2. Enable and force RLS on every tenant-owned table.
--
-- DO $$
-- DECLARE t text;
-- BEGIN
--   FOREACH t IN ARRAY ARRAY[
--     'Category', 'Contact', 'Conversation', 'ReportDraft', 'Attachment',
--     'Report', 'ReportEvent', 'Notification', 'InboxMessage'
--   ] LOOP
--     EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
--     EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
--     EXECUTE format(
--       'CREATE POLICY tenant_isolation ON %I
--          USING ("tenantId" = cc_current_tenant())
--          WITH CHECK ("tenantId" = cc_current_tenant())', t);
--   END LOOP;
-- END $$;
--
-- C3. Tables handled differently:
--   * Registry and auth tables ("Tenant", "TenantChannel", "User", "UserSession",
--     "PlatformAdmin", "PlatformAdminSession") are read before any tenant context
--     exists (login, refresh, webhook resolution). They stay outside
--     tenant_isolation and are reached only through AuthRepository and
--     ChannelResolver, or through narrow SECURITY DEFINER lookup functions.
--   * "AuditEvent": tenant users may read only their own tenant's rows; platform
--     events ("tenantId" IS NULL) are not visible to tenant context.
--       USING      ("tenantId" = cc_current_tenant())
--       WITH CHECK ("tenantId" IS NULL OR "tenantId" = cc_current_tenant())
--   * Workers iterate ACTIVE tenants from the registry and set the context per
--     tenant, so no BYPASSRLS role is needed.
--
-- C4. Activation gate (the activate endpoint refuses a 2nd active tenant unless true):
--
-- CHANGED: Item 6 - C4 RLS gate query updated to require exactly 9 tenant tables to exist
-- and have both relrowsecurity AND relforcerowsecurity enabled.
--
-- SELECT (count(*) = 9 AND bool_and(c.relrowsecurity AND c.relforcerowsecurity)) AS rls_complete
--   FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--  WHERE n.nspname = 'public'
--    AND c.relname IN ('Category', 'Contact', 'Conversation', 'ReportDraft',
--                      'Attachment', 'Report', 'ReportEvent', 'Notification',
--                      'InboxMessage');
--
-- C5. Tests to re-run with RLS on, as cc_app: the full cross-tenant isolation
--     suite, plus a negative test: a query with no app.tenant_id set returns 0 rows.


-- ---------- D. FIRST-RUN VERIFICATION -----------------------------------------
-- CHANGED: Item 12 - First-Run Verification Checklist
--
-- STATUS: None of these verification steps have been run yet.
-- Follow these exact commands in order during initial environment provisioning:
--
-- Step 1: Format and validate Prisma schema
--   npx prisma format && npx prisma validate
--
-- Step 2: Generate initial migration and append Section B
--   npx prisma migrate dev --create-only --name init
--   # Append SQL Section B (B1, B2, B3, B4) to the generated migration.sql file
--   npx prisma migrate dev
--
-- Step 3: Drift detection for partial indexes and CHECK constraints
--   npx prisma migrate diff --from-schema-datamodel schema.prisma --to-schema-datasource schema.prisma --exit-code
--   # [NEEDS VERIFICATION for installed Prisma version]: Confirm Prisma does not propose
--   # DROP INDEX for partial indexes (B2) or attempt to strip CHECK constraints (B1).
--
-- Step 4: Privilege-matrix verification for runtime role (cc_app)
--   psql -U cc_app -d cc -c "SELECT count(*) FROM \"Tenant\";"            -- MUST SUCCEED (SELECT granted)
--   psql -U cc_app -d cc -c "UPDATE \"ReportEvent\" SET \"note\" = 'test';" -- MUST FAIL (permission denied)
--   psql -U cc_app -d cc -c "DELETE FROM \"ReportEvent\";"                -- MUST FAIL (permission denied)
--   psql -U cc_app -d cc -c "UPDATE \"AuditEvent\" SET \"action\" = 'test';" -- MUST FAIL (permission denied)
--   psql -U cc_app -d cc -c "DELETE FROM \"AuditEvent\";"                 -- MUST FAIL (permission denied)
--
-- Step 5: Append-only trigger verification (even under cc_owner)
--   psql -U cc_owner -d cc -c "UPDATE \"ReportEvent\" SET \"note\" = 'test';"
--   # MUST FAIL with: ERROR:  ReportEvent is append-only
--   psql -U cc_owner -d cc -c "DELETE FROM \"ReportEvent\";"
--   # MUST FAIL with: ERROR:  ReportEvent is append-only
--
-- Step 6: Cross-tenant isolation automated test suite
--   npm run test:e2e -- --testPathPattern=cross-tenant-isolation
--   # Verifies application-layer scoping and repository filtering before onboarding tenant 2.
-- =============================================================================
