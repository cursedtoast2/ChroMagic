#include "sd_card.h"

#include "driver/sdmmc_host.h"
#include "esp_console.h"
#include "esp_log.h"
#include "esp_vfs_fat.h"
#include "sdmmc_cmd.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum {
    kMaxOpenFiles = 2,
    kAllocationUnitSize = 16 * 1024,
};

static StaticSemaphore_t MountGateStorage;
static SemaphoreHandle_t MountGate;
static portMUX_TYPE GateInitLock = portMUX_INITIALIZER_UNLOCKED;

static const char *const TAG = "SDCard";
static const char *const MountPoint = SDCARD_MOUNT_POINT;
static const char *const ProbePath = "/sdcard/CHRMTEST.TMP";
static const uint8_t ProbeData[] = {'C', 'H', 'R', 'M'};

static bool CardResponded;
static int LastCommand;
static esp_err_t LastCommandError;

static esp_err_t MountTransaction(int Slot, sdmmc_command_t *Command)
{
    const esp_err_t Result = sdmmc_host_do_transaction(Slot, Command);
    LastCommand = Command->opcode;
    LastCommandError = Result == ESP_OK ? Command->error : Result;
    if (LastCommandError == ESP_OK && (Command->flags & SCF_RSP_PRESENT))
        CardResponded = true;
    return Result;
}

esp_err_t SDCard_Mount(sdmmc_card_t **const ppCard)
{
    if (ppCard == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }

    portENTER_CRITICAL(&GateInitLock);
    if (MountGate == NULL) MountGate = xSemaphoreCreateMutexStatic(&MountGateStorage);
    portEXIT_CRITICAL(&GateInitLock);
    if (MountGate == NULL) return ESP_ERR_NO_MEM;
    if (xSemaphoreTake(MountGate, pdMS_TO_TICKS(250)) != pdTRUE) return ESP_ERR_INVALID_STATE;
    *ppCard = NULL;
    sdmmc_host_t Host = SDMMC_HOST_DEFAULT();
    Host.do_transaction = MountTransaction;
    CardResponded = false;
    LastCommand = -1;
    LastCommandError = ESP_OK;
    sdmmc_slot_config_t Slot = SDMMC_SLOT_CONFIG_DEFAULT();
    Slot.width = 1;
    Slot.flags |= SDMMC_SLOT_FLAG_INTERNAL_PULLUP;

    const esp_vfs_fat_sdmmc_mount_config_t MountConfig = {
        .format_if_mount_failed = false,
        .max_files = kMaxOpenFiles,
        .allocation_unit_size = kAllocationUnitSize,
    };

    esp_err_t Result = esp_vfs_fat_sdmmc_mount(MountPoint, &Host, &Slot, &MountConfig, ppCard);
    if (Result != ESP_OK)
    {
        printf("SDCARD_MOUNT error=%s responded=%u command=%d command_error=%s\n",
               esp_err_to_name(Result), CardResponded ? 1 : 0, LastCommand,
               esp_err_to_name(LastCommandError));
        if (Result == ESP_ERR_TIMEOUT && !CardResponded)
            Result = ESP_ERR_NOT_FOUND;
        xSemaphoreGive(MountGate);
    }
    return Result;
}

esp_err_t SDCard_ProbeReadWrite(void)
{
    esp_err_t Result = ESP_FAIL;
    bool CreatedProbe = false;
    FILE *pFile = NULL;

    struct stat ExistingFile;
    if (stat(ProbePath, &ExistingFile) == 0)
    {
        ESP_LOGE(TAG, "Refusing to replace existing probe path %s", ProbePath);
        printf("SDTEST_STAGE=probe_exists\r\n");
        return ESP_ERR_INVALID_STATE;
    }
    if (errno != ENOENT)
    {
        ESP_LOGE(TAG, "Cannot inspect probe path: errno=%d", errno);
        printf("SDTEST_STAGE=stat errno=%d\r\n", errno);
        return ESP_FAIL;
    }

    pFile = fopen(ProbePath, "wb");
    if (pFile == NULL)
    {
        ESP_LOGE(TAG, "Probe create failed: errno=%d", errno);
        printf("SDTEST_STAGE=create errno=%d\r\n", errno);
        return ESP_FAIL;
    }
    CreatedProbe = true;

    if (fwrite(ProbeData, sizeof(ProbeData), 1, pFile) != 1)
    {
        ESP_LOGE(TAG, "Probe write failed: errno=%d", errno);
        printf("SDTEST_STAGE=write errno=%d\r\n", errno);
        goto Cleanup;
    }

    if (fflush(pFile) != 0)
    {
        ESP_LOGE(TAG, "Probe flush failed: errno=%d", errno);
        printf("SDTEST_STAGE=flush errno=%d\r\n", errno);
        goto Cleanup;
    }

    if (fsync(fileno(pFile)) != 0)
    {
        ESP_LOGE(TAG, "Probe sync failed: errno=%d", errno);
        printf("SDTEST_STAGE=sync errno=%d\r\n", errno);
        goto Cleanup;
    }

    if (fclose(pFile) != 0)
    {
        pFile = NULL;
        ESP_LOGE(TAG, "Probe close failed: errno=%d", errno);
        printf("SDTEST_STAGE=write_close errno=%d\r\n", errno);
        goto Cleanup;
    }
    pFile = NULL;

    pFile = fopen(ProbePath, "rb");
    if (pFile == NULL)
    {
        ESP_LOGE(TAG, "Probe reopen failed: errno=%d", errno);
        printf("SDTEST_STAGE=reopen errno=%d\r\n", errno);
        goto Cleanup;
    }

    uint8_t Readback[sizeof(ProbeData)] = {0};
    if ((fread(Readback, sizeof(Readback), 1, pFile) != 1) ||
        (memcmp(Readback, ProbeData, sizeof(ProbeData)) != 0) ||
        (fgetc(pFile) != EOF))
    {
        ESP_LOGE(TAG, "Probe readback did not match");
        printf("SDTEST_STAGE=readback errno=%d\r\n", errno);
        Result = ESP_ERR_INVALID_RESPONSE;
        goto Cleanup;
    }

    Result = ESP_OK;

Cleanup:
    if (pFile != NULL)
    {
        if ((fclose(pFile) != 0) && (Result == ESP_OK))
        {
            ESP_LOGE(TAG, "Probe close failed: errno=%d", errno);
            printf("SDTEST_STAGE=read_close errno=%d\r\n", errno);
            Result = ESP_FAIL;
        }
    }

    if (CreatedProbe && (unlink(ProbePath) != 0))
    {
        ESP_LOGE(TAG, "Probe cleanup failed: errno=%d", errno);
        printf("SDTEST_STAGE=cleanup errno=%d\r\n", errno);
        if (Result == ESP_OK)
        {
            Result = ESP_FAIL;
        }
    }

    return Result;
}

esp_err_t SDCard_RunReadWriteTest(void)
{
    sdmmc_card_t *pCard = NULL;
    esp_err_t Result = SDCard_Mount(&pCard);
    if (Result != ESP_OK)
    {
        ESP_LOGE(TAG, "Mount failed: %s", esp_err_to_name(Result));
        return Result;
    }

    ESP_LOGI(TAG, "Card mounted in conservative 1-bit mode");
    sdmmc_card_print_info(stdout, pCard);

    Result = SDCard_ProbeReadWrite();
    printf("SDTEST_PROBE=%s (%s)\r\n",
           (Result == ESP_OK) ? "PASS" : "FAIL", esp_err_to_name(Result));
    const esp_err_t UnmountResult = SDCard_Unmount(pCard);
    printf("SDTEST_UNMOUNT=%s (%s)\r\n",
           (UnmountResult == ESP_OK) ? "PASS" : "FAIL", esp_err_to_name(UnmountResult));
    if (UnmountResult != ESP_OK)
    {
        ESP_LOGE(TAG, "Unmount failed: %s", esp_err_to_name(UnmountResult));
        if (Result == ESP_OK)
        {
            Result = UnmountResult;
        }
    }

    if (Result == ESP_OK)
    {
        ESP_LOGI(TAG, "SD read/write/sync test passed; card unmounted");
    }

    return Result;
}

esp_err_t SDCard_Unmount(sdmmc_card_t *const pCard)
{
    if (pCard == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    esp_err_t Result = esp_vfs_fat_sdcard_unmount(MountPoint, pCard);
    xSemaphoreGive(MountGate);
    return Result;
}

static int SDTestCommand(const int argc, char **const argv)
{
    (void)argc;
    (void)argv;

    const esp_err_t Result = SDCard_RunReadWriteTest();
    printf("{\"sdtest\":\"%s\",\"error\":\"%s\"}\r\n",
           (Result == ESP_OK) ? "pass" : "fail", esp_err_to_name(Result));
    return (Result == ESP_OK) ? 0 : 1;
}

esp_err_t SDCard_RegisterConsoleCommand(void)
{
    const esp_console_cmd_t Command = {
        .command = "sdtest",
        .help = "Safely test the internal microSD card, then unmount it",
        .hint = NULL,
        .func = SDTestCommand,
        .argtable = NULL,
    };

    return esp_console_cmd_register(&Command);
}
