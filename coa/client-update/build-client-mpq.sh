#!/usr/bin/env bash
# Rebuild the CoA client-side supplement as a single late-loading MPQ: Data/patch-ZG.MPQ
#
# Why an MPQ instead of loose files: this is the upstream way to ship client art for the
# Groot Coin icon.  modules/mod-ethereal-bazaar/client-art/build_client_patch.sh builds a
# patch-ZG.MPQ (sorts after patch-Z / patch-ZH) carrying Interface\Icons\INV_GrootCoin.blp
# for item display id 990001.  A separate late-loading archive leaves every CoA official
# file (patch-B.MPQ / patch-T.MPQ / patch-Z.MPQ) untouched, so upstream client revisions
# never conflict with our supplement.
#
# Pinned upstream ref (jealous-sound/azerothcore-wotlk-coa): 7c0ba643782eeec4814350f312fc0adfde5960c6
# Archive payload (exactly these 5 files):
#   Interface\Icons\INV_GrootCoin.blp
#   Interface\AddOns\AncientEnchantingAltars\{AncientEnchantingAltars.toc,OutlandAltarPOIs.lua}
#   Interface\AddOns\CoACrowsCache\{CoACrowsCache.toc,CoACrowsCache.lua}
# Package payload:
#   Data\patch-ZG.MPQ + README-CN.txt   ->  coa-client-update-mpq.zip
set -euo pipefail

REF="${COA_UPSTREAM_REF:-7c0ba643782eeec4814350f312fc0adfde5960c6}"
REPO="https://raw.githubusercontent.com/jealous-sound/azerothcore-wotlk-coa/$REF"
OUT="$(cd "$(dirname "$0")" && pwd)"
PROXY="${COA_HTTPS_PROXY:-http://127.0.0.1:7890}"
MPQCLI="${COA_MPQCLI:-$OUT/.tools/mpqcli}"
MPQCLI_URL="https://github.com/thegraydot/mpqcli/releases/download/v0.13.0/mpqcli-linux-x86_64"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
UI="$WORK/Interface"
PKG="$WORK/pkg"

get() { curl -fsSL -x "$PROXY" "$REPO/$1" -o "$2"; }

if [ ! -x "$MPQCLI" ]; then
    mkdir -p "$(dirname "$MPQCLI")"
    echo "fetching mpqcli -> $MPQCLI"
    curl -fsSL -x "$PROXY" "$MPQCLI_URL" -o "$MPQCLI"
    chmod +x "$MPQCLI"
fi
echo "mpqcli: $("$MPQCLI" version)"

mkdir -p "$UI/Icons" "$UI/AddOns/AncientEnchantingAltars" "$UI/AddOns/CoACrowsCache"
get modules/mod-ethereal-bazaar/client-art/INV_GrootCoin.blp "$UI/Icons/INV_GrootCoin.blp"
get client/AncientEnchantingAltars/AncientEnchantingAltars.toc "$UI/AddOns/AncientEnchantingAltars/AncientEnchantingAltars.toc"
get client/AncientEnchantingAltars/OutlandAltarPOIs.lua "$UI/AddOns/AncientEnchantingAltars/OutlandAltarPOIs.lua"
get client-addons/CoACrowsCache/CoACrowsCache.toc "$UI/AddOns/CoACrowsCache/CoACrowsCache.toc"
get client-addons/CoACrowsCache/CoACrowsCache.lua "$UI/AddOns/CoACrowsCache/CoACrowsCache.lua"

# --- assertions on the source payload -------------------------------------------------
expected=3ca16759835b0974b8ec799a50f4024c6c9fcde636221f19e056b348e6b435ca
actual=$(sha256sum "$UI/Icons/INV_GrootCoin.blp" | cut -d' ' -f1)
[ "$actual" = "$expected" ] || { echo "INV_GrootCoin.blp hash mismatch: $actual" >&2; exit 1; }
head -c 4 "$UI/Icons/INV_GrootCoin.blp" | grep -q BLP2 || { echo "not a BLP2 file" >&2; exit 1; }

want="Interface\AddOns\AncientEnchantingAltars\AncientEnchantingAltars.toc
Interface\AddOns\AncientEnchantingAltars\OutlandAltarPOIs.lua
Interface\AddOns\CoACrowsCache\CoACrowsCache.lua
Interface\AddOns\CoACrowsCache\CoACrowsCache.toc
Interface\Icons\INV_GrootCoin.blp"

# --- build the MPQ (the -p prefix keeps the Interface\ archive paths) -----------------
# The archive embeds per-file timestamps, so pin them to keep the MPQ byte-reproducible.
find "$UI" -exec touch -d '2026-10-18T00:00:00Z' {} +
mkdir -p "$PKG/Data"
rm -f "$PKG/Data/patch-ZG.MPQ"
"$MPQCLI" create -g wow-wotlk -p Interface "$PKG/Data/patch-ZG.MPQ" "$UI" >/dev/null

have=$("$MPQCLI" list "$PKG/Data/patch-ZG.MPQ" | sort)
[ "$have" = "$(echo "$want" | sort)" ] || { echo "unexpected MPQ payload:"; echo "$have" >&2; exit 1; }

# --- round-trip: extract every member back and compare ---------------------------------
RT="$WORK/rt"
mkdir -p "$RT"
"$MPQCLI" extract -o "$RT" "$PKG/Data/patch-ZG.MPQ" >/dev/null
while IFS= read -r rel; do
    src="$UI/${rel#Interface\\}"
    src="${src//\\//}"
    dst="$RT/${rel//\\//}"
    [ -f "$dst" ] || { echo "missing after extract: $rel" >&2; exit 1; }
    a=$(sha256sum "$src" | cut -d' ' -f1)
    b=$(sha256sum "$dst" | cut -d' ' -f1)
    [ "$a" = "$b" ] || { echo "round-trip mismatch: $rel" >&2; exit 1; }
done <<< "$want"

mpq_sha=$(sha256sum "$PKG/Data/patch-ZG.MPQ" | cut -d' ' -f1)
mpq_size=$(stat -c%s "$PKG/Data/patch-ZG.MPQ")
echo "patch-ZG.MPQ: $mpq_size B  sha256 $mpq_sha"

sed -e "s/__MPQ_SHA256__/$mpq_sha/" -e "s/__MPQ_SIZE__/$mpq_size/" \
    "$OUT/README-CN-mpq.txt" > "$PKG/README-CN.txt"

find "$PKG" -exec touch -d '2026-10-18T00:00:00Z' {} +
rm -f "$OUT/coa-client-update-mpq.zip"
( cd "$PKG" && zip -Xqr "$OUT/coa-client-update-mpq.zip" . )
echo "built $OUT/coa-client-update-mpq.zip"
sha256sum "$OUT/coa-client-update-mpq.zip"
ls -l "$OUT/coa-client-update-mpq.zip"
