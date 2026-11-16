-- Mock CRM schema + synthetic seed data. Runs once on an empty volume.

CREATE TABLE tenants (
    id   TEXT PRIMARY KEY,
    name TEXT NOT NULL
);

-- SECURITY: we store only the SHA-256 of each API token, never the token itself.
-- A DB dump/backup therefore does not leak usable tokens.
CREATE TABLE users (
    id               SERIAL PRIMARY KEY,
    tenant_id        TEXT NOT NULL REFERENCES tenants(id),
    role             TEXT NOT NULL CHECK (role IN ('admin', 'agent')),
    api_token_sha256 TEXT NOT NULL UNIQUE
);

-- DEDUP: one lead per (tenant, phone) and per (tenant, email).
-- Postgres UNIQUE allows many NULLs, so leads with no phone or no email are fine.
-- Uniqueness is per tenant: the same customer may legitimately exist in both tenants.
CREATE TABLE leads (
    id           SERIAL PRIMARY KEY,
    tenant_id    TEXT NOT NULL REFERENCES tenants(id),
    name         TEXT,
    phone_norm   TEXT,
    email_norm   TEXT,
    last_message TEXT,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT leads_tenant_phone_uniq UNIQUE (tenant_id, phone_norm),
    CONSTRAINT leads_tenant_email_uniq UNIQUE (tenant_id, email_norm)
);

-- IDEMPOTENCY: an event_id is processed at most once per tenant.
-- PK is (tenant_id, event_id) rather than event_id alone so tenant B re-using an
-- event_id can never be answered with tenant A's lead.
CREATE TABLE processed_events (
    tenant_id   TEXT NOT NULL REFERENCES tenants(id),
    event_id    TEXT NOT NULL,
    lead_id     INT REFERENCES leads(id),
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, event_id)
);

-- Facts the answer engine may cite. value NULL = unknown (never guessed).
CREATE TABLE property_facts (
    id            SERIAL PRIMARY KEY,
    tenant_id     TEXT NOT NULL REFERENCES tenants(id),
    property_code TEXT NOT NULL,
    field         TEXT NOT NULL,
    value         TEXT,
    source        TEXT NOT NULL
);

CREATE TABLE handoffs (
    id         SERIAL PRIMARY KEY,
    tenant_id  TEXT NOT NULL REFERENCES tenants(id),
    lead_id    INT REFERENCES leads(id),
    reason     TEXT NOT NULL,
    summary    TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE alerts (
    id         SERIAL PRIMARY KEY,
    source     TEXT NOT NULL,
    message    TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------- Seed (synthetic only) ----------
INSERT INTO tenants (id, name) VALUES
    ('tenant_a', 'Tenant A Realty (test)'),
    ('tenant_b', 'Tenant B Homes (test)');

-- Plain-text test tokens are documented in README / scripts; only hashes stored here.
-- sha256() is built into Postgres 11+.
INSERT INTO users (tenant_id, role, api_token_sha256) VALUES
    ('tenant_a', 'admin', encode(sha256('test-token-a-admin'::bytea), 'hex')),
    ('tenant_a', 'agent', encode(sha256('test-token-a-agent'::bytea), 'hex')),
    ('tenant_b', 'admin', encode(sha256('test-token-b-admin'::bytea), 'hex')),
    ('tenant_b', 'agent', encode(sha256('test-token-b-agent'::bytea), 'hex'));

-- P1: price known, availability unknown (NULL) -> must hand off, never guess.
INSERT INTO property_facts (tenant_id, property_code, field, value, source) VALUES
    ('tenant_a', 'P1', 'price',        'AED 1,000,000', 'brief:P1-listing-sheet'),
    ('tenant_a', 'P1', 'availability', NULL,            'brief:P1-listing-sheet'),
    ('tenant_b', 'P1', 'price',        'AED 1,000,000', 'brief:P1-listing-sheet'),
    ('tenant_b', 'P1', 'availability', NULL,            'brief:P1-listing-sheet');

-- One tenant_b lead so the cross-tenant read test has a real target.
INSERT INTO leads (tenant_id, name, phone_norm, email_norm, last_message) VALUES
    ('tenant_b', 'Tenant B Seed Customer', '971559999999', 'seed.b@example.test', 'seed');
