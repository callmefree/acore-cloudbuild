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

log "pulling ${IMAGE}"
docker pull "$IMAGE"

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

# SOAP and the telnet remote console (Ra.*) authenticate against an account in the
# auth database, not against config keys - this fork's worldserver.conf has neither
# SOAP.Username nor SOAP.Password.  Create the account with ./botcmd.sh
# "account create <user> <pass>" and "./botcmd.sh account set gmlevel <user> 4 -1".
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
])
PY
chown -R 1000:1000 config logs 2>/dev/null || true
chmod 600 config/coa-bots-level-builds.json 2>/dev/null || true
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

log "importing databases with dbimport (first run takes a while)"
docker compose run --rm coa-db-import

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

# ------------------------------------------------------------------ servers
log "starting authserver + worldserver"
docker compose up -d
sleep 5
docker compose ps
echo
echo "logs:  docker compose logs -f coa-worldserver coa-authserver"
