-- schema + fake seed data. only runs when the volume is empty

CREATE TABLE tenants (
    id   TEXT PRIMARY KEY,
    name TEXT NOT NULL
);

-- only the sha256 of the token is stored, not the token.
-- so a backup file doesn't contain working tokens
CREATE TABLE users (
    id               SERIAL PRIMARY KEY,
    tenant_id        TEXT NOT NULL REFERENCES tenants(id),
    role             TEXT NOT NULL CHECK (role IN ('admin', 'agent')),
    api_token_sha256 TEXT NOT NULL UNIQUE
);

-- dedup: one lead per (tenant, phone) and one per (tenant, email).
-- unique allows multiple NULLs so missing phone/email is ok.
-- per tenant, so the same person can be a lead in both tenants
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

-- each event_id is processed once per tenant.
-- PK includes tenant_id, otherwise tenant B sending the same event_id
-- would get tenant A's lead back
CREATE TABLE processed_events (
    tenant_id   TEXT NOT NULL REFERENCES tenants(id),
    event_id    TEXT NOT NULL,
    lead_id     INT REFERENCES leads(id),
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, event_id)
);

-- facts we can quote in answers. value NULL = unknown
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

-- ---- seed data (fake) ----
INSERT INTO tenants (id, name) VALUES
    ('tenant_a', 'Tenant A Realty (test)'),
    ('tenant_b', 'Tenant B Homes (test)');

-- test tokens are listed in the README, only hashes go in the table
-- (sha256() is built in since pg 11)
INSERT INTO users (tenant_id, role, api_token_sha256) VALUES
    ('tenant_a', 'admin', encode(sha256('test-token-a-admin'::bytea), 'hex')),
    ('tenant_a', 'agent', encode(sha256('test-token-a-agent'::bytea), 'hex')),
    ('tenant_b', 'admin', encode(sha256('test-token-b-admin'::bytea), 'hex')),
    ('tenant_b', 'agent', encode(sha256('test-token-b-agent'::bytea), 'hex'));

-- P1: price known, availability unknown -> should hand off
INSERT INTO property_facts (tenant_id, property_code, field, value, source) VALUES
    ('tenant_a', 'P1', 'price',        'AED 1,000,000', 'brief:P1-listing-sheet'),
    ('tenant_a', 'P1', 'availability', NULL,            'brief:P1-listing-sheet'),
    ('tenant_b', 'P1', 'price',        'AED 1,000,000', 'brief:P1-listing-sheet'),
    ('tenant_b', 'P1', 'availability', NULL,            'brief:P1-listing-sheet');

-- a tenant_b lead for the cross-tenant test
INSERT INTO leads (tenant_id, name, phone_norm, email_norm, last_message) VALUES
    ('tenant_b', 'Tenant B Seed Customer', '971559999999', 'seed.b@example.test', 'seed');
