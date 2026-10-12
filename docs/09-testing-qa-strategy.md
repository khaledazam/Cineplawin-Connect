# 9. Testing & Quality Assurance Strategy: واصل (Wassel)

## 9.1 Lean Testing Philosophy for a Solo Developer

In a tight 120–160 hour delivery window, a solo developer cannot afford 100% code coverage. Testing boilerplate or trivial CRUD mapping burns precious hours without reducing critical risk.

**The Wassel testing strategy focuses aggressively on high-consequence failure zones:**
1. **Multi-Tenant Isolation**: Ensuring Tenant A can never read or mutate Tenant B's data under any condition.
2. **Conversational State Machine**: Ensuring the WhatsApp bot never gets stuck, leaks another citizen's report, or misroutes inputs.
3. **Webhook & Outbox Durability**: Ensuring incoming messages are never lost or double-processed, and outbound notifications survive worker crashes.
4. **Data Integrity & Immutability**: Ensuring audit trails and legal constraints cannot be violated.

```
       / \
      / E2E \         Cross-Tenant Isolation Suite (Mandatory CI Gate)
     /-------\        Full WhatsApp Ingestion -> DB -> Outbox Smoke Flow
    /  Integ. \       Repository Layer + PostgreSQL Triggers + Outbox Worker
   /-----------\
  /    Unit     \     Pure Bot State Machine Transitions + Crypto + Code Generators
 /---------------\
```

---

## 9.2 The Cross-Tenant Isolation CI Gate (Non-Negotiable)

This automated test suite runs as a **blocking gate in GitHub Actions CI**. If a single assertion fails, deployments are halted. It executes using the non-owner runtime database role (`cc_app`).

### Test Suite Implementation (`test/e2e/cross-tenant-isolation.spec.ts`)

```typescript
import { Test } from '@nestjs/testing';
import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { AppModule } from '../../src/app.module';
import { PrismaService } from '../../src/prisma/prisma.service';

describe('Cross-Tenant Isolation CI Gate', () => {
  let app: INestApplication;
  let prisma: PrismaService;

  let tenantA: { id: string; token: string; reportId: string };
  let tenantB: { id: string; token: string; reportId: string };

  beforeAll(async () => {
    const moduleRef = await Test.createTestingModule({ imports: [AppModule] }).compile();
    app = moduleRef.createNestApplication();
    await app.init();
    prisma = app.get(PrismaService);

    // Seed two isolated tenants with staff users and sample reports
    tenantA = await seedTenantWithReport(prisma, 'tenant-a-sunbullawein');
    tenantB = await seedTenantWithReport(prisma, 'tenant-b-mansoura');
  });

  afterAll(async () => {
    await app.close();
  });

  it('GATE-01: Agent A cannot read Report B by ID', async () => {
    const res = await request(app.getHttpServer())
      .get(`/api/v1/reports/${tenantB.reportId}`)
      .set('Authorization', `Bearer ${tenantA.token}`);

    // Must return 404 (not 403, to prevent ID enumeration)
    expect(res.status).toBe(404);
  });

  it('GATE-02: Agent A cannot update status or assign Report B', async () => {
    const res = await request(app.getHttpServer())
      .patch(`/api/v1/reports/${tenantB.reportId}`)
      .set('Authorization', `Bearer ${tenantA.token}`)
      .send({ status: 'RESOLVED', version: 1 });

    expect(res.status).toBe(404);

    // Verify in database that Report B was not mutated
    const reportB = await prisma.report.findUnique({ where: { id: tenantB.reportId } });
    expect(reportB?.status).not.toBe('RESOLVED');
  });

  it('GATE-03: Tenant A report list query never leaks Tenant B reports', async () => {
    const res = await request(app.getHttpServer())
      .get('/api/v1/reports')
      .set('Authorization', `Bearer ${tenantA.token}`);

    expect(res.status).toBe(200);
    const reportIds: string[] = res.body.data.map((r: any) => r.id);
    expect(reportIds).toContain(tenantA.reportId);
    expect(reportIds).not.toContain(tenantB.reportId);
  });

  it('GATE-04: Citizen from Tenant A cannot look up Report B tracking code', async () => {
    const trackingCodeB = (await prisma.report.findUnique({ where: { id: tenantB.reportId } }))!.trackingCode;

    // Simulate WhatsApp tracking lookup via bot engine with Tenant A channel
    const res = await simulateInboundWhatsAppMessage(app, tenantA.id, trackingCodeB);
    expect(res.botReplyText).toContain('مش لاقيين بلاغ بالرقم ده');
  });
});
```

---

## 9.3 State Machine Unit Test Suite

The bot transition engine is structured as a **pure state transition function**:
$$\text{nextState} = f(\text{currentState}, \text{inboundMessage}, \text{draftContext})$$

This allows testing every permutation in milliseconds without touching database or network sockets:

```typescript
describe('Bot State Machine (Pure Transition Function)', () => {
  const baseDraft = { id: 'd-1', categoryId: null, description: null, photoSkipped: false, locationSkipped: false };

  it('SM-01: IDLE with "1" transitions to AWAITING_CATEGORY', () => {
    const next = transition('IDLE', { text: '1' }, baseDraft);
    expect(next.state).toBe('AWAITING_CATEGORY');
    expect(next.replyTemplate).toBe('MENU_CATEGORIES');
  });

  it('SM-02: AWAITING_CATEGORY accepts valid numeric choice and stores snapshot', () => {
    const next = transition('AWAITING_CATEGORY', { text: '2' }, baseDraft, { categories: ['إنارة', 'مياه'] });
    expect(next.state).toBe('AWAITING_DESCRIPTION');
    expect(next.updatedDraft.categoryId).toBeDefined();
  });

  it('SM-03: Description min-length validation rejects strings < 5 chars', () => {
    const next = transition('AWAITING_DESCRIPTION', { text: 'نور' }, baseDraft);
    expect(next.state).toBe('AWAITING_DESCRIPTION'); // Stays in state
    expect(next.replyText).toContain('الوصف قصير أوي');
  });

  it('SM-04: Photo step accepts "تخطي" and marks photoSkipped = true', () => {
    const next = transition('AWAITING_PHOTO', { text: 'تخطي' }, baseDraft);
    expect(next.state).toBe('AWAITING_LOCATION');
    expect(next.updatedDraft.photoSkipped).toBe(true);
  });

  it('SM-05: Global "إلغاء" in any draft state returns to IDLE and cancels draft', () => {
    const next = transition('AWAITING_LOCATION', { text: 'إلغاء' }, baseDraft);
    expect(next.state).toBe('IDLE');
    expect(next.draftStatus).toBe('CANCELLED');
    expect(next.replyText).toContain('تم إلغاء البلاغ');
  });
});
```

---

## 9.4 Integration & Database Constraint Tests

These tests verify database triggers and worker reliability using a localized PostgreSQL test container:

| Test ID | Target Component | Scenario | Expected Outcome |
|---|---|---|---|
| **INT-01** | `constraints-and-roles.sql` | Attempt direct SQL `UPDATE "ReportEvent" SET note = 'hack'` | PostgreSQL raises error: `ReportEvent is append-only` (57P01). |
| **INT-02** | `constraints-and-roles.sql` | Insert `Report` with `status = 'RESOLVED'` and `resolvedAt = NULL` | Check constraint `report_resolved_at_matches_status` fails. |
| **INT-03** | `InboxMessage` | Send identical `(tenantId, provider, providerMessageId)` twice | Second insert fails unique constraint; API returns `200` without enqueuing duplicate job. |
| **INT-04** | Outbox Worker | Simulates Chatwoot API network timeout (HTTP 504) | Notification row increments `attempts`, sets exponential backoff on `nextAttemptAt`, stays in `PENDING`. |
| **INT-05** | Tracking Generator | Generate 100,000 tracking codes concurrently | 0 collisions detected, all match regex `^[A-Z]{2,4}-[2-9A-HJKMNP-Z]{6}$`. |

---

## 9.5 End-to-End Field Smoke Test Runbook (10 Minutes)

Before declaring any deployment ready for Sunbullawein pilot users, the developer executes this manual WhatsApp smoke test:

1. **Submit Flow**:
   - Send `"مرحبا"` from personal WhatsApp $\rightarrow$ Verify greeting and menu appear within 3 seconds.
   - Send `"1"` $\rightarrow$ Select category `"1"` $\rightarrow$ Send description `"عمود نور مطفي أمام المستشفى"`.
   - Send test camera photo $\rightarrow$ Send location pin $\rightarrow$ Send `"نعم"` to confirm.
   - **Verification**: Verify receipt of confirmation message containing tracking code `SBL-XXXXXX`.
2. **Dashboard Verification**:
   - Open `/reports` in browser.
   - Verify report appears immediately at top of list with badge `🔴 جديد`.
   - Verify photo thumbnail renders and Google Maps link points to submitted coordinates.
3. **Triage & Status Change**:
   - Open drawer $\rightarrow$ Assign to staff member $\rightarrow$ Change status to `🔵 جاري العمل` $\rightarrow$ Click Save.
   - **Verification**: Verify WhatsApp receives status update message within 5 seconds.
4. **Tracking Flow**:
   - In WhatsApp, send `"2"` (Track Report) $\rightarrow$ Send `SBL-XXXXXX`.
   - **Verification**: Bot returns formatted report summary showing status `جاري العمل`.
5. **Resolution**:
   - In dashboard, change status to `🟢 تم الحل` $\rightarrow$ Enter closing message $\rightarrow$ Save.
   - **Verification**: WhatsApp receives final resolution update with closing message.
