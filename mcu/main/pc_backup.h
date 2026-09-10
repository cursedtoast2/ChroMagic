#pragma once

#include "esp_err.h"

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

enum {
    kPCBackupConsoleBaud = 2000000,
    kPCBackupNormalConsoleBaud = 115200,
};

esp_err_t PCBackup_Init(void);

uint32_t PCBackup_GetConsoleBaud(void);
bool PCBackup_IsEnabled(void);

void PCBackup_TransportReady(void);

esp_err_t PCBackup_ConfigureConsoleInput(void);

void PCBackup_ConsoleReady(void);

esp_err_t PCBackup_RegisterConsoleCommand(void);

esp_err_t PCBackup_ReadUpload(uint8_t *pData, size_t Size);
