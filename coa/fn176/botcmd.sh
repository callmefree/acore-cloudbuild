#!/usr/bin/env bash
# Drive the running worldserver console with a single command.
# Usage: ./botcmd.sh "botcmd spawnleveled 200"
#        ./botcmd.sh "account create local local"
#        ./botcmd.sh "account set gmlevel local 3 -1"
#
# Notes:
#  * the container runs with tty=true, so stdin must arrive through a PTY
#    (`script -qec ...`); a plain pipe makes docker attach fail with
#    "the input device is not a TTY".
#  * docker attach must use --sig-proxy=false, otherwise the `timeout` kill
#    (or Ctrl-C) is forwarded to the worldserver process itself.
#  * the console session has security level 4 (SEC_CONSOLE), so it can only set
#    account security up to 3; `account set gmlevel <user> 4 -1` is rejected with
#    "You have low security level for this."
set -uo pipefail
CMD="${1:?usage: botcmd.sh \"<console command>\"}"
WAIT="${COA_CONSOLE_WAIT:-8}"
TMO="${COA_CONSOLE_TIMEOUT:-30}"
{ printf '%s\n' "$CMD"; sleep "$WAIT"; } | timeout "$TMO" \
  script -qec "docker attach --sig-proxy=false --detach-keys='' coa-worldserver" /dev/null || true
