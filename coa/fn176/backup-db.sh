#!/usr/bin/env bash
# CoA database snapshot -- scheduled mysqldump of all three acore_* databases.
#
# Restore (from the deployment directory, e.g. /vol1/1000/docker/coa-fn176):
#   ./backup-db.sh --restore backups/coa-all-<stamp>.sql.gz
# which stops worldserver+authserver, recreates the three databases and loads the
# dump back in (worldserver is restarted afterwards).
#
# Schedule (installed by deploy.sh): every 6 hours, retention 14 days / newest 20.
# The dump is written through the coa-database container so the root password never
# appears in host argv or in the process list.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="${COA_BACKUP_DIR:-$DIR/backups}"
LOG="${COA_BACKUP_LOG:-$DIR/logs/backup.log}"
KEEP_DAYS="${COA_BACKUP_KEEP_DAYS:-14}"
KEEP_COUNT="${COA_BACKUP_KEEP_COUNT:-20}"
DB_CONTAINER="${COA_DB_CONTAINER:-coa-database}"
DBS=(acore_auth acore_characters acore_world)

mkdir -p "$BACKUP_DIR"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

dump() {
  local stamp out tmp
  stamp="$(date '+%Y%m%d-%H%M%S')"
  out="$BACKUP_DIR/coa-all-$stamp.sql.gz"
  tmp="$out.part"
  log "snapshot -> $out"
  docker exec -e DBS="${DBS[*]}" "$DB_CONTAINER" sh -c '
      set -e
      export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
      exec mysqldump -uroot --single-transaction --quick --routines --triggers --events \
        --set-gtid-purged=OFF --no-tablespaces --max-allowed-packet=1G \
        --databases $DBS
    ' | gzip -1 >"$tmp"
  # An empty/failed dump must not be kept: mysqldump exits non-zero on error and
  # `set -o pipefail` above propagates it, but check the payload anyway.
  if [ ! -s "$tmp" ] || ! gzip -t "$tmp" 2>/dev/null; then
    rm -f "$tmp"; log "ERROR snapshot failed (empty or corrupt), kept nothing"; return 1
  fi
  mv "$tmp" "$out"
  sha256sum "$out" >"$out.sha256"
  log "OK $(du -h "$out" | cut -f1) $(sha256sum "$out" | cut -c1-16)…"
  prune
}

prune() {
  local f
  # by age
  while IFS= read -r f; do rm -f "$f" "$f.sha256"; log "pruned (age) $(basename "$f")"; done \
    < <(find "$BACKUP_DIR" -maxdepth 1 -name 'coa-all-*.sql.gz' -mtime "+$KEEP_DAYS" | sort)
  # by count
  while IFS= read -r f; do rm -f "$f" "$f.sha256"; log "pruned (count) $(basename "$f")"; done \
    < <(find "$BACKUP_DIR" -maxdepth 1 -name 'coa-all-*.sql.gz' | sort | head -n "-$KEEP_COUNT")
}

restore() {
  local file="$1"
  [ -f "$file" ] || { echo "no such dump: $file" >&2; exit 1; }
  gzip -t "$file" || { echo "corrupt dump: $file" >&2; exit 1; }
  log "RESTORE from $file"
  docker stop coa-worldserver coa-authserver >/dev/null 2>&1 || true
  docker exec -i "$DB_CONTAINER" sh -c '
      set -e
      for db in '"${DBS[*]}"'; do
        mysql -uroot -e "DROP DATABASE IF EXISTS $db; CREATE DATABASE $db DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;"
      done
    '
  gunzip -c "$file" | docker exec -i "$DB_CONTAINER" sh -c '
      export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
      exec mysql -uroot --max-allowed-packet=1G
    '
  log "OK restore finished, starting servers"
  (cd "$DIR" && docker compose up -d coa-authserver coa-worldserver >/dev/null)
  log "OK servers up"
}

case "${1:-}" in
  --restore) restore "${2:?usage: backup-db.sh --restore <dump.sql.gz>}" ;;
  ""|--run)  dump ;;
  *) echo "usage: $0 [--run|--restore <dump.sql.gz>]" >&2; exit 2 ;;
esac
