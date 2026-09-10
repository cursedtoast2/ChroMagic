#include "rom_browser_ui.h"
#include "pc_backup_mode.h"

#include "freertos/FreeRTOS.h"
#include "lvgl.h"
#include "tab_shared.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

enum { kVisibleRows = 5, kRowHeight = 12, kListX = 18, kListY = 44 };

typedef enum {
    kRomBrowserIdle,
    kRomBrowserSelecting,
    kRomBrowserEmpty,
    kRomBrowserLoading,
    kRomBrowserError,
    kRomBrowserModeBlocked,
} RomBrowserState_t;

typedef struct {
    lv_obj_t *pRows[kVisibleRows];
    lv_obj_t *pSelection;
    lv_obj_t *pStatus;
    lv_obj_t *pHint;
    lv_obj_t *pPosition;
    RomBrowserDataSource_t Source;
    RomBrowserState_t State;
    size_t Count;
    size_t Selected;
    bool CatalogOpen;
    bool TrackingLoad;
    uint8_t Progress;
    bool RenderValid;
    bool RenderedBlocked;
    char CurrentName[64];
    char Error[32];
} RomBrowserContext_t;

static RomBrowserContext_t Context;
static portMUX_TYPE ContextLock = portMUX_INITIALIZER_UNLOCKED;

static void CloseCatalog(void)
{
    if (Context.CatalogOpen && Context.Source.Close != NULL)
    {
        Context.Source.Close();
    }
    Context.CatalogOpen = false;
    Context.Count = 0;
    Context.Selected = 0;
}

static bool AtRoot(void)
{
    return Context.Source.AtRoot == NULL || Context.Source.AtRoot();
}

static bool IsDirectory(size_t Index)
{
    return Context.Source.IsDirectory != NULL && Context.Source.IsDirectory(Index);
}

static void MakeDisplayName(const char *pName, bool Directory, char Output[64])
{
    size_t Length = 0;
    if (Directory) Output[Length++] = '[';
    if (pName != NULL)
    {
        const char *pDot = Directory ? NULL : strrchr(pName, '.');
        const size_t Maximum = pDot != NULL ? (size_t)(pDot - pName)
                                             : strlen(pName);
        for (size_t Index = 0; Index < Maximum && Length + (Directory ? 2 : 1) < 64; ++Index)
        {
            const unsigned char Byte = (unsigned char)pName[Index];
            Output[Length] = Byte >= 'a' && Byte <= 'z' ? Byte - ('a' - 'A')
                : (Byte == '_' || Byte < ' ') ? ' ' : Byte;
            ++Length;
        }
    }
    if (Directory) Output[Length++] = ']';
    Output[Length] = '\0';
}

static void SetCatalogResult(esp_err_t Result, size_t Count, size_t Selected)
{
    Context.RenderValid = false;
    Context.CatalogOpen = true;
    Context.Count = Result == ESP_OK ? Count : 0;
    Context.Selected = Selected < Context.Count ? Selected : 0;
    if (Result != ESP_OK)
    {
        snprintf(Context.Error, sizeof(Context.Error), "%s",
                 Result == ESP_ERR_NOT_FOUND ? "NO SD CARD INSTALLED" :
                 Result == ESP_ERR_TIMEOUT ? "SD CARD NOT RESPONDING" :
                 "COULD NOT READ SD CARD");
        Context.State = kRomBrowserError;
        return;
    }
    Context.State = Count == 0 ? kRomBrowserEmpty : kRomBrowserSelecting;
}

static void OpenCatalog(void)
{
    Context.RenderValid = false;
    if (Context.Source.Open == NULL || Context.Source.NameAt == NULL ||
        Context.Source.Close == NULL || Context.Source.Start == NULL)
    {
        snprintf(Context.Error, sizeof(Context.Error), "NOT READY");
        Context.State = kRomBrowserError;
        return;
    }
    size_t Count = 0;
    const esp_err_t Result = Context.Source.Open(&Count);
    SetCatalogResult(Result, Count, 0);
}

void RomBrowserUI_RegisterDataSource(const RomBrowserDataSource_t *pSource)
{
    if (pSource != NULL) Context.Source = *pSource;
}

void RomBrowserUI_SetProgress(uint32_t Completed, uint32_t Total)
{
    portENTER_CRITICAL(&ContextLock);
    if (Context.TrackingLoad && Context.State == kRomBrowserLoading && Total != 0)
    {
        const uint32_t Bounded = Completed < Total ? Completed : Total;
        const uint8_t Progress = (uint8_t)((Bounded * 100u) / Total);
        if (Progress != Context.Progress)
        {
            Context.Progress = Progress;
            Context.RenderValid = false;
        }
    }
    portEXIT_CRITICAL(&ContextLock);
}

bool RomBrowserUI_SetComplete(void)
{
    portENTER_CRITICAL(&ContextLock);
    const bool CloseMenu = Context.TrackingLoad;
    if (CloseMenu)
    {
        Context.TrackingLoad = false;
        Context.State = kRomBrowserSelecting;
        Context.Progress = 0;
        Context.RenderValid = false;
    }
    portEXIT_CRITICAL(&ContextLock);
    return CloseMenu;
}

void RomBrowserUI_SetError(esp_err_t Error)
{
    portENTER_CRITICAL(&ContextLock);
    if (Context.TrackingLoad)
    {
        snprintf(Context.Error, sizeof(Context.Error), "COULD NOT LOAD\n%s", esp_err_to_name(Error));
        Context.State = kRomBrowserError;
        Context.RenderValid = false;
    }
    portEXIT_CRITICAL(&ContextLock);
}

static lv_obj_t *Label(lv_obj_t *pScreen, int X, int Y, int Width)
{
    lv_obj_t *pLabel = lv_label_create(pScreen);
    lv_obj_add_style(pLabel, OSD_GetStyleTextWhite(), 0);
    lv_obj_set_pos(pLabel, X, Y);
    lv_obj_set_width(pLabel, Width);
    return pLabel;
}

OSD_Result_t RomBrowserUI_Draw(void *pArg)
{
    if (pArg == NULL || ((Tab_DrawCtx_t *)pArg)->pScreen == NULL)
    {
        return kOSD_Result_Err_NullDataPtr;
    }
    const Tab_DrawCtx_t *pDraw = pArg;
    lv_obj_t *pScreen = pDraw->pScreen;
    const bool Blocked = PCBackupMode_GetState() == kPCBackupModeState_On;
    if (!Blocked && Context.State == kRomBrowserIdle) OpenCatalog();

    if (Context.pStatus == NULL)
    {
        Context.pStatus = Label(pScreen, kListX, kListY, 126);
        lv_label_set_long_mode(Context.pStatus, LV_LABEL_LONG_WRAP);
        Context.pHint = Label(pScreen, kListX, 103, 82);
        Context.pPosition = Label(pScreen, 101, 103, 43);
        lv_obj_set_style_text_align(Context.pPosition, LV_TEXT_ALIGN_RIGHT, 0);
        Context.pSelection = lv_obj_create(pScreen);
        lv_obj_remove_style_all(Context.pSelection);
        lv_obj_set_size(Context.pSelection, 130, 11);
        lv_obj_set_style_border_color(Context.pSelection, pDraw->AccentColor, 0);
        lv_obj_set_style_border_width(Context.pSelection, 1, 0);
        for (size_t Row = 0; Row < kVisibleRows; ++Row)
        {
            Context.pRows[Row] = Label(pScreen, kListX, kListY + Row * kRowHeight, 126);
            lv_obj_set_height(Context.pRows[Row], kRowHeight - 2);
            lv_label_set_long_mode(Context.pRows[Row], LV_LABEL_LONG_DOT);
        }
        Context.RenderValid = false;
    }

    portENTER_CRITICAL(&ContextLock);
    const RomBrowserState_t State = Blocked ? kRomBrowserModeBlocked : Context.State;
    const uint8_t Progress = Context.Progress;
    const bool Dirty = !Context.RenderValid || Context.RenderedBlocked != Blocked;
    Context.RenderValid = true;
    Context.RenderedBlocked = Blocked;
    char Name[64], Error[32];
    memcpy(Name, Context.CurrentName, sizeof(Name));
    memcpy(Error, Context.Error, sizeof(Error));
    portEXIT_CRITICAL(&ContextLock);
    if (!Dirty) return kOSD_Result_Ok;

    const bool Selecting = State == kRomBrowserSelecting;
    if (Selecting)
    {
        lv_obj_add_flag(Context.pStatus, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(Context.pSelection, LV_OBJ_FLAG_HIDDEN);
        const size_t First = Context.Selected < kVisibleRows
            ? 0 : Context.Selected - kVisibleRows + 1;
        for (size_t Row = 0; Row < kVisibleRows; ++Row)
        {
            lv_obj_t *pLabel = Context.pRows[Row];
            const size_t Index = First + Row;
            if (Index >= Context.Count)
            {
                lv_obj_add_flag(pLabel, LV_OBJ_FLAG_HIDDEN);
                continue;
            }
            char DisplayName[64];
            MakeDisplayName(Context.Source.NameAt(Index), IsDirectory(Index), DisplayName);
            lv_obj_clear_flag(pLabel, LV_OBJ_FLAG_HIDDEN);
            const bool Selected = Index == Context.Selected;
            lv_label_set_long_mode(pLabel, Selected ? LV_LABEL_LONG_SCROLL_CIRCULAR : LV_LABEL_LONG_DOT);
            lv_obj_set_style_text_color(pLabel, lv_color_hex(Selected ? 0xffffff : 0x999999), 0);
            lv_label_set_text(pLabel, DisplayName);
            if (Selected)
            {
                lv_obj_set_pos(Context.pSelection, kListX - 3, kListY - 2 + Row * kRowHeight);
            }
        }
        lv_label_set_text_static(Context.pHint, "");
        lv_label_set_text_fmt(Context.pPosition, "%u/%u", (unsigned)(Context.Selected + 1), (unsigned)Context.Count);
    }
    else
    {
        for (size_t Row = 0; Row < kVisibleRows; ++Row)
            lv_obj_add_flag(Context.pRows[Row], LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(Context.pSelection, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(Context.pStatus, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text_static(Context.pPosition, "");
        lv_label_set_text_static(Context.pHint,
            State == kRomBrowserLoading || Blocked ? "" : "A: REFRESH");
        switch (State)
        {
            case kRomBrowserEmpty:
                lv_label_set_text_static(Context.pStatus,
                    AtRoot() ? "NO BACKUPS\nON SD CARD" : "EMPTY FOLDER");
                break;
            case kRomBrowserLoading:
                lv_label_set_text_fmt(Context.pStatus, "LOADING\n%s\n%u%%", Name, (unsigned)Progress);
                break;
            case kRomBrowserError:
                lv_label_set_text(Context.pStatus, Error);
                break;
            case kRomBrowserModeBlocked:
                lv_label_set_text_static(Context.pStatus,
                                        "DISABLE C. MAGICIAN\nIN SYSTEM SETTINGS");
                break;
            default:
                break;
        }
    }
    return kOSD_Result_Ok;
}

OSD_Result_t RomBrowserUI_OnButton(Button_t Button, ButtonState_t State, void *pArg)
{
    (void)pArg;
    if (State != kButtonState_Pressed) return kOSD_Result_Ok;
    if (PCBackupMode_GetState() == kPCBackupModeState_On) return kOSD_Result_Ok;
    if (Button == kButton_B && Context.State != kRomBrowserLoading)
    {
        Context.TrackingLoad = false;
        if (!AtRoot() && Context.Source.Parent != NULL)
        {
            size_t Count = 0, Selected = 0;
            const esp_err_t Result = Context.Source.Parent(&Count, &Selected);
            SetCatalogResult(Result, Count, Selected);
        }
        else if (Context.State == kRomBrowserError) OpenCatalog();
        return kOSD_Result_Ok;
    }
    if (Context.State == kRomBrowserSelecting)
    {
        if (Button == kButton_Up || Button == kButton_Down)
        {
            Context.Selected = Button == kButton_Up
                ? (Context.Selected == 0 ? Context.Count - 1 : Context.Selected - 1)
                : (Context.Selected + 1) % Context.Count;
            Context.RenderValid = false;
        }
        else if (Button == kButton_A)
        {
            if (IsDirectory(Context.Selected) && Context.Source.Enter != NULL)
            {
                size_t Count = 0;
                const esp_err_t Result = Context.Source.Enter(Context.Selected, &Count);
                SetCatalogResult(Result, Count, 0);
                return kOSD_Result_Ok;
            }
            const char *pName = Context.Source.NameAt(Context.Selected);
            MakeDisplayName(pName, false, Context.CurrentName);
            portENTER_CRITICAL(&ContextLock);
            Context.TrackingLoad = true;
            Context.State = kRomBrowserLoading;
            Context.Progress = 0;
            Context.RenderValid = false;
            portEXIT_CRITICAL(&ContextLock);
            const esp_err_t Result = Context.Source.Start(pName);
            if (Result != ESP_OK) RomBrowserUI_SetError(Result);
        }
    }
    else if (Context.State != kRomBrowserLoading && Button == kButton_A)
    {
        Context.TrackingLoad = false;
        OpenCatalog();
    }
    return kOSD_Result_Ok;
}

OSD_Result_t RomBrowserUI_OnTransition(void *pArg)
{
    (void)pArg;
    portENTER_CRITICAL(&ContextLock);
    Context.TrackingLoad = false;
    Context.State = kRomBrowserIdle;
    Context.RenderValid = false;
    portEXIT_CRITICAL(&ContextLock);
    CloseCatalog();
    lv_obj_t **Objects[] = {&Context.pStatus, &Context.pHint, &Context.pPosition, &Context.pSelection};
    for (size_t Index = 0; Index < ARRAY_SIZE(Objects); ++Index)
    {
        if (*Objects[Index] != NULL) lv_obj_del(*Objects[Index]);
        *Objects[Index] = NULL;
    }
    for (size_t Row = 0; Row < kVisibleRows; ++Row)
    {
        if (Context.pRows[Row] != NULL) lv_obj_del(Context.pRows[Row]);
        Context.pRows[Row] = NULL;
    }
    return kOSD_Result_Ok;
}
