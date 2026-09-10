#include "pc_backup_mode.h"

#include "esp_log.h"
#include "lvgl.h"
#include "mutex.h"

#include <stdbool.h>

LV_IMG_DECLARE(img_toggle_on);
LV_IMG_DECLARE(img_toggle_off);

enum {
    kToggleX = 77,
    kToggleY = 55,
    kStateOnX = kToggleX + 14,
    kStateOffX = kToggleX + 44,
    kStateY = kToggleY + 12,
};

typedef struct {
    lv_obj_t *pToggle;
    lv_obj_t *pState;
    PCBackupModeState_t State;
    fnOnUpdateCb_t OnUpdate;
} PCBackupModeContext_t;

static const char *TAG = "PCBackupMode";
static PCBackupModeContext_t Context;

OSD_Result_t PCBackupMode_Draw(void *pArg)
{
    if (pArg == NULL)
    {
        return kOSD_Result_Err_NullDataPtr;
    }
    lv_obj_t *const pScreen = pArg;
    if (Context.pToggle == NULL)
    {
        Context.pToggle = lv_img_create(pScreen);
        lv_obj_align(Context.pToggle, LV_ALIGN_TOP_LEFT, kToggleX, kToggleY);
    }
    if (Context.pState == NULL)
    {
        Context.pState = lv_label_create(pScreen);
        lv_obj_add_style(Context.pState, OSD_GetStyleTextBlack(), 0);
        lv_obj_set_align(Context.pState, LV_ALIGN_TOP_LEFT);
    }

    const bool Enabled = Context.State == kPCBackupModeState_On;
    lv_img_set_src(Context.pToggle,
                   Enabled ? &img_toggle_on : &img_toggle_off);
    lv_obj_set_pos(Context.pState, Enabled ? kStateOnX : kStateOffX,
                   kStateY);
    lv_label_set_text_static(Context.pState, Enabled ? "ON" : "OFF");
    lv_obj_move_foreground(Context.pState);
    return kOSD_Result_Ok;
}

void PCBackupMode_Update(PCBackupModeState_t NewState)
{
    if ((unsigned)NewState >= kNumPCBackupModeStates)
    {
        return;
    }
    PCBackupMode_OnTransition(NULL);
    if (Mutex_Take(kMutexKey_PCBackupMode) == kMutexResult_Ok)
    {
        const bool Changed = Context.State != NewState;
        Context.State = NewState;
        if (Changed)
        {
            OSD_Result_t Result = Settings_Update(kSettingKey_PCBackupMode,
                                                  NewState);
            if (Result == kOSD_Result_Ok)
            {
                Result = Settings_Commit();
            }
            if (Result != kOSD_Result_Ok)
            {
                ESP_LOGE(TAG, "PC backup mode save failed: %d", Result);
            }
        }
        (void)Mutex_Give(kMutexKey_PCBackupMode);
    }
    if (Context.OnUpdate != NULL)
    {
        Context.OnUpdate();
    }
}

OSD_Result_t PCBackupMode_OnButton(Button_t Button, ButtonState_t State,
                                   void *pArg)
{
    (void)pArg;
    if ((Button == kButton_A || Button == kButton_B) &&
        State == kButtonState_Pressed)
    {
        PCBackupMode_Update(Context.State == kPCBackupModeState_On
                                ? kPCBackupModeState_Off
                                : kPCBackupModeState_On);
    }
    return kOSD_Result_Ok;
}

OSD_Result_t PCBackupMode_OnTransition(void *pArg)
{
    (void)pArg;
    if (Context.pToggle != NULL)
    {
        lv_obj_del(Context.pToggle);
        Context.pToggle = NULL;
    }
    if (Context.pState != NULL)
    {
        lv_obj_del(Context.pState);
        Context.pState = NULL;
    }
    return kOSD_Result_Ok;
}

PCBackupModeState_t PCBackupMode_GetState(void)
{
    return Context.State;
}

OSD_Result_t PCBackupMode_ApplySetting(const SettingValue_t *pValue)
{
    if (pValue == NULL)
    {
        return kOSD_Result_Err_NullDataPtr;
    }
    if (pValue->eType != kSettingDataType_U8)
    {
        return kOSD_Result_Err_UnexpectedSettingDataType;
    }
    Context.State = pValue->U8 == 0 ? kPCBackupModeState_Off
                                    : kPCBackupModeState_On;
    return kOSD_Result_Ok;
}

void PCBackupMode_RegisterOnUpdateCb(fnOnUpdateCb_t Callback)
{
    Context.OnUpdate = Callback;
}
