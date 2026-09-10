#include "cart_backup_ui.h"
#include "pc_backup_mode.h"

#include "freertos/FreeRTOS.h"
#include "lvgl.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

typedef enum {
    kState_Idle,
    kState_Running,
    kState_Complete,
    kState_Error,
    kState_ModeBlocked,
} BackupState_t;

typedef struct {
    lv_obj_t *pStatus;
    lv_obj_t *pButton;
    BackupState_t State;
    uint8_t Percent;
    char Detail[32];
    bool RenderValid;
    BackupState_t RenderedState;
    uint8_t RenderedPercent;
    char RenderedDetail[32];
    CartBackupStartCallback_t StartCallback;
} BackupUiContext_t;

static BackupUiContext_t Context;
static portMUX_TYPE ContextLock = portMUX_INITIALIZER_UNLOCKED;

static void CopyDetail(const char *pText)
{
    snprintf(Context.Detail, sizeof(Context.Detail), "%s",
             pText != NULL ? pText : "UNKNOWN");
}

void CartBackupUI_RegisterStartCallback(CartBackupStartCallback_t Callback)
{
    portENTER_CRITICAL(&ContextLock);
    Context.StartCallback = Callback;
    portEXIT_CRITICAL(&ContextLock);
}

void CartBackupUI_SetProgress(uint8_t Percent, const char *pStage)
{
    portENTER_CRITICAL(&ContextLock);
    Context.State = kState_Running;
    Context.Percent = Percent > 100 ? 100 : Percent;
    CopyDetail(pStage);
    portEXIT_CRITICAL(&ContextLock);
}

void CartBackupUI_SetComplete(const char *pPath)
{
    const char *pName = pPath != NULL ? strrchr(pPath, '/') : NULL;
    portENTER_CRITICAL(&ContextLock);
    Context.State = kState_Complete;
    Context.Percent = 100;
    CopyDetail(pName != NULL ? pName + 1 : pPath);
    portEXIT_CRITICAL(&ContextLock);
}

void CartBackupUI_SetError(const char *pError)
{
    portENTER_CRITICAL(&ContextLock);
    Context.State = kState_Error;
    CopyDetail(pError);
    portEXIT_CRITICAL(&ContextLock);
}

OSD_Result_t CartBackupUI_Draw(void *pArg)
{
    if (pArg == NULL)
    {
        return kOSD_Result_Err_NullDataPtr;
    }
    lv_obj_t *pScreen = pArg;
    if (Context.pStatus == NULL)
    {
        Context.pButton = lv_obj_create(pScreen);
        lv_obj_remove_style_all(Context.pButton);
        lv_obj_set_pos(Context.pButton, 98, 44);
        lv_obj_set_size(Context.pButton, 24, 24);
        lv_obj_set_style_radius(Context.pButton, LV_RADIUS_CIRCLE, 0);
        lv_obj_set_style_bg_color(Context.pButton, lv_color_hex(0xff3399), 0);
        lv_obj_set_style_bg_opa(Context.pButton, LV_OPA_COVER, 0);
        static const lv_point_t Letter[] = {{0, 10}, {4, 0}, {8, 10}};
        static const lv_point_t Bar[] = {{2, 6}, {6, 6}};
        const lv_point_t *Lines[] = {Letter, Bar};
        for (unsigned i = 0; i < 2; ++i)
        {
            lv_obj_t *pLine = lv_line_create(Context.pButton);
            lv_line_set_points(pLine, Lines[i], i == 0 ? 3 : 2);
            lv_obj_set_pos(pLine, 8, 7);
            lv_obj_set_style_line_color(pLine, lv_color_black(), 0);
            lv_obj_set_style_line_width(pLine, 2, 0);
        }
        Context.pStatus = lv_label_create(pScreen);
        lv_obj_align(Context.pStatus, LV_ALIGN_TOP_LEFT, 77, 44);
        lv_obj_set_width(Context.pStatus, 65);
        lv_label_set_long_mode(Context.pStatus, LV_LABEL_LONG_WRAP);
        lv_obj_add_style(Context.pStatus, OSD_GetStyleTextWhite(), 0);
        lv_obj_move_foreground(Context.pStatus);
    }

    BackupState_t State;
    uint8_t Percent;
    char Detail[sizeof(Context.Detail)];
    portENTER_CRITICAL(&ContextLock);
    State = PCBackupMode_GetState() == kPCBackupModeState_On
        ? kState_ModeBlocked : Context.State;
    Percent = Context.Percent;
    memcpy(Detail, Context.Detail, sizeof(Detail));
    portEXIT_CRITICAL(&ContextLock);
    Detail[sizeof(Detail) - 1] = '\0';

    if (Context.RenderValid && State == Context.RenderedState &&
        Percent == Context.RenderedPercent &&
        strcmp(Detail, Context.RenderedDetail) == 0)
    {
        return kOSD_Result_Ok;
    }

    const bool Idle = State == kState_Idle;
    if (Idle) lv_obj_clear_flag(Context.pButton, LV_OBJ_FLAG_HIDDEN);
    else lv_obj_add_flag(Context.pButton, LV_OBJ_FLAG_HIDDEN);
    lv_obj_set_pos(Context.pStatus, 77, Idle ? 73 : 44);
    lv_obj_set_style_text_align(Context.pStatus, LV_TEXT_ALIGN_CENTER, 0);
    switch (State)
    {
        case kState_Running:
            lv_label_set_text_fmt(Context.pStatus, "%s\n%u%%", Detail, Percent);
            break;
        case kState_Complete:
            lv_label_set_text_fmt(Context.pStatus, "DONE\n%s", Detail);
            break;
        case kState_Error:
            if (strcmp(Detail, "NO SD CARD INSTALLED") == 0)
                lv_label_set_text_static(Context.pStatus, "NO SD CARD INSTALLED");
            else
                lv_label_set_text_fmt(Context.pStatus, "FAILED\n%s\nA: RETRY", Detail);
            break;
        case kState_ModeBlocked:
            lv_label_set_text_static(Context.pStatus,
                                    "DISABLE\nC. MAGICIAN\nIN SYSTEM\nSETTINGS");
            break;
        default:
            lv_label_set_text_static(Context.pStatus, "BACK UP\nTO SD CARD");
            break;
    }
    Context.RenderValid = true;
    Context.RenderedState = State;
    Context.RenderedPercent = Percent;
    memcpy(Context.RenderedDetail, Detail, sizeof(Context.RenderedDetail));
    return kOSD_Result_Ok;
}

OSD_Result_t CartBackupUI_OnButton(Button_t Button, ButtonState_t State,
                                   void *pArg)
{
    (void)pArg;
    if (Button != kButton_A || State != kButtonState_Pressed)
    {
        return kOSD_Result_Ok;
    }

    CartBackupStartCallback_t Callback;
    BackupState_t CurrentState;
    portENTER_CRITICAL(&ContextLock);
    Callback = Context.StartCallback;
    CurrentState = Context.State;
    portEXIT_CRITICAL(&ContextLock);
    if (Callback != NULL && CurrentState != kState_Running)
    {
        if (PCBackupMode_GetState() == kPCBackupModeState_On)
        {
            return kOSD_Result_Ok;
        }
        CartBackupUI_SetProgress(0, "STARTING");
        const esp_err_t Result = Callback();
        if (Result != ESP_OK)
        {
            CartBackupUI_SetError(esp_err_to_name(Result));
        }
    }
    return kOSD_Result_Ok;
}

OSD_Result_t CartBackupUI_OnTransition(void *pArg)
{
    (void)pArg;
    if (Context.pStatus != NULL)
    {
        lv_obj_del(Context.pStatus);
        Context.pStatus = NULL;
    }
    if (Context.pButton != NULL)
    {
        lv_obj_del(Context.pButton);
        Context.pButton = NULL;
    }
    Context.RenderValid = false;
    return kOSD_Result_Ok;
}
