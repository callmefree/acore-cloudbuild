#!/usr/bin/env bash
# Entrypoint for the CoA server image (worldserver / authserver / dbimport).
set -euo pipefail

CONF_DIR="${AC_CONF_DIR:-/azerothcore/env/dist/etc}"
LOGS_DIR="${AC_LOGS_DIR:-/azerothcore/env/dist/logs}"
DATA_DIR="${AC_DATA_DIR:-/azerothcore/env/dist/data}"
TEMP_DIR="${AC_TEMP_DIR:-/azerothcore/env/dist/temp}"

mkdir -p "$CONF_DIR" "$CONF_DIR/modules" "$LOGS_DIR" "$LOGS_DIR/reports" "$DATA_DIR" "$TEMP_DIR" 2>/dev/null || true

# Seed the mounted configuration directory from the templates baked at build time.
if [ -d /azerothcore/env/ref/etc ]; then
    cp -rn /azerothcore/env/ref/etc/. "$CONF_DIR/" 2>/dev/null || true
fi

COMPONENT="${ACORE_COMPONENT:-unknown}"
if [ "$COMPONENT" != "unknown" ]; then
    CONF="$CONF_DIR/$COMPONENT.conf"
    DIST="$CONF_DIR/$COMPONENT.conf.dist"
    if [ ! -f "$CONF" ]; then
        if [ -f "$DIST" ]; then
            cp "$DIST" "$CONF"
            echo "[ENTRYPOINT] initialised $CONF from $COMPONENT.conf.dist"
        else
            touch "$CONF"
            echo "[ENTRYPOINT] created empty $CONF (no template found)"
        fi
    fi
fi

echo "[ENTRYPOINT] component=${COMPONENT} conf=${CONF_DIR} data=${DATA_DIR} logs=${LOGS_DIR}"
exec "$@"
