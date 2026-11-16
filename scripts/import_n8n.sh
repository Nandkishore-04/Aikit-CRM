#!/usr/bin/env bash
# imports both workflows and activates the enquiry one.
# safe to run again, same id just gets overwritten
set -euo pipefail
cd "$(dirname "$0")/.."

# wait for n8n to be up first. on a fresh volume it's still running
# migrations and the import fails with SQLITE_BUSY
wait_for_n8n() {
  for i in $(seq 1 90); do
    curl -sf http://localhost:5678/healthz >/dev/null && return 0
    sleep 1
  done
  echo "n8n did not come up"; exit 1
}
wait_for_n8n
sleep 2

# error workflow first since the enquiry workflow points to it
docker compose exec -T n8n n8n import:workflow --input=/workflows/error_alert.json
docker compose exec -T n8n n8n import:workflow --input=/workflows/enquiry.json
# error workflow doesn't need to be active, the webhook one does
docker compose exec -T n8n n8n update:workflow --id=AikitEnquiry0001 --active=true
# needs a restart to pick up the activation
docker compose restart n8n

# check /healthz, not the webhook - hitting the webhook without a token
# would fail, retry 3 times and create a fake alert
echo "Waiting for n8n..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:5678/healthz >/dev/null; then
    sleep 3   # give the webhook a sec to register
    echo "n8n is up: POST http://localhost:5678/webhook/enquiry"; exit 0
  fi
  sleep 1
done
echo "n8n did not come up"; exit 1
