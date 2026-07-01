#!/usr/bin/env bash
# pg-fetch-db.sh — robustly export ONE Postgres DB out of a flaky kube-exec path.
#
# The DOKS apiserver exec/cp stream truncates on transfers >~25MB (unexpected
# EOF), so a single `pg_dump | gzip` stream or one big `kubectl cp` loses data.
# This dumps + gzips ENTIRELY inside the pod, splits into small chunks, and pulls
# each chunk with a MD5-verified retry loop — so a dropped stream just re-pulls
# that chunk. Reassembles + verifies the whole-file md5 before declaring success.
#
# Usage:  pg-fetch-db.sh <db>
# Env:    NS(hanzo) POD(sql-0) DEST(~/Desktop/hanzo-pg-export) CHUNK(8m) TRIES(10)
set -uo pipefail
DB="${1:?usage: pg-fetch-db.sh <db>}"
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
NS="${NS:-hanzo}"; POD="${POD:-sql-0}"
DEST="${DEST:-$HOME/Desktop/hanzo-pg-export}"; CHUNK="${CHUNK:-8m}"; TRIES="${TRIES:-10}"
WORK="$DEST/.$DB-work"; mkdir -p "$WORK"

echo "→ [$DB] dump+gzip+split inside $NS/$POD (chunk=$CHUNK)"
kubectl -n "$NS" exec "$POD" -- sh -c \
  'set -e; PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" --no-owner --no-privileges '"$DB"' | gzip > /tmp/'"$DB"'.sql.gz
   split -b '"$CHUNK"' /tmp/'"$DB"'.sql.gz /tmp/'"$DB"'.part.
   cd /tmp && md5sum '"$DB"'.sql.gz '"$DB"'.part.*' > "$WORK/manifest.txt" 2>/dev/null

if [ ! -s "$WORK/manifest.txt" ]; then echo "  !! dump/split failed"; exit 1; fi
FULL_MD5="$(/usr/bin/grep -E " ${DB}\.sql\.gz$" "$WORK/manifest.txt" | /usr/bin/awk '{print $1}')"
echo "  full md5 (in-pod): $FULL_MD5"

# Pull each chunk with md5-verified retry.
FAIL=0
while read -r want name; do
  case "$name" in *.part.*) ;; *) continue ;; esac
  got=""
  for t in $(seq 1 "$TRIES"); do
    kubectl cp "$NS/$POD:/tmp/$name" "$WORK/$name" >/dev/null 2>&1 || true
    got="$(/usr/bin/md5sum "$WORK/$name" 2>/dev/null | /usr/bin/awk '{print $1}')"
    [ "$got" = "$want" ] && break
    sleep 2
  done
  if [ "$got" = "$want" ]; then echo "  ✓ $name"; else echo "  ✗ $name (gave up after $TRIES)"; FAIL=1; fi
done < "$WORK/manifest.txt"

if [ "$FAIL" -ne 0 ]; then echo "  !! some chunk never verified — NOT writing $DB.sql.gz"; exit 1; fi

# Reassemble in split order + verify whole-file md5.
cat $(/usr/bin/ls -1 "$WORK/$DB".part.* | /usr/bin/sort) > "$DEST/$DB.sql.gz"
LOCAL_MD5="$(/usr/bin/md5sum "$DEST/$DB.sql.gz" | /usr/bin/awk '{print $1}')"
kubectl -n "$NS" exec "$POD" -- sh -c "rm -f /tmp/$DB.sql.gz /tmp/$DB.part.*" >/dev/null 2>&1 || true
rm -rf "$WORK"

if [ "$LOCAL_MD5" = "$FULL_MD5" ] && gzip -t "$DEST/$DB.sql.gz" 2>/dev/null; then
  echo "✓ [$DB] complete + md5-verified — $(/usr/bin/du -h "$DEST/$DB.sql.gz" | /usr/bin/awk '{print $1}')"
else
  echo "✗ [$DB] reassembly md5 mismatch ($LOCAL_MD5 vs $FULL_MD5)"; exit 1
fi
