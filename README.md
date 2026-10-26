# OnePlus 9 (lemonade): restore stock OxygenOS from LineageOS, via fastboot

Scripts and a tested, documented procedure to take a OnePlus 9 (`lemonade`, LE2113/LE2115/LE2111)
from LineageOS (or any custom ROM) back to **stock OxygenOS 14** using only `fastboot`/`fastbootd`
and the official **full OTA** zip. No Windows, no MSM Download Tool, no EDL. Bootloader stays unlocked.

[Versione italiana](README.it.md)

Tested on: OnePlus 9 LE2113 (EU), LineageOS 24 → OxygenOS `LE2113_14.0.0.1902(EX01)`, macOS host.

> **Everything here wipes the phone and can soft-brick it if misused. Read the whole README first.**
> The bootloader stays unlocked throughout; do **not** relock it unless OxygenOS boots and you have
> installed at least one OTA afterwards.

## Why this repo exists

The procedure "extract the OTA payload, flash every image with fastboot" is well known, but on
OnePlus phones running OxygenOS 12+ it fails in a way that is hard to diagnose: the phone shows
the OnePlus logo for ~5 seconds and drops back to **FastBoot Mode**, with no error on screen and no
kernel log. We hit that and found the actual cause:

**The OxygenOS fstab requires ten `my_*` logical partitions to be mounted at first stage
(`my_product`, `my_engineering`, `my_company`, `my_carrier`, `my_region`, `my_heytap`, `my_stock`,
`my_preload`, `my_bigball`, `my_manifest`), none of them `nofail`. Full OTA packages only ship
eight of them: `my_company` and `my_preload` are never updated via OTA, so they are not in the
payload.** When LineageOS was installed, its updater deleted every logical partition it did not
know about, including those two. Recreating only the partitions present in the OTA leaves the
phone unbootable: `init` fails to mount `/mnt/vendor/my_company`, calls `InitFatalReboot()` and
reboots into the bootloader. Recovery still works, because recovery does not mount them.

The fix is to recreate `my_company` and `my_preload` with a valid (empty) image. `flash-stock.sh`
does it automatically, deriving the stubs from the empty `my_carrier.img` that *is* in the OTA
(see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for the full investigation).

## What you need

- A Mac or Linux PC with:
  - `fastboot`/`adb` from recent platform-tools (`brew install --cask android-platform-tools`)
  - [`payload-dumper-go`](https://github.com/ssut/payload-dumper-go/releases) in your `PATH`
    or in `scripts/bin/`
  - `python3`, `curl`, `jq`, `unzip`
- The **full OTA zip** for *your* region (LE2113 EU, LE2115 NA, LE2111 IN). Do not mix regions.
  `scripts/get-ota.sh` fetches the latest one.
- ~16 GB free disk space (payload + extracted images)
- A good USB cable, directly on the computer (no hubs). Large transfers in fastbootd time out
  easily; the script retries each flash three times.

## Step by step

### 1. Get the full OTA

```bash
./scripts/get-ota.sh EU        # or NA / IN
```

It asks the Oxygen Updater API for the latest "Stable (full)" package, prints version, size, MD5
and URL, downloads it (resumable) and verifies the MD5. The OnePlus/Oplus OTA servers no longer
answer for the OnePlus 9, so this is currently the only automated source we found.

### 2. Check the package (optional but recommended)

```bash
unzip -l your-ota.zip                      # payload.bin + META-INF + payload_properties.txt only
unzip -p your-ota.zip META-INF/com/android/metadata | grep -E 'post-build|ota_version|pre-'
payload-dumper-go -l your-ota.zip          # 43 partitions on OOS 14
```

A *full* OTA has no `pre-build`/`pre-device` lines and `payload-dumper-go -l` says
"no source images required". The zip is signed by OnePlus (`META-INF/com/android/otacert`).

### 3. Dry run

Put the phone in fastbootd (from the LineageOS recovery: *Advanced → Enter fastboot*; or from the
bootloader `fastboot reboot fastboot`) and run:

```bash
./scripts/flash-stock.sh your-ota.zip --plan
```

It extracts the images and prints what it would do: which images are physical (flashed to both
slots), which are logical (recreated inside `super` on the current slot), which stubs it will
create, and which logical partitions currently exist (all of them will be deleted). Nothing is
written. On OOS 14 you should see 30 physical, 13 logical, 2 stubs.

### 4. Flash

```bash
./scripts/flash-stock.sh your-ota.zip
```

Type `YES` when asked. It then:

1. flashes the 30 physical partitions (firmware, boot, vendor_boot, dtbo, vbmeta…) to slot a **and** b;
2. deletes every logical partition in `super` (LineageOS's `system`, `vendor`, `vendor_dlkm`, `-cow`…);
3. creates the 13 OOS logical partitions on the current slot, each sized exactly like its image,
   and flashes them;
4. creates `my_company` and `my_preload` stubs;
5. sets the current slot active and erases userdata/metadata.

### 5. Reboot *for real*, wipe, boot

```bash
fastboot reboot bootloader
```

then select **Recovery mode** with the volume keys. You should see the **OnePlus recovery**
(logo, language selection). Choose *English → Wipe data and cache → Erase everything*, then *Reboot*.
First boot takes 5–10 minutes.

Do not use `fastboot reboot recovery` from a LineageOS fastbootd: it only switches back to the
LineageOS recovery already in RAM, it does not load what you just flashed.

### 6. Fill the other slot

Only the current slot has a system now. Once OxygenOS is up, copy the same OTA zip to the phone and
install it from *Settings → About device → Version → (menu) → Local install*. That populates the other
slot through the official updater.

## Going back to LineageOS later

Firmware is already the one LineageOS 24 expects (LineageOS ships the OOS 14 firmware inside its
own zip, see `proprietary-firmware.txt` in the device tree). So:

```bash
fastboot flash dtbo dtbo.img              # from the LineageOS download page, same build as the zip
fastboot flash vendor_boot vendor_boot.img
fastboot flash boot boot.img
fastboot reboot recovery
```

then *Factory reset → Format data*, *Apply update → ADB* and `adb sideload lineage-*.zip`,
reboot to recovery, sideload GApps, reboot. Follow the official LineageOS wiki for your build.

## Other tools in `scripts/`

| Script | Purpose |
|---|---|
| `get-ota.sh [EU\|NA\|IN]` | find + download the latest full OTA (Oxygen Updater API), verify MD5 |
| `flash-stock.sh` | the restore procedure above (`--plan`, `--extract-only`, `--no-stubs`) |
| `flash-fw.sh` | for LineageOS users: extract the 23 firmware images from an OTA (or a LineageOS zip) and flash them in fastbootd, skipping the OOS 14 `abl` that LineageOS pins to OOS 13 |
| `make-stub-images.py` | build `my_company.img`/`my_preload.img` from `my_carrier.img` (fixes the erofs superblock crc32c) |
| `lpparse.py` | dump the `super` partition table from the first 1 MB of the device (`adb exec-out "dd if=/dev/block/by-name/super bs=1M count=1" > super_head.bin`) |
| `extract-fstab.py` | print the first-stage fstab embedded in a `vendor_boot.img` — this is how we found the `my_company`/`my_preload` requirement |

## Credits / references

- [XDA: OnePlus 13, revert from LineageOS to OxygenOS (fastboot method)](https://xdaforums.com/t/guide-oneplus-13-cph2649-revert-from-lineageos-to-oxygenos-linux-fastboot-method.4783962/) — the delete/recreate/flash approach for `super`
- [LineageOS device tree for lemonade](https://github.com/LineageOS/android_device_oneplus_lemonade) — firmware list and the `abl` pin
- [Oxygen Updater](https://oxygenupdater.com) — OTA index used by `get-ota.sh`
- [payload-dumper-go](https://github.com/ssut/payload-dumper-go)

MIT licensed. Use at your own risk.
