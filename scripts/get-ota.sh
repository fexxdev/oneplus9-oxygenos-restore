#!/usr/bin/env bash
# Chiede a Oxygen Updater l'ultimo full OTA OxygenOS per OnePlus 9 e lo scarica (con resume + verifica MD5).
# Uso: ./get-ota.sh [EU|NA|IN]      (default: EU = LE2113)
set -euo pipefail

REGION="${1:-EU}"
case "$REGION" in
  EU) DID=52 ;;   # OnePlus 9 (EU)  LE2113
  NA) DID=56 ;;   # OnePlus 9 (NA)  LE2115
  IN) DID=53 ;;   # OnePlus 9 (IN)  LE2111
  *) echo "Regione non valida: $REGION (usa EU, NA o IN)"; exit 1 ;;
esac
MID=2   # Stable (full)
UA='Oxygen_updater_6.6.0'
API='https://oxygenupdater.com/api/v2.10'

for t in curl jq; do command -v "$t" >/dev/null || { echo "Manca $t (brew install $t)"; exit 1; }; done
if command -v md5 >/dev/null; then md5of() { md5 -q "$1"; }; else md5of() { md5sum "$1" | cut -d' ' -f1; }; fi

cd "$(dirname "$0")"

echo "==> Chiedo l'ultimo full OTA per OnePlus 9 ($REGION, device $DID)..."
JSON="$(curl -fsS -A "$UA" "$API/mostRecentUpdateData/$DID/$MID")"
URL="$(jq -r '.download_url // empty' <<<"$JSON")"
VER="$(jq -r '.version_number // empty' <<<"$JSON")"
OTA="$(jq -r '.ota_version_number // empty' <<<"$JSON")"
MD5="$(jq -r '.md5sum // empty' <<<"$JSON")"
SIZE="$(jq -r '.download_size // 0' <<<"$JSON")"

[ -n "$URL" ] || { echo "Nessun link nella risposta:"; jq . <<<"$JSON"; exit 1; }

echo "    Versione : $VER"
echo "    OTA      : $OTA"
echo "    Size     : $(awk -v s="$SIZE" 'BEGIN{printf "%.2f GB", s/1e9}')"
echo "    MD5      : $MD5"
echo "    URL      : $URL"

OUT="${VER//[()]/_}_full.zip"; OUT="${OUT//__/_}"
if [ -f "$OUT" ] && [ -n "$MD5" ] && [ "$(md5of "$OUT")" = "$MD5" ]; then
  echo "==> $OUT già presente e MD5 OK"; exit 0
fi

echo "==> Scarico in $(pwd)/$OUT (riprende se interrotto)"
curl -fL -C - --retry 5 --retry-delay 5 -o "$OUT" "$URL"

if [ -n "$MD5" ]; then
  echo "==> Verifico MD5..."
  GOT="$(md5of "$OUT")"
  if [ "$GOT" = "$MD5" ]; then echo "MD5 OK -> ora: ./flash-fw.sh \"$OUT\" --extract-only"
  else echo "MD5 SBAGLIATO ($GOT != $MD5). Cancella il file e riprova."; exit 1; fi
fi
