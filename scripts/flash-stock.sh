#!/usr/bin/env bash
# OnePlus 9 (lemonade) — restore stock OxygenOS from a FULL OTA zip, via fastbootd.
# Bootloader stays unlocked. THIS WIPES ALL DATA.
#
# Usage: flash-stock.sh <full-ota.zip> [--plan] [--extract-only] [--no-stubs]
#   --plan          query the phone and print what would be done, change nothing
#   --extract-only  extract payload images and exit
#   --no-stubs      do not create my_company/my_preload stub partitions
#
# What it does (see README): extract payload -> flash physical partitions to both
# slots -> delete every logical partition in super -> recreate OOS logical
# partitions on the current slot -> flash them -> create the my_* stubs that the
# OOS fstab requires but the OTA does not ship -> wipe.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HERE/bin:$HERE/../bin:$PATH"

SRC="${1:?Usage: $0 <full-ota.zip> [--plan] [--extract-only] [--no-stubs]}"; shift || true
PLAN=0; EXTRACT_ONLY=0; STUBS=1
for a in "$@"; do case "$a" in --plan) PLAN=1;; --extract-only) EXTRACT_ONLY=1;; --no-stubs) STUBS=0;; esac; done
for t in payload-dumper-go fastboot adb unzip python3; do command -v "$t" >/dev/null || { echo "Missing tool: $t"; exit 1; }; done

# Logical partitions (inside super) in OxygenOS. Everything else is physical.
is_known_logical() { case "$1" in system|system_ext|product|vendor|odm|my_*) return 0;; *) return 1;; esac; }
# Required by the OOS fstab (first_stage_mount, no nofail) but absent from full OTAs.
STUB_NAMES=(my_company my_preload)

# ---------- 1. extraction ----------
WORK="$HERE/stock"; IMG="$WORK/images"; mkdir -p "$IMG"
[ -s "$WORK/payload.bin" ] || { echo "==> Extracting payload.bin"; unzip -o -q "$SRC" payload.bin -d "$WORK"; }
[ -n "$(ls -A "$IMG" 2>/dev/null)" ] || { echo "==> Extracting all images"; payload-dumper-go -o "$IMG" "$WORK/payload.bin"; }
PARTS=(); for f in "$IMG"/*.img; do PARTS+=("$(basename "$f" .img)"); done
echo "==> ${#PARTS[@]} images extracted"
[ $EXTRACT_ONLY -eq 1 ] && exit 0

# ---------- 2. helpers ----------
gv()  { fastboot getvar "$1" 2>&1 | awk -v k="$1:" '$1==k{print $2}'; }
waitfb() { until fastboot devices 2>/dev/null | grep -q .; do sleep 1; done; }
fl() {  # fl <partition> <img>: flash with 3 attempts (USB hiccups are common with large images)
  for i in 1 2 3; do fastboot flash "$1" "$2" && return 0; echo "!! '$1' attempt $i failed, retrying in 3s"; sleep 3; waitfb; done
  echo "!! flashing '$1' failed 3 times. Stop."; exit 1; }
fsize() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; }

# ---------- 3. get into fastbootd ----------
if ! fastboot devices 2>/dev/null | grep -q .; then adb reboot fastboot 2>/dev/null || true; fi
echo "==> Waiting for fastboot..."; waitfb
if [ "$(gv is-userspace)" != "yes" ]; then
  echo "==> In bootloader, switching to fastbootd (tap English on the phone if a language screen appears)"
  fastboot reboot fastboot; sleep 3; waitfb
  until [ "$(gv is-userspace)" = "yes" ]; do sleep 2; done
fi
SLOT="$(gv current-slot)"; [ "$SLOT" = a ] && OTHER=b || OTHER=a
SUPER_NAME="$(gv super-partition-name)"; [ -n "$SUPER_NAME" ] || SUPER_NAME=super
SUPER_SIZE=$(( $(gv "partition-size:$SUPER_NAME" 2>/dev/null || echo 0) ))
echo "==> fastbootd OK | slot: $SLOT | $SUPER_NAME = $((SUPER_SIZE/1024/1024)) MB | product: $(gv product)"

# ---------- 4. classification ----------
PHYS=(); LOGICAL=(); UNKNOWN=(); LOGICAL_BYTES=0
for p in "${PARTS[@]}"; do
  if is_known_logical "$p"; then LOGICAL+=("$p"); LOGICAL_BYTES=$((LOGICAL_BYTES + $(fsize "$IMG/$p.img")))
  elif [ -n "$(gv "partition-size:${p}_a")" ]; then PHYS+=("$p")
  else UNKNOWN+=("$p"); fi
done
STUBS_TODO=()
if [ $STUBS -eq 1 ]; then for s in "${STUB_NAMES[@]}"; do [ -f "$IMG/$s.img" ] || STUBS_TODO+=("$s"); done; fi
echo "==> Physical (${#PHYS[@]}, both slots): ${PHYS[*]}"
echo "==> Logical  (${#LOGICAL[@]}, recreated in $SUPER_NAME on slot $SLOT): ${LOGICAL[*]}"
echo "    logical total: $((LOGICAL_BYTES/1024/1024)) MB"
[ ${#STUBS_TODO[@]} -eq 0 ] || echo "==> Stubs to create (required by fstab, not in OTA): ${STUBS_TODO[*]}"
[ ${#UNKNOWN[@]} -eq 0 ] || echo "!! Not on the phone and not known logical (will be SKIPPED): ${UNKNOWN[*]}"
if [ "$SUPER_SIZE" -gt 0 ]; then
  [ "$LOGICAL_BYTES" -lt "$SUPER_SIZE" ] || { echo "!! Logical images do not fit in $SUPER_NAME. Stop."; exit 1; }
else
  echo "!! This fastbootd does not report the super size (OOS fastbootd does not): skipping the capacity check"
fi
EXISTING_LOGICAL="$(fastboot getvar all 2>&1 | sed -n 's/.*is-logical:\([^:]*\): *yes.*/\1/p' | sort -u | tr '\n' ' ')"
echo "==> Logical partitions currently present (ALL will be deleted): $EXISTING_LOGICAL"
[ $PLAN -eq 1 ] && { echo "(--plan: stopping here)"; exit 0; }

echo; echo "WARNING: every partition will be overwritten and ALL DATA ERASED."
read -r -p "Type YES to continue: " ok; [ "$ok" = "YES" ] || exit 0

# ---------- 5. physical partitions ----------
fastboot snapshot-update cancel >/dev/null 2>&1 || true
for p in "${PHYS[@]}"; do echo "==> [physical] $p"; fl "${p}_a" "$IMG/$p.img"; fl "${p}_b" "$IMG/$p.img"; done

# ---------- 6. rebuild super ----------
echo "==> Deleting all existing logical partitions"
for lp in $EXISTING_LOGICAL; do fastboot delete-logical-partition "$lp" >/dev/null 2>&1 && echo "    - $lp" || echo "    ? $lp (not deleted)"; done
echo "==> Creating OOS logical partitions on slot $SLOT"
for p in "${LOGICAL[@]}"; do
  sz=$(fsize "$IMG/$p.img")
  fastboot create-logical-partition "${p}_${SLOT}" "$sz" >/dev/null 2>&1 || { echo "!! create-logical-partition ${p}_${SLOT} ($sz) failed. Stop."; exit 1; }
  echo "    + ${p}_${SLOT} ($((sz/1024/1024)) MB)"
done
for p in "${LOGICAL[@]}"; do echo "==> [logical] $p"; fl "${p}_${SLOT}" "$IMG/$p.img"; done

# ---------- 7. stubs for my_company / my_preload ----------
if [ ${#STUBS_TODO[@]} -gt 0 ]; then
  [ -f "$IMG/my_carrier.img" ] || { echo "!! my_carrier.img not found, cannot build stubs. Stop."; exit 1; }
  python3 "$HERE/make-stub-images.py" "$IMG/my_carrier.img" "$WORK/stubs" "${STUBS_TODO[@]}"
  for s in "${STUBS_TODO[@]}"; do
    sz=$(fsize "$WORK/stubs/$s.img")
    fastboot create-logical-partition "${s}_${SLOT}" "$sz" >/dev/null 2>&1 || { echo "!! create-logical-partition ${s}_${SLOT} failed. Stop."; exit 1; }
    echo "==> [stub] $s"; fl "${s}_${SLOT}" "$WORK/stubs/$s.img"
  done
fi

# ---------- 8. active slot, data ----------
fastboot set_active "$SLOT" >/dev/null 2>&1 || fastboot --set-active="$SLOT" >/dev/null 2>&1 || true
echo "==> Erasing userdata/metadata (formatting happens in the OOS recovery)"
fastboot -w >/dev/null 2>&1 || true

echo; echo "============================================================"
echo "DONE. Next, a REAL reboot is required (not 'fastboot reboot recovery' from this fastbootd,"
echo "which may only switch back to the recovery already in RAM):"
echo "   fastboot reboot bootloader        -> then choose 'Recovery mode' with the volume keys"
echo "In the OxygenOS recovery: English -> Wipe data and cache -> Erase everything -> Reboot."
echo "First boot takes 5-10 minutes. Then install the same full OTA via"
echo "Settings > About device > Version > Local install, to populate slot $OTHER."
echo "============================================================"
