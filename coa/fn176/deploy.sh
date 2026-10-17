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
    log "creating .env with a fresh database password"
    pw="$(openssl rand -hex 16)"
    sed -e "s|^COA_DB_ROOT_PASSWORD=.*|COA_DB_ROOT_PASSWORD=${pw}|" .env.example > .env
    chmod 600 .env
fi
set -a; . ./.env; set +a
IMAGE="${COA_IMAGE:-$IMAGE_DEFAULT}"
: "${COA_DB_ROOT_PASSWORD:?empty}"

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

python3 - <<'PY'
import pathlib, re
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

patch('config/worldserver.conf', [
    (r'^DataDir\s*=.*$',                  'DataDir = "/azerothcore/env/dist/data"'),
    (r'^LogsDir\s*=.*$',                  'LogsDir = "/azerothcore/env/dist/logs"'),
    (r'^Updates\.EnableDatabases\s*=.*$', 'Updates.EnableDatabases = 0'),
    (r'^SOAP\.Enabled\s*=.*$',            'SOAP.Enabled = 1'),
    (r'^Ra\.Enable\s*=.*$',               'Ra.Enable = 1'),
    (r'^Ra\.IP\s*=.*$',                   'Ra.IP = "0.0.0.0"'),
])
patch('config/authserver.conf', [
    (r'^LogsDir\s*=.*$', 'LogsDir = "/azerothcore/env/dist/logs"'),
])
PY
chown -R 1000:1000 config logs 2>/dev/null || true
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
