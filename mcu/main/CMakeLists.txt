cmake_minimum_required(VERSION 3.22)

idf_component_register(
    SRCS
        "main.c" "gfx.c" "fpga_tx.c" "fpga_rx.c" "fpga_common.c" "pwrmgr.c"
        "sd_card.c" "sd_publish.c" "cart_link.c" "cart_bulk.c" "cart_mapper.c" "cart_rtc.c"
        "cart_backup.c" "virtual_cart.c" "rom_browser.c" "pc_backup.c" "pc_sd.c"
    INCLUDE_DIRS "."
    REQUIRES
        images esp_driver_uart esp_driver_spi esp_driver_gpio esp_driver_sdmmc
        nvs_flash fatfs sdmmc
        common battery button osd menu_mgr settings mutex
        console crc mbedtls json
)
