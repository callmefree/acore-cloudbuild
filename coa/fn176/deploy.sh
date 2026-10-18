#!/usr/bin/env bash
# Deploy (or refresh) the CoA server on fn176 from the image built by
# .github/workflows/coa-linux-image.yml.
#
#   ./deploy.sh            full deploy / refresh
#   ./deploy.sh config     only re-seed and patch the configuration
#
set -euo pipefail
cd "$(dirname "$0")"

IMAGE_DEFAULT=ghcr.io/callmefree/coa-server:latest
log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }

if [ ! -f .env ]; then
    log "creating .env with fresh database and SOAP passwords"
    sed -e "s|^COA_DB_ROOT_PASSWORD=.*|COA_DB_ROOT_PASSWORD=$(openssl rand -hex 16)|" \
        -e "s|^COA_SOAP_PASSWORD=.*|COA_SOAP_PASSWORD=$(openssl rand -hex 12)|" .env.example > .env
    chmod 600 .env
elif ! grep -q '^COA_SOAP_PASSWORD=..' .env; then
    printf 'COA_SOAP_PASSWORD=%s\n' "$(openssl rand -hex 12)" >> .env
fi
set -a; . ./.env; set +a
IMAGE="${COA_IMAGE:-$IMAGE_DEFAULT}"
: "${COA_DB_ROOT_PASSWORD:?empty}"
: "${COA_SOAP_PASSWORD:?empty}"
PROXY="${COA_HTTPS_PROXY:-http://127.0.0.1:7890}"

if docker image inspect "$IMAGE" >/dev/null 2>&1 && [ "${COA_FORCE_PULL:-0}" != 1 ]; then
    log "using local image ${IMAGE} (COA_FORCE_PULL=1 to pull anyway)"
else
    log "pulling ${IMAGE}"
    docker pull "$IMAGE"
fi

# ------------------------------------------------------------------ configuration
log "seeding config/ from the image templates (existing files are kept)"
mkdir -p config data logs
id="$(docker create "$IMAGE")"
tmp="$(mktemp -d)"
docker cp "$id:/azerothcore/env/ref/etc/." "$tmp/" >/dev/null
docker rm -f "$id" >/dev/null
cp -rn "$tmp/." config/
rm -rf "$tmp"

for c in worldserver authserver dbimport; do
    [ -f "config/$c.conf" ] || cp "config/$c.conf.dist" "config/$c.conf"
done
for f in config/modules/*.conf.dist; do
    [ -e "$f" ] || continue
    [ -f "${f%.dist}" ] || cp "$f" "${f%.dist}"
done

# CoA Bots reads the community talent builds (classId:specId -> talent picks) from
# CoaBots.TalentBuildsPath.  That file lives in the module repository, not in the
# image, so keep a copy in config/ and point the module config at it.
if [ ! -s config/coa-bots-level-builds.json ]; then
    log "fetching CoA Bots talent builds (reference/ascensionsidekick-level-builds.json)"
    curl -fsSL -x "$PROXY" -o config/coa-bots-level-builds.json.part \
        https://raw.githubusercontent.com/Corfirean/mod-coa-playerbots/master/reference/ascensionsidekick-level-builds.json \
        && mv config/coa-bots-level-builds.json.part config/coa-bots-level-builds.json \
        || { log "  [warn] download failed - CoaBots.TalentBuildsPath will not resolve"; rm -f config/coa-bots-level-builds.json.part; }
fi

# The CoA Bots module keeps two character tables in its release payload
# (dist/sql/...) instead of in module/src/data/sql, so dbimport never applies them.
# Keep a copy in config/extra-sql; the database step below loads it.
mkdir -p config/extra-sql
if ! compgen -G "config/extra-sql/*.sql" >/dev/null; then
    log "fetching CoA Bots extra SQL (dist/sql/2026_09_15_00_ascension_character_selection.sql)"
    f=config/extra-sql/2026_09_15_00_ascension_character_selection.sql
    curl -fsSL -x "$PROXY" -o "$f.part" \
        https://raw.githubusercontent.com/Corfirean/mod-coa-playerbots/master/dist/sql/2026_09_15_00_ascension_character_selection.sql \
        && mv "$f.part" "$f" \
        || { log "  [warn] download failed - character_ascension_state/account_ascension_settings stay missing"; rm -f "$f.part"; }
fi

python3 - <<'PY'
import os, pathlib, re
def patch(path, rules):
    f = pathlib.Path(path)
    if not f.exists():
        print('  [skip]', path); return
    text = f.read_text()
    for pat, rep in rules:
        text, n = re.subn(pat, rep, text, count=1, flags=re.M)
        if not n:
            print('  [warn] pattern not found in', path, '->', pat)
    f.write_text(text)
    print('  patched', path)

def ensure(path, pairs):
    """Add key = value lines that the shipped .conf.dist does not know about yet.

    They are inserted right below the first [worldserver] header so the keys land
    in the section the module reads.
    """
    f = pathlib.Path(path)
    if not f.exists():
        print('  [skip]', path); return
    lines = f.read_text().splitlines()
    for key, value in pairs:
        if any(re.match(r'^\s*' + re.escape(key) + r'\s*=', ln) for ln in lines):
            continue
        for i, ln in enumerate(lines):
            if ln.strip().lower() == '[worldserver]':
                lines.insert(i + 1, f'{key} = {value}')
                print('  added', key, 'to', path)
                break
    f.write_text('\n'.join(lines) + '\n')

# SOAP and the telnet remote console (Ra.*) authenticate against an account in the
# auth database, not against config keys - this fork's worldserver.conf has neither
# SOAP.Username nor SOAP.Password.  Create the account with ./botcmd.sh
# "account create <user> <pass>" and "./botcmd.sh account set gmlevel <user> 3 -1".
# (The console session runs at security level 4 - SEC_CONSOLE - so 4 is refused with
# "You have low security level for this."; 3 = SEC_ADMINISTRATOR is what you want.)
patch('config/worldserver.conf', [
    (r'^DataDir\s*=.*$',                  'DataDir = "/azerothcore/env/dist/data"'),
    (r'^LogsDir\s*=.*$',                  'LogsDir = "/azerothcore/env/dist/logs"'),
    (r'^Updates\.EnableDatabases\s*=.*$', 'Updates.EnableDatabases = 0'),
    (r'^SOAP\.Enabled\s*=.*$',            'SOAP.Enabled = 1'),
    (r'^SOAP\.IP\s*=.*$',                 'SOAP.IP = "0.0.0.0"'),
    (r'^SOAP\.Port\s*=.*$',               'SOAP.Port = 7878'),
    (r'^Ra\.Enable\s*=.*$',               'Ra.Enable = 1'),
    (r'^Ra\.IP\s*=.*$',                   'Ra.IP = "0.0.0.0"'),
    (r'^Ra\.Port\s*=.*$',                 'Ra.Port = 3443'),
    # 195 CoA bots saturate the single map-update thread (cpu ~105%, one core); two
    # threads keep the update diff low.  Raise further if more bot-heavy maps run.
    (r'^MapUpdate\.Threads\s*=.*$',       'MapUpdate.Threads = 2'),
])
patch('config/authserver.conf', [
    (r'^LogsDir\s*=.*$', 'LogsDir = "/azerothcore/env/dist/logs"'),
])
# CoA Bots: point the module at the talent file in this config directory (mounted at
# env/dist/etc inside the container) and log existing bots in on every startup.
# Bots themselves are created with ./botcmd.sh spawnleveled <count>.
patch('config/modules/mod_coa_playerbots.conf', [
    (r'^CoaBots\.TalentBuildsPath\s*=.*$',
     'CoaBots.TalentBuildsPath = "/azerothcore/env/dist/etc/coa-bots-level-builds.json"'),
    (r'^CoaBots\.AutoLoginOnStartup\s*=.*$', 'CoaBots.AutoLoginOnStartup = 1'),
    # a restart replays auto-login; 800 bots at once is far more than fn176 wants
    (r'^CoaBots\.AutoLogin\.MaxCount\s*=.*$', 'CoaBots.AutoLogin.MaxCount = 200'),
])
# Two keys the module reads but its .conf.dist does not ship (upstream gap) - without
# them the worldserver logs "Config: Missing property ..." on every start.
ensure('config/modules/mod_coa_playerbots.conf', [
    ('CoA.CollectionsForBots', '0'),
    ('CoA.RandomBotAccountPrefix', '"rndbot"'),
])

def ensure_from_file(path, frag):
    """Merge key = value lines from a fragment file into the [worldserver] section.

    extra-config.conf holds the ~33 fork options whose defaults the core falls back
    to silently; adding them is behaviour-neutral and removes the startup
    'Config: Missing property ...' lines.
    """
    f, g = pathlib.Path(path), pathlib.Path(frag)
    if not f.exists() or not g.exists():
        print('  [skip]', path, frag); return
    pairs = []
    for ln in g.read_text().splitlines():
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        key, _, value = ln.partition('=')
        pairs.append((key.strip(), value.strip()))
    ensure(path, pairs)

ensure_from_file('config/worldserver.conf', 'extra-config.conf')
PY
chown -R 1000:1000 config logs 2>/dev/null || true
chmod 600 config/coa-bots-level-builds.json 2>/dev/null || true
chmod +x watchdog.sh backup-db.sh botcmd.sh build-from-artifact.sh 2>/dev/null || true
[ "${1:-deploy}" = config ] && exit 0

# ------------------------------------------------------------------ database
log "starting coa-database"
docker compose up -d coa-database
for _ in $(seq 1 60); do
    st="$(docker inspect -f '{{.State.Health.Status}}' coa-database 2>/dev/null || echo none)"
    [ "$st" = healthy ] && break
    sleep 5
done
echo "database health: ${st:-unknown}"

# The supported database source is the pre-built dump that ships with the official
# install-base package (or linux-unsigned's Database/baseline/*.sql.zst), because the
# raw core SQL chain does not rebuild a consistent database (see README "Database").
# COA_DB_SOURCE=dbimport keeps the from-scratch experiment available.
if [ "${COA_DB_SOURCE:-baseline}" = dbimport ]; then
    log "importing databases with dbimport (from-scratch, experimental)"
    docker compose run --rm coa-db-import
elif [ -n "${COA_DB_BASELINE:-}" ] && [ -r "${COA_DB_BASELINE}" ]; then
    log "restoring the database baseline from ${COA_DB_BASELINE}"
    case "$COA_DB_BASELINE" in
        *.gz)  zcat "$COA_DB_BASELINE" ;;
        *.zst) zstd -dc "$COA_DB_BASELINE" ;;
        *)     cat "$COA_DB_BASELINE" ;;
    esac | docker exec -i coa-database mysql -uroot -p"${COA_DB_ROOT_PASSWORD}" \
              --max-allowed-packet=1GB
else
    log "no database baseline given - keeping the databases as they are"
    log "set COA_DB_BASELINE=<dump.sql[.gz|.zst]> (see README, dump-official-db.sh)"
fi

# The CoA Bots module keeps these two character tables in its release payload
# (dist/sql/...) rather than in module/src/data/sql, so dbimport never sees them.
# Both statements are CREATE TABLE IF NOT EXISTS, so re-applying them is harmless.
if compgen -G "config/extra-sql/*.sql" >/dev/null; then
    log "applying extra SQL from config/extra-sql to acore_characters"
    for f in config/extra-sql/*.sql; do
        echo "  -> $f"
        docker exec -i coa-database mysql -uroot -p"${COA_DB_ROOT_PASSWORD}" \
            acore_characters < "$f"
    done
fi

log "pointing realm 1 at ${COA_REALM_ADDRESS}"
docker exec coa-database mysql -uroot -p"${COA_DB_ROOT_PASSWORD}" -e \
    "UPDATE acore_auth.realmlist
        SET address='${COA_REALM_ADDRESS}', localAddress='${COA_REALM_ADDRESS}',
            port=${COA_WORLD_EXTERNAL_PORT}
      WHERE id=1;
     SELECT id, name, address, port, flag FROM acore_auth.realmlist;"

# ------------------------------------------------------------------ register site
# The account-registration page used to run on the old server
# (192.168.1.89 C:\COA\CoA-Repack\WebRegister).  It now runs here as its own
# container and writes SRP6 salt/verifier straight into acore_auth.account, so the
# accounts it creates exist on THIS realm.  It uses a dedicated least-privilege MySQL
# account; the two coa_qq_* tables it creates on first start need CREATE/ALTER.
if [ "${COA_REGISTER_ENABLE:-1}" = 1 ]; then
    log "preparing the account-registration service (coa-register)"
    settings=webregister/context/Settings
    if [ ! -s "$settings/database.json" ]; then
        mkdir -p "$settings"
        printf '{\n  "appUser": "acore",\n  "appPassword": "%s"\n}\n' "$(openssl rand -hex 12)" \
            > "$settings/database.json"
        chmod 600 "$settings/database.json"
    fi
    printf '{\n  "mysqlHost": "coa-database",\n  "mysqlPort": 3306,\n  "authPort": %s,\n  "worldPort": %s,\n  "realmAddress": "%s"\n}\n' \
        "${COA_AUTH_EXTERNAL_PORT:-3724}" "${COA_WORLD_EXTERNAL_PORT:-8085}" "$COA_REALM_ADDRESS" \
        > "$settings/repack.json"
    APP_PW="$(python3 -c "import json;print(json.load(open('$settings/database.json'))['appPassword'])")"
    docker exec -i coa-database mysql -uroot -p"${COA_DB_ROOT_PASSWORD}" <<SQL
CREATE USER IF NOT EXISTS 'acore'@'%' IDENTIFIED BY '${APP_PW}';
ALTER USER 'acore'@'%' IDENTIFIED BY '${APP_PW}';
GRANT SELECT, INSERT, UPDATE, DELETE ON acore_auth.* TO 'acore'@'%';
GRANT SELECT ON acore_characters.* TO 'acore'@'%';
GRANT CREATE, ALTER, INDEX, DROP ON acore_auth.* TO 'acore'@'%';
FLUSH PRIVILEGES;
SQL
    if [ -s webregister/context/WebRegister/register_server.py ]; then
        docker compose build coa-register
    else
        log "  [warn] webregister/context/WebRegister/register_server.py missing - coa-register cannot build"
    fi
    # Public ingress stays off on purpose: the site becomes reachable only after the
    # cutover, when the "tunnel" profile is started and the VPS nginx vhost proxies
    # to the frps port this frpc publishes.  See README "Register site".
    [ -s frpc.toml ] && log "  frpc.toml found - start ingress with: docker compose --profile tunnel up -d coa-frpc"
fi

# ------------------------------------------------------------------ servers
log "starting authserver + worldserver"
docker compose up -d
sleep 5
docker compose ps

# ------------------------------------------------------------------ self-healing + snapshots
# Two cron jobs in the deploying user's crontab (no root needed):
#   watchdog.sh  - every 2 min: restart coa-* containers that are down or whose
#                  healthcheck (3724/8085) has failed twice in a row.
#   backup-db.sh - every 6 h: mysqldump the three acore_* databases into backups/,
#                  keep 14 days / newest 20 dumps.
log "installing cron jobs (watchdog every 2 min, database snapshot every 6 h)"
DIR="$(pwd)"
if command -v crontab >/dev/null 2>&1; then
    marker='# coa-stack'
    cron_tmp="$(mktemp)"
    crontab -l 2>/dev/null | grep -vF "$marker" > "$cron_tmp" || true
    cat >> "$cron_tmp" <<EOF
*/2 * * * * $DIR/watchdog.sh >> $DIR/logs/watchdog.cron.log 2>&1 $marker
17 */6 * * * $DIR/backup-db.sh >> $DIR/logs/backup.cron.log 2>&1 $marker
EOF
    if crontab "$cron_tmp"; then
        rm -f "$cron_tmp"
        crontab -l | grep -F "$marker"
    else
        log "  [warn] could not install the crontab - run watchdog.sh/backup-db.sh manually"
        rm -f "$cron_tmp"
    fi
else
    log "  [warn] no crontab command - run watchdog.sh/backup-db.sh manually"
fi
# ------------------------------------------------------------------ client DBC tables
# The player client carries DBC rows the official server package does not (86 extra
# CharBaseInfo race/class combinations for the CoA custom classes, 4 extra
# SpellCustomAttr rows) and the core reads the player's own display tables from
# Data/dbc_clientset.  Both gaps make the worldserver silently drop content, so install
# them whenever a client extraction is available.  See README "Client DBC tables".
if [ -n "${COA_CLIENT_DBC_DIR:-}" ] && [ -d "${COA_CLIENT_DBC_DIR}" ]; then
    log "installing client DBC tables from $COA_CLIENT_DBC_DIR"
    bash "$(dirname "$0")/patch-client-dbc.sh" "$COA_CLIENT_DBC_DIR"
else
    log "client DBC tables: skipped (export COA_CLIENT_DBC_DIR=<client dbc dir> to install them)"
fi

echo
echo "logs:     docker compose logs -f coa-worldserver coa-authserver"
echo "console:  ./botcmd.sh \"server info\""
echo "watchdog: tail -f logs/watchdog.log        snapshot: ./backup-db.sh"
