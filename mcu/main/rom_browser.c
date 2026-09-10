#include "rom_browser.h"

#include "rom_browser_ui.h"
#include "button.h"
#include "fpga_tx.h"
#include "osd.h"
#include "sd_card.h"
#include "virtual_cart.h"

#include <dirent.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>

#ifndef ROM_BROWSER_ROOT
#define ROM_BROWSER_ROOT "/sdcard/CHROMAGIC/BACKUPS"
#endif
static const char *const RomDirectory = ROM_BROWSER_ROOT;
enum { kPathSize = 320, kSavePathReserve = 5 };
static char CurrentDirectory[kPathSize] = ROM_BROWSER_ROOT;

typedef struct {
    char *pName;
    bool Directory;
} RomEntry_t;

typedef struct RomCatalog {
    RomEntry_t *pEntries;
    size_t Count;
} RomCatalog_t;

static RomCatalog_t Catalog;

static bool IsRomName(const char *pName)
{
    if (pName == NULL)
    {
        return false;
    }
    const char *pDot = strrchr(pName, '.');
    return pDot != NULL &&
           (strcasecmp(pDot, ".gb") == 0 || strcasecmp(pDot, ".gbc") == 0);
}

static int CompareNames(const void *pLeft, const void *pRight)
{
    const RomEntry_t *Left = pLeft, *Right = pRight;
    if (Left->Directory != Right->Directory) return Left->Directory ? -1 : 1;
    return strcasecmp(Left->pName, Right->pName);
}

static void CloseCatalog(void)
{
    for (size_t i = 0; i < Catalog.Count; ++i)
    {
        free(Catalog.pEntries[i].pName);
    }
    free(Catalog.pEntries);
    Catalog.pEntries = NULL;
    Catalog.Count = 0;
}

static esp_err_t AppendName(const char *pName, bool Directory)
{
    RomEntry_t *const pExpanded = realloc(
        Catalog.pEntries, (Catalog.Count + 1) * sizeof(*Catalog.pEntries));
    if (pExpanded == NULL)
    {
        return ESP_ERR_NO_MEM;
    }
    Catalog.pEntries = pExpanded;
    Catalog.pEntries[Catalog.Count].pName = strdup(pName);
    if (Catalog.pEntries[Catalog.Count].pName == NULL)
    {
        return ESP_ERR_NO_MEM;
    }
    Catalog.pEntries[Catalog.Count++].Directory = Directory;
    return ESP_OK;
}

static bool AtRoot(void)
{
    return strcmp(CurrentDirectory, RomDirectory) == 0;
}

static esp_err_t ReadCatalog(size_t *pCount, bool ResumeLocation)
{
    if (pCount == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    CloseCatalog();

    sdmmc_card_t *pCard = NULL;
    esp_err_t Result = SDCard_Mount(&pCard);
    if (Result != ESP_OK)
    {
        return Result;
    }

    DIR *pDirectory = opendir(CurrentDirectory);
    if (pDirectory == NULL && ResumeLocation && !AtRoot() &&
        (errno == ENOENT || errno == ENOTDIR))
    {
        strcpy(CurrentDirectory, RomDirectory);
        pDirectory = opendir(CurrentDirectory);
    }
    if (pDirectory == NULL)
    {
        Result = errno == ENOENT && AtRoot() ? ESP_OK : ESP_FAIL;
        goto Cleanup;
    }

    struct dirent *pEntry;
    while ((pEntry = readdir(pDirectory)) != NULL)
    {
        if (strcmp(pEntry->d_name, ".") == 0 || strcmp(pEntry->d_name, "..") == 0)
        {
            continue;
        }

        char Path[kPathSize];
        const int Length = snprintf(Path, sizeof(Path), "%s/%s", CurrentDirectory,
                                    pEntry->d_name);
        struct stat Stat;
        if (Length < 0 || Length >= (int)sizeof(Path) ||
            stat(Path, &Stat) != 0)
        {
            continue;
        }
        const bool Directory = S_ISDIR(Stat.st_mode);
        if (!Directory && (!S_ISREG(Stat.st_mode) || !IsRomName(pEntry->d_name) ||
                           Length + kSavePathReserve >= kPathSize)) continue;
        Result = AppendName(pEntry->d_name, Directory);
        if (Result != ESP_OK)
        {
            break;
        }
    }
    if (closedir(pDirectory) != 0 && Result == ESP_OK)
    {
        Result = ESP_FAIL;
    }

Cleanup:
    {
        const esp_err_t UnmountResult = SDCard_Unmount(pCard);
        if (Result == ESP_OK && UnmountResult != ESP_OK)
        {
            Result = UnmountResult;
        }
    }
    if (Result != ESP_OK)
    {
        CloseCatalog();
        return Result;
    }

    if (Catalog.Count > 1)
    {
        qsort(Catalog.pEntries, Catalog.Count, sizeof(*Catalog.pEntries),
              CompareNames);
    }
    *pCount = Catalog.Count;
    return ESP_OK;
}

static esp_err_t OpenCatalog(size_t *pCount)
{
    return ReadCatalog(pCount, true);
}

static const char *NameAt(size_t Index)
{
    return Index < Catalog.Count ? Catalog.pEntries[Index].pName : NULL;
}

static bool IsDirectory(size_t Index)
{
    return Index < Catalog.Count && Catalog.pEntries[Index].Directory;
}

static esp_err_t EnterDirectory(size_t Index, size_t *pCount)
{
    if (!IsDirectory(Index) || pCount == NULL) return ESP_ERR_INVALID_ARG;
    char Path[kPathSize];
    const int Length = snprintf(Path, sizeof(Path), "%s/%s", CurrentDirectory,
                                NameAt(Index));
    if (Length < 0 || Length >= (int)sizeof(Path)) return ESP_ERR_INVALID_SIZE;
    memcpy(CurrentDirectory, Path, Length + 1);
    return ReadCatalog(pCount, false);
}

static esp_err_t ParentDirectory(size_t *pCount, size_t *pSelected)
{
    if (AtRoot() || pCount == NULL || pSelected == NULL) return ESP_ERR_INVALID_ARG;
    char *pSlash = strrchr(CurrentDirectory, '/');
    char Previous[kPathSize];
    strcpy(Previous, pSlash + 1);
    *pSlash = '\0';
    const esp_err_t Result = ReadCatalog(pCount, false);
    *pSelected = 0;
    for (size_t Index = 0; Result == ESP_OK && Index < Catalog.Count; ++Index)
    {
        if (IsDirectory(Index) && strcmp(NameAt(Index), Previous) == 0)
        {
            *pSelected = Index;
            break;
        }
    }
    return Result;
}

static esp_err_t StartRom(const char *pName)
{
    printf("ROM_BROWSER_LOAD name=\"%s\"\n", pName != NULL ? pName : "");

    if (pName == NULL) return ESP_ERR_INVALID_ARG;
    char Path[kPathSize];
    const int Length = snprintf(Path, sizeof(Path), "%s/%s", CurrentDirectory, pName);
    if (Length < 0 || Length + kSavePathReserve >= (int)sizeof(Path)) return ESP_ERR_INVALID_SIZE;
    return VirtualCart_Start(Path);
}

esp_err_t RomBrowser_CloseMenu(void)
{
    return OSD_IsVisible()
        ? FPGA_Tx_PulseButtons(kButtonBits_MenuEnAlt) : ESP_OK;
}

esp_err_t RomBrowser_Init(void)
{
    static const RomBrowserDataSource_t Source = {
        .Open = OpenCatalog,
        .NameAt = NameAt,
        .Close = CloseCatalog,
        .Start = StartRom,
        .IsDirectory = IsDirectory,
        .Enter = EnterDirectory,
        .Parent = ParentDirectory,
        .AtRoot = AtRoot,
    };
    RomBrowserUI_RegisterDataSource(&Source);
    return ESP_OK;
}
