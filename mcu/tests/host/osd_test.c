#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lvgl.h"
#include "menu_mgr.h"
#include "rom_browser_ui.h"
#include "cart_backup_ui.h"
#include "pc_backup_mode.h"
#include "fw.h"

LV_IMG_DECLARE(menu_system);
static const char *Names[] = {"Bomberman.gb", "Kirby.gb", "Links_Awakening_DX_An_Extra_Long_Backup_Name.gbc", "Mario.gb", "Pokemon_Crystal.gbc", "Pokemon_Gold.gbc", "Zelda_An_Extra_Long_Backup_Filename_For_Scrolling.gbc"};
static size_t Count = 7;
static int Opens, Closes, Starts;
static esp_err_t OpenResult, StartResult;
static bool CompleteImmediately;
static bool FolderFixture;
static unsigned Depth;
static PCBackupModeState_t PCMode;
PCBackupModeState_t PCBackupMode_GetState(void) { return PCMode; }
static unsigned BackupStarts;
static esp_err_t BackupStart(void) { ++BackupStarts; return ESP_OK; }
static char StartedName[80];
static esp_err_t Open(size_t *pCount) { ++Opens; *pCount = FolderFixture ? (Depth == 2 ? 0 : 2) : Count; return OpenResult; }
static const char *NameAt(size_t Index) {
    if (FolderFixture) {
        assert(Depth < 2 && Index < 2);
        return Depth == 0 ? (Index == 0 ? "Bomberman.gb" : "Japan.v1")
                          : (Index == 0 ? "Empty.folder" : "Pokemon.gbc");
    }
    assert(Index < Count); return Names[Index];
}
static bool IsDirectory(size_t Index) { return FolderFixture && Index == (Depth == 0 ? 1 : 0); }
static bool AtRoot(void) { return Depth == 0; }
static esp_err_t Enter(size_t Index, size_t *pCount) {
    assert(IsDirectory(Index)); ++Depth; return Open(pCount);
}
static esp_err_t Parent(size_t *pCount, size_t *pSelected) {
    assert(Depth > 0); --Depth; *pSelected = Depth == 0 ? 1 : 0; return Open(pCount);
}
static void Close(void) { ++Closes; Depth = 0; }
static esp_err_t Start(const char *pName) {
    ++Starts; snprintf(StartedName, sizeof(StartedName), "%s", pName);
    if (CompleteImmediately) assert(RomBrowserUI_SetComplete());
    return StartResult;
}
static lv_obj_t *Text(lv_obj_t *pObj, const char *Value) {
    if (lv_obj_check_type(pObj, &lv_label_class) && strcmp(lv_label_get_text(pObj), Value) == 0) return pObj;
    for (uint32_t i = 0; i < lv_obj_get_child_cnt(pObj); ++i) {
        lv_obj_t *pFound = Text(lv_obj_get_child(pObj, i), Value);
        if (pFound != NULL) return pFound;
    }
    return NULL;
}
static lv_color_t Frame[160 * 144], Buffer[160 * 144];
static void Flush(lv_disp_drv_t *pDrv, const lv_area_t *pArea, lv_color_t *pPixels) {
    for (int y = pArea->y1; y <= pArea->y2; ++y)
        for (int x = pArea->x1; x <= pArea->x2; ++x)
            Frame[y * 160 + x] = *pPixels++;
    lv_disp_flush_ready(pDrv);
}
static void Snapshot(const char *Name) {
    lv_refr_now(NULL);
    const char *Dir = getenv("CHROMATIC_TEST_RENDER_DIR");
    if (Dir == NULL) return;
    char Path[512]; snprintf(Path, sizeof(Path), "%s/%s.ppm", Dir, Name);
    FILE *pFile = fopen(Path, "wb"); assert(pFile);
    fprintf(pFile, "P6\n160 144\n255\n");
    for (size_t i = 0; i < 160 * 144; ++i) {
        lv_color32_t c = { .full = lv_color_to32(Frame[i]) };
        const unsigned char RGB[] = {c.ch.red, c.ch.green, c.ch.blue};
        fwrite(RGB, 1, 3, pFile);
    }
    fclose(pFile);
}
static OSD_Result_t FirmwarePage(void *pArg) {
    return Firmware_Draw(((Tab_DrawCtx_t *)pArg)->pScreen);
}
static void CheckRowHeights(lv_obj_t *pObj, unsigned *pCount) {
    if (lv_obj_check_type(pObj, &lv_label_class) &&
        !lv_obj_has_flag(pObj, LV_OBJ_FLAG_HIDDEN) && lv_obj_get_width(pObj) == 126) {
        assert(lv_obj_get_height(pObj) == 10);
        ++*pCount;
    }
    for (uint32_t i = 0; i < lv_obj_get_child_cnt(pObj); ++i)
        CheckRowHeights(lv_obj_get_child(pObj, i), pCount);
}
static void CheckRows(lv_obj_t *Screen) {
    lv_obj_update_layout(Screen);
    unsigned Count = 0; CheckRowHeights(Screen, &Count); assert(Count == 5);
}

int main(void) {
    lv_init(); OSD_Common_Init(); Firmware_Initialize();
    static lv_disp_draw_buf_t DrawBuffer;
    lv_disp_draw_buf_init(&DrawBuffer, Buffer, NULL, 160 * 144);
    static lv_disp_drv_t Driver; lv_disp_drv_init(&Driver);
    Driver.hor_res = 160; Driver.ver_res = 144; Driver.draw_buf = &DrawBuffer; Driver.flush_cb = Flush;
    lv_disp_drv_register(&Driver);
    lv_obj_t *Screen = lv_scr_act();
    lv_obj_set_style_bg_color(Screen, lv_color_hex(0x111111), 0);
    const RomBrowserDataSource_t Source = {
        .Open = Open, .NameAt = NameAt, .Close = Close, .Start = Start,
        .IsDirectory = IsDirectory, .Enter = Enter, .Parent = Parent, .AtRoot = AtRoot,
    };
    RomBrowserUI_RegisterDataSource(&Source);
    OSD_Widget_t Menu = { .Name = "test" };
    assert(MenuMgr_Initialize(&Menu, Screen) == kOSD_Result_Ok);
    for (int i = 0; i < kNumTabIDs; ++i) {
        MenuTab_t *pTab = calloc(1, sizeof(*pTab));
        const MenuTab_t Template = { .pImageDesc = &menu_system };
        memcpy(pTab, &Template, sizeof(*pTab));
        pTab->Accent = lv_color_hex(0xff3399);
        if (i == kTabID_System) {
            pTab->Widget.fnDraw = FirmwarePage;
            pTab->Widget.fnOnTransition = Firmware_OnTransition;
            pTab->Widget.fnOnButton = Firmware_OnButton;
        }
        if (i == kTabID_Backups) {
            pTab->Accent = lv_color_hex(0x66ff66);
            pTab->Widget.fnDraw = RomBrowserUI_Draw;
            pTab->Widget.fnOnTransition = RomBrowserUI_OnTransition;
            pTab->Widget.fnOnButton = RomBrowserUI_OnButton;
        }
        assert(MenuMgr_AddTab(i, pTab) == kOSD_Result_Ok);
    }
    for (int i = 0; i < kTabID_Backups; ++i)
        Menu.fnOnButton(kButton_Right, kButtonState_Pressed, NULL);
    PCMode = kPCBackupModeState_On;
    assert(Menu.fnDraw(Screen) == kOSD_Result_Ok);
    assert(Opens == 0 && Starts == 0);
    assert(Text(Screen, "DISABLE C. MAGICIAN\nIN SYSTEM SETTINGS"));
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL);
    assert(Opens == 0 && Starts == 0);
    PCMode = kPCBackupModeState_Off;
    assert(Menu.fnDraw(Screen) == kOSD_Result_Ok);
    assert(Opens == 1 && Starts == 0);
    assert(Text(Screen, "1/7"));
    Snapshot("backups");
    CheckRows(Screen);
    assert(Text(Screen, "BOMBERMAN") && Text(Screen, "POKEMON CRYSTAL"));
    Menu.fnDraw(Screen); assert(Opens == 1);
    Menu.fnOnButton(kButton_Up, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "7/7"));
    lv_obj_t *Long = Text(Screen, "ZELDA AN EXTRA LONG BACKUP FILENAME FOR SCROLLING");
    assert(Long && lv_label_get_long_mode(Long) == LV_LABEL_LONG_SCROLL_CIRCULAR);
    Snapshot("backups-scrolled");
    CheckRows(Screen);
    Menu.fnOnButton(kButton_Down, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "1/7"));
    CheckRows(Screen);
    Menu.fnOnButton(kButton_Down, kButtonState_Pressed, NULL);
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL);
    assert(Starts == 1 && strcmp(StartedName, "Kirby.gb") == 0);
    RomBrowserUI_SetProgress(1, 2); Menu.fnDraw(Screen);
    assert(Text(Screen, "LOADING\nKIRBY\n50%"));
    Menu.fnOnButton(kButton_Down, kButtonState_Pressed, NULL);
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); assert(Starts == 1);
    assert(RomBrowserUI_SetComplete()); Menu.fnDraw(Screen);
    assert(Text(Screen, "2/7") && Opens == 1);
    CompleteImmediately = true;
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "2/7")); CompleteImmediately = false;
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL);
    Menu.fnOnButton(kButton_Left, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Closes == 1 && !RomBrowserUI_SetComplete());
    assert(Text(Screen, "1.0.0 (4.2)") && !Text(Screen, "SYSTEM    INFO"));
    Snapshot("firmware");
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "MCU:") && Text(Screen, "FPGA:"));
    Menu.fnOnButton(kButton_Right, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    StartResult = ESP_FAIL;
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "COULD NOT LOAD\nESP_FAIL"));
    StartResult = ESP_OK; Count = 0;
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "NO BACKUPS\nON SD CARD"));
    OpenResult = ESP_FAIL;
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "COULD NOT READ SD CARD"));
    OpenResult = ESP_ERR_NOT_FOUND;
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "NO SD CARD INSTALLED"));
    OpenResult = ESP_ERR_TIMEOUT;
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "SD CARD NOT RESPONDING"));
    OpenResult = ESP_OK; Count = 7;
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Text(Screen, "1/7"));
    PCMode = kPCBackupModeState_On;
    const int PreviousStarts = Starts;
    Menu.fnDraw(Screen);
    assert(Text(Screen, "DISABLE C. MAGICIAN\nIN SYSTEM SETTINGS"));
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Starts == PreviousStarts);
    assert(Text(Screen, "DISABLE C. MAGICIAN\nIN SYSTEM SETTINGS"));
    Snapshot("backups-disable-magician");
    PCMode = kPCBackupModeState_Off;
    Menu.fnDraw(Screen);
    assert(Text(Screen, "1/7"));
    Menu.fnOnTransition(NULL);
    FolderFixture = true;
    Menu.fnDraw(Screen);
    const int FolderStarts = Starts, FolderOpens = Opens;
    Menu.fnOnButton(kButton_B, kButtonState_Pressed, NULL);
    assert(Depth == 0 && Opens == FolderOpens);
    Menu.fnOnButton(kButton_Down, kButtonState_Pressed, NULL);
    Menu.fnDraw(Screen);
    Snapshot("backups-folders");
    assert(Text(Screen, "[JAPAN.V1]"));
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Depth == 1 && Starts == FolderStarts && Text(Screen, "[EMPTY.FOLDER]"));
    Snapshot("backups-inside-folder");
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Depth == 2 && Text(Screen, "EMPTY FOLDER"));
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Depth == 2);
    Menu.fnOnButton(kButton_B, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Depth == 1 && Text(Screen, "1/2"));
    Menu.fnOnButton(kButton_Down, kButtonState_Pressed, NULL);
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Starts == FolderStarts + 1 && !strcmp(StartedName, "Pokemon.gbc"));
    Menu.fnOnButton(kButton_B, kButtonState_Pressed, NULL);
    assert(Depth == 1);
    assert(RomBrowserUI_SetComplete()); Menu.fnDraw(Screen);
    assert(Text(Screen, "2/2"));
    PCMode = kPCBackupModeState_On;
    Menu.fnOnButton(kButton_B, kButtonState_Pressed, NULL);
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL);
    assert(Depth == 1 && Starts == FolderStarts + 1);
    PCMode = kPCBackupModeState_Off;
    Menu.fnOnButton(kButton_B, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Depth == 0 && Text(Screen, "2/2"));
    OpenResult = ESP_ERR_NOT_FOUND;
    Menu.fnOnButton(kButton_A, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Depth == 1 && Text(Screen, "NO SD CARD INSTALLED"));
    OpenResult = ESP_OK;
    Menu.fnOnButton(kButton_B, kButtonState_Pressed, NULL); Menu.fnDraw(Screen);
    assert(Depth == 0 && Text(Screen, "2/2"));
    assert(Starts == FolderStarts + 1 && !Text(Screen, "B: BACK"));
    Menu.fnOnTransition(NULL);
    lv_obj_t *Background = lv_img_create(Screen);
    lv_img_set_src(Background, &menu_system);
    lv_obj_set_pos(Background, 16, 7);
    CartBackupUI_RegisterStartCallback(BackupStart);
    CartBackupUI_Draw(Screen);
    assert(Text(Screen, "BACK UP\nTO SD CARD"));
    lv_obj_t *Button = lv_obj_get_child(Screen, lv_obj_get_child_cnt(Screen) - 2);
    assert(lv_obj_get_style_radius(Button, 0) == LV_RADIUS_CIRCLE);
    assert(lv_obj_get_child_cnt(Button) == 2);
    Snapshot("cart-backup-button");
    PCMode = kPCBackupModeState_On;
    CartBackupUI_Draw(Screen);
    assert(Text(Screen, "DISABLE\nC. MAGICIAN\nIN SYSTEM\nSETTINGS"));
    CartBackupUI_OnButton(kButton_A, kButtonState_Pressed, NULL);
    CartBackupUI_Draw(Screen);
    assert(BackupStarts == 0);
    assert(Text(Screen, "DISABLE\nC. MAGICIAN\nIN SYSTEM\nSETTINGS"));
    Snapshot("cart-backup-disable-magician");
    PCMode = kPCBackupModeState_Off;
    CartBackupUI_Draw(Screen);
    assert(Text(Screen, "BACK UP\nTO SD CARD"));
    CartBackupUI_OnButton(kButton_A, kButtonState_Pressed, NULL);
    assert(BackupStarts == 1);
    CartBackupUI_OnTransition(NULL);
    lv_obj_del(Background);
    puts("PASS: menu routing, list scrolling, exact file selection, progress, immediate completion, errors, cleanup, firmware layout");
    return 0;
}
