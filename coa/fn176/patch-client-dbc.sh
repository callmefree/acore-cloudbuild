#!/usr/bin/env bash
# Install the client-side DBC tables the worldserver needs.
#
# The CoA client's DBC set is not a subset of the tables shipped in the official
# server package: it carries 86 extra CharBaseInfo (race, class) combinations for
# the CoA custom classes and 4 extra SpellCustomAttr rows.  The core also looks
# for the player's own copies of the display tables under <DataDir>/dbc_clientset
# and, when they are missing, falls back to streaming every display id >= 652000
# / only the *_dbc rows (see the "Unable to open client DBC" lines in Server.log).
#
# Usage: patch-client-dbc.sh <client-dbc-dir> [data-dir]
#   <client-dbc-dir>  directory of .dbc files extracted from the player client, e.g.
#       python apps/coa-dbc/client_dbc.py extract "<client>/Data" out --original \
#              --mpqcli mpqcli
#   [data-dir]        DataDir of the deployment (default $COA_DATA_DIR or the fn176 path)
set -euo pipefail
SRC=${1:?usage: patch-client-dbc.sh <client-dbc-dir> [data-dir]}
DATA=${2:-${COA_DATA_DIR:-/vol1/1000/docker/coa-fn176/root/Data}}
DBC="$DATA/dbc"
[ -d "$DBC" ] || { echo "no such DBC dir: $DBC" >&2; exit 1; }

# 1. Tables where the client is a strict superset (the server-package copy is kept
#    next to it as *.serverpkg so the change can be undone).
for t in CharBaseInfo.dbc SpellCustomAttr.dbc; do
    [ -f "$SRC/$t" ] || { echo "missing $t in $SRC" >&2; exit 1; }
    [ -f "$DBC/$t.serverpkg" ] || cp -a "$DBC/$t" "$DBC/$t.serverpkg"
    cp -a "$SRC/$t" "$DBC/$t"
    echo "installed $t (server-package copy kept as $t.serverpkg)"
done

# 2. The client-set directory used for display streaming.  Item/ItemAddon/ItemDisplayInfo
#    in the *server* package stay in dbc/ because each has one extra row the world DB
#    references (item 558531, displayid 141229); dbc_clientset must hold what the player
#    already has, i.e. the client's copies.
mkdir -p "$DATA/dbc_clientset"
for t in CreatureDisplayInfo.dbc ItemDisplayInfo.dbc Item.dbc; do
    [ -f "$SRC/$t" ] || { echo "missing $t in $SRC" >&2; exit 1; }
    cp -a "$SRC/$t" "$DATA/dbc_clientset/$t"
    echo "installed dbc_clientset/$t"
done

chmod 644 "$DBC"/*.dbc "$DATA/dbc_clientset"/*.dbc 2>/dev/null || true
echo "done - restart the worldserver: docker compose up -d coa-worldserver"
