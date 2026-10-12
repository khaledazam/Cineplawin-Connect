# 8. Operations & Deployment: واصل (Wassel)

## 8.1 Infrastructure Overview & Hosting Topology

Wassel (منصة واصل) v1 runs entirely on a **single Virtual Private Server (VPS)** to keep operational complexity, cloud bills, and maintenance overhead manageable for a solo developer. 

### Sizing Specification
- **Compute & RAM**: 4 vCPU, 8 GB RAM (Locked decision: replaced the 4 GB assumption).
- **Disk**: 80 GB NVMe SSD (minimum).
- **Swap**: 4 GB swapfile configured at the OS level as an emergency buffer for memory spikes.
- **Operating System**: Ubuntu 24.04 LTS (x86_64).
- **Network**: Static public IPv4, ports 80 and 443 open; SSH (port 22) restricted to key-only authentication.

```mermaid
graph TD
    Internet((Internet: WhatsApp & Web)) -->|Ports 80, 443| Caddy[Caddy Reverse Proxy & TLS]
    
    subgraph "Docker Compose Internal Network"
        Caddy -->|api.wassel.city /api/*| API[NestJS API Service :3000]
        Caddy -->|dashboard.wassel.city /*| Web[Next.js Staff Dashboard :3001]
        Caddy -->|chatwoot.wassel.city| CW[Chatwoot Web :3000]
        
        API --> PG[(PostgreSQL 16 :5432)]
        API --> Redis[(Redis 7 :6379)]
        API --> S3[(MinIO Object Storage :9000)]
        
        Worker[Background Worker Process] --> PG
        Worker --> Redis
        Worker --> S3
        Worker -->|WhatsApp API| Meta[Meta Cloud API]
        Worker -->|Agent Bot API| CW
        
        CW --> PG
        CW --> Redis
        Sidekiq[Chatwoot Sidekiq] --> CW
    end
```

---

## 8.2 Docker Compose Production Specification

All platform components are declared in a single, version-controlled `docker-compose.prod.yml` file:

```yaml
version: '3.8'

networks:
  cityconnect-net:
    driver: bridge

volumes:
  pg_data:
  redis_data:
  minio_data:
  caddy_data:
  caddy_config:

services:
  # ---------------------------------------------------------------------------
  # Edge Reverse Proxy
  # ---------------------------------------------------------------------------
  caddy:
    image: caddy:2.8-alpine
    restart: always
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - cityconnect-net
    depends_on:
      - api
      - dashboard

  # ---------------------------------------------------------------------------
  # Storage & State
  # ---------------------------------------------------------------------------
  postgres:
    image: postgres:16-alpine
    restart: always
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${SUPERUSER_DB_PASSWORD}
      POSTGRES_DB: cc
    volumes:
      - pg_data:/var/lib/postgresql/data
      - ./init-dbs.sh:/docker-entrypoint-initdb.d/00-init-dbs.sh:ro
    networks:
      - cityconnect-net
    deploy:
      resources:
        limits:
          memory: 2048M

  redis:
    image: redis:7-alpine
    restart: always
    command: redis-server --appendonly yes --requirepass ${REDIS_PASSWORD}
    volumes:
      - redis_data:/data
    networks:
      - cityconnect-net
    deploy:
      resources:
        limits:
          memory: 512M

  minio:
    image: minio/minio:RELEASE.2024-05-10T01-41-38Z
    restart: always
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    volumes:
      - minio_data:/data
    networks:
      - cityconnect-net
    deploy:
      resources:
        limits:
          memory: 512M

  # ---------------------------------------------------------------------------
  # Application Services (Wassel)
  # ---------------------------------------------------------------------------
  api:
    image: cityconnect-api:latest
    build:
      context: .
      dockerfile: Dockerfile.api
    restart: always
    environment:
      NODE_ENV: production
      DATABASE_URL: postgresql://cc_app:${CC_APP_PASSWORD}@postgres:5432/cc?schema=public
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      APP_ENCRYPTION_KEY: ${APP_ENCRYPTION_KEY}
      APP_HMAC_KEY: ${APP_HMAC_KEY}
      JWT_SECRET: ${JWT_SECRET}
      S3_ENDPOINT: http://minio:9000
      S3_BUCKET: cityconnect-attachments
      S3_ACCESS_KEY: ${MINIO_ROOT_USER}
      S3_SECRET_KEY: ${MINIO_ROOT_PASSWORD}
    networks:
      - cityconnect-net
    depends_on:
      - postgres
      - redis
    deploy:
      resources:
        limits:
          memory: 768M

  worker:
    image: cityconnect-api:latest
    command: ["node", "dist/worker.main.js"]
    restart: always
    environment:
      NODE_ENV: production
      DATABASE_URL: postgresql://cc_app:${CC_APP_PASSWORD}@postgres:5432/cc?schema=public
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      APP_ENCRYPTION_KEY: ${APP_ENCRYPTION_KEY}
      APP_HMAC_KEY: ${APP_HMAC_KEY}
      S3_ENDPOINT: http://minio:9000
      S3_BUCKET: cityconnect-attachments
      S3_ACCESS_KEY: ${MINIO_ROOT_USER}
      S3_SECRET_KEY: ${MINIO_ROOT_PASSWORD}
    networks:
      - cityconnect-net
    depends_on:
      - postgres
      - redis
    deploy:
      resources:
        limits:
          memory: 768M

  dashboard:
    image: cityconnect-dashboard:latest
    build:
      context: .
      dockerfile: Dockerfile.dashboard
    restart: always
    environment:
      NODE_ENV: production
      NEXT_PUBLIC_API_URL: https://${APP_DOMAIN}/api/v1
    networks:
      - cityconnect-net
    deploy:
      resources:
        limits:
          memory: 512M

  # ---------------------------------------------------------------------------
  # Chatwoot Gateway (Preconfigured memory caps to fit within 8 GB VPS)
  # ---------------------------------------------------------------------------
  chatwoot_web:
    image: chatwoot/chatwoot:v3.8.0
    restart: always
    environment:
      NODE_ENV: production
      RAILS_ENV: production
      INSTALLATION_ENV: docker
      MALLOC_ARENA_MAX: "2"
      DATABASE_URL: postgresql://postgres:${SUPERUSER_DB_PASSWORD}@postgres:5432/chatwoot_production
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
      SECRET_KEY_BASE: ${CHATWOOT_SECRET_KEY_BASE}
      FRONTEND_URL: https://${APP_DOMAIN}/chatwoot
    networks:
      - cityconnect-net
    depends_on:
      - postgres
      - redis
    deploy:
      resources:
        limits:
          memory: 1536M

  chatwoot_worker:
    image: chatwoot/chatwoot:v3.8.0
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
    restart: always
    environment:
      NODE_ENV: production
      RAILS_ENV: production
      MALLOC_ARENA_MAX: "2"
      DATABASE_URL: postgresql://postgres:${SUPERUSER_DB_PASSWORD}@postgres:5432/chatwoot_production
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
      SECRET_KEY_BASE: ${CHATWOOT_SECRET_KEY_BASE}
    networks:
      - cityconnect-net
    depends_on:
      - postgres
      - redis
    deploy:
      resources:
        limits:
          memory: 1024M
```

### PostgreSQL Multiple Databases Bootstrap Script (`init-dbs.sh`)

PostgreSQL official images create only one database by default. This script is mounted to `/docker-entrypoint-initdb.d/00-init-dbs.sh` and executes once during the first container startup to provision all required databases and roles:

```bash
#!/usr/bin/env bash
set -e

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- 1. Create app owner and runtime roles
    CREATE ROLE cc_owner LOGIN PASSWORD '${CC_OWNER_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    CREATE ROLE cc_app LOGIN PASSWORD '${CC_APP_PASSWORD}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

    -- 2. Create shadow database for Prisma dev migrations
    CREATE DATABASE cc_shadow OWNER cc_owner;

    -- 3. Create Chatwoot production database
    CREATE DATABASE chatwoot_production OWNER postgres;

    -- 4. Transfer ownership of main app DB
    ALTER DATABASE cc OWNER TO cc_owner;
EOSQL
```

### One-Time Chatwoot Database Preparation

Before running the full stack for the first time, Chatwoot requires running Rails migrations and seed data:

```bash
# Execute once on initial VPS deployment:
docker compose -f docker-compose.prod.yml run --rm chatwoot_web bundle exec rails db:chatwoot_prepare
```

---

## 8.3 Caddy Reverse Proxy Configuration (`Caddyfile`)

Caddy automates HTTPS certificate provisioning via Let's Encrypt and enforces security headers:

```caddyfile
{$APP_DOMAIN} {
    encode gzip zstd

    # Security Headers
    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
        X-Content-Type-Options "nosniff"
        X-Frame-Options "DENY"
        Referrer-Policy "strict-origin-when-cross-origin"
        Permissions-Policy "camera=(), microphone=(), geolocation=()"
    }

    # API endpoints
    handle /api/* {
        reverse_proxy api:3000 {
            header_up X-Real-IP {remote_host}
            header_up X-Forwarded-For {remote_host}
        }
    }

    # Health checks (unauthenticated probe)
    handle /healthz {
        reverse_proxy api:3000
    }

    handle /readyz {
        reverse_proxy api:3000
    }

    # Chatwoot Webhook Ingestion Callback
    handle /api/v1/webhooks/chatwoot/* {
        reverse_proxy api:3000
    }

    # Next.js Dashboard Frontend
    handle /* {
        reverse_proxy dashboard:3001
    }
}

# Dedicated Chatwoot Gateway Domain (prevents ActionCable /packs asset clashes with Next.js)
{$CHATWOOT_DOMAIN:chatwoot.wassel.city} {
    encode gzip zstd
    reverse_proxy chatwoot_web:3000
}
```

---

## 8.4 Backup, Retention & Disaster Recovery Automation

### 1. Daily Automated Database Backup Script (`scripts/backup.sh`)
Runs nightly via root cron (`0 3 * * *`), performs an encrypted logical dump of PostgreSQL, and syncs to an offsite S3-compatible cold bucket:

```bash
#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="/var/backups/cityconnect"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/cc_db_${TIMESTAMP}.sql.gz.enc"
RETENTION_DAYS=30

mkdir -p "${BACKUP_DIR}"

# 1. Dump database as cc_owner and compress
docker compose -f /opt/cityconnect/docker-compose.prod.yml exec -T postgres \
  pg_dump -U cc_owner -d cc | gzip -9 | \
  openssl enc -aes-256-cbc -salt -pbkdf2 -pass env:BACKUP_ENCRYPTION_KEY -out "${BACKUP_FILE}"

# 2. Upload to cold storage bucket
aws s3 cp "${BACKUP_FILE}" "s3://${COLD_BACKUP_BUCKET}/db/${TIMESTAMP}.enc" --endpoint-url "${OFFSITE_S3_ENDPOINT}"

# 3. Clean up local backups older than 30 days (PDPL compliance limit)
find "${BACKUP_DIR}" -name "cc_db_*.sql.gz.enc" -type f -mtime +${RETENTION_DAYS} -delete

echo "[$(date)] Backup completed and encrypted successfully: ${BACKUP_FILE}"
```

### 2. The 30-Minute Bare-Metal Resurrection Runbook (Scenario 8: Datacenter Destruction)

If the production VPS hardware or SSD is catastrophically lost:

```mermaid
flowchart LR
    A[New Fresh 8 GB VPS] --> B[Clone Git Repo & Inject .env]
    B --> C[Pull Encrypted Backup from Cold S3]
    C --> D[Run init-dbs.sh & Stream Restore]
    D --> E[docker compose up -d & 10m Smoke Test]
```

**Step-by-step restoration commands:**
```bash
# 1. On fresh Ubuntu 24.04 VPS: Install Docker & Clone repo
git clone https://github.com/khaledazam/Cineplawin-Connect.git /opt/cityconnect
cd /opt/cityconnect

# 2. Inject master production.env (retrieved from secure Bitwarden vault)
chmod 600 .env.production

# 3. Pull latest encrypted cold backup from offsite S3
aws s3 cp s3://${COLD_BACKUP_BUCKET}/db/latest.enc /tmp/latest.enc --endpoint-url "${OFFSITE_S3_ENDPOINT}"

# 4. Decrypt logical dump stream directly into fresh container
docker compose -f docker-compose.prod.yml up -d postgres
sleep 5 # Wait for postgres socket

# Execute multi-db initialization
docker compose -f docker-compose.prod.yml exec -T postgres /docker-entrypoint-initdb.d/00-init-dbs.sh

# Decrypt and stream restore database
openssl enc -d -aes-256-cbc -pbkdf2 -in /tmp/latest.enc -pass env:BACKUP_ENCRYPTION_KEY | gunzip | \
  docker compose -f docker-compose.prod.yml exec -T postgres psql -U cc_owner -d cc

# 5. Bring up entire platform & Caddy reverse proxy
docker compose -f docker-compose.prod.yml up -d

# 6. Execute 10-minute smoke test runbook
npm run test:smoke
```
*Recovery Objective*: RTO (Recovery Time Objective) < 30 minutes; RPO (Recovery Point Objective) < 24 hours (nightly snapshot).

---

## 8.5 Observability Strategy (Lean v1 Scope)

In accordance with the locked v1 scope cuts:
- **No Heavy Stacks**: Prometheus, Grafana, OpenTelemetry, and Jaeger are excluded.
- **Structured JSON Logging**: Winston/Pino logger emitting standardized JSON on `stdout`:
  ```json
  {"level":"info","time":"2026-10-11T12:00:00.123Z","tenantId":"9b1deb4d-...","event":"report.created","reportId":"...","durationMs":42}
  ```
- **Probes**:
  - `/healthz`: Shallow liveness probe (returns `200 OK` if the Node event loop is responsive).
  - `/readyz`: Deep readiness probe (checks PostgreSQL `SELECT 1` and Redis `PING`; returns `503 Service Unavailable` if downstream is down).
- **Free External Uptime Monitor**: One free probe (e.g. Better Uptime or UptimeRobot) pinging `https://api.cityconnect.eg/healthz` every 60 seconds with instant Telegram/WhatsApp alerts to the developer.

---

## 8.6 Media Optimization & Disk Full Mitigation (Scenario 5.2)

To prevent media uploads from exhausting the 80 GB SSD over long-term operations:

### 1. In-Flight WebP Image Compression
When the background worker downloads an attachment from Chatwoot, it processes the image buffer through `sharp` before streaming to MinIO:
```typescript
import sharp from 'sharp';

export async function compressImage(rawBuffer: Buffer): Promise<Buffer> {
  return sharp(rawBuffer)
    .resize({ width: 1200, height: 1200, fit: 'inside', withoutEnlargement: true })
    .webp({ quality: 80, effort: 4 })
    .toBuffer();
}
```
*Result*: Typical photo size drops from 3.5 MB to ~220 KB (94% space reduction), while maintaining clear detail for municipal staff inspection.

### 2. Automated 180-Day Media Pruning Cron Job (`scripts/prune-media.sh`)
Runs weekly on Sundays (`0 4 * * 0`). Scans PostgreSQL for reports resolved > 180 days ago, purges their object keys from MinIO/S3, and marks `Attachment.status = 'PURGED'`:
```bash
#!/usr/bin/env bash
set -euo pipefail

# Execute media pruning via API internal CLI command
docker compose -f /opt/cityconnect/docker-compose.prod.yml exec -T api \
  node dist/cli.main.js storage:prune-resolved --older-than-days 180

echo "[$(date)] Media retention pruning completed."
```
