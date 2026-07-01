#!/usr/bin/env bash
# pg-export.sh — SAFE first step of the Hanzo V8 Postgres decommission.
#
# Dumps every INTERNAL logical database off the shared `sql` Postgres to the
# operator desktop BEFORE any migration or shutdown. Read-only on the source; it
# never drops, alters, or flips anything. Nothing here is destructive.
#
# Reaches the cluster via `kubectl exec` into the Postgres pod's OWN pg_dump, so
# the dump is produced by the exact server version (no client/server skew) — the
# local box does not need postgresql-client installed.
#
# Usage:  scripts/pg-export.sh
# Env:    NS (default hanzo) · POD (default sql-0) · PGUSER (default hanzo)
#         DEST (default ~/Desktop/hanzo-pg-export) · CTX (kube-context, optional)
#
# The managed-Postgres PRODUCT (pgx provisioner offering + Neon cloud-sql) is NOT
# dumped here — it is customer data that stays running (see migration.yaml
# keep_postgres_product).
set -euo pipefail

NS="${NS:-hanzo}"
POD="${POD:-sql-0}"
PGUSER="${PGUSER:-hanzo}"
DEST="${DEST:-$HOME/Desktop/hanzo-pg-export}"
KUBECTL="kubectl"
[ -n "${CTX:-}" ] && KUBECTL="kubectl --context $CTX"

mkdir -p "$DEST"
echo "→ exporting internal Postgres from $NS/$POD (user=$PGUSER) to $DEST"

# Resolve the password from the in-cluster secret (never printed, never committed).
PGPASSWORD="$($KUBECTL -n "$NS" get secret postgres-credentials \
  -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
export PGPASSWORD

kx() { $KUBECTL -n "$NS" exec -i "$POD" -- env PGPASSWORD="$PGPASSWORD" "$@"; }

# Enumerate real (non-template) databases on the instance.
mapfile -t DBS < <(kx psql -U "$PGUSER" -tAc \
  "SELECT datname FROM pg_database WHERE datistemplate=false AND datname<>'postgres';" \
  | tr -d '\r')

if [ "${#DBS[@]}" -eq 0 ]; then
  echo "!! no databases enumerated — check NS/POD/PGUSER and cluster access"; exit 1
fi

echo "→ databases: ${DBS[*]}"
FAIL=0
for db in "${DBS[@]}"; do
  [ -z "$db" ] && continue
  out="$DEST/${db}.sql.gz"
  echo "  · pg_dump $db → $out"
  # -Fp plain SQL (portable into the pg2sqlite tools), streamed + gzipped locally.
  if kx pg_dump -U "$PGUSER" --no-owner --no-privileges "$db" | gzip > "$out"; then
    sz=$(du -h "$out" | cut -f1)
    echo "    ok ($sz)"
  else
    echo "    !! FAILED — $db"; FAIL=1; rm -f "$out"
  fi
done

echo "→ verifying dumps are non-empty + gunzip-clean"
for f in "$DEST"/*.sql.gz; do
  [ -e "$f" ] || continue
  if gzip -t "$f" 2>/dev/null && [ "$(stat -c%s "$f")" -gt 100 ]; then
    echo "  ✓ $(basename "$f")"
  else
    echo "  ✗ $(basename "$f") — suspect"; FAIL=1
  fi
done

if [ "$FAIL" -ne 0 ]; then
  echo "‼ export incomplete — do NOT proceed to convert/flip/shutdown"; exit 1
fi
echo "✓ export complete + verified in $DEST — safe to proceed to convert (-verify)"
