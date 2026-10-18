#!/usr/bin/env bash
# Rebuild the CoA client-side supplement package from pinned upstream sources.
# Pinned ref (jealous-sound/azerothcore-wotlk-coa): 7c0ba643782eeec4814350f312fc0adfde5960c6
# Contains only client-side files; no MPQ, no client binaries, no realmlist changes.
set -euo pipefail
REF="${COA_UPSTREAM_REF:-7c0ba643782eeec4814350f312fc0adfde5960c6}"
REPO="https://raw.githubusercontent.com/jealous-sound/azerothcore-wotlk-coa/$REF"
OUT="$(cd "$(dirname "$0")" && pwd)"
DEST="$OUT/patch-files"
PROXY="${COA_HTTPS_PROXY:-http://127.0.0.1:7890}"
get() { curl -fsSL -x "$PROXY" "$REPO/$1" -o "$2"; }
mkdir -p "$DEST/Interface/Icons" "$DEST/Interface/AddOns/AncientEnchantingAltars" "$DEST/Interface/AddOns/CoACrowsCache"
get modules/mod-ethereal-bazaar/client-art/INV_GrootCoin.blp "$DEST/Interface/Icons/INV_GrootCoin.blp"
get client/AncientEnchantingAltars/AncientEnchantingAltars.toc "$DEST/Interface/AddOns/AncientEnchantingAltars/AncientEnchantingAltars.toc"
get client/AncientEnchantingAltars/OutlandAltarPOIs.lua "$DEST/Interface/AddOns/AncientEnchantingAltars/OutlandAltarPOIs.lua"
get client-addons/CoACrowsCache/CoACrowsCache.toc "$DEST/Interface/AddOns/CoACrowsCache/CoACrowsCache.toc"
get client-addons/CoACrowsCache/CoACrowsCache.lua "$DEST/Interface/AddOns/CoACrowsCache/CoACrowsCache.lua"
cp "$OUT/README-CN.txt" "$DEST/README-CN.txt"
expected=3ca16759835b0974b8ec799a50f4024c6c9fcde636221f19e056b348e6b435ca
actual=$(sha256sum "$DEST/Interface/Icons/INV_GrootCoin.blp" | cut -d' ' -f1)
[ "$actual" = "$expected" ] || { echo "INV_GrootCoin.blp hash mismatch: $actual" >&2; exit 1; }
head -c 4 "$DEST/Interface/Icons/INV_GrootCoin.blp" | grep -q BLP2 || { echo "not a BLP2 file" >&2; exit 1; }
rm -f "$OUT/coa-client-update.zip"
( cd "$DEST" && zip -qr "$OUT/coa-client-update.zip" . )
echo "built $OUT/coa-client-update.zip"; sha256sum "$OUT/coa-client-update.zip"
