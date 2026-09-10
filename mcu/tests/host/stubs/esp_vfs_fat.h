#pragma once
#include <stdbool.h>
#include "driver/sdmmc_host.h"
typedef struct { bool format_if_mount_failed; int max_files, allocation_unit_size; } esp_vfs_fat_sdmmc_mount_config_t;
esp_err_t esp_vfs_fat_sdmmc_mount(const char *, const sdmmc_host_t *, const sdmmc_slot_config_t *, const esp_vfs_fat_sdmmc_mount_config_t *, sdmmc_card_t **);
esp_err_t esp_vfs_fat_sdcard_unmount(const char *, sdmmc_card_t *);
