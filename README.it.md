# OnePlus 9 (lemonade): tornare a OxygenOS stock da LineageOS, via fastboot

Script e procedura testata e documentata per riportare un OnePlus 9 (`lemonade`, LE2113/LE2115/LE2111)
da LineageOS (o altra custom ROM) a **OxygenOS 14 stock**, usando solo `fastboot`/`fastbootd` e lo
zip **full OTA** ufficiale. Niente Windows, niente MSM Download Tool, niente EDL. Il bootloader resta sbloccato.

[English version](README.md) — la versione inglese è quella di riferimento e contiene tutti i dettagli.

Testato su: OnePlus 9 LE2113 (EU), LineageOS 24 → OxygenOS `LE2113_14.0.0.1902(EX01)`, da macOS.

> **Tutto quello che c'è qui cancella il telefono e, usato male, può bloccarlo. Leggi tutto prima.**
> Non ribloccare il bootloader finché OxygenOS non si avvia e non hai installato almeno un aggiornamento.

## Perché questo repo

La procedura "estrai il payload dell'OTA e flasha tutte le immagini con fastboot" è nota, ma sui OnePlus
con OxygenOS 12+ fallisce in un modo difficile da diagnosticare: logo OnePlus per ~5 secondi, poi
**FastBoot Mode**, senza errori a schermo né log. La causa vera:

**La fstab di OxygenOS richiede dieci partizioni logiche `my_*` montate in prima fase, nessuna `nofail`.
Il full OTA ne contiene otto: `my_company` e `my_preload` non vengono mai aggiornate via OTA e non sono nel
payload.** LineageOS, installandosi, le cancella da `super`. Se si ricreano solo le partizioni presenti
nell'OTA, `init` non trova `my_company`, va in errore fatale e riavvia nel bootloader. La recovery invece
parte, perché non le monta.

La soluzione è ricreare `my_company` e `my_preload` con un'immagine vuota valida. `flash-stock.sh` lo fa da
solo, derivando le stub da `my_carrier.img`, che nell'OTA c'è. L'indagine completa è in
[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) (in inglese).

## Cosa serve

- Mac o Linux con `fastboot`/`adb` recenti (`brew install --cask android-platform-tools`),
  [`payload-dumper-go`](https://github.com/ssut/payload-dumper-go/releases) nel `PATH` o in `scripts/bin/`,
  `python3`, `curl`, `jq`, `unzip`.
- Il **full OTA** della *tua* regione (LE2113 EU, LE2115 NA, LE2111 IN). Non mischiare regioni.
- ~16 GB liberi su disco.
- Un buon cavo USB, collegato direttamente al computer (niente hub).

## Procedura

```bash
./scripts/get-ota.sh EU                       # 1. scarica l'ultimo full OTA (EU | NA | IN), verifica MD5
./scripts/flash-stock.sh ota.zip --plan       # 2. prova a secco: mostra cosa farebbe, non scrive nulla
./scripts/flash-stock.sh ota.zip              # 3. flash vero (chiede YES); telefono in fastbootd
fastboot reboot bootloader                    # 4. riavvio VERO, poi "Recovery mode" coi tasti volume
```

Nella recovery OnePlus: *English → Wipe data and cache → Erase everything → Reboot*. Primo avvio 5–10 minuti.
Poi copia lo stesso zip sul telefono e installalo da *Impostazioni → Info → Versione → Aggiornamento locale*:
serve a riempire l'altro slot.

Non usare `fastboot reboot recovery` dal fastbootd di LineageOS: torna solo alla recovery già in RAM,
non carica quello che hai appena flashato.

## Tornare a LineageOS

Il firmware è già quello che LineageOS 24 si aspetta (lo include nel suo zip). Basta flashare `dtbo`,
`vendor_boot` e `boot` di LineageOS dal bootloader, entrare in recovery, *Format data*, sideload dello zip
LineageOS, riavvio in recovery, sideload delle GApps. Segui la wiki ufficiale per la tua build.

## Gli script

| Script | A cosa serve |
|---|---|
| `get-ota.sh [EU\|NA\|IN]` | trova e scarica l'ultimo full OTA (API Oxygen Updater), verifica MD5 |
| `flash-stock.sh` | la procedura di ripristino (`--plan`, `--extract-only`, `--no-stubs`) |
| `flash-fw.sh` | per chi resta su LineageOS: estrae le 23 immagini firmware da un OTA e le flasha, saltando l'`abl` di OOS 14 che LineageOS tiene fermo a OOS 13 |
| `make-stub-images.py` | crea `my_company.img`/`my_preload.img` da `my_carrier.img` (ricalcola il crc32c erofs) |
| `lpparse.py` | legge la tabella di `super` dal primo MB del dispositivo |
| `extract-fstab.py` | stampa la fstab di prima fase contenuta in `vendor_boot.img` |

Licenza MIT. Usalo a tuo rischio.
