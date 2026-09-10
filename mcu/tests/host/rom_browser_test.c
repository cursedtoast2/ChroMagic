#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "rom_browser.h"
#include "rom_browser_ui.h"
#include "sd_card.h"

static RomBrowserDataSource_t Source;
static bool Mounted;
static unsigned Mounts, Unmounts, Starts;
static esp_err_t MountResult;
static char StartedPath[320];

void RomBrowserUI_RegisterDataSource(const RomBrowserDataSource_t *pSource) { Source = *pSource; }
esp_err_t SDCard_Mount(sdmmc_card_t **ppCard) {
    assert(!Mounted);
    if (MountResult != ESP_OK) return MountResult;
    Mounted = true; ++Mounts; *ppCard = (sdmmc_card_t *)&Mounted;
    return ESP_OK;
}
esp_err_t SDCard_Unmount(sdmmc_card_t *pCard) {
    assert(Mounted && pCard == (sdmmc_card_t *)&Mounted);
    Mounted = false; ++Unmounts; return ESP_OK;
}
bool OSD_IsVisible(void) { return false; }
esp_err_t FPGA_Tx_PulseButtons(uint16_t Buttons) { assert(false); return ESP_FAIL; }
esp_err_t VirtualCart_Start(const char *pPath) {
    assert(!Mounted && Mounts == Unmounts);
    ++Starts; snprintf(StartedPath, sizeof(StartedPath), "%s", pPath);
    return ESP_OK;
}
static void FileAt(const char *pName) {
    FILE *pFile = fopen(pName, "wb"); assert(pFile); assert(fclose(pFile) == 0);
}
static void Row(size_t Index, const char *pName, bool Directory) {
    assert(strcmp(Source.NameAt(Index), pName) == 0);
    assert(Source.IsDirectory(Index) == Directory);
}

int main(void) {
    assert(mkdir(ROM_BROWSER_ROOT, 0700) == 0);
    assert(mkdir(ROM_BROWSER_ROOT "/Empty.folder", 0700) == 0);
    assert(mkdir(ROM_BROWSER_ROOT "/Japan.v1", 0700) == 0);
    assert(mkdir(ROM_BROWSER_ROOT "/Japan.v1/Deeper", 0700) == 0);
    FileAt(ROM_BROWSER_ROOT "/Pokemon.gbc");
    FileAt(ROM_BROWSER_ROOT "/Pokemon.sav");
    FileAt(ROM_BROWSER_ROOT "/Japan.v1/Pokemon.gbc");
    FileAt(ROM_BROWSER_ROOT "/Japan.v1/Pokemon.rtc");
    FileAt(ROM_BROWSER_ROOT "/Japan.v1/Deeper/Pokemon.gbc");
    assert(RomBrowser_Init() == ESP_OK);
    size_t Count = 0, Selected = 99;
    assert(Source.AtRoot());
    assert(Source.Open(&Count) == ESP_OK && Count == 3);
    Row(0, "Empty.folder", true); Row(1, "Japan.v1", true); Row(2, "Pokemon.gbc", false);
    assert(Source.Enter(2, &Count) == ESP_ERR_INVALID_ARG);
    assert(Source.Parent(&Count, &Selected) == ESP_ERR_INVALID_ARG);
    assert(Source.Enter(0, &Count) == ESP_OK && Count == 0 && !Source.AtRoot());
    assert(Starts == 0 && !Mounted);
    assert(Source.Parent(&Count, &Selected) == ESP_OK && Count == 3 && Selected == 0);
    assert(Source.Enter(1, &Count) == ESP_OK && Count == 2);
    Row(0, "Deeper", true); Row(1, "Pokemon.gbc", false);
    Source.Close();
    assert(!Source.AtRoot() && Source.NameAt(0) == NULL && !Mounted);
    assert(Source.Open(&Count) == ESP_OK && Count == 2);
    Row(0, "Deeper", true); Row(1, "Pokemon.gbc", false);
    assert(Source.Start(Source.NameAt(1)) == ESP_OK);
    assert(strcmp(StartedPath, ROM_BROWSER_ROOT "/Japan.v1/Pokemon.gbc") == 0);
    assert(Source.Enter(0, &Count) == ESP_OK && Count == 1);
    for (unsigned Reopen = 0; Reopen < 3; ++Reopen) {
        Source.Close();
        assert(!Source.AtRoot() && Source.NameAt(0) == NULL && !Mounted);
        assert(Source.Open(&Count) == ESP_OK && Count == 1);
        Row(0, "Pokemon.gbc", false);
    }
    assert(Source.Start(Source.NameAt(0)) == ESP_OK);
    assert(strcmp(StartedPath, ROM_BROWSER_ROOT "/Japan.v1/Deeper/Pokemon.gbc") == 0);
    assert(Source.Parent(&Count, &Selected) == ESP_OK && Count == 2 && Selected == 0);
    assert(Source.Parent(&Count, &Selected) == ESP_OK && Count == 3 && Selected == 1);
    assert(Source.AtRoot());
    assert(Source.Start(Source.NameAt(2)) == ESP_OK);
    assert(strcmp(StartedPath, ROM_BROWSER_ROOT "/Pokemon.gbc") == 0 && Starts == 3);

    MountResult = ESP_ERR_INVALID_STATE;
    assert(Source.Enter(1, &Count) == ESP_ERR_INVALID_STATE);
    assert(!Mounted && Starts == 3);
    MountResult = ESP_ERR_NOT_FOUND;
    assert(Source.Open(&Count) == ESP_ERR_NOT_FOUND);
    MountResult = ESP_OK;
    assert(Source.Open(&Count) == ESP_OK && Count == 2);
    assert(Source.Parent(&Count, &Selected) == ESP_OK && Selected == 1);
    assert(rmdir(ROM_BROWSER_ROOT "/Empty.folder") == 0);
    assert(Source.Enter(0, &Count) == ESP_FAIL);
    assert(Source.Parent(&Count, &Selected) == ESP_OK && Count == 2);
    assert(Source.Enter(0, &Count) == ESP_OK);
    Source.Close();
    assert(!Source.AtRoot() && Source.NameAt(0) == NULL);
    MountResult = ESP_ERR_INVALID_STATE;
    assert(Source.Open(&Count) == ESP_ERR_INVALID_STATE && !Source.AtRoot());
    MountResult = ESP_OK;
    assert(Source.Open(&Count) == ESP_OK && Count == 2);
    assert(Source.Parent(&Count, &Selected) == ESP_OK && Source.AtRoot());

    char Folder[512], LongRom[512], ShortRom[512];
    char Name[181]; memset(Name, 'x', 180); Name[180] = '\0';
    snprintf(Folder, sizeof(Folder), "%s/%s", ROM_BROWSER_ROOT, Name);
    assert(mkdir(Folder, 0700) == 0);
    char LongName[256];
    const size_t Stem = 315 - strlen(Folder) - 1 - strlen(".gb");
    assert(Stem > 0 && Stem + 4 < sizeof(LongName));
    memset(LongName, 'L', Stem); strcpy(LongName + Stem, ".gb");
    snprintf(LongRom, sizeof(LongRom), "%s/%s", Folder, LongName);
    assert(strlen(LongRom) == 315);
    snprintf(ShortRom, sizeof(ShortRom), "%s/a.gb", Folder);
    FileAt(LongRom); FileAt(ShortRom);
    assert(Source.Open(&Count) == ESP_OK && Count == 3);
    assert(Source.Enter(1, &Count) == ESP_OK && Count == 1);
    Row(0, "a.gb", false);
    assert(Source.Start(Source.NameAt(0)) == ESP_OK && strcmp(StartedPath, ShortRom) == 0);
    Source.Close();
    assert(unlink(LongRom) == 0 && unlink(ShortRom) == 0 && rmdir(Folder) == 0);
    assert(!Source.AtRoot());
    assert(Source.Open(&Count) == ESP_OK && Count == 2 && Source.AtRoot());
    assert(mkdir(Folder, 0700) == 0);
    assert(Source.Open(&Count) == ESP_OK && Count == 3);
    assert(Source.Enter(1, &Count) == ESP_OK && Count == 0);
    Source.Close();
    assert(rmdir(Folder) == 0);
    FileAt(Folder);
    assert(Source.Open(&Count) == ESP_OK && Count == 2 && Source.AtRoot());
    assert(unlink(Folder) == 0);
    Source.Close();
    assert(unlink(ROM_BROWSER_ROOT "/Pokemon.gbc") == 0);
    assert(unlink(ROM_BROWSER_ROOT "/Pokemon.sav") == 0);
    assert(unlink(ROM_BROWSER_ROOT "/Japan.v1/Pokemon.gbc") == 0);
    assert(unlink(ROM_BROWSER_ROOT "/Japan.v1/Pokemon.rtc") == 0);
    assert(unlink(ROM_BROWSER_ROOT "/Japan.v1/Deeper/Pokemon.gbc") == 0);
    assert(rmdir(ROM_BROWSER_ROOT "/Japan.v1/Deeper") == 0);
    assert(rmdir(ROM_BROWSER_ROOT "/Japan.v1") == 0);
    assert(rmdir(ROM_BROWSER_ROOT) == 0);
    assert(Mounts == Unmounts && !Mounted);
    puts("PASS: real folder enumeration, full ROM paths, back selection, SD ownership and path limits");
}
