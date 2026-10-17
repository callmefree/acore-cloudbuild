#!/usr/bin/env bash
# Run a worldserver console command through the SOAP endpoint.
#
#   ./botcmd.sh "botcmd spawnleveled 200"
#   ./botcmd.sh "botcmd spawnrandom 10"
#   ./botcmd.sh "server info"
#   ./botcmd.sh "account create tester tester"
#
# Needs SOAP.Enabled = 1 in worldserver.conf (deploy.sh sets it) and the port
# published in docker-compose.yml (7878 by default).
set -euo pipefail
cd "$(dirname "$0")"
set -a; . ./.env; set +a
: "${COA_SOAP_PASSWORD:?empty}"

CMD="${*:?usage: botcmd.sh <console command>}"
HOST="${COA_SOAP_HOST:-127.0.0.1}"
PORT="${COA_SOAP_EXTERNAL_PORT:-7878}"
esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

body=$(cat <<EOF
<?xml version="1.0" encoding="utf-8"?>
<SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" xmlns:ns1="urn:AC">
  <SOAP-ENV:Body>
    <ns1:executeCommand>
      <command>$(esc "$CMD")</command>
    </ns1:executeCommand>
  </SOAP-ENV:Body>
</SOAP-ENV:Envelope>
EOF
)

reply=$(curl -sS -u "coa:${COA_SOAP_PASSWORD}" \
    -H 'Content-Type: text/xml; charset=utf-8' \
    --data "$body" "http://${HOST}:${PORT}/" || true)

# strip the SOAP envelope, keep the result text
printf '%s' "$reply" \
    | sed -e 's|<SOAP-ENV:Envelope[^>]*>||' -e 's|</SOAP-ENV:Envelope>||' \
          -e 's|<[^>]*>||g' \
    | sed -e 's/&lt;/</g' -e 's/&gt;/>/g' -e 's/&quot;/"/g' -e 's/&amp;/\&/g'
printf '\n'
