# Troubleshooting and how we found the root cause

Everything below happened on a OnePlus 9 LE2113 going from LineageOS 24 to OxygenOS 14.0.0.1902.
Each item: symptom → cause → fix.

## 1. `Writing 'boot_b' FAILED (usb_read failed with status e00002ed)`

A USB timeout on the host side while fastbootd was writing a ~200 MB image. Nothing was damaged.
Use a direct port (no hub/dock), ideally another cable; `flash-stock.sh` retries each flash three
times and waits for the device to reappear.

## 2. `fastboot flash my_bigball_a` → `FAILED (remote: 'No such file or directory')`

`my_*`, `system`, `vendor`, `odm`, `product`, `system_ext` are **logical** partitions living inside
`super`. After LineageOS, `super` only contains LineageOS's partitions (`system`, `system_ext`,
`product`, `vendor`, `odm`, `vendor_dlkm`); the OOS ones do not exist and cannot be flashed until
they are created. The script deletes every existing logical partition and recreates the OOS set
with `fastboot create-logical-partition <name>_<slot> <image size>`.

The accompanying `Invalid sparse file format at header magic` line is harmless: fastboot checks
whether the image is sparse, it is not, and splits it into chunks itself ("Sending sparse 1/4").

## 3. `fastboot -w` says "Erase successful, but not automatically formatting"

fastbootd erased `userdata` and `metadata` but did not create a filesystem on them. Format from
the OxygenOS recovery (*Wipe data and cache → Erase everything*); it creates `userdata` (f2fs) and
`metadata` (ext4) the way the OOS fstab expects. Check with
`adb exec-out "dd if=/dev/block/by-name/metadata bs=4096 count=2" | xxd | head` — ext4 has `53 ef`
at offset 0x438, f2fs has `10 20 f5 f2` at 0x400.

## 4. `fastboot reboot recovery` from fastbootd brings back the *LineageOS* recovery

fastbootd and recovery are the same binary. From a LineageOS fastbootd, `reboot recovery` is a
soft switch to the recovery already in RAM; the new `boot`/`vendor_boot` on disk are never loaded.
Do a real reboot: `fastboot reboot bootloader`, then *Recovery mode* from the bootloader menu.

## 5. OnePlus logo for ~5 s, then FastBoot Mode. Recovery boots fine. No error on screen.

This was the hard one. What we ruled out, and how:

- **Slots**: `fastboot getvar slot-unbootable:a` = no, retry count still > 0, so the bootloader
  *was* attempting slot a. The 5 s of logo means the kernel started.
- **Reboot-to-bootloader** (rather than a plain bootloop) is the signature of Android `init`
  calling `InitFatalReboot()`: a required first-stage mount failed, or SELinux policy failed to
  load. Recovery booting fine with the same `boot`/`vendor_boot`/`dtbo` clears the boot chain
  and the kernel: recovery mode does not mount the system partitions.
- **AVB/dm-verity**: flashing `vbmeta` with `--disable-verity --disable-verification` changed
  nothing, so not a hashtree problem. (Stock vbmeta was restored afterwards.)
- **`super` metadata**: read with `lpparse.py` from the first 1 MB of `super`
  (`adb exec-out "dd if=/dev/block/by-name/super bs=1M count=1" > super_head.bin`). Version 10.2,
  header flags = Virtual A/B, 13 partitions with valid extents and the exact image sizes. Fine.
  (They sit in group `default` instead of `oneplus_dynamic_partitions_a`; that does not matter
  for mounting, the OnePlus 13 guide creates them the same way.)
- **Partition content**: the first 8 KB of every logical partition, read from `super` at the
  extent offsets, were byte-identical to the images, with the erofs magic (`e2 e1 f5 e0`) in place.
- **pstore**: only `pmsg-ramoops-0` existed, and it contained the current LineageOS recovery's
  logs, not the failed boot. No `console-ramoops` on this kernel.

What was left: the fstab. `extract-fstab.py vendor_boot.img` prints the first-stage fstab shipped
in the OOS vendor ramdisk (`fstab.default` / `oplus.fstab`). It lists, with `first_stage_mount` and
**without** `nofail`:

```
my_product my_engineering my_company my_carrier my_region
my_heytap  my_stock       my_preload my_bigball my_manifest
```

The full OTA ships only eight of them. `my_company` and `my_preload` are never updated via OTA
(they hold company/region preloads that stay fixed for the life of the device), so they live only
in factory images. LineageOS's updater deleted them from `super` when it installed. Result: `init`
cannot map `my_company_a`, treats it as required, fatal reboot to bootloader.

**Fix**: create both partitions with a valid empty image. The OTA contains `my_carrier.img`, a
328 KB erofs stub (`ro.oplus.image.my_carrier.type=empty`, standard dirs, proper SELinux labels).
`make-stub-images.py` renames it in place (`my_carrier` → `my_company`/`my_preload`, same length)
and recomputes the erofs superblock crc32c, which covers the first 4 KiB block where the inline
`build.prop` lives (two of the five occurrences are inside that block; without the fix the kernel
rejects the image). Then:

```bash
fastboot create-logical-partition my_company_a 335872
fastboot flash my_company_a my_company.img
fastboot create-logical-partition my_preload_a 335872
fastboot flash my_preload_a my_preload.img
```

The phone booted on the next attempt. `flash-stock.sh` now does this automatically.

Side effect: `my_preload` normally carries the regional preinstalled apps; with the stub they are
simply absent. A later OTA/local install does not restore that partition.

## 6. `partition-size:super` → `FAILED (remote: 'Could not open partition')` on OOS fastbootd

The OxygenOS fastbootd does not expose the size of `super` (LineageOS's does). The script skips the
capacity check in that case. On the OnePlus 9 `super` is 11190403072 bytes (10672 MB); the 13 OOS 14
logical images plus the two stubs take ~6.9 GB.

## 7. Which fastbootd should I use, LineageOS's or OxygenOS's?

Either works for `delete-logical-partition` / `create-logical-partition` / `flash`: the `super`
metadata written by LineageOS 24's fastbootd (liblp 10.2) was read without problems by OxygenOS 14.
After the boot chain is flashed, `fastboot reboot bootloader` + `fastboot reboot fastboot` gets
you the OOS fastbootd (tap *English* on the phone), which is what the OnePlus 13 guide uses.

## Useful checks

```bash
# slot state, from the bootloader
for v in current-slot slot-unbootable:a slot-unbootable:b slot-retry-count:a slot-retry-count:b slot-successful:a unlocked is-userspace; do fastboot getvar $v 2>&1 | head -1; done
fastboot set_active a            # resets retry count / unbootable flag of slot a

# logical partitions seen by fastbootd
fastboot getvar all 2>&1 | grep 'is-logical:.*:yes'

# super table + partition heads, from a recovery with adb shell (LineageOS recovery on the spare slot)
adb exec-out "dd if=/dev/block/by-name/super bs=1M count=1 2>/dev/null" > super_head.bin
python3 scripts/lpparse.py super_head.bin
```
