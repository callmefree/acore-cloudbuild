#!/usr/bin/env bash
# Produce a restorable SQL dump from the pre-built MySQL data directory that ships
# inside the official install-base package (Corfirean/coa-server-build, release tag
# server-0.261015.58, assets install-base.tar.zst.001/.002).
#
# That data directory was created by MySQL 8.4 on Windows, so it must be served with
# --lower-case-table-names=1 (the data dictionary was created with 1) before it can be
# dumped.  Verified on fn176 with mysql:8.4 (8.4.11 upgrades a 8.4.9 data dictionary in
# place and then serves it normally).
#
#   ./dump-official-db.sh /vol1/1000/docker/coa-fn176/root /vol1/1000/docker/coa-fn176/baseline-dump.sql.gz
#
# Result (fn176, install-base server-0.261015.58):
#   dump 113 MB gzipped; acore_auth 22 / acore_characters 20 / acore_world 3025 rows in
#   `updates`, coa_boss_schedule already carries the effect_d0..d3 columns.
#
# Restore with:  COA_DB_BASELINE=<dump> ./deploy.sh
set -euo pipefail

SRC="${1:?usage: dump-official-db.sh <repack-root-dir> <out.sql.gz>}"
OUT="${2:?usage: dump-official-db.sh <repack-root-dir> <out.sql.gz>}"
DATADIR="${SRC%/}/mysql/data"
WORKDIR="$(cd "$(dirname "$OUT")" && pwd)/mysql-src"
CTR=coa-mysql-src

[ -d "$DATADIR" ] || { echo "no MySQL data directory at $DATADIR" >&2; exit 1; }

echo "== staging a copy of $DATADIR (mysqld writes to its data directory)"
rm -rf "$WORKDIR"; mkdir -p "$WORKDIR"
cp -a "$DATADIR" "$WORKDIR/data"

echo "== serving the copy (lower_case_table_names=1, no grants needed for a dump)"
docker rm -f "$CTR" >/dev/null 2>&1 || true
docker run -d --name "$CTR" -v "$WORKDIR/data:/var/lib/mysql" mysql:8.4 \
    --lower-case-table-names=1 --skip-log-bin --skip-grant-tables >/dev/null
for _ in $(seq 1 60); do
    docker exec "$CTR" mysqladmin -uroot ping >/dev/null 2>&1 && break
    sleep 2
done
docker exec "$CTR" mysql -uroot -N -e \
    "select 'auth',count(*) from acore_auth.updates
     union all select 'characters',count(*) from acore_characters.updates
     union all select 'world',count(*) from acore_world.updates;"

echo "== dumping acore_auth / acore_characters / acore_world -> $OUT"
docker exec "$CTR" mysqldump -uroot \
    --databases acore_auth acore_characters acore_world \
    --single-transaction --routines --triggers --events \
    --set-gtid-purged=OFF --no-tablespaces | gzip -1 > "$OUT"

docker rm -f "$CTR" >/dev/null
rm -rf "$WORKDIR"
echo "== done: $(stat -c%s "$OUT") bytes"
