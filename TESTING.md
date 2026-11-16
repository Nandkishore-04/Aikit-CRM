# Manual test guide (Postman + n8n UI)

Every step has the same layout: **Send** (or **Do**), **Expect**, and sometimes **Look**.
Do them in order. Each step takes about 30 seconds.

**How to set the token in Postman:** open the **Authorization** tab, choose **Type: Bearer Token**, and paste the token.
**How to send a body:** open the **Body** tab, choose **raw**, then **JSON**, and paste the JSON.

| Token | Who |
|---|---|
| `test-token-a-admin` | Tenant A, admin |
| `test-token-a-agent` | Tenant A, agent (not admin) |
| `test-token-b-agent` | Tenant B, agent |

---

## Step 0: Start clean (terminal)

**Do**
```bash
cd ~/Aikit-CRM
docker compose down -v
docker compose up -d --build
./scripts/import_n8n.sh
```
**Expect:** the last line says `n8n is up: POST http://localhost:5678/webhook/enquiry`.

A clean start matters because it makes the ids below predictable: tenant B's seed lead is **id 1**, and your first new lead is **id 2**.

---

## Step 1: Health check

**Send:** `GET http://localhost:8000/health`, with no token.

**Expect:** `200` and `{"status":"ok"}`

---

## Test 1: Logged out is blocked

**Send:** `GET http://localhost:8000/admin/leads`, with **no token** (Authorization tab: *No Auth*).

**Expect:** `401` and `{"detail":"missing bearer token"}`

---

## Test 2: Non-admin is blocked

**Send:** `GET http://localhost:8000/admin/leads`, with token `test-token-a-agent`.

**Expect:** `403` and `{"detail":"forbidden for role agent"}`

**Control:** the same request with `test-token-a-admin` returns `200` and a list containing only `tenant_a` leads.

---

## Test 3: Another tenant's data is blocked

Lead **1** belongs to **tenant B**.

**Send:** `GET http://localhost:8000/leads/1`, with token `test-token-b-agent`.

**Expect:** `200`. Tenant B can see its own lead.

**Send:** `GET http://localhost:8000/leads/1`, with token `test-token-a-admin`.

**Expect:** `404` and `{"detail":"lead not found"}`. Tenant A can't see it, and can't even tell that it exists.

---

## Test 4: Duplicate event is ignored

**Send:** `POST http://localhost:5678/webhook/enquiry`, with token `test-token-a-agent` and this body:
```json
{
  "event_id": "e1",
  "name": "Jane",
  "phone": "050 123 4567",
  "email": "jane@example.test",
  "message": "How much is P1?"
}
```
**Expect:** `200`, `"duplicate": false`, `"lead_id": 2`, and the price answer.

**Send exactly the same request again** (same `event_id: "e1"`).

**Expect:** `200`, `"duplicate": true`, the same `lead_id: 2`, and `"answer": null`. Nothing was processed twice.

---

## Test 5: Same customer, phone written differently, updates the same lead

**Send:** `POST http://localhost:5678/webhook/enquiry`, with token `test-token-a-agent` and this body:
```json
{
  "event_id": "e2",
  "name": "Jane D",
  "phone": "+971 50 123 4567",
  "message": "How much is P1?"
}
```
**Expect:** `"duplicate": false` but the **same `"lead_id": 2`**. `+971 50…` and `050…` are recognised as one customer.

**Look (optional):** `GET http://localhost:8000/admin/leads` with `test-token-a-admin` shows **one** Jane, with `phone_norm: "971501234567"` and name updated to "Jane D".

---

## Test 6: Price question gets a cited answer

**Send:** `POST http://localhost:5678/webhook/enquiry`, with token `test-token-a-agent` and this body:
```json
{ "event_id": "e3", "phone": "050 123 4567", "message": "What is the price of P1?" }
```
**Expect:**
```json
"answer": "The price of P1 is AED 1,000,000.",
"citation": { "fact_id": 1, "source": "brief:P1-listing-sheet", "property_code": "P1", "field": "price" },
"handoff": false
```

---

## Test 7: Unknown availability, so no guess and a human handoff

**Send:** `POST http://localhost:5678/webhook/enquiry`, with token `test-token-a-agent` and this body:
```json
{ "event_id": "e4", "phone": "050 123 4567", "message": "Is P1 still available?" }
```
**Expect:** `"answer": "I don't have confirmed information on that..."`, `"citation": null`, `"handoff": true` and a `"handoff_id"` number.

**Bonus:** `"message": "Can I talk to a human?"` (with `event_id` `"e4b"`) also returns `"handoff": true`.

**Look (terminal):**
```bash
docker compose exec postgres psql -U crm -d crm -c "select id, lead_id, reason, summary from handoffs"
```
You should see the handoff row with `reason = no_confirmed_availability`.

---

## Test 8: CRM fails, n8n retries exactly 3 times, then an alert

**8a. Make the CRM fail the next 5 calls (test-only switch)**

**Send:** `POST http://localhost:8000/_debug/fail-next?count=5`, with token `test-token-a-admin`.

**Expect:** `{"fail_next":5,"upsert_attempts":0}`

**8b. Send an enquiry**

**Send:** `POST http://localhost:5678/webhook/enquiry`, with token `test-token-a-agent` and this body:
```json
{ "event_id": "e5", "phone": "050 123 4567", "message": "How much is P1?" }
```
**Expect:** `500` and `{"message":"Error in workflow"}`. Postman's response time is about **2 seconds** (3 tries, 1 second apart).

**8c. Count the attempts**

**Send:** `GET http://localhost:8000/_debug/stats`, with token `test-token-a-admin`.

**Expect:** `{"fail_next":2,"upsert_attempts":3}`. Only **3** attempts were made, and 2 of the 5 injected failures were never used, so the retry stopped by itself.

**8d. See it in n8n (browser)**

**Do:** open http://localhost:5678 (first time only: create an owner account, which stays on your machine).
1. Open **AiKit - Enquiry to CRM** and go to the **Executions** tab. The newest run is **red**. Click it: the **Upsert Lead** node is red.
2. Go back, open **AiKit - Error Alert**, then **Executions**. There's a run at the same time. Click **Write Alert** to see the alert it sent.

**8e. See the alert row and the 3 attempts (terminal)**
```bash
docker compose exec postgres psql -U crm -d crm -c "select id, source, message from alerts"
docker compose logs mock-crm | grep "injected 500" | tail -3
```
**Expect:** one alert, `Execution … failed at node "Upsert Lead"`, and exactly **3** "injected 500" log lines.

---

## Test 9: One failure, then the retry succeeds

**Send:** `POST http://localhost:8000/_debug/fail-next?count=1`, with token `test-token-a-admin`.

**Send:** `POST http://localhost:5678/webhook/enquiry`, with token `test-token-a-agent` and this body:
```json
{ "event_id": "e6", "phone": "050 123 4567", "message": "How much is P1?" }
```
**Expect:** `200` and the normal price answer, after about 1 second.

**Send:** `GET http://localhost:8000/_debug/stats`, with token `test-token-a-admin`.

**Expect:** `"upsert_attempts": 2`: 1 failed and 1 succeeded. In n8n, **Executions** shows a new **green** run.

---

## Test 10: Backup, then restore into a clean database (terminal)

**Do**
```bash
./scripts/backup_restore.sh
```
**Expect**
- `tables in fresh instance before restore: 0`, so the target really was empty
- a table where every row has **original = restored**
- `BACKUP/RESTORE: PASS` as the last line

---

## Test 11: Everything automatically (terminal)

**Do**
```bash
./scripts/run_evidence.sh
```
**Expect:** `=== SUMMARY: 10 passed, 0 failed ===`, saved to `evidence/results.txt`.

---

## Bonus: Watch n8n run node by node

1. In n8n, open **AiKit - Enquiry to CRM** and click **Test workflow**.
2. In Postman, send to the **test** URL: `POST http://localhost:5678/webhook-test/enquiry`, with token `test-token-a-agent` and this body:
   ```json
   { "event_id": "ui-1", "name": "Demo", "phone": "052 555 0000", "message": "How much is P1?" }
   ```
3. The nodes turn green one by one. Click any node to see its input and output.

Test runs don't trigger the error-alert workflow. That's why Test 8 uses the normal `/webhook/` URL.

---

## If something looks wrong

| You see | Why | Fix |
|---|---|---|
| `"duplicate": true` when you didn't expect it | that `event_id` was already used | use a new id (e.g. `e7`), or redo Step 0 |
| `lead_id` isn't 2 | not a clean start | doesn't matter; check it stays the **same** in Tests 4 and 5 |
| `404` from `localhost:5678/webhook/enquiry` | workflow not active | run `./scripts/import_n8n.sh` |
| Postman "Could not send request" | web Postman can't reach localhost | use the Postman desktop app |
| `permission denied ... docker.sock` | terminal not in the docker group yet | run `newgrp docker` |
