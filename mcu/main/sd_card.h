#pragma once

#include "esp_err.h"
#include "sdmmc_cmd.h"

#ifndef SDCARD_MOUNT_POINT
#define SDCARD_MOUNT_POINT "/sdcard"
#endif

esp_err_t SDCard_RunReadWriteTest(void);

esp_err_t SDCard_Mount(sdmmc_card_t **ppCard);

esp_err_t SDCard_ProbeReadWrite(void);

esp_err_t SDCard_Unmount(sdmmc_card_t *pCard);

esp_err_t SDCard_RegisterConsoleCommand(void);
