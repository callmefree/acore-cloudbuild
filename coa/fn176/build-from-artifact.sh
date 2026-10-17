#!/usr/bin/env bash
# Assemble the CoA server image on the host from the workflow artifact instead of
# pulling it from GHCR (no registry credentials needed).
#
#   ./build-from-artifact.sh <tag> [run_id]
#   ./build-from-artifact.sh 0.261017.5
#
# Produces image  coa-server:<tag>  and  coa-server:local  and prints the line to
# put into .env:   COA_IMAGE=coa-server:local
#
# Needs: ~/.ghtok (PAT with repo scope), curl, python3, zstd, unzip, docker.
set -euo pipefail
cd "$(dirname "$0")"

REPO=callmefree/acore-cloudbuild
TAG="${1:?usage: build-from-artifact.sh <tag> [run_id]}"
RUN_ID="${2:-}"
TOKEN_FILE="${GITHUB_TOKEN_FILE:-$HOME/.ghtok}"
PROXY_URL="${COA_HTTPS_PROXY:-http://127.0.0.1:7890}"
ART_NAME="coa-server-bin-${TAG}"
WORK="${COA_WORK:-$(pwd)/build-artifact}"
CTX="$WORK/context"

log() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }
TOKEN="$(cat "$TOKEN_FILE")"
API="https://api.github.com/repos/${REPO}"
api() { curl -sS -x "$PROXY_URL" -H "Authorization: Bearer ${TOKEN}" \
             -H 'Accept: application/vnd.github+json' "$@"; }

log "locating artifact ${ART_NAME}"
if [ -z "$RUN_ID" ]; then
    RUN_ID="$(api "${API}/actions/runs?branch=main&per_page=20" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)["workflow_runs"][0]["id"])')"
fi
echo "run: ${RUN_ID}"
ART_ID="$(api "${API}/actions/runs/${RUN_ID}/artifacts?per_page=100" \
    | python3 -c '
import sys, json
name = sys.argv[1]
d = json.load(sys.stdin)
hit = [a for a in d.get("artifacts", []) if a["name"] == name]
if not hit:
    print("", end=""); sys.exit(0)
a = hit[0]
print(a["id"])
' "$ART_NAME")"
if [ -z "$ART_ID" ]; then
    echo "artifact ${ART_NAME} not found in run ${RUN_ID}" >&2
    api "${API}/actions/runs/${RUN_ID}/artifacts" \
        | python3 -c 'import sys,json;[print("  -",a["name"],a["size_in_bytes"]) for a in json.load(sys.stdin).get("artifacts",[])]' >&2
    exit 1
fi
echo "artifact id: ${ART_ID}"

log "downloading artifact"
rm -rf "$WORK"; mkdir -p "$WORK" "$CTX"
curl -sSL -x "$PROXY_URL" -H "Authorization: Bearer ${TOKEN}" \
     -o "$WORK/artifact.zip" "${API}/actions/artifacts/${ART_ID}/zip"
ls -lh "$WORK/artifact.zip"

log "unpacking"
( cd "$WORK" && unzip -o -q artifact.zip )
TARBALL="$(find "$WORK" -name 'coa-server-bin-*.tar.zst' | head -1)"
[ -n "$TARBALL" ] || { echo "no .tar.zst in artifact" >&2; exit 1; }
echo "payload: $(basename "$TARBALL") $(du -h "$TARBALL" | cut -f1)"
zstd -dc "$TARBALL" | tar -x -C "$CTX"
ls -l "$CTX" "$CTX/bin"

log "building runtime image coa-server:${TAG}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Works both in the repository layout (coa/fn176/..) and in the flat deployment
# directory on the host (docker-compose.yml, entrypoint.sh and Dockerfile.runtime
# side by side).
if [ -f "$HERE/Dockerfile.runtime" ]; then
    DOCKERFILE="$HERE/Dockerfile.runtime"; ENTRYPOINT="$HERE/entrypoint.sh"
else
    DOCKERFILE="$HERE/../Dockerfile.runtime"; ENTRYPOINT="$HERE/../entrypoint.sh"
fi
[ -f "$DOCKERFILE" ]  || { echo "Dockerfile.runtime not found next to $HERE" >&2; exit 1; }
[ -f "$ENTRYPOINT" ]  || { echo "entrypoint.sh not found next to $HERE" >&2; exit 1; }
cp "$ENTRYPOINT" "$CTX/entrypoint.sh"
docker build -f "$DOCKERFILE" -t "coa-server:${TAG}" -t coa-server:local "$CTX"

log "smoke test"
docker run --rm --entrypoint /azerothcore/env/dist/bin/worldserver coa-server:local --version
docker run --rm --entrypoint /azerothcore/env/dist/bin/authserver coa-server:local --version

cat <<EOF

== done ==
image:  coa-server:${TAG}  (also tagged coa-server:local)
use:    add or edit  COA_IMAGE=coa-server:local  in .env, then
        ./deploy.sh
EOF
