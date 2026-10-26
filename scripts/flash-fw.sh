#!/usr/bin/env bash
# Flash firmware OnePlus 9 (lemonade) da un full OTA OxygenOS 14 (o dallo zip LineageOS).
# Lista partizioni = device/oneplus/lemonade/proprietary-firmware.txt (lineage-24.0)
#   base: LE2115_14.0.0.1902(EX01) | abl pinnato a OOS 13.1.0.593 (abl OOS14 fa crashare il bootloader)
# Uso: ./flash-fw.sh <ota.zip | payload.bin> [--with-abl] [--extract-only]
set -euo pipefail

PARTS=(aop bluetooth cpucp devcfg dsp engineering_cdt featenabler hyp imagefv keymaster
       modem multiimgoem oplus_sec oplusstanvbk qupfw qweslicstore shrm splash tz
       uefisecapp xbl xbl_config)
ABL_SHA1="4875db77f095947337b42d6e48f7a7510f56f4ed"   # abl pinnato da LineageOS

SRC="${1:?Uso: $0 <ota.zip|payload.bin> [--with-abl] [--extract-only]}"; shift || true
WITH_ABL=0; EXTRACT_ONLY=0
for a in "$@"; do case "$a" in --with-abl) WITH_ABL=1;; --extract-only) EXTRACT_ONLY=1;; esac; done

for t in payload-dumper-go fastboot adb unzip shasum; do
  command -v "$t" >/dev/null || { echo "Manca: $t"; [ "$t" = payload-dumper-go ] && echo "  -> https://github.com/ssut/payload-dumper-go/releases (darwin_arm64), mettilo nel PATH"; [ "$t" = fastboot ] && echo "  -> brew install --cask android-platform-tools"; exit 1; }
done

WORK="$(cd "$(dirname "$0")" && pwd)/work"; OUT="$WORK/fw"; mkdir -p "$OUT"
if [[ "$SRC" == *.zip ]]; then
  echo "==> Estraggo payload.bin da $SRC"; unzip -o -q "$SRC" payload.bin -d "$WORK"; PAYLOAD="$WORK/payload.bin"
else PAYLOAD="$SRC"; fi

LIST=("${PARTS[@]}"); LIST+=(abl)
echo "==> Estraggo: ${LIST[*]}"
payload-dumper-go -o "$OUT" -p "$(IFS=,; echo "${LIST[*]}")" "$PAYLOAD"

missing=0; for p in "${LIST[@]}"; do [ -s "$OUT/$p.img" ] || { echo "!! manca $p.img"; missing=1; }; done
[ $missing -eq 0 ] || { echo "Payload incompleto o non è un full OTA. Stop."; exit 1; }

ABL_OK=0; [ "$(shasum -a 1 "$OUT/abl.img" | cut -d' ' -f1)" = "$ABL_SHA1" ] && ABL_OK=1
if [ $ABL_OK -eq 1 ]; then echo "==> abl.img = quello pinnato da LineageOS (OOS 13.1.0.593): verrà flashato"; FLASH=("${PARTS[@]}" abl)
elif [ $WITH_ABL -eq 1 ]; then echo "!! abl.img NON è quello pinnato (probabilmente OOS14): lo flasho perché hai chiesto --with-abl"; FLASH=("${PARTS[@]}" abl)
else echo "==> abl.img è di OOS14: lo SALTO (LineageOS usa l'abl di OOS13). --with-abl per forzarlo"; FLASH=("${PARTS[@]}"); fi

( cd "$OUT" && shasum -a 1 *.img > SHA1SUMS ); echo "==> Immagini in $OUT"
[ $EXTRACT_ONLY -eq 1 ] && exit 0

echo; echo "Telefono acceso con debug USB, oppure in Lineage Recovery (adb abilitato)."
read -r -p "Proseguo con il riavvio in fastbootd? [y/N] " ok; [ "$ok" = y ] || exit 0
adb reboot fastboot || true
echo "==> Attendo fastbootd..."; until fastboot devices | grep -q .; do sleep 1; done
[ "$(fastboot getvar is-userspace 2>&1 | awk '/is-userspace/{print $2}')" = "yes" ] || { echo "Non sono in fastbootd. Stop."; exit 1; }
[ "$(fastboot getvar product 2>&1 | awk '/product/{print $2}')" = "lahaina" ] || echo "!! product != lahaina, controlla il device"

for p in "${FLASH[@]}"; do echo "==> $p"; fastboot flash --slot=all "$p" "$OUT/$p.img"; done
echo; echo "Fatto. Ora: fastboot reboot recovery -> Apply update -> ADB -> adb sideload lineage-24...zip"
