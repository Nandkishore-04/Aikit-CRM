# Test guide: copy and paste into the terminal

Run everything in **one terminal** (the VS Code terminal is fine: **Ctrl + `**), **in order, once**.
Each test has a **copy block** and the result you should **expect**.
The ids (`e1`–`e6`, lead `2`, handoff `1`) assume a fresh start (Step 0).

---

## Step 0: Clean start (do this before recording)

**Copy:**
```bash
newgrp docker
```
(It prints nothing; it just gives this terminal Docker access.)

**Copy:**
```bash
cd ~/Aikit-CRM
docker compose down -v && docker compose up -d --build && ./scripts/import_n8n.sh
```
**Expect:** the last line is `n8n is up: POST http://localhost:5678/webhook/enquiry`

---

## Step 1: Setup shortcuts (paste once)

**Copy:**
```bash
CRM=http://localhost:8000; N8N=http://localhost:5678/webhook/enquiry; J="Content-Type: application/json"
AA="Authorization: Bearer test-token-a-admin"; AG="Authorization: Bearer test-token-a-agent"; BG="Authorization: Bearer test-token-b-agent"
clear; echo "ready"
```
**Expect:** `ready`

| Shortcut | Means |
|---|---|
| `$CRM` | mock CRM at `http://localhost:8000` (stands in for Zoho Bigin) |
| `$N8N` | n8n enquiry webhook at `http://localhost:5678/webhook/enquiry` |
| `$AA` | tenant A **admin** token |
| `$AG` | tenant A **agent** (non-admin) token |
| `$BG` | tenant B agent token |

---

## Test 1: Logged out → 401

**Copy:**
```bash
clear; curl -s -w "  -> HTTP %{http_code}\n" $CRM/admin/leads
```
**Expect:** `{"detail":"missing bearer token"}  -> HTTP 401`

---

## Test 2: Non-admin → 403

**Copy:**
```bash
clear; curl -s -w "  -> HTTP %{http_code}\n" -H "$AG" $CRM/admin/leads
```
**Expect:** `{"detail":"forbidden for role agent"}  -> HTTP 403`

---

## Test 3: Cross-tenant → 404

Lead 1 belongs to **tenant B**. Tenant B can read it; tenant A gets 404 (not 403, so tenant A can't even learn the lead exists).

**Copy:**
```bash
clear
curl -s -o /dev/null -w "tenant B reads lead 1 -> HTTP %{http_code}\n" -H "$BG" $CRM/leads/1
curl -s -w "  -> HTTP %{http_code}\n" -H "$AA" $CRM/leads/1
```
**Expect:**
```
tenant B reads lead 1 -> HTTP 200
{"detail":"lead not found"}  -> HTTP 404
```

---

## Test 4: Same event sent twice → one lead, `duplicate: true`

**Copy:**
```bash
clear
curl -s -H "$AG" -H "$J" -d '{"event_id":"e1","name":"Jane","phone":"050 123 4567","email":"jane@example.test","message":"How much is P1?"}' $N8N | jq -c '{lead_id,duplicate}'
curl -s -H "$AG" -H "$J" -d '{"event_id":"e1","name":"Jane","phone":"050 123 4567","email":"jane@example.test","message":"How much is P1?"}' $N8N | jq -c '{lead_id,duplicate}'
```
**Expect:**
```
{"lead_id":2,"duplicate":false}
{"lead_id":2,"duplicate":true}
```

---

## Test 5: Same customer, phone written differently → existing lead updated

**Copy:**
```bash
clear
curl -s -H "$AG" -H "$J" -d '{"event_id":"e2","name":"Jane D","phone":"+971 50 123 4567","message":"How much is P1?"}' $N8N | jq -c '{lead_id,duplicate}'
curl -s -H "$AA" $CRM/admin/leads | jq -c '.leads[] | {id,name,phone_norm}'
```
**Expect:** a new event (`duplicate:false`) but the **same lead 2**, and only **one** Jane, with her name updated:
```
{"lead_id":2,"duplicate":false}
{"id":2,"name":"Jane D","phone_norm":"971501234567"}
```

---

## Test 6: Price question → AED 1,000,000 + citation

**Copy:**
```bash
clear; curl -s -H "$AG" -H "$J" -d '{"event_id":"e3","phone":"050 123 4567","message":"What is the price of P1?"}' $N8N | jq
```
**Expect:**
```
"answer": "The price of P1 is AED 1,000,000.",
"citation": { "fact_id": 1, "source": "brief:P1-listing-sheet", "property_code": "P1", "field": "price" },
"handoff": false
```

---

## Test 7: Availability → no guess + handoff row

**Copy:**
```bash
clear
curl -s -H "$AG" -H "$J" -d '{"event_id":"e4","phone":"050 123 4567","message":"Is P1 still available?"}' $N8N | jq
docker compose exec -T postgres psql -U crm -d crm -c "select id, lead_id, reason from handoffs"
```
**Expect:**
```
"answer": "I don't have confirmed information on that. ...",
"citation": null,
"handoff": true,
"handoff_id": 1

 id | lead_id |          reason
----+---------+---------------------------
  1 |       2 | no_confirmed_availability
```

---

## Test 8: Forced 500 → exactly 3 attempts → alert row

`fail-next=5` makes the CRM fail its next 5 calls (test-only switch). n8n retries **3** times, gives up, and its error workflow writes an alert.

**Copy:**
```bash
clear
curl -s -X POST -H "$AA" "$CRM/_debug/fail-next?count=5"; echo
curl -s -w "  -> HTTP %{http_code} in %{time_total}s\n" -H "$AG" -H "$J" -d '{"event_id":"e5","phone":"050 123 4567","message":"How much is P1?"}' $N8N
sleep 2
curl -s -H "$AA" $CRM/_debug/stats; echo
docker compose logs mock-crm | grep "injected 500"
docker compose exec -T postgres psql -U crm -d crm -c "select id, source, message from alerts"
```
**Expect:**
```
{"fail_next":5,"upsert_attempts":0}
{"message":"Error in workflow"}  -> HTTP 500 in 2.3s
{"fail_next":2,"upsert_attempts":3}          <- only 3 tries; 2 failures never used = bounded
... upsert attempt 1 -> injected 500 (remaining=4)
... upsert attempt 2 -> injected 500 (remaining=3)
... upsert attempt 3 -> injected 500 (remaining=2)
 1 | n8n:AiKit - Enquiry to CRM | Execution 6 failed at node "Upsert Lead": ...
```
(The execution number may differ.)

---

## Test 9: fail-next=1 → retry recovers

**Copy:**
```bash
clear
curl -s -X POST -H "$AA" "$CRM/_debug/fail-next?count=1"; echo
curl -s -H "$AG" -H "$J" -d '{"event_id":"e6","phone":"050 123 4567","message":"How much is P1?"}' $N8N | jq -c '{lead_id,answer}'
curl -s -H "$AA" $CRM/_debug/stats; echo
```
**Expect:**
```
{"fail_next":1,"upsert_attempts":0}
{"lead_id":2,"answer":"The price of P1 is AED 1,000,000."}
{"fail_next":0,"upsert_attempts":2}          <- 1 failed + 1 succeeded
```

---

## Test 10: Backup → restore into a clean database

**Copy:**
```bash
clear; ./scripts/backup_restore.sh
```
**Expect:** `tables in fresh instance before restore: 0`, every table has original = restored, and the last line is `BACKUP/RESTORE: PASS`

---

## Test 11: Everything again, automated

**Copy:**
```bash
clear; ./scripts/run_evidence.sh
```
**Expect:** `=== SUMMARY: 10 passed, 0 failed ===` (saved to `evidence/results.txt`)

---

## Optional: Show it in the n8n UI

Open http://localhost:5678 and create an owner account (local only, any details).
- **AiKit - Enquiry to CRM → Executions:** the green runs are Tests 4–7 and 9; the **red** run is Test 8, with **Upsert Lead** red.
- **AiKit - Error Alert → Executions:** the run that wrote the Test 8 alert. Click **Write Alert**.

---

## If something goes wrong

| You see | Fix |
|---|---|
| `permission denied ... docker.sock` | run `newgrp docker`, then paste Step 1 again |
| `curl: (3) URL rejected` / empty `$CRM` | you're in a new terminal; paste Step 1 again |
| `"duplicate": true` where it shouldn't be, or the ids don't match | you've already run that test; redo Step 0, then Step 1 |
| `404` from the webhook | run `./scripts/import_n8n.sh` |

A Postman collection with the same cases is in `postman/` (see the README).
