#pragma once

#include "esp_err.h"
#include "osd_shared.h"

#include <stdint.h>

typedef esp_err_t (*CartBackupStartCallback_t)(void);

OSD_Result_t CartBackupUI_Draw(void *pArg);
OSD_Result_t CartBackupUI_OnButton(Button_t Button, ButtonState_t State,
                                   void *pArg);
OSD_Result_t CartBackupUI_OnTransition(void *pArg);

void CartBackupUI_RegisterStartCallback(CartBackupStartCallback_t Callback);
void CartBackupUI_SetProgress(uint8_t Percent, const char *pStage);
void CartBackupUI_SetComplete(const char *pPath);
void CartBackupUI_SetError(const char *pError);
