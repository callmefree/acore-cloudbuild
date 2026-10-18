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

# 2. The client-set directory used for display streaming.  It mirrors *all* of the
#    client's tables: the core asks this directory for the copies the player already
#    has (CreatureDisplayInfo/ItemDisplayInfo/Item are the ones it names in the log),
#    and a partial set silently degrades to "stream every display id >= 652000" /
#    "stream only the *_dbc rows".  Item/ItemAddon/ItemDisplayInfo in dbc/ stay the
#    server-package versions, because those carry one extra row each that the world
#    DB references (item 558531, displayid 141229).
mkdir -p "$DATA/dbc_clientset"
count=0
for f in "$SRC"/*.dbc; do
    [ -e "$f" ] || continue
    cp -a "$f" "$DATA/dbc_clientset/$(basename "$f")"
    count=$((count + 1))
done
for t in CreatureDisplayInfo.dbc ItemDisplayInfo.dbc Item.dbc; do
    [ -f "$DATA/dbc_clientset/$t" ] || { echo "missing $t in $SRC" >&2; exit 1; }
done
echo "mirrored $count client DBC tables into dbc_clientset/"

chmod 644 "$DBC"/*.dbc "$DATA/dbc_clientset"/*.dbc 2>/dev/null || true
echo "done - restart the worldserver: docker compose up -d coa-worldserver"
