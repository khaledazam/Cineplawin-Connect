#!/usr/bin/env bash
set -e

# =============================================================================
# Wassel (واصل): PostgreSQL Multi-Database & Role Provisioning
# Executed automatically by official postgres container on first startup
# (/docker-entrypoint-initdb.d/00-init-dbs.sh)
# =============================================================================

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    -- 1. Create app owner and runtime roles
    CREATE ROLE cc_owner LOGIN PASSWORD '${CC_OWNER_PASSWORD:-cc_owner_default_pw}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;
    CREATE ROLE cc_app LOGIN PASSWORD '${CC_APP_PASSWORD:-cc_app_default_pw}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS;

    -- 2. Create shadow database for Prisma dev migrations
    CREATE DATABASE cc_shadow OWNER cc_owner;

    -- 3. Create Chatwoot production database
    CREATE DATABASE chatwoot_production OWNER postgres;

    -- 4. Transfer ownership of main app DB
    ALTER DATABASE cc OWNER TO cc_owner;
EOSQL

echo "[$(date)] Successfully provisioned cc, cc_shadow, chatwoot_production and application roles."
