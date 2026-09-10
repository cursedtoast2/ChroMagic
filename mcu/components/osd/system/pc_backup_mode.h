#pragma once

#include "osd_shared.h"
#include "settings.h"

typedef enum PCBackupModeState
{
    kPCBackupModeState_Off,
    kPCBackupModeState_On,
    kNumPCBackupModeStates,
} PCBackupModeState_t;

OSD_Result_t PCBackupMode_Draw(void *pArg);
void PCBackupMode_Update(PCBackupModeState_t NewState);
OSD_Result_t PCBackupMode_OnButton(Button_t Button, ButtonState_t State,
                                   void *pArg);
OSD_Result_t PCBackupMode_OnTransition(void *pArg);
PCBackupModeState_t PCBackupMode_GetState(void);
OSD_Result_t PCBackupMode_ApplySetting(const SettingValue_t *pValue);
void PCBackupMode_RegisterOnUpdateCb(fnOnUpdateCb_t Callback);
