#!/usr/bin/env bash
# backup the crm db, restore into a fresh postgres container,
# compare row counts, then delete the container
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

TS=$(date +%Y%m%d_%H%M%S)
FILE="backups/backup_${TS}.sql"
RESTORE=postgres-restore
TABLES="tenants users leads processed_events property_facts handoffs alerts"

# remove the restore container + its volume when the script ends
cleanup() { docker rm -fv "$RESTORE" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "1) pg_dump -> $FILE"
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --no-owner > "$FILE"
echo "   $(wc -c < "$FILE") bytes"

echo "2) start clean container '$RESTORE' (same pinned image, no named volume, not on app network)"
cleanup
docker run -d --name "$RESTORE" \
  -e POSTGRES_USER="$POSTGRES_USER" -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" -e POSTGRES_DB="$POSTGRES_DB" \
  postgres:16 >/dev/null
# check over tcp - during first start postgres only listens on the socket,
# so this only passes when it's really ready
for i in $(seq 1 60); do
  docker exec "$RESTORE" pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" >/dev/null 2>&1 && break
  sleep 1
done
EMPTY=$(docker exec "$RESTORE" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc \
  "select count(*) from information_schema.tables where table_schema='public'")
echo "   tables in fresh instance before restore: $EMPTY (must be 0)"
[[ "$EMPTY" == 0 ]] || { echo "FAIL: restore target not clean"; exit 1; }

echo "3) restore"
docker exec -i "$RESTORE" psql -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" < "$FILE" >/dev/null

echo "4) verify row counts (original vs restored)"
RESULT=PASS
printf "   %-18s %8s %8s\n" table original restored
for t in $TABLES; do
  o=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from $t")
  r=$(docker exec "$RESTORE" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select count(*) from $t")
  flag=""; [[ "$o" == "$r" ]] || { flag="  <-- MISMATCH"; RESULT=FAIL; }
  printf "   %-18s %8s %8s%s\n" "$t" "$o" "$r" "$flag"
done
# also compare actual lead data, not just counts
o=$(docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select md5(string_agg(id||phone_norm||coalesce(email_norm,''),',' order by id)) from leads")
r=$(docker exec "$RESTORE" psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "select md5(string_agg(id||phone_norm||coalesce(email_norm,''),',' order by id)) from leads")
echo "   leads content md5: original=$o restored=$r"
[[ "$o" == "$r" ]] || RESULT=FAIL

echo "5) cleanup: removing $RESTORE (trap)"
echo "BACKUP/RESTORE: $RESULT  ($FILE)"
[[ $RESULT == PASS ]]
