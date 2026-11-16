"""Mock CRM (stands in for Zoho Bigin). Local, synthetic data only."""
import hashlib
import logging
import os

import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException
from psycopg.rows import dict_row
from pydantic import BaseModel

from app.normalise import normalise_email, normalise_phone

DATABASE_URL = os.environ["DATABASE_URL"]

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mock-crm")

app = FastAPI(title="AiKit Mock CRM")


def db():
    """One short-lived connection per request (boring and safe for a demo)."""
    return psycopg.connect(DATABASE_URL, row_factory=dict_row)


# ---------------------------------------------------------------- auth / tenancy
def current_user(authorization: str | None = Header(default=None)) -> dict:
    """SECURITY: resolve 'Authorization: Bearer <token>' to a user row.

    Missing/malformed/unknown token -> 401. We compare SHA-256 hashes, so the DB
    never holds the plain token. The returned tenant_id is the ONLY source of
    tenant identity for the request; request bodies are never trusted for it.
    """
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=401, detail="missing bearer token")
    token_hash = hashlib.sha256(token.encode()).hexdigest()
    with db() as conn:
        user = conn.execute(
            "SELECT id, tenant_id, role FROM users WHERE api_token_sha256 = %s",
            (token_hash,),
        ).fetchone()
    if not user:
        raise HTTPException(status_code=401, detail="invalid token")
    return user


def require_role(*roles: str):
    """SECURITY: authenticated but wrong role -> 403."""
    def checker(user: dict = Depends(current_user)) -> dict:
        if user["role"] not in roles:
            raise HTTPException(status_code=403, detail="forbidden for role " + user["role"])
        return user
    return checker


any_user = require_role("admin", "agent")
admin_only = require_role("admin")


def get_lead_in_tenant(conn, lead_id: int, tenant_id: str) -> dict:
    """SECURITY: every lead lookup is filtered by the caller's tenant.

    Another tenant's lead returns 404 (same as a missing id) so callers cannot
    probe which ids exist in other tenants.
    """
    lead = conn.execute(
        "SELECT * FROM leads WHERE id = %s AND tenant_id = %s", (lead_id, tenant_id)
    ).fetchone()
    if not lead:
        raise HTTPException(status_code=404, detail="lead not found")
    return lead


# ---------------------------------------------------------------- endpoints
@app.get("/health")
def health():
    with db() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


class UpsertIn(BaseModel):
    event_id: str
    name: str | None = None
    phone: str | None = None
    email: str | None = None
    message: str | None = None


@app.post("/leads/upsert")
def upsert_lead(body: UpsertIn, user: dict = Depends(any_user)):
    tenant = user["tenant_id"]
    phone = normalise_phone(body.phone)
    email = normalise_email(body.email)
    if not phone and not email:
        raise HTTPException(status_code=422, detail="phone or email required")

    # One transaction: claiming the event_id and writing the lead commit together,
    # or neither does (e.g. on a crash we can safely retry the same event).
    with db() as conn, conn.transaction():
        # IDEMPOTENCY: try to claim the event. ON CONFLICT DO NOTHING means a
        # concurrent duplicate blocks on the PK row lock and then sees the conflict,
        # so the same event can never create two leads.
        claimed = conn.execute(
            "INSERT INTO processed_events (tenant_id, event_id) VALUES (%s, %s) "
            "ON CONFLICT DO NOTHING RETURNING event_id",
            (tenant, body.event_id),
        ).fetchone()
        if not claimed:
            prev = conn.execute(
                "SELECT lead_id FROM processed_events WHERE tenant_id = %s AND event_id = %s",
                (tenant, body.event_id),
            ).fetchone()
            lead = get_lead_in_tenant(conn, prev["lead_id"], tenant)
            log.info("duplicate event tenant=%s event=%s lead=%s", tenant, body.event_id, lead["id"])
            return {"lead": lead, "duplicate": True, "created": False}

        # DEDUP: same tenant + same normalised phone OR email = same customer.
        # Phone match is preferred (ORDER BY) if phone and email point at different leads.
        matches = conn.execute(
            "SELECT * FROM leads WHERE tenant_id = %s AND (phone_norm = %s OR email_norm = %s) "
            "ORDER BY (phone_norm IS NOT DISTINCT FROM %s) DESC, id LIMIT 2",
            (tenant, phone, email, phone),
        ).fetchall()

        if matches:
            target = matches[0]
            # Only fill a missing phone/email when exactly one lead matched; if two
            # leads matched, filling would violate a UNIQUE constraint.
            fill = len(matches) == 1
            lead = conn.execute(
                "UPDATE leads SET name = COALESCE(%s, name), last_message = %s, "
                "phone_norm = CASE WHEN %s THEN COALESCE(phone_norm, %s) ELSE phone_norm END, "
                "email_norm = CASE WHEN %s THEN COALESCE(email_norm, %s) ELSE email_norm END, "
                "updated_at = now() WHERE id = %s RETURNING *",
                (body.name, body.message, fill, phone, fill, email, target["id"]),
            ).fetchone()
            created = False
        else:
            lead = conn.execute(
                "INSERT INTO leads (tenant_id, name, phone_norm, email_norm, last_message) "
                "VALUES (%s, %s, %s, %s, %s) RETURNING *",
                (tenant, body.name, phone, email, body.message),
            ).fetchone()
            created = True

        conn.execute(
            "UPDATE processed_events SET lead_id = %s WHERE tenant_id = %s AND event_id = %s",
            (lead["id"], tenant, body.event_id),
        )
    log.info("upsert tenant=%s event=%s lead=%s created=%s", tenant, body.event_id, lead["id"], created)
    return {"lead": lead, "duplicate": False, "created": created}


@app.get("/leads/{lead_id}")
def read_lead(lead_id: int, user: dict = Depends(any_user)):
    with db() as conn:
        return get_lead_in_tenant(conn, lead_id, user["tenant_id"])


@app.get("/admin/leads")
def admin_list_leads(user: dict = Depends(admin_only)):
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM leads WHERE tenant_id = %s ORDER BY id", (user["tenant_id"],)
        ).fetchall()
    return {"tenant": user["tenant_id"], "leads": rows}
