#pragma once
#include "sdmmc_cmd.h"
#define SCF_RSP_PRESENT 1
#define SDMMC_SLOT_FLAG_INTERNAL_PULLUP 1
typedef struct { int width; unsigned flags; } sdmmc_slot_config_t;
typedef struct {
    esp_err_t (*do_transaction)(int, sdmmc_command_t *);
} sdmmc_host_t;
#define SDMMC_HOST_DEFAULT() { .do_transaction = sdmmc_host_do_transaction }
#define SDMMC_SLOT_CONFIG_DEFAULT() { .width = 4 }
esp_err_t sdmmc_host_do_transaction(int, sdmmc_command_t *);
