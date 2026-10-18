#!/usr/bin/env bash
# Import the legacy CoA player data (from 192.168.1.89, staged in coa-legacy-db)
# into a CoA server database.
#
# What is imported:
#   acore_auth.account + the other account tables  -> verbatim, ids preserved
#   acore_auth.coa_qq_bind / coa_qq_verify         -> created if missing, then loaded
#   acore_characters.*                             -> every table that also exists in
#                                                     the target schema, column lists
#                                                     limited to the legacy columns
# What is deliberately NOT imported:
#   acore_playerbots.*            (the old server used upstream playerbots with its own
#                                  database; this deployment uses mod-coa-playerbots,
#                                  whose bots are ordinary rows in acore_characters)
#   playerbots_names, playerbots_guild_names, playerbots_arena_team_names
#                                 (obsolete tables of that other bot system)
#   grootcoin_award_mail          (the target schema added four NOT NULL columns the
#                                  legacy rows cannot fill; only a log table)
#
# The target rows of the imported tables are deleted first, so the character ids match
# the legacy ones and nothing collides.  Take a snapshot first (the script does).
#
#   ./import-legacy-players.sh                    # real run against coa-database
#   COA_TARGET_DB_CONTAINER=coa-target-test ./import-legacy-players.sh
#
# Order of operations: stop worldserver/authserver -> snapshot -> wipe -> load ->
# rebuild the local GM account -> start servers (the post steps are printed, not run,
# when the target is not coa-database).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
set -a; . ./.env; set +a

LEGACY="${COA_LEGACY_DB_CONTAINER:-coa-legacy-db}"
LEGACY_PW="${COA_LEGACY_DB_PASSWORD:-legacy}"
TARGET="${COA_TARGET_DB_CONTAINER:-coa-database}"
TARGET_PW="${COA_TARGET_DB_PASSWORD:-$COA_DB_ROOT_PASSWORD}"
if [ "$TARGET" = coa-database ]; then REAL=coa-database; else REAL=; fi
WORK="$DIR/legacy/import-work"
mkdir -p "$WORK"

CHAR_SKIP=(playerbots_names playerbots_guild_names playerbots_arena_team_names grootcoin_award_mail)
log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
lq() { docker exec "$LEGACY" mysql -uroot -p"$LEGACY_PW" -N -e "$1" 2>/dev/null; }
tq() { docker exec "$TARGET" mysql -uroot -p"$TARGET_PW" -N -e "$1" 2>/dev/null; }
traw() { docker exec -i "$TARGET" mysql -uroot -p"$TARGET_PW" "$@"; }

# ------------------------------------------------------------------ preflight
log "preflight"
for c in "$LEGACY" "$TARGET"; do
    [ "$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" = running ] \
        || { echo "container $c is not running" >&2; exit 1; }
done
l_acc="$(lq "SELECT COUNT(*) FROM acore_auth.account")"
t_acc="$(tq "SELECT COUNT(*) FROM acore_auth.account")"
l_chr="$(lq "SELECT COUNT(*) FROM acore_characters.characters")"
echo "legacy: $l_acc accounts, $l_chr characters   target: $t_acc accounts"

if [ "$REAL" = coa-database ]; then
    log "snapshot before touching the live database"
    ./backup-db.sh | tail -2
    log "stopping servers"
    docker compose stop coa-worldserver coa-authserver >/dev/null
else
    log "dry run against $TARGET - servers stay up"
fi

# ------------------------------------------------------------------ legacy data dumps
log "dumping the legacy rows (data only, complete column lists)"
docker exec "$LEGACY" mysqldump -uroot -p"$LEGACY_PW" \
    --no-create-info --complete-insert --skip-extended-insert --hex-blob \
    --skip-triggers --no-tablespaces --single-transaction \
    acore_auth > "$WORK/legacy-auth.sql" 2>/dev/null
docker exec "$LEGACY" mysqldump -uroot -p"$LEGACY_PW" \
    --no-create-info --complete-insert --skip-extended-insert --hex-blob \
    --skip-triggers --no-tablespaces --single-transaction \
    $(for t in "${CHAR_SKIP[@]}"; do printf -- '--ignore-table=acore_characters.%s ' "$t"; done) \
    acore_characters > "$WORK/legacy-characters.sql" 2>/dev/null
ls -lh "$WORK/legacy-auth.sql" "$WORK/legacy-characters.sql" | awk '{print "  ", $9, $5}'

# ------------------------------------------------------------------ target wipe
log "wiping the target rows of every table that is about to be reloaded"
lq "SELECT table_name FROM information_schema.tables WHERE table_schema='acore_auth'" | sort > "$WORK/l-auth-tables"
lq "SELECT table_name FROM information_schema.tables WHERE table_schema='acore_characters'" | sort > "$WORK/l-char-tables"
tq "SELECT table_name FROM information_schema.tables WHERE table_schema='acore_auth'" | sort > "$WORK/t-auth-tables"
tq "SELECT table_name FROM information_schema.tables WHERE table_schema='acore_characters'" | sort > "$WORK/t-char-tables"

{
    echo "SET FOREIGN_KEY_CHECKS=0;"
    comm -12 "$WORK/l-auth-tables" "$WORK/t-auth-tables" |
        while read -r t; do echo "DELETE FROM \`acore_auth\`.\`$t\`;"; done
    comm -12 "$WORK/l-char-tables" "$WORK/t-char-tables" |
        grep -vxF -f <(printf '%s\n' "${CHAR_SKIP[@]}") |
        while read -r t; do echo "DELETE FROM \`acore_characters\`.\`$t\`;"; done
    echo "SET FOREIGN_KEY_CHECKS=1;"
} | traw acore_auth >/dev/null

# the old registration site kept its QQ binding in two auth tables the current
# schema does not create - bring them along so the site keeps working
log "ensuring the legacy registration tables exist in the target"
{ echo "USE \`acore_auth\`;"; 
  docker exec "$LEGACY" mysqldump -uroot -p"$LEGACY_PW" --no-data --skip-add-drop-table \
    acore_auth coa_qq_bind coa_qq_verify 2>/dev/null |
    sed 's/^CREATE TABLE /CREATE TABLE IF NOT EXISTS /'; } |
    traw acore_auth >/dev/null

# ------------------------------------------------------------------ load
log "loading the legacy rows"
{ echo "SET FOREIGN_KEY_CHECKS=0;"; cat "$WORK/legacy-auth.sql"; echo "SET FOREIGN_KEY_CHECKS=1;"; } | traw acore_auth >/dev/null
{ echo "SET FOREIGN_KEY_CHECKS=0;"; cat "$WORK/legacy-characters.sql"; echo "SET FOREIGN_KEY_CHECKS=1;"; } | traw acore_characters >/dev/null

# ------------------------------------------------------------------ verify
log "verification"
tq "SELECT CONCAT('accounts=', COUNT(*)) FROM acore_auth.account;
    SELECT CONCAT('characters=', COUNT(*)) FROM acore_characters.characters;
    SELECT CONCAT('guilds=', COUNT(*)) FROM acore_characters.guild;
    SELECT CONCAT('orphan characters=', COUNT(*)) FROM acore_characters.characters c
        LEFT JOIN acore_auth.account a ON a.id = c.account WHERE a.id IS NULL;
    SELECT CONCAT('top: ', name, ' lvl ', level, ' ', race, '/', class) FROM acore_characters.characters ORDER BY level DESC LIMIT 5;"

if [ "$REAL" = coa-database ]; then
    log "restarting the servers"
    docker compose up -d coa-authserver coa-worldserver >/dev/null
    echo "the 'local' GM account was wiped with the account table - recreate it:"
    echo "  ./botcmd.sh \"account create local local\""
    echo "  ./botcmd.sh \"account set gmlevel local 3 -1\""
    echo "  ./botcmd.sh \"botcmd spawnleveled 200\""
else
    log "dry run finished - the live database was not touched"
fi
