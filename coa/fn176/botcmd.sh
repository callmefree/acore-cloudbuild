#!/usr/bin/env bash
# Send a console command to the running worldserver.
#
#   ./botcmd.sh "botcmd spawnleveled 200"
#   ./botcmd.sh "botcmd spawnrandom 10"
#   ./botcmd.sh "server info"
#   ./botcmd.sh "account create local local"
#   ./botcmd.sh "account set gmlevel local 4 -1"
#
# The worldserver container runs with an open stdin and a tty, so its console is
# driven with `docker attach`.  That needs no SOAP or remote-access credentials
# (this fork's worldserver.conf has no SOAP.Username/SOAP.Password keys: SOAP and
# the telnet remote console both authenticate against an auth-database account
# with a high security level, so create one with the two commands above).
set -euo pipefail
cd "$(dirname "$0")"

CMD="${*:?usage: botcmd.sh <console command>}"
SRV="${COA_WORLD_CONTAINER:-coa-worldserver}"
WAIT="${COA_CONSOLE_WAIT:-6}"
TIMEOUT="${COA_CONSOLE_TIMEOUT:-25}"

[ "$(docker inspect -f '{{.State.Running}}' "$SRV" 2>/dev/null || echo no)" = true ] \
    || { echo "container $SRV is not running" >&2; exit 1; }

# Feed the command, let the server answer, then close the attach.
{ printf '%s\n' "$CMD"; sleep "$WAIT"; } \
    | timeout "$TIMEOUT" docker attach --detach-keys='' "$SRV" 2>&1 || true
