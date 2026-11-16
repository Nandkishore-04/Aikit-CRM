#!/usr/bin/env bash
# Runs every required evidence case against the live stack, prints PASS/FAIL,
# and saves the full output to evidence/results.txt.
# Prereq: docker compose up -d --build && ./scripts/import_n8n.sh
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

CRM=http://localhost:8000
N8N=http://localhost:5678/webhook/enquiry
A_ADMIN="Authorization: Bearer test-token-a-admin"
A_AGENT="Authorization: Bearer test-token-a-agent"
B_AGENT="Authorization: Bearer test-token-b-agent"
JSON="Content-Type: application/json"
RUN=$(date +%s)                         # unique per run -> fresh event ids / phones
PHONE_LOCAL="05${RUN: -8}"              # e.g. 0512345678
PHONE_INTL="+971 5${RUN: -8:1} ${RUN: -7:3} ${RUN: -4}"   # same number, different format
PHONE_NORM="9715${RUN: -8}"
OUT=evidence/results.txt
PASSES=0; FAILS=0

exec > >(tee "$OUT") 2>&1

sql() { docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "$1"; }
# req <curl args...> -> prints body, sets $CODE
req() { local tmp; tmp=$(mktemp); CODE=$(curl -s -o "$tmp" -w '%{http_code}' "$@"); BODY=$(cat "$tmp"); rm -f "$tmp"; }
check() {  # check "<name>" <condition-exit-code> "<detail>"
  if [[ "$2" == "0" ]]; then echo "PASS  $1  | $3"; PASSES=$((PASSES+1));
  else echo "FAIL  $1  | $3"; FAILS=$((FAILS+1)); fi
}

echo "=== AiKit evidence run $(date -Is)  commit $(git rev-parse --short HEAD) ==="
echo

# 0. Unit tests for the normaliser (inside the mock-crm container)
UT=$(docker compose exec -T mock-crm python -m pytest -q -p no:warnings tests 2>&1)
check "0  normaliser unit tests" $? "$(tail -1 <<<"$UT")"

# 1. Logged out -> 401
req "$CRM/admin/leads"
[[ $CODE == 401 ]]; check "1  logged-out denied (401)" $? "HTTP $CODE $BODY"

# 2. Non-admin on admin endpoint -> 403
req -H "$A_AGENT" "$CRM/admin/leads"
[[ $CODE == 403 ]]; check "2  non-admin denied (403)" $? "HTTP $CODE $BODY"

# 3. Tenant A reads Tenant B's lead -> 404 (B itself can read it: control)
req -H "$B_AGENT" -H "$JSON" -d "{\"event_id\":\"ev-b-$RUN\",\"name\":\"B customer\",\"phone\":\"0559$RUN\"}" "$CRM/leads/upsert"
B_LEAD=$(jq -r .lead.id <<<"$BODY")
req -H "$B_AGENT" "$CRM/leads/$B_LEAD"; B_CODE=$CODE
req -H "$A_ADMIN" "$CRM/leads/$B_LEAD"
[[ $CODE == 404 && $B_CODE == 200 ]]; check "3  cross-tenant denied (404)" $? "B lead $B_LEAD: tenant_b=$B_CODE, tenant_a=$CODE $BODY"

# 4. Same event twice via n8n -> one lead, second says duplicate
EV="ev-dup-$RUN"
PAYLOAD="{\"event_id\":\"$EV\",\"name\":\"Dup Test\",\"phone\":\"$PHONE_LOCAL\",\"email\":\"dup.$RUN@example.test\",\"message\":\"What is the price of P1?\"}"
req -H "$A_AGENT" -H "$JSON" -d "$PAYLOAD" "$N8N"; FIRST="$BODY"
req -H "$A_AGENT" -H "$JSON" -d "$PAYLOAD" "$N8N"; SECOND="$BODY"
ROWS=$(sql "select count(*) from leads where tenant_id='tenant_a' and phone_norm='$PHONE_NORM'")
[[ $(jq -r .duplicate <<<"$FIRST") == false && $(jq -r .duplicate <<<"$SECOND") == true && $ROWS == 1 ]]
check "4  duplicate event deduped" $? "2nd response duplicate=$(jq -r .duplicate <<<"$SECOND"), lead rows=$ROWS"
LEAD_ID=$(jq -r .lead_id <<<"$FIRST")

# 5. Same customer, different phone format, new event -> updates same lead
req -H "$A_AGENT" -H "$JSON" -d "{\"event_id\":\"ev-fmt-$RUN\",\"name\":\"Dup Test\",\"phone\":\"$PHONE_INTL\",\"message\":\"What is the price of P1?\"}" "$N8N"
ROWS=$(sql "select count(*) from leads where tenant_id='tenant_a' and phone_norm='$PHONE_NORM'")
[[ $(jq -r .lead_id <<<"$BODY") == "$LEAD_ID" && $ROWS == 1 ]]
check "5  reformatted phone -> same lead" $? "'$PHONE_LOCAL' vs '$PHONE_INTL' -> lead $(jq -r .lead_id <<<"$BODY") (expected $LEAD_ID), rows=$ROWS"

# 6. Price question -> AED 1,000,000 + citation
req -H "$A_AGENT" -H "$JSON" -d "{\"event_id\":\"ev-price-$RUN\",\"phone\":\"$PHONE_LOCAL\",\"message\":\"How much is P1?\"}" "$N8N"
[[ $(jq -r .answer <<<"$BODY") == *"AED 1,000,000"* && $(jq -r .citation.fact_id <<<"$BODY") != null ]]
check "6  price answered with citation" $? "$(jq -c '{answer,citation}' <<<"$BODY")"

# 7. Availability -> no guess + handoff row
req -H "$A_AGENT" -H "$JSON" -d "{\"event_id\":\"ev-avail-$RUN\",\"phone\":\"$PHONE_LOCAL\",\"message\":\"Is P1 still available?\"}" "$N8N"
HID=$(jq -r .handoff_id <<<"$BODY")
HROW=$(sql "select reason from handoffs where id=${HID/null/0} and tenant_id='tenant_a'")
[[ $(jq -r .handoff <<<"$BODY") == true && $(jq -r .answer <<<"$BODY") == *"don't have confirmed"* && -n "$HROW" ]]
check "7  availability -> no guess + handoff" $? "answer='$(jq -r .answer <<<"$BODY")' handoff_id=$HID reason=$HROW"

# 8. Forced 500 x5 -> exactly 3 attempts (bounded), caller gets 500, alert row written
ALERTS_BEFORE=$(sql "select count(*) from alerts")
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
req -X POST -H "$A_ADMIN" "$CRM/_debug/fail-next?count=5"
T0=$(date +%s%N)
req -H "$A_AGENT" -H "$JSON" -d "{\"event_id\":\"ev-fail-$RUN\",\"phone\":\"$PHONE_LOCAL\",\"message\":\"price of P1?\"}" "$N8N"
FAIL_CODE=$CODE; ELAPSED=$(( ($(date +%s%N)-T0)/1000000 ))
for i in $(seq 1 15); do   # error workflow runs async; wait up to 15s for the alert
  ALERTS_AFTER=$(sql "select count(*) from alerts"); [[ $ALERTS_AFTER -gt $ALERTS_BEFORE ]] && break; sleep 1
done
req -H "$A_ADMIN" "$CRM/_debug/stats"; ATTEMPTS=$(jq -r .upsert_attempts <<<"$BODY"); LEFT=$(jq -r .fail_next <<<"$BODY")
echo "      mock-crm log for this request:"
docker compose logs --no-log-prefix --since "$SINCE" mock-crm 2>/dev/null | grep -E "fail injection armed|injected 500" | sed 's/^/        /'
echo "      latest alert: $(sql "select id||' | '||source||' | '||message from alerts order by id desc limit 1")"
[[ $FAIL_CODE == 500 && $ATTEMPTS == 3 && $LEFT == 2 && $ALERTS_AFTER -gt $ALERTS_BEFORE ]]
check "8  500 -> bounded retry (3) + alert" $? "caller HTTP $FAIL_CODE after ${ELAPSED}ms, attempts=$ATTEMPTS, unused failures=$LEFT, alerts $ALERTS_BEFORE->$ALERTS_AFTER"

# 9. Recovery: one transient 500 -> retry succeeds
req -X POST -H "$A_ADMIN" "$CRM/_debug/fail-next?count=1"
req -H "$A_AGENT" -H "$JSON" -d "{\"event_id\":\"ev-recover-$RUN\",\"phone\":\"$PHONE_LOCAL\",\"message\":\"price of P1?\"}" "$N8N"
OK_CODE=$CODE; OK_BODY="$BODY"
req -H "$A_ADMIN" "$CRM/_debug/stats"; ATTEMPTS=$(jq -r .upsert_attempts <<<"$BODY")
[[ $OK_CODE == 200 && $ATTEMPTS == 2 && $(jq -r .answer <<<"$OK_BODY") == *"AED 1,000,000"* ]]
check "9  transient 500 -> retry recovers" $? "HTTP $OK_CODE, attempts=$ATTEMPTS, answer='$(jq -r .answer <<<"$OK_BODY")'"

echo
echo "=== SUMMARY: $PASSES passed, $FAILS failed ==="
[[ $FAILS == 0 ]]
