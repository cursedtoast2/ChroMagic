#pragma once

#include "esp_err.h"

#include <stdbool.h>

esp_err_t VirtualCart_Start(const char *pPath);
esp_err_t VirtualCart_Stop(void);
bool VirtualCart_IsActive(void);
bool VirtualCart_IsBusy(void);

esp_err_t VirtualCart_RegisterConsoleCommands(void);
