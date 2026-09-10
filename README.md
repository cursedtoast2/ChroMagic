# ChroMagic

ChroMagic is custom firmware for the [ModRetro Chromatic](https://modretro.com/products/chromatic-tetris-bundle). Back up the cartridges you own, keep their saves, and play your backups from an SD card right on the handheld.

## On your Chromatic

- Back up a cartridge's game and save through **SYSTEM → CART BACKUP**.
- Browse your collection in **BACKUPS**, including folders you've created to organize it.
- Load a backup with its save and switch games from the menu.
- Connect to [ChroMagician](https://github.com/cursedtoast2/ChroMagician) for cartridge tools and SD file management over USB.

On-device backups and playback require a Chromatic with an SD card installed. Backups are stored in `CHROMAGIC/BACKUPS`.

## Install

Install [ChroMagician](https://github.com/cursedtoast2/ChroMagician/releases), turn on your Chromatic, and connect it over USB. Open **Firmware**, select **ChroMagic**, and install. Keep the handheld powered on and connected until installation finishes.

For USB setup on Windows or Linux, follow [ModRetro's MRUpdater instructions](https://support.modretro.com/en_us/chromatic-firmware-updater-ryhoYnzCx).

Leave **C. MAGICIAN** off for on-device backups and playback. Enable it when using ChroMagician's cartridge and SD tools.

ChroMagician can also restore stock firmware from ModRetro's releases.

[Website and guide](https://chromagic.org)

## Source and credits

`mcu/` contains the ESP32 firmware and menus. `fpga/` contains the FPGA design and included Gameboy_MiSTer core.

See [mcu/LICENSE](mcu/LICENSE), [fpga/LICENSE](fpga/LICENSE), and [NOTICE](NOTICE) for licenses and upstream credits.

By [CursedToast](https://x.com/CursedToastSDA). An independent project, not affiliated with ModRetro or Nintendo.
