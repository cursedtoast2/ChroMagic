#pragma once
#include "esp_err.h"
#include <stdio.h>
typedef struct { int unused; } sdmmc_card_t;
typedef struct { int opcode, flags; esp_err_t error; } sdmmc_command_t;
void sdmmc_card_print_info(FILE *, const sdmmc_card_t *);
