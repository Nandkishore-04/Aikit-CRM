"""Mock CRM - pretends to be Zoho Bigin for local testing. Fake data only."""
import hashlib
import hmac
import logging
import os
import re
import threading

import psycopg
from fastapi import Depends, FastAPI, Header, HTTPException
from psycopg.rows import dict_row
from pydantic import BaseModel

from app.normalise import normalise_email, normalise_phone

DATABASE_URL = os.environ["DATABASE_URL"]
INTERNAL_ALERT_TOKEN = os.environ["INTERNAL_ALERT_TOKEN"]
# only for the forced 500 test, off by default
ENABLE_FAIL_INJECTION = os.environ.get("ENABLE_FAIL_INJECTION", "false").lower() == "true"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mock-crm")

app = FastAPI(title="AiKit Mock CRM")


def db():
    """new connection per request, fine for this demo"""
    return psycopg.connect(DATABASE_URL, row_factory=dict_row)


# --- auth / tenant ---
def current_user(authorization: str | None = Header(default=None)) -> dict:
    # Bearer token -> user row. No token or unknown token = 401.
    # DB only has sha256 of the token, so we hash and compare.
    # tenant always comes from here, never from the request body.
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
    # logged in but wrong role = 403
    def checker(user: dict = Depends(current_user)) -> dict:
        if user["role"] not in roles:
            raise HTTPException(status_code=403, detail="forbidden for role " + user["role"])
        return user
    return checker


any_user = require_role("admin", "agent")
admin_only = require_role("admin")


def get_lead_in_tenant(conn, lead_id: int, tenant_id: str) -> dict:
    # always filter by the caller's tenant.
    # other tenant's lead gives 404 (same as not found) so nobody can
    # find out which ids exist in another tenant
    lead = conn.execute(
        "SELECT * FROM leads WHERE id = %s AND tenant_id = %s", (lead_id, tenant_id)
    ).fetchone()
    if not lead:
        raise HTTPException(status_code=404, detail="lead not found")
    return lead


# --- failure injection (test only) ---
# kept in memory, works because we run 1 uvicorn worker.
# used to show n8n stops retrying after 3 tries
_fail_lock = threading.Lock()
_fail_state = {"fail_next": 0, "upsert_attempts": 0}


def record_attempt_or_fail():
    # count each upsert call, and throw 500 while fail_next > 0
    with _fail_lock:
        _fail_state["upsert_attempts"] += 1
        attempt = _fail_state["upsert_attempts"]
        if _fail_state["fail_next"] > 0:
            _fail_state["fail_next"] -= 1
            log.warning("upsert attempt %s -> injected 500 (remaining=%s)", attempt, _fail_state["fail_next"])
            raise HTTPException(status_code=500, detail="injected failure (test only)")
    log.info("upsert attempt %s", attempt)


# --- endpoints ---
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
    record_attempt_or_fail()   # does nothing unless fail-next was set
    tenant = user["tenant_id"]
    phone = normalise_phone(body.phone)
    email = normalise_email(body.email)
    if not phone and not email:
        raise HTTPException(status_code=422, detail="phone or email required")

    # event insert + lead write in one transaction. if anything fails both
    # roll back, so retrying the same event is safe
    with db() as conn, conn.transaction():
        # try to insert the event id. if it's already there we get nothing back
        # -> duplicate. two requests with the same id at the same time: the 2nd
        # one waits on the PK lock and then hits the conflict, so still 1 lead
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

        # same tenant + same phone or email = same person.
        # if phone and email match two different leads, take the phone one
        matches = conn.execute(
            "SELECT * FROM leads WHERE tenant_id = %s AND (phone_norm = %s OR email_norm = %s) "
            "ORDER BY (phone_norm IS NOT DISTINCT FROM %s) DESC, id LIMIT 2",
            (tenant, phone, email, phone),
        ).fetchall()

        if matches:
            target = matches[0]
            # only fill in a missing phone/email if 1 lead matched,
            # with 2 matches it would break the unique constraint
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


# --- answer + handoff ---
class AnswerIn(BaseModel):
    lead_id: int
    question: str


HUMAN_WORDS = ("human", "real person", "agent", "someone", "call me", "speak to", "talk to")
AVAILABILITY_WORDS = ("availab", "vacant", "still for sale", "sold", "free to view")
PRICE_WORDS = ("price", "cost", "how much", "asking")
NO_INFO = "I don't have confirmed information on that. I've passed your question to a colleague who will get back to you."


def create_handoff(conn, tenant: str, lead_id: int, reason: str, summary: str) -> dict:
    return conn.execute(
        "INSERT INTO handoffs (tenant_id, lead_id, reason, summary) VALUES (%s, %s, %s, %s) RETURNING *",
        (tenant, lead_id, reason, summary[:500]),
    ).fetchone()


@app.post("/answer")
def answer(body: AnswerIn, user: dict = Depends(any_user)):
    # simple keyword rules, no LLM.
    # question text is just matched against keywords, never put into SQL
    # (all queries use params) and can't change tenant or which facts we read.
    # we only answer with a value from property_facts + where it came from
    tenant = user["tenant_id"]
    q = body.question.lower()
    m = re.search(r"\bp(\d+)\b", q)                  # P1, P2.. defaults to P1
    code = f"P{m.group(1)}" if m else "P1"

    if any(w in q for w in HUMAN_WORDS):
        intent = "human"
    elif any(w in q for w in AVAILABILITY_WORDS):
        intent = "availability"
    elif any(w in q for w in PRICE_WORDS):
        intent = "price"
    else:
        intent = "unknown"

    with db() as conn, conn.transaction():
        lead = get_lead_in_tenant(conn, body.lead_id, tenant)
        who = lead["name"] or f"lead {lead['id']}"

        if intent == "human":
            h = create_handoff(conn, tenant, lead["id"], "customer_requested_human",
                               f"{who} asked to speak to a person about {code}.")
            return {"answer": "Sure, a colleague will contact you shortly.", "citation": None,
                    "handoff": True, "handoff_id": h["id"], "intent": intent}

        facts = []
        if intent in ("price", "availability"):
            facts = conn.execute(
                "SELECT id, value, source FROM property_facts "
                "WHERE tenant_id = %s AND property_code = %s AND field = %s",
                (tenant, code, intent),
            ).fetchall()
        values = {f["value"] for f in facts if f["value"] is not None}

        # answer only if there's exactly 1 known value.
        # missing / null / conflicting -> don't guess, hand off to a person
        if len(values) == 1:
            fact = next(f for f in facts if f["value"] is not None)
            return {"answer": f"The {intent} of {code} is {fact['value']}.",
                    "citation": {"fact_id": fact["id"], "source": fact["source"],
                                 "property_code": code, "field": intent},
                    "handoff": False, "handoff_id": None, "intent": intent}

        reason = "conflicting_fact" if len(values) > 1 else f"no_confirmed_{intent}"
        h = create_handoff(conn, tenant, lead["id"], reason,
                           f"{who} asked about {intent} of {code}; no confirmed fact. Question: {body.question[:200]}")
        return {"answer": NO_INFO, "citation": None, "handoff": True,
                "handoff_id": h["id"], "intent": intent}


class HandoffIn(BaseModel):
    lead_id: int
    reason: str
    summary: str


@app.post("/handoffs")
def post_handoff(body: HandoffIn, user: dict = Depends(any_user)):
    with db() as conn, conn.transaction():
        get_lead_in_tenant(conn, body.lead_id, user["tenant_id"])   # tenant check
        return create_handoff(conn, user["tenant_id"], body.lead_id, body.reason, body.summary)


# --- alerts (internal) ---
class AlertIn(BaseModel):
    source: str
    message: str


@app.post("/alerts")
def post_alert(body: AlertIn, x_internal_token: str | None = Header(default=None)):
    # internal only - uses its own shared secret, not a user token.
    # compare_digest so the check takes the same time either way
    if not x_internal_token or not hmac.compare_digest(x_internal_token, INTERNAL_ALERT_TOKEN):
        raise HTTPException(status_code=401, detail="invalid internal token")
    with db() as conn, conn.transaction():
        row = conn.execute(
            "INSERT INTO alerts (source, message) VALUES (%s, %s) RETURNING *",
            (body.source[:100], body.message[:2000]),
        ).fetchone()
    log.error("ALERT from %s: %s", body.source, body.message[:200])
    return row


# --- debug endpoints (test only) ---
def require_fail_injection_enabled():
    if not ENABLE_FAIL_INJECTION:
        raise HTTPException(status_code=404, detail="not found")


@app.post("/_debug/fail-next", dependencies=[Depends(require_fail_injection_enabled)])
def debug_fail_next(count: int, user: dict = Depends(admin_only)):
    # test only: next `count` upserts return 500, also resets the counter
    with _fail_lock:
        _fail_state["fail_next"] = max(0, count)
        _fail_state["upsert_attempts"] = 0
    log.warning("fail injection armed: next %s upserts will 500", count)
    return dict(_fail_state)


@app.get("/_debug/stats", dependencies=[Depends(require_fail_injection_enabled)])
def debug_stats(user: dict = Depends(admin_only)):
    with _fail_lock:
        return dict(_fail_state)
