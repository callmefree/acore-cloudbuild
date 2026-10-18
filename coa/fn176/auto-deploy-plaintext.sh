#!/bin/bash
# Wait for a coa-linux-image run, build the local image from its artifact and recreate
# the game containers with it.  Used for the 2026-10-18 plaintext-world-header fix
# (run 39042202484 -> image sha256:8e6f751d...); kept as the unattended-deploy helper.
#
#   ./auto-deploy-plaintext.sh <run_id> <image_tag>
#
# Needs: ~/.ghtok (repo scope), curl, python3, zstd, unzip, docker, and the PAT of the
# workflow's repository.  Writes auto-deploy.log next to itself.
set -u
cd "$(dirname "$0")"
RUN="${1:?usage: auto-deploy-plaintext.sh <run_id> <image_tag>}"
TAG="${2:?usage: auto-deploy-plaintext.sh <run_id> <image_tag>}"
LOG=auto-deploy.log
log(){ echo "$(date '+%F %T') $*" >> "$LOG"; }
T=$(cat ~/.ghtok); PX=${PROXY_URL:-http://127.0.0.1:7890}

log "waiting for run $RUN (tag $TAG)"
for i in $(seq 1 150); do
  st=$(curl -sS -x "$PX" -H "Authorization: Bearer $T" \
       "https://api.github.com/repos/callmefree/acore-cloudbuild/actions/runs/$RUN" \
       | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['status'],d.get('conclusion'))" 2>/dev/null)
  log "poll $i: $st"
  case "$st" in
    "completed success") break ;;
    completed*) log "RUN FAILED: $st"; exit 1 ;;
  esac
  sleep 60
done

log "building local image from the artifact"
./build-from-artifact.sh "$TAG" "$RUN" >> "$LOG" 2>&1 || { log "build-from-artifact FAILED"; exit 1; }
docker tag "coa-server:$TAG" coa-server:local

log "config keys in place:"
grep -n 'CoA\.\(Enable\|AllowRemoteClients\|PlaintextWorldHeaders\)' config/worldserver.conf >> "$LOG" 2>&1

log "checking the new binary understands the option"
docker run --rm --entrypoint sh "coa-server:local" -c \
  'grep -ac PlaintextWorldHeaders /azerothcore/env/dist/bin/worldserver || true' >> "$LOG" 2>&1

log "recreating coa-authserver + coa-worldserver"
docker compose up -d coa-authserver coa-worldserver >> "$LOG" 2>&1
sleep 75
docker compose ps >> "$LOG" 2>&1
./botcmd.sh "server info" >> "$LOG" 2>&1 || true
log "DONE"
