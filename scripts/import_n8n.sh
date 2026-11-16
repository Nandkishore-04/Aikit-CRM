#!/usr/bin/env bash
# Import both workflows into n8n and activate the enquiry webhook. Idempotent:
# re-importing the same workflow id overwrites it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Error workflow first so the enquiry workflow's settings.errorWorkflow points at a real id.
docker compose exec -T n8n n8n import:workflow --input=/workflows/error_alert.json
docker compose exec -T n8n n8n import:workflow --input=/workflows/enquiry.json
# Error-trigger workflows do not need activating; the webhook workflow does.
docker compose exec -T n8n n8n update:workflow --id=AikitEnquiry0001 --active=true
# CLI activation takes effect on restart.
docker compose restart n8n

# Wait on /healthz rather than calling the webhook: a probe enquiry would itself
# fail auth, retry 3x and write a spurious alert row.
echo "Waiting for n8n..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:5678/healthz >/dev/null; then
    sleep 3   # give active workflows a moment to register their webhooks
    echo "n8n is up: POST http://localhost:5678/webhook/enquiry"; exit 0
  fi
  sleep 1
done
echo "n8n did not come up"; exit 1
