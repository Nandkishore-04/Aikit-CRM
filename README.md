# AiKit – Enquiry → Dedup CRM → Cited Answer → Human Handoff

Timed assessment (AI & Automation Engineer, AiKit UAE). Everything runs locally in Docker
with **mock CRM + synthetic data only**. No live client systems, no real credentials, no paid services.

## Overview

A property enquiry (fictional property **P1**: price **AED 1,000,000**, availability **unknown**)
arrives at an n8n webhook. n8n upserts the lead into a **mock CRM** (FastAPI + Postgres, standing in
for Zoho Bigin), which deduplicates it, then asks the CRM for an answer. The CRM answers **only from
stored facts with a citation**; anything unknown, conflicting or a request for a person becomes a
**handoff** row for a human. CRM failures are retried a **bounded** number of times, then an
**alert** is written.

```
  client (tenant token)
        │  POST /webhook/enquiry   Authorization: Bearer <token>
        ▼
 ┌──────────────────────────── n8n 1.70.0 (:5678) ───────────────────────────┐
 │ Webhook ─► Upsert Lead ─► Is Duplicate? ─yes─► Respond {duplicate:true}   │
 │            (retry: 3 tries,      │                                        │
 │             1000 ms apart)       no                                       │
 │                                  ▼                                        │
 │                             Get Answer ─► Respond {answer,citation,handoff}│
 │                                                                           │
 │ on any failure ─► Error workflow: Error Trigger ─► POST /alerts           │
 └──────────────┬───────────────────────────────────────────┬────────────────┘
                │ http://mock-crm:8000 (Docker network)      │ X-Internal-Token
                ▼                                            ▼
 ┌──────────────────── mock-crm (FastAPI, :8000) ──────────────────────────┐
 │ auth: token → user → tenant (401 / 403 / 404)                           │
 │ /leads/upsert  /leads/{id}  /admin/leads  /answer  /handoffs  /alerts   │
 │ /_debug/fail-next  /_debug/stats   (TEST ONLY, flag-gated)              │
 └──────────────────────────────┬──────────────────────────────────────────┘
                                ▼
            postgres:16 (not exposed to host, named volume)
   tenants · users · leads · processed_events · property_facts · handoffs · alerts
```

| Path | What |
|---|---|
| `docker-compose.yml` | 3 services, pinned images |
| `db/init.sql` | schema + synthetic seed (2 tenants, 4 users, P1 facts) |
| `mock-crm/app/main.py` | API: auth, tenancy, dedup upsert, answers, handoffs, alerts, fail injection |
| `mock-crm/app/normalise.py` | phone/email normaliser (+ `tests/test_normalise.py`) |
| `n8n/workflows/*.json` | enquiry workflow + error-alert workflow |
| `scripts/import_n8n.sh` | import + activate workflows |
| `scripts/run_evidence.sh` | all evidence cases → `evidence/results.txt` |
| `scripts/backup_restore.sh` | backup → clean-instance restore → verify |
| `postman/` | Postman collection + environment for the same cases |

## Assumptions

- **"Two test tenants" = two separate client organisations** sharing one system (multi-tenancy).
  Every row carries `tenant_id`; the tenant is **always derived from the API token**, never from the request body.
- **Cross-tenant access returns 404, not 403.** Returning 403 would confirm that the id exists in
  another tenant; 404 is indistinguishable from a missing id, so nothing leaks.
- **Rule-based answers instead of an LLM**, because paid services are out of scope. Keyword intent
  (`human` → `availability` → `price`, checked in that order) + lookup in `property_facts`.
  It can only ever return a value that exists in the table, with its `fact_id` and `source`.
  NULL (unknown), missing or conflicting facts → "I don't have confirmed information" + handoff.
  User text is treated purely as data: lower-cased and keyword-matched, never executed or templated into SQL.
- **Dedup key** = same tenant + same normalised phone (digits, UAE → `9715…`) **or** same normalised
  email (trim + lowercase). Enforced by `UNIQUE(tenant_id, phone_norm)` and `UNIQUE(tenant_id, email_norm)`.
- **Idempotency** = `processed_events` PK `(tenant_id, event_id)`. Scoped per tenant so tenant B
  re-using an event id can never be answered with tenant A's lead. Event claim + lead write happen
  in **one transaction**.
- **Tokens are stored as SHA-256 hashes**, so a DB dump does not contain usable tokens.
  Synthetic test tokens: `test-token-a-admin`, `test-token-a-agent`, `test-token-b-admin`, `test-token-b-agent`.
- **Roles:** `admin` and `agent` can upsert/read/answer within their tenant; only `admin` can list
  all leads (`/admin/leads`) and use the debug endpoints.
- n8n uses its default SQLite store on its own volume (simplest). n8n passes the caller's
  `Authorization` header through, so the CRM, not n8n, decides tenant and role.

## How to run

Requires Docker + Compose v2, `curl`, `jq`. The first run needs internet to pull the images and pip packages.

```bash
cp .env.example .env          # then replace every change-me value, e.g. with: openssl rand -hex 32
docker compose up -d --build
./scripts/import_n8n.sh       # imports both workflows, activates the webhook, restarts n8n
./scripts/run_evidence.sh     # prints PASS/FAIL, writes evidence/results.txt
./scripts/backup_restore.sh   # backup → clean restore → verify
```

What `import_n8n.sh` runs:
```bash
docker compose exec -T n8n n8n import:workflow --input=/workflows/error_alert.json
docker compose exec -T n8n n8n import:workflow --input=/workflows/enquiry.json
docker compose exec -T n8n n8n update:workflow --id=AikitEnquiry0001 --active=true
docker compose restart n8n
```
**Manual UI steps: none required.** The production webhook works without logging in. Optional, for
the demo: open http://localhost:5678, create the owner account, and open *Executions* to see the
failed run (Upsert Lead tried 3×) and the error-workflow run.

Manual example:
```bash
curl -s -X POST http://localhost:5678/webhook/enquiry \
  -H 'Authorization: Bearer test-token-a-agent' -H 'Content-Type: application/json' \
  -d '{"event_id":"demo-1","name":"Jane","phone":"050 123 4567","email":"jane@example.test","message":"How much is P1?"}' | jq
```

### Postman (optional)

Import `postman/AiKit-CRM.postman_collection.json` and `postman/AiKit-local.postman_environment.json`
into the Postman **desktop app** (the web app can't reach `localhost` without the Postman Agent), select
the **AiKit local** environment, and run folders `0 Setup` → `8-9` in order with the **Collection Runner**.
That's 20 requests with 32 assertions. Each run uses fresh event ids and phone numbers. Skip the `Extras` folder in the runner.

Headless, same collection (verified: 32/32 assertions pass):
```bash
docker run --rm --network host -v "$PWD/postman:/etc/newman:ro" postman/newman:6.1.3 \
  run AiKit-CRM.postman_collection.json -e AiKit-local.postman_environment.json \
  --folder "0 Setup" --folder "1-3 Security denials" --folder "4-7 Enquiry flow via n8n" \
  --folder "8-9 Forced 500, bounded retry, recovery"
```

Fresh start: `docker compose down -v` (deletes both volumes), then the commands above.

## Evidence

`./scripts/run_evidence.sh` output (`evidence/results.txt`), against the live stack:

```
=== AiKit evidence run 2026-11-16T16:26:03+05:30  commit bf07245 ===

PASS  0  normaliser unit tests  | 5 passed in 0.01s
PASS  1  logged-out denied (401)  | HTTP 401 {"detail":"missing bearer token"}
PASS  2  non-admin denied (403)  | HTTP 403 {"detail":"forbidden for role agent"}
PASS  3  cross-tenant denied (404)  | B lead 2: tenant_b=200, tenant_a=404 {"detail":"lead not found"}
PASS  4  duplicate event deduped  | 2nd response duplicate=true, lead rows=1
PASS  5  reformatted phone -> same lead  | '0594826563' vs '+971 59 482 6563' -> lead 3 (expected 3), rows=1
PASS  6  price answered with citation  | {"answer":"The price of P1 is AED 1,000,000.","citation":{"fact_id":1,"source":"brief:P1-listing-sheet","property_code":"P1","field":"price"}}
PASS  7  availability -> no guess + handoff  | answer='I don't have confirmed information on that. I've passed your question to a colleague who will get back to you.' handoff_id=1 reason=no_confirmed_availability
      mock-crm log for this request:
        2026-11-16 10:56:06,605 WARNING fail injection armed: next 5 upserts will 500
        2026-11-16 10:56:06,705 WARNING upsert attempt 1 -> injected 500 (remaining=4)
        2026-11-16 10:56:07,830 WARNING upsert attempt 2 -> injected 500 (remaining=3)
        2026-11-16 10:56:08,862 WARNING upsert attempt 3 -> injected 500 (remaining=2)
      latest alert: 1 | n8n:AiKit - Enquiry to CRM | Execution 6 failed at node "Upsert Lead": The service was not able to process your request
PASS  8  500 -> bounded retry (3) + alert  | caller HTTP 500 after 2282ms, attempts=3, unused failures=2, alerts 0->1
PASS  9  transient 500 -> retry recovers  | HTTP 200, attempts=2, answer='The price of P1 is AED 1,000,000.'

=== SUMMARY: 10 passed, 0 failed ===
```

| # | Required demonstration | How it is shown |
|---|---|---|
| 1 | logged-out denial | no token → 401 |
| 2 | non-admin denial | agent on `/admin/leads` → 403 |
| 3 | cross-tenant denial | tenant A token on tenant B lead → 404 (tenant B gets 200 as a control) |
| 4 | duplicate event | same `event_id` twice via n8n → `duplicate:true`, 1 lead row, no second answer/handoff |
| 5 | dedup across formats | `05…` vs `+971 5…` → same lead id, 1 row |
| 6 | cited answer | "AED 1,000,000" + `fact_id` + `source` |
| 7 | no guessing + handoff | availability is NULL → "I don't have confirmed information" + handoff row |
| 8 | API 500, bounded retry + alert | `fail-next=5` → exactly **3** attempts (~2.2 s), 2 injected failures never used, caller gets 500, alert row written by the error workflow |
| 9 | recovery | `fail-next=1` → 2nd attempt succeeds |

## Backup & restore proof

`./scripts/backup_restore.sh` dumps the CRM DB, starts a **new `postgres-restore` container from the same
pinned image with no named volume and not on the app network**, checks that it has 0 tables, restores
with `ON_ERROR_STOP=1`, compares the row counts of all 7 tables plus an md5 of the lead contents, then
removes the container (trap, so it is removed even on failure).

```
1) pg_dump -> backups/backup_20261116_162610.sql
   12256 bytes
2) start clean container 'postgres-restore' (same pinned image, no named volume, not on app network)
   tables in fresh instance before restore: 0 (must be 0)
3) restore
4) verify row counts (original vs restored)
   table              original restored
   tenants                   2        2
   users                     4        4
   leads                     3        3
   processed_events          6        6
   property_facts            4        4
   handoffs                  1        1
   alerts                    1        1
   leads content md5: original=c865ab54de91bf825686a041828d5137 restored=c865ab54de91bf825686a041828d5137
5) cleanup: removing postgres-restore (trap)
BACKUP/RESTORE: PASS  (backups/backup_20261116_162610.sql)
```

Scope: this covers the **CRM database**. n8n's state is reproducible from git (`n8n/workflows/*.json`
+ `import_n8n.sh`). In production you would also snapshot the `n8n_data` volume, and you would need
the `N8N_ENCRYPTION_KEY` to read any credentials stored in it.

## Rollback

1. **Everything is pinned:** `postgres:16`, `n8nio/n8n:1.70.0`, `python:3.12-slim`, an exact
   `requirements.txt`, and the app image tagged `aikit-mock-crm:0.1.0`. Never deploy `latest`.
2. **Before each release:** run `./scripts/backup_restore.sh` (this takes a backup *and* proves it restores),
   keep the previous image tag, and note the git commit.
3. **To roll back the app:** `git checkout <previous-commit>` (or set the previous image tag in
   `docker-compose.yml`), then `docker compose up -d`. For n8n, set the previous image tag and re-run
   `./scripts/import_n8n.sh` from the previous commit, so the workflow JSON matches.
4. **If the release changed the schema:** stop `mock-crm`, restore the pre-release backup into Postgres
   (`psql < backups/backup_<ts>.sql` into a recreated, empty DB), then start the old version.
   Because the backup has already been restore-tested, this is not the first time it is used.
5. Verify with `./scripts/run_evidence.sh`.

## Secrets handling

- **`.env` is gitignored.** Only `.env.example`, with `change-me` placeholders, is committed. Postgres
  password, internal alert token and `N8N_ENCRYPTION_KEY` were generated locally with `openssl rand`.
- **`N8N_ENCRYPTION_KEY`** encrypts the credentials n8n stores. Back it up **separately** from the n8n
  volume (password manager / secrets manager). A volume backup without the key cannot decrypt its credentials.
- **The internal alert token** is injected into n8n as an env var and read with `$env.INTERNAL_ALERT_TOKEN`,
  so it is not stored in the workflow JSON in git. The CRM compares it in constant time (`hmac.compare_digest`).
- **API tokens are stored only as SHA-256 hashes.** The plain test tokens in this repo are synthetic and
  documented on purpose. In production they would be random, per user, issued once, rotatable and
  revocable (replace the hash row) and given an expiry.
- **Rotation:** change the value in `.env` / the secrets manager → `docker compose up -d` (recreates the
  containers with the new env). Rotating `N8N_ENCRYPTION_KEY` requires re-entering the n8n credentials.
- Postgres is not published to the host. Only 8000 and 5678 are, for the demo.
- **Production:** use a secrets manager (Docker/K8s secrets, Vault, AWS SM), not a `.env` file on disk.

## How the mock maps to real Zoho Bigin OAuth

| Mock | Real Zoho Bigin |
|---|---|
| Static bearer token per user → tenant | OAuth 2.0 **per client org**. Register a client in the Zoho API Console: a *Self Client* for server-to-server, or a server-based app if the client authorises via consent screen. Exchange the one-time grant code for a **refresh token** (long-lived) and an **access token** (~1 hour). |
| `.env` secret | The **refresh token + client id/secret are the secrets**, stored per tenant in a secrets manager or as an n8n OAuth2 credential (encrypted with `N8N_ENCRYPTION_KEY`). Never in git or workflow JSON. |
| No expiry | Refresh the access token **before expiry** (on `expires_in`, with a margin) via `POST https://accounts.zoho.<dc>/oauth/v2/token?grant_type=refresh_token…`. On 401 `INVALID_TOKEN`, refresh once and retry. |
| `localhost` | **Data-centre-specific domains:** the accounts server (`accounts.zoho.com` / `.eu` / `.in` / `.com.au` …) must match the org's DC, and the API host comes from the `api_domain` returned with the token. Use those values; don't hard-code `.com`. |
| `Authorization: Bearer …` | `Authorization: Zoho-oauthtoken <access_token>` |
| `POST /leads/upsert` | Search Contacts by normalised phone/email (`GET /bigin/v2/Contacts/search?email=…` / `phone=…`), then update or create, or use the Records **upsert** API with duplicate-check fields Email/Phone. The idempotency table stays on **our** side, because Bigin doesn't dedup on our `event_id`. |
| `GET /leads/{id}` | `GET /bigin/v2/Contacts/{id}` |
| enquiry → deal | A record in the **Pipelines** module, linked to the Contact |
| `handoffs` row | A Bigin Task/Note on the Contact or Pipeline record, assigned to an owner, plus a notification |
| `property_facts` | Our own source of truth (a listing DB). Bigin isn't the fact store. |
| fail-next 500s | Real 5xx **and 429 rate-limit** responses. Retry with bounded exponential backoff + jitter, honour rate-limit headers, and only retry idempotent calls. Retry 5xx/429 only; don't retry 4xx. |
| tenant from token | Each tenant has its **own OAuth client / refresh token**. The credential is selected from the authenticated tenant, never from the payload. |

Scope names and endpoint paths are from my understanding of the Bigin v2 API. **They were not verified
against a live Zoho account** (out of scope by the brief) and should be confirmed in Zoho's docs before
real integration.

## Production gaps / unfinished items

Everything in the brief is implemented and passes. Known gaps, **not done** in the 2-hour box:

- **n8n retries any error, including 4xx.** An invalid token through the webhook is tried 3×, then
  raises an alert. It should retry only 5xx/429 (e.g. a Code node or `neverError` + an IF on status).
- **The webhook has no auth of its own.** It relies on the CRM rejecting a bad pass-through token, and
  there is no rate limiting. Production: webhook header auth / HMAC signature + rate limits.
- **Two simultaneous *new* enquiries for the same new customer** (different event ids) can hit the
  unique constraint. One gets a 500; n8n's retry then finds and updates the lead, so it self-heals,
  but it isn't handled explicitly.
- **Alerts are only written to a table**, with no paging/Slack/email. **Handoffs are rows**; no human is notified.
- Intent detection is naive keyword matching (e.g. "agent" in any sentence → human handoff). The phone
  normaliser is UAE-centric. There is no E.164 library.
- The fail-injection state lives in memory and needs `--workers 1`. It is gated by
  `ENABLE_FAIL_INJECTION` + admin role, and must be `false` outside tests.
- No TLS, token expiry/rotation endpoint, audit log, PII retention policy or DB migrations tool
  (schema is `init.sql` only). The backup script covers the CRM DB only, not the n8n volume.
- n8n runs with SQLite and no owner pre-configured. Production: Postgres for n8n, owner/SSO, queue mode.
- The `answer` step isn't retried on purpose (it can create a handoff, which isn't idempotent).

## AI disclosure

This project was built with **Claude Code** (Anthropic, Claude Opus 5.5) as a coding assistant, working from my
written spec and architecture. It generated most of the code, workflow JSON, scripts and this README draft.

What I reviewed and verified myself:
- **Security logic:** token → tenant resolution, 401/403/404 behaviour, tenant filter on every lead
  query, hashed tokens, constant-time internal-token check, fail injection gated by flag + admin.
- **Dedup/idempotency logic:** the normaliser rules, the per-tenant unique constraints, the
  `(tenant_id, event_id)` claim with `ON CONFLICT DO NOTHING` inside one transaction.
- **Behaviour,** by running the stack and the scripts: `run_evidence.sh` 10/10 PASS, `backup_restore.sh` PASS
  (output above). I checked the n8n retry count in the mock-crm logs and the alert row in Postgres.
- Issues found and fixed during live testing: n8n 1.70 `import:workflow` needs a JSON array; the n8n
  readiness probe was changed to `/healthz` so it doesn't create spurious alerts; on a fresh volume the CLI import raced n8n's first-start migrations (`SQLITE_BUSY`), so the import script now waits for `/healthz` first; the evidence log
  excerpt was narrowed to the injected-failure lines.

Exact commit: see `git log -1` (the final commit of this repo).
