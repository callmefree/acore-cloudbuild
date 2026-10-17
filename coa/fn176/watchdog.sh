#!/usr/bin/env bash
# CoA stack watchdog -- host-side self-healing (installed by deploy.sh as a cron job).
#
# Why: docker's `restart: unless-stopped` covers a crashed process, but not a
# worldserver that is still alive while the world port no longer answers (deadlock,
# stalled IO, half-dead session). The compose healthchecks probe 3724/8085; this
# script turns "unhealthy" into an actual restart, and also picks up containers that
# are simply not running (e.g. after a docker daemon hiccup).
#
# A restart sends SIGTERM first, which AzerothCore handles by saving characters
# (stop_grace_period: 60s in docker-compose.yml gives it time before SIGKILL).
#
# Usage:  ./watchdog.sh            # one pass (cron default: every 2 minutes)
#         ./watchdog.sh --dry-run  # report only, do not restart
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG="${COA_WATCHDOG_LOG:-$DIR/logs/watchdog.log}"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# Containers we own. coa-db-import is deliberately absent: it is a "tools" profile
# one-shot job that is expected to exit.
CONTAINERS=(coa-database coa-authserver coa-worldserver)
UNHEALTHY_STRIKES="${COA_WATCHDOG_STRIKES:-2}"   # consecutive unhealthy probes before restart
STRIKE_DIR="${COA_WATCHDOG_STATE:-$DIR/.watchdog}"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }
rotate_log() { [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ] && mv -f "$LOG" "$LOG.1"; }

rotate_log
mkdir -p "$STRIKE_DIR" 2>/dev/null || true

if ! docker info >/dev/null 2>&1; then
  log "WARN docker daemon not reachable, nothing to do"
  exit 0
fi

restart() { # $1 = container, $2 = reason
  if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN would restart $1 ($2)"; return 0; fi
  log "RESTART $1 ($2)"
  if docker restart -t 60 "$1" >>"$LOG" 2>&1; then
    log "OK $1 restarted"
    rm -f "$STRIKE_DIR/$1.strikes"
  else
    log "ERROR restart of $1 failed"
  fi
}

problems=0
strikes_total=0

for c in "${CONTAINERS[@]}"; do
  state="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null)" || { log "WARN $c not found"; problems=$((problems + 1)); continue; }
  if [ "$state" != "running" ]; then
    problems=$((problems + 1))
    restart "$c" "state=$state"
    continue
  fi

  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null)"
  if [ "$health" != "unhealthy" ]; then
    rm -f "$STRIKE_DIR/$c.strikes"
    continue
  fi

  strikes=0
  [ -f "$STRIKE_DIR/$c.strikes" ] && strikes="$(cat "$STRIKE_DIR/$c.strikes" 2>/dev/null || echo 0)"
  strikes=$((strikes + 1))
  strikes_total=$((strikes_total + 1))
  echo "$strikes" >"$STRIKE_DIR/$c.strikes"
  if [ "$strikes" -ge "$UNHEALTHY_STRIKES" ]; then
    problems=$((problems + 1))
    restart "$c" "unhealthy x$strikes"
  else
    log "WARN $c unhealthy (strike $strikes/$UNHEALTHY_STRIKES)"
  fi
done

# Hourly heartbeat: without it an empty log cannot be told apart from "cron not
# running".  Actions/restarts are logged as they happen, above.
hb="$STRIKE_DIR/last-heartbeat"
hour="$(date '+%Y%m%d%H')"
if [ "$(cat "$hb" 2>/dev/null)" != "$hour" ]; then
  printf '%s\n' "$hour" >"$hb"
  log "heartbeat: problems=$problems unhealthy_strikes=$strikes_total"
fi
