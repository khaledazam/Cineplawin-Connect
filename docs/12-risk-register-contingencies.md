# 12. Risk Register & Contingencies

## 12.1 Comprehensive Risk Assessment Matrix

Every technical and operational venture faces points of failure. For a solo developer operating a civic SaaS pilot in an Egyptian municipal hub, identifying these risks early and pre-authoring mitigation playbooks is critical.

```
       ▲ High
       │  [R-01: Meta API Ban/Delay]        [R-02: WhatsApp 24h Window Expiry]
       │  [R-04: Staff Reverts to Paper]     [R-03: VPS Memory Exhaustion]
IMPACT │
       │  [R-05: Spam/Troll Reports]        [R-06: PDPL Regulatory Inquiry]
       │  [R-07: Slow 3G Photo Uploads]     [R-08: Solo Dev Burnout]
       ▼ Low
         ◄ Low ───────────────────────────── PROBABILITY ────────────────────────► High
```

---

## 12.2 Detailed Risk Profiles & Contingency Plans

### 1. Technical Risks

#### Risk R-01: Meta WhatsApp Cloud API Delay or Number Ban
* **Description**: Meta account verification takes weeks, or automated spam algorithms flag the WhatsApp business number due to rapid outbound updates.
* **Probability**: Medium | **Impact**: Critical
* **Preventive Measure**:
  - Warm up the WhatsApp Business number during Sprint 1 with verified business documentation.
  - Never initiate unsolicited outbound messages; all notifications are direct transactional responses to citizen-initiated conversations.
* **Contingency / Fallback**:
  - Connect Chatwoot to a standard WhatsApp Web session via a local gateway (e.g. Baileys / WPPConnect bridge) as a temporary development and staging fallback while Meta Business verification finishes.

#### Risk R-02: WhatsApp 24-Hour Customer Service Window Expiry
* **Description**: A civic report takes 3 days to fix. When the agent changes status to `RESOLVED`, Meta rejects the free-form text message because more than 24 hours elapsed since the citizen's last inbound message.
* **Probability**: High | **Impact**: High
* **Preventive Measure**:
  - The confirmation message explicitly instructs the citizen: *"يمكنك إرسال كلمة (متابعة) في أي وقت لتحديث المحادثة ومعرفة آخر التطورات مجاناً"*.
* **Contingency / Fallback**:
  - Pre-approve an official Meta Utility Message Template (`cityconnect_status_update`):
    `"تحديث بخصوص بلاغك رقم {{1}}: الحالة الحالية هي {{2}}. شكراً لتعاونكم."`
  - The outbox worker detects if `(NOW() - conversation.lastInboundAt) > 24h`: if yes, sends the approved utility template instead of free-text.

#### Risk R-03: 8 GB VPS Memory Starvation (Chatwoot & Sidekiq Spikes)
* **Description**: Chatwoot Rails/Sidekiq processes leak memory over several days, exhausting the 8 GB RAM and triggering Linux OOM-killer against PostgreSQL.
* **Probability**: Medium | **Impact**: High
* **Preventive Measure**:
  - OS-level 4 GB Swapfile already provisioned as an emergency cushion.
  - Hard memory limits set in `docker-compose.prod.yml` (`chatwoot_web: 1536M`, `chatwoot_worker: 1024M`).
  - `MALLOC_ARENA_MAX=2` injected to curb Ruby glibc memory fragmentation.
* **Contingency / Fallback**:
  - Systemd health script checks `free -m` hourly; if available memory drops below 1 GB, issues a rolling restart of Chatwoot containers without stopping Postgres or the API.

#### Risk R-04: Slow 3G / Upload Failures on Citizen Media
* **Description**: Citizens in peripheral villages of Sunbullawein face spotty cellular coverage, leading to timed-out photo uploads.
* **Probability**: Medium | **Impact**: Low
* **Preventive Measure**:
  - The bot explicitly offers `"تخطي"` (Skip) at the photo step, preventing the workflow from blocking.
  - The photo step accepts low-resolution compressed previews sent natively by WhatsApp.

---

### 2. Operational & Field Risks

#### Risk R-05: Staff Abandonment (Reverting to Notebook or WhatsApp Group)
* **Description**: Mohamed (receptionist) finds logging into the dashboard extra effort and returns to writing patient complaints in his paper notebook.
* **Probability**: Medium | **Impact**: High
* **Preventive Measure**:
  - Deliver a zero-clutter dashboard: 1-click status change, auto-filled responses, fast keyboard shortcuts.
  - Dr. Hassan reviews the 3 headline KPIs every Thursday; staff accountability is tied to the dashboard.
* **Contingency / Fallback**:
  - Provide Mohamed with a dedicated tablet/phone shortcut directly to `/reports` so he does not need to sit at a desktop computer.

#### Risk R-06: Spam & Obscene / Troll Reports
* **Description**: Kids or trolls submit repeated nonsensical reports or offensive images.
* **Probability**: Medium | **Impact**: Low
* **Preventive Measure**:
  - Redis rate limiting: max 3 new drafts per 15 minutes per phone hash.
  - Citizen description validation enforces minimum 5 characters and rejects repeated single-character spam.
* **Contingency / Fallback**:
  - Staff can click `[حظر المتصل]` in the report drawer. This writes `Contact.optedOutAt = NOW()`, causing the bot to silently ignore future messages from that contact hash.

---

### 3. Legal & Regulatory Risks

#### Risk R-07: Egyptian PDPL (Law 151/2020) Inquiry
* **Description**: A citizen or authority questions the storage of phone numbers and location data.
* **Probability**: Low | **Impact**: Critical
* **Preventive Measure**:
  - All phone numbers stored encrypted with AES-256-GCM.
  - No cleartext phone numbers exposed in the database or logs.
  - Complete legal right-to-erasure runbook implemented and verifiable in `docs/07-security-privacy-compliance.md`.
* **Contingency / Fallback**:
  - Trigger `/api/v1/contacts/:id/erase` immediately upon any formal privacy complaint; produce the cryptographic AuditEvent receipt as legal evidence of compliance.

#### Risk R-08: Solo Developer Incapacitation / Time Slippage (Part-Time Reality)
* **Description**: Developer works 15–20 hours/week, but scope expansion causes delivery timeline to slip beyond initial targets.
* **Probability**: High | **Impact**: High
* **Preventive Measure**:
  - Re-calibrated 8-week delivery plan at 16–18 hours/week (total ~135h realistic MVP budget).
  - Scope discipline: Voice notes deferred to v2, public web tracking endpoint cut from v1, client-side CSV deferred.
  - Modular monolith architecture ensures single-repo, zero-context-switching delivery.
* **Contingency / Fallback**:
  - If behind schedule at end of Sprint 2, immediately cut the internal settings UI from v1; seed tenant configuration directly via database scripts.

---

## 12.3 Catastrophic & "Black Swan" Scenarios (Extreme Readiness Protocols)

Beyond standard bugs and operational friction, Wassel is hardened against 10 catastrophic operational, legal, geopolitical, and infrastructure crises:

### 1. Legal & Sovereign Security Crises

#### CS-01: Sovereign & Sensitive Terms of Service Enforcement
* **Trigger:** A citizen submits non-civic political slogans or sovereign complaints outside municipal competence.
* **Blast Radius:** Staff confusion or public misunderstanding of municipal mandate.
* **Operational Defense (Terms of Service Clear Boundary):**
  - Bot terms of service state upfront that Wassel is dedicated strictly to municipal maintenance and clinic operations.
  - Standard neutral out-of-scope template informs the citizen: *"شكراً لتواصلك. هذه المنصة مخصصة لمتابعة الخدمات البلدية والصيانة والمرافق فقط."*
  - No automated regex censoring that could falsely suppress legitimate public safety reports.

#### CS-02: Law Enforcement Search Warrant / Subpoena (طلب ضبط قضائي)
* **Trigger:** Public Prosecution (النيابة العامة) or Telecom Police formally issues an official warrant requesting citizen identity and activity logs for a criminal investigation.
* **Blast Radius:** Database encrypts phone numbers with AES-256-GCM and uses salted HMAC blind indexes; revealing master keys would breach all citizen privacy under PDPL Law 151/2020.
* **Automated Defense (Legal Compliance Dossier Export):**
  - Dedicated endpoint `POST /api/v1/compliance/subpoena-export` accessible only with dual master admin credentials and formal warrant reference number.
  - Decrypts and exports a single, tamper-evident cryptographic PDF dossier for *only* the specific ticket/contact, including raw phone number, IP address footprint, and append-only `AuditEvent` hashes, leaving the rest of the database entirely encrypted and protected.

---

### 2. Life-Safety & Public Panic Emergencies

#### CS-03: Life-Safety Emergency Cry (Structural Collapse / Fire / Fatality)
* **Trigger:** A citizen messages the bot in panic: *"الحقونا البيت بيقع علينا"* or *"فيه حريق هائل في المستودع"*, mistaking Wassel for emergency dispatch (123/180).
* **Blast Radius:** Waiting in a standard triage queue or bot multi-step funnel could result in loss of life and severe liability.
* **Automated Defense (Emergency Keyword Fast-Override):**
  - High-priority regex interceptor runs on every inbound message: `(حريقة|حريق|انهيار|بيموت|غرق|انفجار|نزيف|حادثة|طوارئ|كارثة)`.
  - Bypasses active bot state immediately and dispatches an instant emergency response within $< 1000\text{ms}$:
    ```
    🚨 تنبيه طوارئ عاجل!
    منظومة واصل مخصصة للبلاغات الخدمية فقط وليست بديلاً عن خطوط الطوارئ السريعة!
    
    برجاء الاتصال فوراً بالجهات المختصة:
    🚒 المطافئ: 180 (tel:180)
    🚑 الإسعاف: 123 (tel:123)
    🚓 شرطة النجدة: 122 (tel:122)
    ```

#### CS-04: Mass Contamination Outbreak (Water Poisoning / Epidemic in Sunbullawein)
* **Trigger:** An industrial leak or water pipe contamination triggers $> 100$ reports in 30 minutes from adjacent streets.
* **Blast Radius:** Treating reports individually delays municipal recognition of an acute public health catastrophe.
* **Automated Defense (Spatial-Temporal Anomaly Spike Detector):**
  - Background worker computes rolling report density per category per geographic cluster.
  - If velocity exceeds $> 15$ reports in 30 minutes in a single cluster, triggers **Mass Incident Alert** banner on all staff dashboards with audible alarm.
  - Provides a 1-click `[Merge into Master Disaster Ticket]` action and auto-dispatches an official safety guidance WhatsApp broadcast to all impacted citizens.

---

### 3. Egyptian Infrastructure & Telecom Realities

#### CS-05: Thundering Herd after Rolling Blackout (تخفيف الأحمال)
* **Trigger:** Central power and cellular towers in Sunbullawein go down for 2 hours. Upon grid restoration, cellular towers dump thousands of queued WhatsApp messages simultaneously onto Wassel webhooks.
* **Blast Radius:** Webhook saturation causes Node.js memory spike, Redis buffer exhaustion, and server crashes.
* **Automated Defense (Adaptive Ingestion Backpressure & LIFO Prioritization):**
  - If BullMQ incoming queue exceeds 500 jobs, webhook controller enables degraded ingestion: writes raw messages to disk/DB and throttles worker consumption to a steady 30 jobs/sec.
  - Workers prioritize recent messages using LIFO ordering so actively waiting citizens get instant replies rather than receiving stale bot prompts hours later.

#### CS-06: Local Telecom ISP Deep Packet Inspection / Port Throttling
* **Trigger:** Egyptian ISPs (e.g., WE) throttle non-standard ports or disrupt long-lived WebSocket connections.
* **Blast Radius:** Dashboard real-time counters freeze; staff misses urgent incoming reports.
* **Automated Defense (Hybrid Resilient Transport):**
  - Dashboard routes all traffic exclusively through standard HTTPS port 443 via Caddy TLS proxy.
  - Client implements an automated watchdog: if WebSocket heartbeat fails for 5 seconds, client falls back transparently to HTTP polling every 15 seconds without interrupting staff workflows.

---

### 4. WhatsApp Cloud API & Financial Traps

#### CS-07: Egyptian Foreign Exchange (FX) Credit Card Payment Failure
* **Trigger:** Central Bank of Egypt credit card monthly limits cause Meta WhatsApp Cloud API billing invoice to be declined.
* **Blast Radius:** Meta suspends the WhatsApp Business account immediately, shutting down citizen communications.
* **Automated Defense & Contingency:**
  - Usage burn-rate monitor alerts the admin when monthly template spend reaches 70% of credit card limits.
  - **Emergency Public Web Fallback**: When WhatsApp is disconnected, citizens can track and submit reports via a lightweight, zero-cost public web portal (`https://wassel.city/track/:code`).

#### CS-08: WhatsApp Number Banned due to Coordinated Spam Reports
* **Trigger:** Hostile actors or disgruntled citizens flag the WhatsApp bot as "Spam", causing Meta's automated safety rating to drop to "Red" and temporarily restricting the phone number.
* **Blast Radius:** Citizen channel completely severed.
* **Automated Defense (Hot-Standby Inbox Failover):**
  - A pre-registered secondary WhatsApp number is provisioned in Chatwoot as a hot standby.
  - Admin executes a 1-click failover script updating the webhook routing secret in Caddy/API, restoring service within $< 10\text{ minutes}$ with zero database changes.

---

### 5. Adversarial Sabotage & Smear Attacks

#### CS-09: Coordinated Smear Campaign against a Specific Doctor/Clinic
* **Trigger:** An adversarial actor uses 30 disposable SIM cards to flood the system with 100 fake reports targeting a specific physician to distort performance metrics.
* **Blast Radius:** Clinic reputation ruined; reception staff overwhelmed with fraudulent triage.
* **Automated Defense (Cluster Correlation & Anomaly Tagging):**
  - Heuristic engine detects rapid submission bursts targeting identical entities with $> 80\%$ semantic text similarity.
  - Automatically flags reports with `⚠️ شبهة بلاغ كيدي منسق`, isolates them from public KPI calculations, and groups them for senior management sign-off.

#### CS-10: Hostile Media Injection (Illegal / Explicit Media Upload)
* **Trigger:** Malicious user uploads illicit, pornographic, or illegal imagery to compromise the server legally.
* **Blast Radius:** Possession of illegal content on local Egyptian VPS could trigger immediate criminal liability.
* **Automated Defense (Zero-Exif Transcoding & Isolated Vault):**
  - Image pipeline processes uploads in-memory using `sharp`: strips all camera EXIF metadata and re-encodes to sterile WebP.
  - Preserved in private, non-public MinIO bucket.
  - 1-click `[🗑️ Purge Hostile Media]` removes binary object permanently while logging cryptographic SHA-256 hash in audit log as evidence for legal defense.

---

### 6. Catastrophic Infrastructure Loss

#### CS-11: Total Host Server Incineration / Hardware Destruction
* **Trigger:** Physical datacenter fire or catastrophic SSD controller death destroying the primary VPS.
* **Blast Radius:** Complete loss of live containers, databases, and uploaded photos.
* **Automated Defense (30-Minute Bare-Metal Resurrection Runbook):**
  - Nightly encrypted backups (PostgreSQL dump + MinIO objects) are automatically synced off-site to independent S3-compatible cloud storage.
  - Automated 1-line bare-metal resurrection command:
    ```bash
    curl -sS https://raw.githubusercontent.com/wassel/ops/main/restore.sh | bash -s -- --backup=latest
    ```
    Provisions Docker, restores schemas, unpacks object storage, configures SSL certificates, and resumes operations in under 30 minutes.

---

## 12.4 Final Review & Transition to Code Execution

With the completion of **Sections 1 through 12 and the Extreme Catastrophic Protocols**, the entire blueprint for Wassel (واصل) is fully specified and stored under `/docs`.

### Blueprint Inventory Summary

| Document | Section | Content Summary |
|---|:---:|---|
| [01-product-definition.md](file:///d:/Cineplawin-Connect/docs/01-product-definition.md) | 1 | Vision, Personas (Umm Ahmed, Mohamed, Dr. Hassan), Value Props, MVP Scope. |
| [02-conversation-ux-design.md](file:///d:/Cineplawin-Connect/docs/02-conversation-ux-design.md) | 2 | Egyptian Arabic bot scripts (Flows 1–9), State Machine transitions, Error handling. |
| [03-technical-architecture.md](file:///d:/Cineplawin-Connect/docs/03-technical-architecture.md) | 3 | Modular monolith, NestJS, Next.js, Chatwoot integration, RLS Option A. |
| [04-database-design.md](file:///d:/Cineplawin-Connect/docs/04-database-design.md) | 4 | ERD, 30+ Indexes, Tracking code generator, PostGIS migration path. |
| [05-api-design.md](file:///d:/Cineplawin-Connect/docs/05-api-design.md) | 5 | REST endpoints, Zod schemas, Webhook pipeline, Error codes, Rate limits. |
| [06-dashboard-design.md](file:///d:/Cineplawin-Connect/docs/06-dashboard-design.md) | 6 | Next.js App Router, Tailwind, 3 KPIs, Drawer, shadcn components, RTL layout. |
| [07-security-privacy-compliance.md](file:///d:/Cineplawin-Connect/docs/07-security-privacy-compliance.md) | 7 | Egypt PDPL Law 151/2020, Erasure runbook, Threat models, AES/HMAC keys. |
| [08-operations-deployment.md](file:///d:/Cineplawin-Connect/docs/08-operations-deployment.md) | 8 | Docker Compose prod, 8 GB VPS sizing, Caddyfile, Backup script, Lean logs. |
| [09-testing-qa-strategy.md](file:///d:/Cineplawin-Connect/docs/09-testing-qa-strategy.md) | 9 | Lean test philosophy, Cross-Tenant CI Gate, State machine tests, Smoke runbook. |
| [10-project-delivery-plan.md](file:///d:/Cineplawin-Connect/docs/10-project-delivery-plan.md) | 10 | 4 sprints, 124 total hours, solo developer discipline rules. |
| [11-pilot-rollout-sunbullawein.md](file:///d:/Cineplawin-Connect/docs/11-pilot-rollout-sunbullawein.md) | 11 | Sunbullawein clinic pilot, 4-week timeline, Receptionist cheat sheet. |
| [12-risk-register-contingencies.md](file:///d:/Cineplawin-Connect/docs/12-risk-register-contingencies.md) | 12 | Risk matrix, Meta 24h window fallback, OOM mitigations, Black Swan protocols. |
| [schema.prisma](file:///d:/Cineplawin-Connect/schema.prisma) | Schema | Complete data model with shadow DB, PDPL fields, and blind indexes. |
| [constraints-and-roles.sql](file:///d:/Cineplawin-Connect/constraints-and-roles.sql) | SQL | Postgres roles (`cc_owner`, `cc_app`), append-only triggers, RLS gate. |

**The planning and catastrophic threat modeling phase is 100% complete. The project is ready for code execution starting with Sprint 1.**
