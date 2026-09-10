#include "cart_backup.h"
#include "sd_publish.h"

#include "cart_backup_ui.h"
#include "cart_bulk.h"
#include "cart_link.h"
#include "cart_mapper.h"
#include "cart_rtc.h"
#include "esp_attr.h"
#include "esp_console.h"
#include "esp_check.h"
#include "esp_log.h"
#include "esp_rom_crc.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "pc_backup.h"
#include "pwrmgr.h"
#include "sd_card.h"

#include <dirent.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum {
    kHeaderAddress = 0x0100,
    kHeaderSize = 0x50,
    kBankSize = 0x4000,
    kRamBankSize = 0x2000,
    kIoBufferSize = kCartBulkBlockSize,
    kFileBufferSize = 16 * 1024,
    kRomBufferCount = 2,
    kRomWriterStack = 3 * 1024,
    kBackupTaskStack = 8 * 1024,
    kBackupTaskPriority = 4,
    kFileStemSize = 33,
    kPathSize = 96,
};

_Static_assert(kBankSize == kFileBufferSize,
               "ROM writer buffers must hold one complete mapper bank");

typedef struct {
    uint8_t Raw[kHeaderSize];
    char Title[17];
    CartMapperInfo_t Mapper;
    uint32_t RomSize;
    uint32_t RamSize;
    uint16_t GlobalChecksum;
    bool IsColor;
    bool HeaderTypeKnown;
} CartInfo_t;

typedef struct {
    CartMapperWrite_t Writes[kCartMapperMaxWrites];
    size_t Count;
} MapperWriteCache_t;

typedef struct {
    FILE *pFile;
    QueueHandle_t WorkQueue;
    QueueHandle_t FreeQueue;
    SemaphoreHandle_t Done;
    volatile esp_err_t Result;
    uint64_t Write_us;
    uint64_t Checksum_us;
    uint32_t Checksum;
    bool Active;
} RomWriter_t;

static const char *TAG = "CartBackup";
static const char *BackupDirectory = "/sdcard/CHROMAGIC/BACKUPS";
static portMUX_TYPE StateLock = portMUX_INITIALIZER_UNLOCKED;
static bool Running;
static bool PCModeActive;
static DRAM_ATTR uint8_t CartIoBuffer[kIoBufferSize];
static DRAM_ATTR uint8_t RomFileBuffer[kFileBufferSize];
static DRAM_ATTR uint8_t SaveFileBuffer[kFileBufferSize];
static uint8_t *const RomBankBuffers[kRomBufferCount] = {
    RomFileBuffer,
    SaveFileBuffer,
};

static const uint8_t NintendoLogo[48] = {
    0xce, 0xed, 0x66, 0x66, 0xcc, 0x0d, 0x00, 0x0b,
    0x03, 0x73, 0x00, 0x83, 0x00, 0x0c, 0x00, 0x0d,
    0x00, 0x08, 0x11, 0x1f, 0x88, 0x89, 0x00, 0x0e,
    0xdc, 0xcc, 0x6e, 0xe6, 0xdd, 0xdd, 0xd9, 0x99,
    0xbb, 0xbb, 0x67, 0x63, 0x6e, 0x0e, 0xec, 0xcc,
    0xdd, 0xdc, 0x99, 0x9f, 0xbb, 0xb9, 0x33, 0x3e,
};

static esp_err_t RunBackup(void);
static void BackupTask(void *pArg);
static bool BeginRun(void);
static void EndRun(void);

typedef esp_err_t (*DataSinkFn_t)(void *pContext, const uint8_t *pData,
                                  size_t Size);

static esp_err_t TransactionOk(CartLinkOperation_t Operation,
                               uint16_t Address, uint8_t Value,
                               CartLinkResponse_t *pResponse)
{
    const esp_err_t Result = CartLink_Transaction(Operation, Address, Value,
                                                  pResponse);
    if (Result != ESP_OK)
    {
        return Result;
    }
    return pResponse->Status == 0 ? ESP_OK : ESP_ERR_INVALID_RESPONSE;
}

static bool PingReportsMaintenanceActive(const CartLinkResponse_t *pResponse)
{
    return pResponse != NULL && pResponse->Count >= 2 &&
           (pResponse->Data[1] & 1u) != 0;
}

static esp_err_t MapperWrite(uint16_t Address, uint8_t Value)
{
    CartLinkResponse_t Response = {0};
    return TransactionOk(kCartLinkOp_Write, Address, Value, &Response);
}

static esp_err_t ApplyMapperPlan(const CartMapperPlan_t *pPlan,
                                 const char *pDescription)
{
    if (pPlan == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    for (size_t i = 0; i < pPlan->WriteCount; ++i)
    {
        ESP_RETURN_ON_ERROR(MapperWrite(pPlan->Writes[i].Address,
                                        pPlan->Writes[i].Value),
                            TAG, "%s", pDescription);
    }
    return ESP_OK;
}

static esp_err_t NormalizeMapperBeforeHeader(void)
{
    CartLinkResponse_t Response = {0};
    ESP_RETURN_ON_ERROR(TransactionOk(kCartLinkOp_Write, 0x0000, 0x00,
                                      &Response), TAG, "disable mapper RAM");
    ESP_RETURN_ON_ERROR(TransactionOk(kCartLinkOp_Write, 0x6000, 0x00,
                                      &Response), TAG, "reset mapper mode");
    ESP_RETURN_ON_ERROR(TransactionOk(kCartLinkOp_Write, 0x4000, 0x00,
                                      &Response), TAG, "reset mapper upper bank");
    ESP_RETURN_ON_ERROR(TransactionOk(kCartLinkOp_Write, 0x3000, 0x00,
                                      &Response), TAG, "reset mapper high bank");
    return TransactionOk(kCartLinkOp_Write, 0x2100, 0x01, &Response);
}

static esp_err_t DecodeHeader(CartInfo_t *pInfo)
{
    if (memcmp(&pInfo->Raw[4], NintendoLogo, sizeof(NintendoLogo)) != 0)
    {
        return ESP_ERR_INVALID_RESPONSE;
    }

    uint8_t Checksum = 0;
    for (size_t i = 0x34; i <= 0x4c; ++i)
    {
        Checksum = (uint8_t)(Checksum - pInfo->Raw[i] - 1);
    }
    if (Checksum != pInfo->Raw[0x4d])
    {
        return ESP_ERR_INVALID_CRC;
    }

    pInfo->IsColor = (pInfo->Raw[0x43] & 0x80) != 0;
    const size_t MaxTitleLength = pInfo->IsColor ? 15 : 16;
    size_t TitleLength = 0;
    while (TitleLength < MaxTitleLength &&
           pInfo->Raw[0x34 + TitleLength] != 0)
    {
        const uint8_t Character = pInfo->Raw[0x34 + TitleLength];
        if (Character < 0x20 || Character > 0x7e)
        {
            break;
        }
        pInfo->Title[TitleLength] = (char)Character;
        ++TitleLength;
    }
    pInfo->Title[TitleLength] = '\0';
    if (TitleLength == 0)
    {
        memcpy(pInfo->Title, "UNTITLED", 9);
    }

    const uint8_t Type = pInfo->Raw[0x47];
    pInfo->HeaderTypeKnown = true;
    if (!CartMapper_Decode(Type, &pInfo->Mapper))
    {
        return ESP_ERR_NOT_SUPPORTED;
    }

    const uint8_t RomCode = pInfo->Raw[0x48];
    if (RomCode <= 8)
    {
        pInfo->RomSize = 32u * 1024u << RomCode;
    }
    else if (RomCode >= 0x52 && RomCode <= 0x54)
    {
        static const uint8_t OddBanks[] = {72, 80, 96};
        pInfo->RomSize = (uint32_t)OddBanks[RomCode - 0x52] * kBankSize;
    }
    else
    {
        return ESP_ERR_NOT_SUPPORTED;
    }

    static const uint32_t RamSizes[] = {
        0, 2u * 1024u, 8u * 1024u, 32u * 1024u,
        128u * 1024u, 64u * 1024u,
    };
    const uint8_t RamCode = pInfo->Raw[0x49];
    if (RamCode >= sizeof(RamSizes) / sizeof(RamSizes[0]))
    {
        return ESP_ERR_NOT_SUPPORTED;
    }
    const uint32_t HeaderRamSize = RamSizes[RamCode];
    if (!CartMapper_ResolveGeometry(&pInfo->Mapper, pInfo->RomSize,
                                    HeaderRamSize, &pInfo->RamSize))
    {
        return ESP_ERR_NOT_SUPPORTED;
    }

    pInfo->GlobalChecksum = ((uint16_t)pInfo->Raw[0x4e] << 8) |
                            pInfo->Raw[0x4f];
    return ESP_OK;
}

static esp_err_t ReadCartInfo(CartInfo_t *pInfo)
{
    if (pInfo == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    ESP_RETURN_ON_ERROR(NormalizeMapperBeforeHeader(), TAG,
                        "normalize mapper before header");
    ESP_RETURN_ON_ERROR(CartBulk_ReadBlock(0, CartIoBuffer), TAG,
                        "read cartridge header block");
    memcpy(pInfo->Raw, &CartIoBuffer[kHeaderAddress], sizeof(pInfo->Raw));
    return DecodeHeader(pInfo);
}

static bool MapperWriteIsCached(const MapperWriteCache_t *pCache,
                                const CartMapperWrite_t *pWrite)
{
    for (size_t i = 0; i < pCache->Count; ++i)
    {
        if (pCache->Writes[i].Address == pWrite->Address)
        {
            return pCache->Writes[i].Value == pWrite->Value;
        }
    }
    return false;
}

static void CacheMapperWrite(MapperWriteCache_t *pCache,
                             const CartMapperWrite_t *pWrite)
{
    for (size_t i = 0; i < pCache->Count; ++i)
    {
        if (pCache->Writes[i].Address == pWrite->Address)
        {
            pCache->Writes[i].Value = pWrite->Value;
            return;
        }
    }
    if (pCache->Count < kCartMapperMaxWrites)
    {
        pCache->Writes[pCache->Count++] = *pWrite;
    }
}

static esp_err_t BeginRomBankRange(const CartInfo_t *pInfo, uint32_t Bank,
                                   MapperWriteCache_t *pCache)
{
    if (pInfo == NULL || pCache == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }

    CartMapperPlan_t Plan;
    if (!CartMapper_PlanRomBank(&pInfo->Mapper, Bank, &Plan))
    {
        return ESP_ERR_NOT_SUPPORTED;
    }

    CartMapperWrite_t Changed[kCartMapperMaxWrites];
    size_t ChangedCount = 0;
    for (size_t i = 0; i < Plan.WriteCount; ++i)
    {
        if (!MapperWriteIsCached(pCache, &Plan.Writes[i]))
        {
            Changed[ChangedCount++] = Plan.Writes[i];
        }
    }

    for (size_t i = 0; i + 1 < ChangedCount; ++i)
    {
        ESP_RETURN_ON_ERROR(MapperWrite(Changed[i].Address, Changed[i].Value),
                            TAG, "select ROM bank");
        CacheMapperWrite(pCache, &Changed[i]);
    }

    esp_err_t Result;
    if (ChangedCount == 0)
    {
        Result = CartBulk_ReadRangeBegin(
            Plan.WindowAddress, kBankSize / kCartBulkBlockSize);
    }
    else
    {
        const CartMapperWrite_t *pLast = &Changed[ChangedCount - 1];
        Result = CartBulk_ReadMappedRangeBegin(
            Plan.WindowAddress, kBankSize / kCartBulkBlockSize,
            pLast->Address, pLast->Value);
        if (Result == ESP_OK)
        {
            CacheMapperWrite(pCache, pLast);
        }
    }
    return Result;
}

static esp_err_t WriteAndSync(FILE *pFile, const uint8_t *pData, size_t Length)
{
    return fwrite(pData, 1, Length, pFile) == Length ? ESP_OK : ESP_FAIL;
}

static esp_err_t FinishFile(FILE **ppFile)
{
    if (ppFile == NULL || *ppFile == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    FILE *pFile = *ppFile;
    esp_err_t Result = ESP_OK;
    if (fflush(pFile) != 0 || fsync(fileno(pFile)) != 0)
    {
        Result = ESP_FAIL;
    }
    if (fclose(pFile) != 0)
    {
        Result = ESP_FAIL;
    }
    *ppFile = NULL;
    return Result;
}

static void RomWriterTask(void *pArg)
{
    RomWriter_t *pWriter = pArg;
    uint8_t BufferIndex;
    while (xQueueReceive(pWriter->WorkQueue, &BufferIndex,
                         portMAX_DELAY) == pdTRUE)
    {
        if (BufferIndex >= kRomBufferCount)
        {
            break;
        }
        int64_t Start_us = esp_timer_get_time();
        uint32_t BankSum = 0;
        for (size_t i = 0; i < kBankSize; ++i)
        {
            BankSum += RomBankBuffers[BufferIndex][i];
        }
        pWriter->Checksum += BankSum;
        pWriter->Checksum_us += esp_timer_get_time() - Start_us;
        Start_us = esp_timer_get_time();
        if (pWriter->Result == ESP_OK &&
            fwrite(RomBankBuffers[BufferIndex], 1, kBankSize,
                   pWriter->pFile) != kBankSize)
        {
            pWriter->Result = ESP_FAIL;
        }
        pWriter->Write_us += esp_timer_get_time() - Start_us;
        (void)xQueueSend(pWriter->FreeQueue, &BufferIndex, portMAX_DELAY);
    }
    (void)xSemaphoreGive(pWriter->Done);
    vTaskDelete(NULL);
}

static esp_err_t StartRomWriter(RomWriter_t *pWriter, FILE *pFile)
{
    if (pWriter == NULL || pFile == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    memset(pWriter, 0, sizeof(*pWriter));
    pWriter->pFile = pFile;
    pWriter->Result = ESP_OK;
    pWriter->WorkQueue = xQueueCreate(kRomBufferCount, sizeof(uint8_t));
    pWriter->FreeQueue = xQueueCreate(kRomBufferCount, sizeof(uint8_t));
    pWriter->Done = xSemaphoreCreateBinary();
    if (pWriter->WorkQueue == NULL || pWriter->FreeQueue == NULL ||
        pWriter->Done == NULL)
    {
        if (pWriter->WorkQueue != NULL) vQueueDelete(pWriter->WorkQueue);
        if (pWriter->FreeQueue != NULL) vQueueDelete(pWriter->FreeQueue);
        if (pWriter->Done != NULL) vSemaphoreDelete(pWriter->Done);
        memset(pWriter, 0, sizeof(*pWriter));
        return ESP_ERR_NO_MEM;
    }
    for (uint8_t i = 0; i < kRomBufferCount; ++i)
    {
        (void)xQueueSend(pWriter->FreeQueue, &i, 0);
    }
    if (xTaskCreate(RomWriterTask, "cart_sd_writer", kRomWriterStack,
                    pWriter, kBackupTaskPriority, NULL) != pdPASS)
    {
        vQueueDelete(pWriter->WorkQueue);
        vQueueDelete(pWriter->FreeQueue);
        vSemaphoreDelete(pWriter->Done);
        memset(pWriter, 0, sizeof(*pWriter));
        return ESP_ERR_NO_MEM;
    }
    pWriter->Active = true;
    return ESP_OK;
}

static esp_err_t StopRomWriter(RomWriter_t *pWriter)
{
    if (pWriter == NULL || !pWriter->Active)
    {
        return pWriter == NULL ? ESP_ERR_INVALID_ARG : pWriter->Result;
    }
    const uint8_t Stop = UINT8_MAX;
    if (xQueueSend(pWriter->WorkQueue, &Stop, portMAX_DELAY) != pdTRUE ||
        xSemaphoreTake(pWriter->Done, portMAX_DELAY) != pdTRUE)
    {
        pWriter->Result = ESP_FAIL;
    }
    pWriter->Active = false;
    vQueueDelete(pWriter->WorkQueue);
    vQueueDelete(pWriter->FreeQueue);
    vSemaphoreDelete(pWriter->Done);
    pWriter->WorkQueue = NULL;
    pWriter->FreeQueue = NULL;
    pWriter->Done = NULL;
    return pWriter->Result;
}

static esp_err_t DumpRom(const CartInfo_t *pInfo, RomWriter_t *pWriter)
{
    const uint32_t Banks = pInfo->RomSize / kBankSize;
    const int64_t Start_us = esp_timer_get_time();
    MapperWriteCache_t MapperCache = {0};
    uint64_t Begin_us = 0;
    uint64_t Read_us = 0;
    uint64_t Ui_us = 0;
    uint64_t End_us = 0;

    for (uint32_t Bank = 0; Bank < Banks; ++Bank)
    {
        uint8_t BufferIndex;
        if (xQueueReceive(pWriter->FreeQueue, &BufferIndex,
                          portMAX_DELAY) != pdTRUE)
        {
            return ESP_FAIL;
        }
        if (pWriter->Result != ESP_OK)
        {
            return pWriter->Result;
        }
        int64_t StepStart_us = esp_timer_get_time();
        ESP_RETURN_ON_ERROR(BeginRomBankRange(pInfo, Bank, &MapperCache),
                            TAG, "begin ROM bank range");
        Begin_us += esp_timer_get_time() - StepStart_us;
        for (uint32_t Offset = 0; Offset < kBankSize;
             Offset += sizeof(CartIoBuffer))
        {
            StepStart_us = esp_timer_get_time();
            uint8_t *const pBlock = &RomBankBuffers[BufferIndex][Offset];
            esp_err_t Result = CartBulk_ReadRangeNext(pBlock);
            Read_us += esp_timer_get_time() - StepStart_us;
            if (Result != ESP_OK)
            {
                printf("CARTBACKUP_FAIL_STAGE=rom-read bank=%lu offset=%04lx error=%s\n",
                       (unsigned long)Bank, (unsigned long)Offset,
                       esp_err_to_name(Result));
                return Result;
            }
            StepStart_us = esp_timer_get_time();
            CartBackupUI_SetProgress((uint8_t)((Bank * kBankSize + Offset) *
                                               80u / pInfo->RomSize),
                                     "READING ROM");
            Ui_us += esp_timer_get_time() - StepStart_us;
        }
        StepStart_us = esp_timer_get_time();
        ESP_RETURN_ON_ERROR(CartBulk_ReadRangeEnd(), TAG,
                            "finish ROM bank range");
        End_us += esp_timer_get_time() - StepStart_us;
        if (xQueueSend(pWriter->WorkQueue, &BufferIndex,
                       portMAX_DELAY) != pdTRUE)
        {
            return ESP_FAIL;
        }
        if (((Bank + 1) % 64u) == 0 || Bank + 1 == Banks)
        {
            printf("CARTBACKUP_ROM_PROGRESS=%lu/%lu elapsed_ms=%lld\n",
                   (unsigned long)(Bank + 1), (unsigned long)Banks,
                   (long long)((esp_timer_get_time() - Start_us) / 1000));
        }
    }
    printf("CARTBACKUP_ROM_TIMING begin_us=%llu read_us=%llu ui_us=%llu end_us=%llu\n",
           (unsigned long long)Begin_us, (unsigned long long)Read_us,
           (unsigned long long)Ui_us, (unsigned long long)End_us);
    return ESP_OK;
}

static esp_err_t ReadRam(const CartInfo_t *pInfo, DataSinkFn_t Sink,
                         void *pSinkContext, bool UpdateUI)
{
    if (pInfo == NULL || Sink == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    if (pInfo->RamSize == 0)
    {
        return ESP_OK;
    }
    CartMapperPlan_t Plan;
    if (!CartMapper_PlanRamEnable(&pInfo->Mapper, &Plan))
    {
        return ESP_ERR_NOT_SUPPORTED;
    }
    ESP_RETURN_ON_ERROR(ApplyMapperPlan(&Plan, "enable cartridge RAM"), TAG,
                        "mapper RAM enable plan");
    for (uint32_t Linear = 0; Linear < pInfo->RamSize;
         Linear += sizeof(CartIoBuffer))
    {
        const uint8_t Bank = Linear / kRamBankSize;
        const uint16_t Offset = Linear % kRamBankSize;
        const size_t Remaining = pInfo->RamSize - Linear;
        const size_t Chunk = Remaining < sizeof(CartIoBuffer)
            ? Remaining : sizeof(CartIoBuffer);
        if (Offset == 0)
        {
            ESP_LOGI(TAG, "save bank %u/%lu", (unsigned)(Bank + 1),
                     (unsigned long)((pInfo->RamSize + kRamBankSize - 1) /
                                     kRamBankSize));
            if (!CartMapper_PlanRamBank(&pInfo->Mapper, Bank, &Plan))
            {
                return ESP_ERR_NOT_SUPPORTED;
            }
            ESP_RETURN_ON_ERROR(ApplyMapperPlan(&Plan, "select RAM bank"),
                                TAG, "mapper RAM bank plan");
            const size_t BankRemaining = pInfo->RamSize - Linear;
            const size_t BankBytes = BankRemaining < kRamBankSize
                ? BankRemaining : kRamBankSize;
            const uint8_t BlockCount = (uint8_t)(
                (BankBytes + kCartBulkBlockSize - 1) /
                kCartBulkBlockSize);
            ESP_RETURN_ON_ERROR(CartBulk_ReadRangeBegin(0xa000, BlockCount),
                                TAG, "begin save bank range");
        }
        esp_err_t Result = CartBulk_ReadRangeNext(CartIoBuffer);
        if (Result != ESP_OK)
        {
            printf("CARTBACKUP_FAIL_STAGE=save-read bank=%u offset=%04x error=%s\n",
                   Bank, Offset, esp_err_to_name(Result));
            return Result;
        }
        if (pInfo->Mapper.Kind == kCartMapper_Mbc2)
        {
            for (size_t i = 0; i < Chunk; ++i)
            {
                CartIoBuffer[i] &= 0x0f;
            }
        }
        ESP_RETURN_ON_ERROR(Sink(pSinkContext, CartIoBuffer, Chunk), TAG,
                            "consume RAM");
        if (UpdateUI)
        {
            CartBackupUI_SetProgress(
                (uint8_t)(80u + Linear * 20u / pInfo->RamSize),
                "READING SAVE");
        }
        if ((Offset + sizeof(CartIoBuffer) >= kRamBankSize) ||
            (Linear + Chunk >= pInfo->RamSize))
        {
            ESP_RETURN_ON_ERROR(CartBulk_ReadRangeEnd(), TAG,
                                "finish save bank range");
        }
    }
    return ESP_OK;
}

static esp_err_t FileDataSink(void *pContext, const uint8_t *pData,
                              size_t Size)
{
    return WriteAndSync((FILE *)pContext, pData, Size);
}

static esp_err_t DumpRam(const CartInfo_t *pInfo, FILE *pFile)
{
    return ReadRam(pInfo, FileDataSink, pFile, true);
}

static void RestoreMapper(const CartInfo_t *pInfo)
{
    CartMapperPlan_t Plan;
    if (pInfo != NULL &&
        CartMapper_PlanRestore(&pInfo->Mapper, &Plan))
    {
        (void)ApplyMapperPlan(&Plan, "restore mapper");
    }
}

static void MakeFileStem(const char *pTitle, char Stem[kFileStemSize])
{
    size_t Out = 0;
    static const char *InvalidFatCharacters = "\"*/:<>?\\|";
    for (size_t i = 0;
         pTitle[i] != '\0' && Out + 1 < kFileStemSize;
         ++i)
    {
        const unsigned char Character = (unsigned char)pTitle[i];
        Stem[Out++] = Character < 0x20 || Character == 0x7f ||
                      strchr(InvalidFatCharacters, Character) != NULL
            ? '_' : (char)Character;
    }
    while (Out > 0 && (Stem[Out - 1] == ' ' || Stem[Out - 1] == '.'))
    {
        --Out;
    }
    Stem[Out] = '\0';
    if (Out == 0)
    {
        memcpy(Stem, "UNTITLED", sizeof("UNTITLED"));
    }
}

static void MakePaths(const CartInfo_t *pInfo,
                      char RomFinal[kPathSize],
                      char RomTemp[kPathSize],
                      char RomOld[kPathSize],
                      char SaveFinal[kPathSize],
                      char SaveTemp[kPathSize],
                      char SaveOld[kPathSize])
{
    char Stem[kFileStemSize];
    MakeFileStem(pInfo->Title, Stem);
    const char *RomExtension = pInfo->IsColor ? "gbc" : "gb";
    snprintf(RomFinal, kPathSize, "%s/%s.%s", BackupDirectory, Stem,
             RomExtension);
    snprintf(RomTemp, kPathSize, "%s/%s.%s.tmp", BackupDirectory, Stem,
             RomExtension);
    snprintf(RomOld, kPathSize, "%s/%s.%s.old", BackupDirectory, Stem,
             RomExtension);
    snprintf(SaveFinal, kPathSize, "%s/%s.sav", BackupDirectory, Stem);
    snprintf(SaveTemp, kPathSize, "%s/%s.sav.tmp", BackupDirectory, Stem);
    snprintf(SaveOld, kPathSize, "%s/%s.sav.old", BackupDirectory, Stem);
}

static bool EqualsIgnoreCase(const char *pLeft, const char *pRight)
{
    while (*pLeft != '\0' && *pRight != '\0')
    {
        char Left = *pLeft++, Right = *pRight++;
        if (Left >= 'a' && Left <= 'z') Left -= 'a' - 'A';
        if (Right >= 'a' && Right <= 'z') Right -= 'a' - 'A';
        if (Left != Right) return false;
    }
    return *pLeft == *pRight;
}

static bool IsNumberedCopy(const char *pName, const char *pStem,
                           const char *pExtension)
{
    const size_t StemLength = strlen(pStem);
    if (strncmp(pName, pStem, StemLength) != 0 ||
        pName[StemLength] != ' ' || pName[StemLength + 1] != '(')
    {
        return false;
    }
    const char *p = &pName[StemLength + 2];
    unsigned Number = 0, Digits = 0;
    while (*p >= '0' && *p <= '9')
    {
        Number = Number * 10 + (unsigned)(*p++ - '0');
        ++Digits;
    }
    return Digits > 0 && Number >= 2 && *p++ == ')' && *p++ == '.' &&
           EqualsIgnoreCase(p, pExtension);
}

static void MakeLegacyStem(const char *pTitle, char Stem[7])
{
    size_t Out = 0;
    for (size_t i = 0; pTitle[i] != '\0' && Out < 6; ++i)
    {
        char Character = pTitle[i];
        if (Character >= 'a' && Character <= 'z') Character -= 'a' - 'A';
        if ((Character >= 'A' && Character <= 'Z') ||
            (Character >= '0' && Character <= '9'))
        {
            Stem[Out++] = Character;
        }
    }
    if (Out == 0)
    {
        memcpy(Stem, "CART", 4);
        Out = 4;
    }
    Stem[Out] = '\0';
}

static bool IsLegacy83Copy(const char *pName, const char *pLegacyStem,
                           const char *pExtension)
{
    const size_t StemLength = strlen(pLegacyStem);
    if (strlen(pName) != StemLength + 3 + strlen(pExtension))
    {
        return false;
    }
    const char *p = &pName[StemLength];
    return strncmp(pName, pLegacyStem, StemLength) == 0 &&
           p[0] >= '0' && p[0] <= '9' &&
           p[1] >= '0' && p[1] <= '9' && p[2] == '.' &&
           EqualsIgnoreCase(&p[3], pExtension);
}

static void RemoveObsoleteCopies(const CartInfo_t *pInfo,
                                 const char *pRomFinal,
                                 const char *pSaveFinal)
{
    char Stem[kFileStemSize], LegacyStem[7];
    MakeFileStem(pInfo->Title, Stem);
    MakeLegacyStem(pInfo->Title, LegacyStem);
    const char *pRomExtension = pInfo->IsColor ? "gbc" : "gb";
    const char *pRomName = strrchr(pRomFinal, '/') + 1;
    const char *pSaveName = strrchr(pSaveFinal, '/') + 1;
    enum { kCleanupBatchSize = 8, kCleanupNameSize = 64,
           kCleanupMaximum = 128 };
    char Names[kCleanupBatchSize][kCleanupNameSize];
    unsigned TotalRemoved = 0;
    while (TotalRemoved < kCleanupMaximum)
    {
        DIR *pDirectory = opendir(BackupDirectory);
        if (pDirectory == NULL) return;
        unsigned Count = 0;
        struct dirent *pEntry;
        while (Count < kCleanupBatchSize &&
               (pEntry = readdir(pDirectory)) != NULL)
        {
            const bool ObsoleteRom =
                IsNumberedCopy(pEntry->d_name, Stem, pRomExtension) ||
                IsLegacy83Copy(pEntry->d_name, LegacyStem, pRomExtension);
            const bool ObsoleteSave = pInfo->RamSize > 0 &&
                (IsNumberedCopy(pEntry->d_name, Stem, "sav") ||
                 IsLegacy83Copy(pEntry->d_name, LegacyStem, "sav"));
            const size_t NameLength = strlen(pEntry->d_name);
            if ((!ObsoleteRom && !ObsoleteSave) ||
                EqualsIgnoreCase(pEntry->d_name,
                                 ObsoleteRom ? pRomName : pSaveName) ||
                NameLength >= kCleanupNameSize)
            {
                continue;
            }
            memcpy(Names[Count++], pEntry->d_name, NameLength + 1);
        }
        (void)closedir(pDirectory);
        if (Count == 0) break;

        unsigned RemovedThisPass = 0;
        for (unsigned i = 0; i < Count; ++i)
        {
            char Path[kPathSize];
            snprintf(Path, sizeof(Path), "%s/%s", BackupDirectory, Names[i]);
            if (unlink(Path) == 0)
            {
                printf("CARTBACKUP_REMOVED_OBSOLETE=%s\n", Path);
                ++RemovedThisPass;
                ++TotalRemoved;
            }
            vTaskDelay(1);
        }
        if (RemovedThisPass == 0) break;
    }
}

static esp_err_t VerifyPublishedFile(const char *pPath, uint32_t ExpectedSize,
                                     const uint8_t *pExpectedHeader)
{
    struct stat Stat;
    if (stat(pPath, &Stat) != 0 || !S_ISREG(Stat.st_mode) ||
        (uint32_t)Stat.st_size != ExpectedSize)
    {
        ESP_LOGE(TAG, "published file verification failed for %s", pPath);
        return ESP_ERR_INVALID_SIZE;
    }
    if (pExpectedHeader == NULL)
    {
        return ESP_OK;
    }

    FILE *pFile = fopen(pPath, "rb");
    uint8_t Header[kHeaderSize];
    if (pFile == NULL || fseek(pFile, kHeaderAddress, SEEK_SET) != 0 ||
        fread(Header, sizeof(Header), 1, pFile) != 1)
    {
        if (pFile != NULL) (void)fclose(pFile);
        return ESP_FAIL;
    }
    const bool Matches = memcmp(Header, pExpectedHeader, sizeof(Header)) == 0;
    if (fclose(pFile) != 0 || !Matches)
    {
        return ESP_ERR_INVALID_RESPONSE;
    }
    return ESP_OK;
}

typedef struct {
    const CartBackupStreamSink_t *pSink;
    void *pContext;
} PCSaveSinkContext_t;

static esp_err_t PCSaveDataSink(void *pContext, const uint8_t *pData,
                                size_t Size)
{
    PCSaveSinkContext_t *const pSinkContext = pContext;
    return pSinkContext->pSink->OnData(pSinkContext->pContext,
                                       kCartBackupArtifact_Save,
                                       pData, Size);
}

static esp_err_t StreamRom(const CartInfo_t *pInfo,
                               const CartBackupStreamSink_t *pSink,
                               void *pContext, bool ToUSB)
{
    ESP_RETURN_ON_ERROR(
        pSink->OnBegin(pContext, kCartBackupArtifact_Rom, pInfo->RomSize),
        TAG, "start PC ROM stream");

    MapperWriteCache_t MapperCache = {0};
    const uint32_t Banks = pInfo->RomSize / kBankSize;
    for (uint32_t Bank = 0; Bank < Banks; ++Bank)
    {
        ESP_RETURN_ON_ERROR(BeginRomBankRange(pInfo, Bank, &MapperCache),
                            TAG, "begin PC ROM bank");
        for (uint32_t Offset = 0; Offset < kBankSize;
             Offset += sizeof(CartIoBuffer))
        {
            ESP_RETURN_ON_ERROR(CartBulk_ReadRangeNext(CartIoBuffer), TAG,
                                "read PC ROM block");
            if (ToUSB)
            {
                ESP_RETURN_ON_ERROR(
                    pSink->OnData(pContext, kCartBackupArtifact_Rom,
                                  CartIoBuffer, sizeof(CartIoBuffer)),
                    TAG, "send PC ROM block");
            }
            else
            {
                memcpy(RomFileBuffer + Offset, CartIoBuffer, sizeof(CartIoBuffer));
            }
        }
        ESP_RETURN_ON_ERROR(CartBulk_ReadRangeEnd(), TAG,
                            "finish PC ROM bank");
        if (!ToUSB)
            ESP_RETURN_ON_ERROR(pSink->OnData(pContext, kCartBackupArtifact_Rom,
                                            RomFileBuffer, kBankSize),
                                TAG, "save ROM bank to SD");
    }
    return pSink->OnEnd(pContext, kCartBackupArtifact_Rom);
}

static esp_err_t StreamSaveToPC(const CartInfo_t *pInfo,
                                const CartBackupStreamSink_t *pSink,
                                void *pContext)
{
    ESP_RETURN_ON_ERROR(
        pSink->OnBegin(pContext, kCartBackupArtifact_Save, pInfo->RamSize),
        TAG, "start PC save stream");
    PCSaveSinkContext_t SinkContext = {
        .pSink = pSink,
        .pContext = pContext,
    };
    ESP_RETURN_ON_ERROR(ReadRam(pInfo, PCSaveDataSink, &SinkContext, false),
                        TAG, "read PC save");
    return pSink->OnEnd(pContext, kCartBackupArtifact_Save);
}

typedef struct {
    esp_err_t Error;
} RtcBusContext_t;

static bool RtcBusWrite(void *pContext, uint16_t Address, uint8_t Value)
{
    RtcBusContext_t *pBus = pContext;
    const esp_err_t Result = MapperWrite(Address, Value);
    if (pBus->Error == ESP_OK) pBus->Error = Result;
    return Result == ESP_OK;
}

static bool RtcBusRead(void *pContext, uint16_t Address, uint8_t *pData)
{
    RtcBusContext_t *pBus = pContext;
    const esp_err_t Result = CartBulk_ReadBlock(Address, pData);
    if (pBus->Error == ESP_OK) pBus->Error = Result;
    return Result == ESP_OK;
}

static CartRtcBus_t RtcBus(RtcBusContext_t *pContext)
{
    return (CartRtcBus_t) {
        .pContext = pContext, .Write = RtcBusWrite, .ReadBlock = RtcBusRead,
        .pBuffer = CartIoBuffer, .BufferSize = sizeof(CartIoBuffer),
    };
}

static esp_err_t RtcResult(CartRtcResult_t Result, const RtcBusContext_t *pBus)
{
    switch (Result)
    {
        case kCartRtc_Ok: return ESP_OK;
        case kCartRtc_NotPresent:
        case kCartRtc_Unconfirmed: return ESP_ERR_NOT_SUPPORTED;
        case kCartRtc_InvalidState: return ESP_ERR_INVALID_ARG;
        case kCartRtc_IoError: return pBus->Error != ESP_OK ? pBus->Error : ESP_FAIL;
        default: return ESP_ERR_INVALID_RESPONSE;
    }
}

static esp_err_t ProbePhysicalRtc(CartInfo_t *pInfo)
{
    if (!pInfo->Mapper.HasRtc) return ESP_OK;
    RtcBusContext_t Context = {0};
    const CartRtcBus_t Bus = RtcBus(&Context);
    CartRtcProbeDetail_t Detail;
    CartRtcResult_t Result = CartRtc_Probe(&Bus, &Detail);
    if (Result == kCartRtc_Unconfirmed)
    {
        vTaskDelay(pdMS_TO_TICKS(1100));
        Result = CartRtc_Probe(&Bus, &Detail);
    }
    if (Result == kCartRtc_NotPresent || Result == kCartRtc_Unconfirmed)
    {
        pInfo->Mapper.HasRtc = false;
        printf("CART_RTC_PROBE result=%s register=%02x address=%04x values=%02x/%02x\n",
               Result == kCartRtc_NotPresent ? "not_present" : "unconfirmed",
               Detail.Register, Detail.Address, Detail.FirstValue,
               Detail.DifferentValue);
        return ESP_OK;
    }
    return RtcResult(Result, &Context);
}

static esp_err_t ReadPhysicalRtc(uint32_t *pState)
{
    RtcBusContext_t Context = {0};
    const CartRtcBus_t Bus = RtcBus(&Context);
    return RtcResult(CartRtc_Read(&Bus, pState), &Context);
}

static esp_err_t StreamRtcToPC(const CartBackupStreamSink_t *pSink,
                               void *pContext)
{
    uint32_t State;
    ESP_RETURN_ON_ERROR(ReadPhysicalRtc(&State), TAG, "read physical RTC");
    const uint8_t Encoded[4] = {
        (uint8_t)State,
        (uint8_t)(State >> 8),
        (uint8_t)(State >> 16),
        (uint8_t)(State >> 24),
    };
    ESP_RETURN_ON_ERROR(
        pSink->OnBegin(pContext, kCartBackupArtifact_Rtc, sizeof(Encoded)),
        TAG, "start PC RTC stream");
    ESP_RETURN_ON_ERROR(
        pSink->OnData(pContext, kCartBackupArtifact_Rtc,
                      Encoded, sizeof(Encoded)),
        TAG, "send PC RTC state");
    return pSink->OnEnd(pContext, kCartBackupArtifact_Rtc);
}

static void FillMetadata(const CartInfo_t *pInfo,
                         CartBackupMetadata_t *pMetadata)
{
    *pMetadata = (CartBackupMetadata_t) {
        .Type = pInfo->Mapper.Type,
        .RomSize = pInfo->RomSize,
        .SaveSize = pInfo->RamSize,
        .IsColor = pInfo->IsColor,
        .HasRtc = pInfo->Mapper.HasRtc,
    };
    memcpy(pMetadata->Title, pInfo->Title, sizeof(pMetadata->Title));
}

typedef struct {
    uint32_t Offset;
    uint32_t Crc;
    uint32_t Size;
    uint8_t *pExtra;
    bool Compare;
    bool Mismatch;
} RtcSaveSnapshot_t;

static uint8_t *RtcSaveSnapshotData(const RtcSaveSnapshot_t *pSnapshot,
                                   uint32_t Offset)
{
    const size_t BufferedSize = sizeof(RomFileBuffer) + sizeof(SaveFileBuffer);
    return Offset < BufferedSize
        ? RomBankBuffers[Offset / kFileBufferSize] + Offset % kFileBufferSize
        : pSnapshot->pExtra + Offset - BufferedSize;
}

static esp_err_t RtcSaveSnapshotSink(void *pContext, const uint8_t *pData,
                                    size_t Size)
{
    RtcSaveSnapshot_t *pSnapshot = pContext;
    if (pSnapshot->Offset > pSnapshot->Size ||
        Size > pSnapshot->Size - pSnapshot->Offset)
        return ESP_ERR_INVALID_SIZE;
    uint8_t *pSaved = RtcSaveSnapshotData(pSnapshot, pSnapshot->Offset);
    if (pSnapshot->Compare)
        pSnapshot->Mismatch |= memcmp(pSaved, pData, Size) != 0;
    else
        memcpy(pSaved, pData, Size);
    pSnapshot->Offset += Size;
    pSnapshot->Crc = esp_rom_crc32_le(pSnapshot->Crc, pData, Size);
    return ESP_OK;
}

static esp_err_t ReadRtcSaveSnapshot(const CartInfo_t *pInfo,
                                     RtcSaveSnapshot_t *pSnapshot)
{
    if (pInfo->RamSize == 0) return ESP_OK;
    CartMapperPlan_t Plan;
    if (!CartMapper_PlanRamEnable(&pInfo->Mapper, &Plan))
        return ESP_ERR_NOT_SUPPORTED;
    ESP_RETURN_ON_ERROR(ApplyMapperPlan(&Plan, "enable RTC save check"), TAG,
                        "enable RTC save check");
    for (uint32_t Linear = 0; Linear < pInfo->RamSize; Linear += kIoBufferSize)
    {
        if (Linear % kRamBankSize == 0)
        {
            if (!CartMapper_PlanRamBank(&pInfo->Mapper, Linear / kRamBankSize, &Plan))
                return ESP_ERR_NOT_SUPPORTED;
            ESP_RETURN_ON_ERROR(ApplyMapperPlan(&Plan, "RTC save check bank"), TAG,
                                "RTC save check bank");
        }
        ESP_RETURN_ON_ERROR(CartBulk_ReadBlock(0xa000 + Linear % kRamBankSize,
                                               CartIoBuffer), TAG,
                            "read RTC save check block");
        ESP_RETURN_ON_ERROR(RtcSaveSnapshotSink(pSnapshot, CartIoBuffer,
                                                kIoBufferSize), TAG,
                            "capture/check RTC save block");
    }
    return ESP_OK;
}

static esp_err_t RestoreRtcSaveSnapshot(const CartInfo_t *pInfo,
                                       RtcSaveSnapshot_t *pSnapshot)
{
    CartMapperPlan_t Plan;
    if (!CartMapper_PlanRamEnable(&pInfo->Mapper, &Plan))
        return ESP_ERR_NOT_SUPPORTED;
    ESP_RETURN_ON_ERROR(ApplyMapperPlan(&Plan, "enable RTC save recovery"), TAG,
                        "enable RTC save recovery");
    for (uint32_t Linear = 0; Linear < pInfo->RamSize; Linear += kIoBufferSize)
    {
        if (Linear % kRamBankSize == 0)
        {
            if (!CartMapper_PlanRamBank(&pInfo->Mapper, Linear / kRamBankSize, &Plan))
                return ESP_ERR_NOT_SUPPORTED;
            ESP_RETURN_ON_ERROR(ApplyMapperPlan(&Plan, "RTC save recovery bank"),
                                TAG, "RTC save recovery bank");
        }
        const uint8_t *pSaved = RtcSaveSnapshotData(pSnapshot, Linear);
        ESP_RETURN_ON_ERROR(CartBulk_WriteCartBlock(0xa000 + Linear % kRamBankSize,
                                                   pSaved, kIoBufferSize), TAG,
                            "restore save after RTC alias");
    }
    RtcSaveSnapshot_t Check = {
        .Compare = true, .Size = pSnapshot->Size, .pExtra = pSnapshot->pExtra,
    };
    ESP_RETURN_ON_ERROR(ReadRtcSaveSnapshot(pInfo, &Check), TAG,
                        "verify RTC save recovery");
    return Check.Mismatch ? ESP_ERR_INVALID_CRC : ESP_OK;
}

static esp_err_t WritePhysicalRtc(const CartInfo_t *pInfo, uint32_t State,
                                  uint32_t ExpectedSaveCrc, uint8_t *pExtra)
{
    if (pInfo->RamSize > sizeof(RomFileBuffer) + sizeof(SaveFileBuffer) &&
        pExtra == NULL)
        return ESP_ERR_NO_MEM;
    RtcSaveSnapshot_t Snapshot = {.Size = pInfo->RamSize, .pExtra = pExtra};
    ESP_RETURN_ON_ERROR(ReadRtcSaveSnapshot(pInfo, &Snapshot), TAG,
                        "snapshot save before RTC write");
    if (Snapshot.Crc != ExpectedSaveCrc) return ESP_ERR_INVALID_CRC;
    RtcBusContext_t Context = {0};
    const CartRtcBus_t Bus = RtcBus(&Context);
    const esp_err_t Result = RtcResult(CartRtc_WriteAndVerify(&Bus, State), &Context);
    RtcSaveSnapshot_t Check = {
        .Compare = true, .Size = pInfo->RamSize, .pExtra = pExtra,
    };
    ESP_RETURN_ON_ERROR(ReadRtcSaveSnapshot(pInfo, &Check), TAG,
                        "check complete save after RTC write");
    if (Check.Mismatch)
    {
        ESP_RETURN_ON_ERROR(RestoreRtcSaveSnapshot(pInfo, &Snapshot), TAG,
                            "recover save after RTC alias");
        ESP_LOGE(TAG, "RTC writes changed save RAM; complete save restored and verified");
        return ESP_ERR_INVALID_RESPONSE;
    }
    return Result;
}

static esp_err_t ReceiveImportPass(
    const CartInfo_t *pInfo, uint32_t ExpectedSaveCrc, bool HasRtc,
    uint32_t ExpectedRtcCrc, bool Write,
    const CartSaveImportSource_t *pSource, void *pContext,
    uint32_t *pRtcState, uint8_t *pRtcSaveExtra)
{
    uint32_t SaveCrc = 0;
    CartMapperPlan_t Plan;
    if (Write && pInfo->RamSize != 0)
    {
        if (!CartMapper_PlanRamEnable(&pInfo->Mapper, &Plan))
        {
            return ESP_ERR_NOT_SUPPORTED;
        }
        ESP_RETURN_ON_ERROR(ApplyMapperPlan(&Plan, "enable imported RAM"),
                            TAG, "enable imported cartridge RAM");
    }

    for (uint32_t Linear = 0; Linear < pInfo->RamSize;
         Linear += sizeof(CartIoBuffer))
    {
        const size_t Remaining = pInfo->RamSize - Linear;
        const size_t Chunk = Remaining < sizeof(CartIoBuffer)
            ? Remaining : sizeof(CartIoBuffer);
        ESP_RETURN_ON_ERROR(pSource->Read(pContext, CartIoBuffer, Chunk), TAG,
                            "receive imported save block");
        SaveCrc = esp_rom_crc32_le(SaveCrc, CartIoBuffer, Chunk);
        if (!Write)
        {
            continue;
        }

        const uint8_t Bank = Linear / kRamBankSize;
        const uint16_t Offset = Linear % kRamBankSize;
        if (Offset == 0)
        {
            if (!CartMapper_PlanRamBank(&pInfo->Mapper, Bank, &Plan))
            {
                return ESP_ERR_NOT_SUPPORTED;
            }
            ESP_RETURN_ON_ERROR(ApplyMapperPlan(&Plan, "select imported RAM bank"),
                                TAG, "select imported cartridge RAM bank");
        }
        if (pInfo->Mapper.Kind == kCartMapper_Mbc2)
        {
            for (size_t Index = 0; Index < Chunk; ++Index)
            {
                CartIoBuffer[Index] &= 0x0f;
            }
        }

        const uint16_t Address = 0xa000 + Offset;
        ESP_RETURN_ON_ERROR(
            CartBulk_WriteCartBlock(Address, CartIoBuffer, Chunk), TAG,
            "write imported cartridge RAM block");
        ESP_RETURN_ON_ERROR(CartBulk_ReadBlock(Address, SaveFileBuffer), TAG,
                            "verify imported cartridge RAM block");
        for (size_t Index = 0; Index < Chunk; ++Index)
        {
            const uint8_t Actual = pInfo->Mapper.Kind == kCartMapper_Mbc2
                ? SaveFileBuffer[Index] & 0x0f : SaveFileBuffer[Index];
            if (Actual != CartIoBuffer[Index])
            {
                return ESP_ERR_INVALID_CRC;
            }
        }
        if (pSource->OnProgress != NULL)
        {
            pSource->OnProgress(pContext, Linear + Chunk,
                                pInfo->RamSize + (HasRtc ? 4u : 0u));
        }
    }
    if (SaveCrc != ExpectedSaveCrc)
    {
        return ESP_ERR_INVALID_CRC;
    }

    if (HasRtc)
    {
        uint8_t Encoded[4];
        ESP_RETURN_ON_ERROR(pSource->Read(pContext, Encoded, sizeof(Encoded)),
                            TAG, "receive imported RTC state");
        if (esp_rom_crc32_le(0, Encoded, sizeof(Encoded)) != ExpectedRtcCrc)
        {
            return ESP_ERR_INVALID_CRC;
        }
        const uint32_t State = (uint32_t)Encoded[0] |
                               ((uint32_t)Encoded[1] << 8) |
                               ((uint32_t)Encoded[2] << 16) |
                               ((uint32_t)Encoded[3] << 24);
        if (!CartRtc_IsStateValid(State) ||
            (Write && State != *pRtcState))
        {
            return ESP_ERR_INVALID_ARG;
        }
        *pRtcState = State;
        if (Write)
        {
            ESP_RETURN_ON_ERROR(WritePhysicalRtc(pInfo, State, ExpectedSaveCrc,
                                                 pRtcSaveExtra), TAG,
                                "write RTC and verify complete save");
            if (pSource->OnProgress != NULL)
            {
                pSource->OnProgress(pContext, pInfo->RamSize + 4u,
                                    pInfo->RamSize + 4u);
            }
        }
    }
    return ESP_OK;
}

bool CartBackup_IsPCModeActive(void)
{
    bool Active;
    portENTER_CRITICAL(&StateLock);
    Active = PCModeActive;
    portEXIT_CRITICAL(&StateLock);
    return Active;
}

esp_err_t CartBackup_SetPCMode(bool Enabled)
{
    if (!BeginRun())
    {
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t Result = CartBulk_Begin();
    bool BulkOpen = Result == ESP_OK;
    const bool SoftwareOwnsSession = CartBackup_IsPCModeActive();
    CartLinkResponse_t Response = {0};
    if (Result == ESP_OK)
    {
        Result = TransactionOk(kCartLinkOp_Ping, 0, 0, &Response);
    }
    bool HardwareActive = Result == ESP_OK &&
                          PingReportsMaintenanceActive(&Response);
    if (Result == ESP_OK && Enabled && HardwareActive &&
        !SoftwareOwnsSession)
    {
        Result = TransactionOk(kCartLinkOp_Exit, 0, 0, &Response);
        HardwareActive = false;
    }
    if (Result == ESP_OK && Enabled && !HardwareActive)
    {
        Result = TransactionOk(kCartLinkOp_Enter, 0, 1, &Response);
    }
    else if (Result == ESP_OK && !Enabled && HardwareActive)
    {
        Result = TransactionOk(kCartLinkOp_Exit, 0, 0, &Response);
    }
    if (Result == ESP_OK)
    {
        portENTER_CRITICAL(&StateLock);
        PCModeActive = Enabled;
        portEXIT_CRITICAL(&StateLock);
    }
    if (BulkOpen)
    {
        CartBulk_End();
    }
    EndRun();
    return Result;
}

esp_err_t CartBackup_FlashSession(uint8_t MapperType,
                                 esp_err_t (*Run)(void *pContext),
                                 void *pContext)
{
    CartMapperInfo_t Mapper;
    if (Run == NULL || !CartMapper_Decode(MapperType, &Mapper))
    {
        return ESP_ERR_INVALID_ARG;
    }
    if (!CartBackup_IsPCModeActive() || !BeginRun())
    {
        return ESP_ERR_INVALID_STATE;
    }
    esp_err_t Result = CartBulk_Begin();
    const bool BulkOpen = Result == ESP_OK;
    CartLinkResponse_t Response = {0};
    if (Result == ESP_OK)
    {
        Result = TransactionOk(kCartLinkOp_Ping, 0, 0, &Response);
    }
    if (Result == ESP_OK && (!PingReportsMaintenanceActive(&Response) ||
                            (Response.Data[1] & 2u) == 0))
    {
        Result = ESP_ERR_INVALID_STATE;
    }
    if (Result == ESP_OK)
    {
        Result = CartBulk_ReadRangeAbort();
    }
    if (Result == ESP_OK)
    {
        Result = Run(pContext);
    }
    if (BulkOpen)
    {
        (void)CartBulk_ReadRangeAbort();
        const esp_err_t Reset = CartLink_WriteOnce(0, 0xf0);
        if (Result == ESP_OK) Result = Reset;
        CartMapperPlan_t Plan;
        if (CartMapper_PlanRestore(&Mapper, &Plan))
        {
            const esp_err_t Restore = ApplyMapperPlan(&Plan, "restore flash mapper");
            if (Result == ESP_OK) Result = Restore;
        }
        CartBulk_End();
    }
    EndRun();
    return Result;
}

esp_err_t CartBackup_ImportSaveFromPC(
    uint32_t SaveSize, uint32_t SaveCrc, bool HasRtc, uint32_t RtcCrc,
    const CartSaveImportSource_t *pSource, void *pContext)
{
    if (pSource == NULL || pSource->OnInfo == NULL ||
        pSource->OnReady == NULL || pSource->Read == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    if (!CartBackup_IsPCModeActive() || !BeginRun())
    {
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t Result = CartBulk_Begin();
    const bool BulkOpen = Result == ESP_OK;
    bool InfoValid = false;
    CartInfo_t Info = {0};
    CartLinkResponse_t Response = {0};
    uint32_t RtcState = 0;
    uint8_t *pRtcSaveExtra = NULL;
    if (Result == ESP_OK)
    {
        Result = TransactionOk(kCartLinkOp_Ping, 0, 0, &Response);
    }
    if (Result == ESP_OK && !PingReportsMaintenanceActive(&Response))
    {
        Result = ESP_ERR_INVALID_STATE;
    }
    if (Result == ESP_OK)
    {
        Result = ReadCartInfo(&Info);
        InfoValid = Result == ESP_OK;
    }
    if (Result == ESP_OK)
    {
        Result = ProbePhysicalRtc(&Info);
    }
    if (Result == ESP_OK)
    {
        CartBackupMetadata_t Metadata;
        FillMetadata(&Info, &Metadata);
        Result = pSource->OnInfo(pContext, &Metadata);
    }
    if (Result == ESP_OK &&
        (SaveSize != Info.RamSize || (HasRtc && !Info.Mapper.HasRtc) ||
         (SaveSize == 0 && !HasRtc)))
    {
        Result = ESP_ERR_INVALID_SIZE;
    }
    if (Result == ESP_OK && HasRtc &&
        Info.RamSize > sizeof(RomFileBuffer) + sizeof(SaveFileBuffer))
    {
        pRtcSaveExtra = malloc(Info.RamSize - sizeof(RomFileBuffer) -
                               sizeof(SaveFileBuffer));
        if (pRtcSaveExtra == NULL) Result = ESP_ERR_NO_MEM;
    }
    if (Result == ESP_OK)
    {
        Result = pSource->OnReady(pContext, kCartSaveImportPhase_Validate,
                                  SaveSize, HasRtc);
    }
    if (Result == ESP_OK)
    {
        Result = ReceiveImportPass(&Info, SaveCrc, HasRtc, RtcCrc, false,
                                   pSource, pContext, &RtcState, pRtcSaveExtra);
    }
    if (Result == ESP_OK)
    {
        Result = pSource->OnReady(pContext, kCartSaveImportPhase_Write,
                                  SaveSize, HasRtc);
    }
    if (Result == ESP_OK)
    {
        Result = ReceiveImportPass(&Info, SaveCrc, HasRtc, RtcCrc, true,
                                   pSource, pContext, &RtcState, pRtcSaveExtra);
    }

    if (BulkOpen)
    {
        (void)CartBulk_ReadRangeAbort();
        if (InfoValid)
        {
            RestoreMapper(&Info);
        }
        CartBulk_End();
    }
    free(pRtcSaveExtra);
    EndRun();
    return Result;
}

static esp_err_t StreamBackup(uint32_t Selection,
                                const CartBackupStreamSink_t *pSink,
                                void *pContext, bool ToUSB)
{
    const uint32_t ValidSelection = kCartBackupSelectRom |
                                    kCartBackupSelectSave;
    if (Selection == 0 || (Selection & ~ValidSelection) != 0 ||
        pSink == NULL || pSink->OnInfo == NULL ||
        pSink->OnBegin == NULL || pSink->OnData == NULL ||
        pSink->OnEnd == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    if (!CartBackup_IsPCModeActive() || !BeginRun())
    {
        return ESP_ERR_INVALID_STATE;
    }

    esp_err_t Result = CartBulk_Begin();
    const bool BulkOpen = Result == ESP_OK;
    bool InfoValid = false;
    CartInfo_t Info = {0};
    CartLinkResponse_t Response = {0};
    if (Result == ESP_OK)
    {
        Result = TransactionOk(kCartLinkOp_Ping, 0, 0, &Response);
    }
    if (Result == ESP_OK && !PingReportsMaintenanceActive(&Response))
    {
        Result = ESP_ERR_INVALID_STATE;
    }
    const bool RestoreUSB = Result == ESP_OK && !ToUSB;
    if (RestoreUSB)
    {
        Result = TransactionOk(kCartLinkOp_Exit, 0, 0, &Response);
        if (Result == ESP_OK)
            Result = TransactionOk(kCartLinkOp_Enter, 0, 0, &Response);
    }
    if (Result == ESP_OK)
    {
        Result = ReadCartInfo(&Info);
        InfoValid = Result == ESP_OK;
    }
    if (Result == ESP_OK)
    {
        Result = ProbePhysicalRtc(&Info);
    }

    if (Result == ESP_OK)
    {
        CartBackupMetadata_t Metadata;
        FillMetadata(&Info, &Metadata);
        Result = pSink->OnInfo(pContext, &Metadata);
    }
    if (Result == ESP_OK &&
        (Selection == kCartBackupSelectSave &&
         Info.RamSize == 0 && !Info.Mapper.HasRtc))
    {
        Result = ESP_ERR_NOT_FOUND;
    }
    if (Result == ESP_OK && (Selection & kCartBackupSelectRom) != 0)
    {
        Result = StreamRom(&Info, pSink, pContext, ToUSB);
    }
    if (Result == ESP_OK && (Selection & kCartBackupSelectSave) != 0 &&
        Info.RamSize != 0)
    {
        Result = StreamSaveToPC(&Info, pSink, pContext);
    }
    if (Result == ESP_OK && (Selection & kCartBackupSelectSave) != 0 &&
        Info.Mapper.HasRtc)
    {
        Result = StreamRtcToPC(pSink, pContext);
    }

    if (BulkOpen)
    {
        (void)CartBulk_ReadRangeAbort();
        if (InfoValid)
        {
            RestoreMapper(&Info);
        }
        if (RestoreUSB)
        {
            esp_err_t Restore = TransactionOk(kCartLinkOp_Exit, 0, 0, &Response);
            if (Restore == ESP_OK)
                Restore = TransactionOk(kCartLinkOp_Enter, 0, 1, &Response);
            if (Result == ESP_OK) Result = Restore;
        }
        CartBulk_End();
    }
    EndRun();
    return Result;
}

esp_err_t CartBackup_StreamToPC(uint32_t Selection,
                                const CartBackupStreamSink_t *pSink,
                                void *pContext)
{
    return StreamBackup(Selection, pSink, pContext, true);
}

esp_err_t CartBackup_StreamToSD(uint32_t Selection,
                                const CartBackupStreamSink_t *pSink,
                                void *pContext)
{
    return StreamBackup(Selection, pSink, pContext, false);
}

static esp_err_t RunBackup(void)
{
    esp_err_t Result = ESP_FAIL;
    bool Acquired = false;
    bool BulkSessionOpen = false;
    bool Mounted = false;
    bool RomPublished = false;
    bool SavePublished = false;
    bool RomStaged = false;
    bool SaveStaged = false;
    sdmmc_card_t *pCard = NULL;
    FILE *pRom = NULL;
    FILE *pSave = NULL;
    RomWriter_t RomWriter = {0};
    CartInfo_t Info = {0};
    char RomFinal[kPathSize] = {0}, RomTemp[kPathSize] = {0};
    char RomOld[kPathSize] = {0};
    char SaveFinal[kPathSize] = {0}, SaveTemp[kPathSize] = {0};
    char SaveOld[kPathSize] = {0};
    char ErrorDetail[32] = {0};

    CartBackupUI_SetProgress(0, "CHECKING SD");
    Result = SDCard_Mount(&pCard);
    if (Result != ESP_OK)
    {
        snprintf(ErrorDetail, sizeof(ErrorDetail), "%s",
                 Result == ESP_ERR_NOT_FOUND ? "NO SD CARD INSTALLED" :
                 Result == ESP_ERR_TIMEOUT ? "SD CARD NOT RESPONDING" :
                 "COULD NOT READ SD CARD");
        goto Cleanup;
    }
    Mounted = true;
    Result = SDCard_ProbeReadWrite();
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }
    if ((mkdir("/sdcard/CHROMAGIC", 0775) != 0 && errno != EEXIST) ||
        (mkdir(BackupDirectory, 0775) != 0 && errno != EEXIST))
    {
        Result = ESP_FAIL;
        goto Cleanup;
    }

    CartBackupUI_SetProgress(0, "CHECKING CART");
    Result = CartBulk_Begin();
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }
    BulkSessionOpen = true;

    CartLinkResponse_t Response = {0};
    Result = TransactionOk(kCartLinkOp_Ping, 0, 0, &Response);
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }
    Result = TransactionOk(kCartLinkOp_Enter, 0, 0, &Response);
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }
    Acquired = true;

    Result = ReadCartInfo(&Info);
    if (Result != ESP_OK)
    {
        if (Result == ESP_ERR_NOT_SUPPORTED && Info.HeaderTypeKnown)
        {
            const char *pTypeName = CartMapper_TypeName(Info.Raw[0x47]);
            printf("CARTBACKUP_UNSUPPORTED type=0x%02x mapper=\"%s\" rom_code=0x%02x ram_code=0x%02x\n",
                   Info.Raw[0x47], pTypeName, Info.Raw[0x48], Info.Raw[0x49]);
            snprintf(ErrorDetail, sizeof(ErrorDetail), "TYPE %02X\n%.20s",
                     Info.Raw[0x47], pTypeName);
        }
        goto Cleanup;
    }
    printf("CARTBACKUP_START title=\"%s\" type=0x%02x mapper=\"%s\" rom=%lu save=%lu rtc=%u rumble=%u\n",
           Info.Title, Info.Mapper.Type,
           CartMapper_TypeName(Info.Mapper.Type),
           (unsigned long)Info.RomSize, (unsigned long)Info.RamSize,
           Info.Mapper.HasRtc ? 1u : 0u,
           Info.Mapper.HasRumble ? 1u : 0u);

    MakePaths(&Info, RomFinal, RomTemp, RomOld,
              SaveFinal, SaveTemp, SaveOld);
    Result = SDPublish_Recover(RomFinal, RomOld);
    if (Result == ESP_OK && Info.RamSize > 0)
    {
        Result = SDPublish_Recover(SaveFinal, SaveOld);
    }
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }

    pRom = fopen(RomTemp, "wb");
    if (pRom == NULL)
    {
        Result = ESP_FAIL;
        goto Cleanup;
    }
    if (setvbuf(pRom, NULL, _IONBF, 0) != 0)
    {
        Result = ESP_FAIL;
        goto Cleanup;
    }
    Result = StartRomWriter(&RomWriter, pRom);
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }
    const int64_t RomPipelineStart_us = esp_timer_get_time();
    Result = DumpRom(&Info, &RomWriter);
    if (Result == ESP_OK)
    {
        Result = StopRomWriter(&RomWriter);
    }
    if (Result == ESP_OK)
    {
        const uint32_t GlobalSum = RomWriter.Checksum - Info.Raw[0x4e] -
                                   Info.Raw[0x4f];
        if ((uint16_t)GlobalSum != Info.GlobalChecksum)
        {
            Result = ESP_ERR_INVALID_CRC;
        }
    }
    printf("CARTBACKUP_ROM_PIPELINE elapsed_ms=%lld sd_write_us=%llu checksum_us=%llu\n",
           (long long)((esp_timer_get_time() - RomPipelineStart_us) / 1000),
           (unsigned long long)RomWriter.Write_us,
           (unsigned long long)RomWriter.Checksum_us);
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }

    if (Info.RamSize > 0)
    {
        pSave = fopen(SaveTemp, "wb");
        if (pSave == NULL)
        {
            Result = ESP_FAIL;
            goto Cleanup;
        }
        if (setvbuf(pSave, (char *)SaveFileBuffer, _IOFBF,
                    sizeof(SaveFileBuffer)) != 0)
        {
            Result = ESP_FAIL;
            goto Cleanup;
        }
        Result = DumpRam(&Info, pSave);
        if (Result != ESP_OK)
        {
            goto Cleanup;
        }
    }

    RestoreMapper(&Info);
    Result = TransactionOk(kCartLinkOp_Exit, 0, 0, &Response);
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }
    Acquired = false;
    CartBulk_End();
    BulkSessionOpen = false;

    Result = FinishFile(&pRom);
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }
    if (pSave != NULL)
    {
        Result = FinishFile(&pSave);
        if (Result != ESP_OK)
        {
            goto Cleanup;
        }
    }

    Result = SDPublish_Stage(RomFinal, RomOld, &RomStaged);
    if (Result == ESP_OK && Info.RamSize > 0)
    {
        Result = SDPublish_Stage(SaveFinal, SaveOld, &SaveStaged);
    }
    if (Result != ESP_OK || rename(RomTemp, RomFinal) != 0)
    {
        Result = ESP_FAIL;
        goto Cleanup;
    }
    RomPublished = true;
    if (Info.RamSize > 0)
    {
        if (rename(SaveTemp, SaveFinal) != 0)
        {
            Result = ESP_FAIL;
            goto Cleanup;
        }
        SavePublished = true;
    }
    Result = VerifyPublishedFile(RomFinal, Info.RomSize, Info.Raw);
    if (Result != ESP_OK)
    {
        goto Cleanup;
    }
    if (Info.RamSize > 0)
    {
        Result = VerifyPublishedFile(SaveFinal, Info.RamSize, NULL);
        if (Result != ESP_OK)
        {
            goto Cleanup;
        }
    }
    if (RomStaged && unlink(RomOld) == 0) RomStaged = false;
    if (SaveStaged && unlink(SaveOld) == 0) SaveStaged = false;
    RemoveObsoleteCopies(&Info, RomFinal, SaveFinal);
    Result = ESP_OK;

Cleanup:
    if (RomWriter.Active)
    {
        const esp_err_t WriterResult = StopRomWriter(&RomWriter);
        if (Result == ESP_OK)
        {
            Result = WriterResult;
        }
    }
    if (pRom != NULL)
    {
        (void)fclose(pRom);
    }
    if (pSave != NULL)
    {
        (void)fclose(pSave);
    }
    if (Acquired)
    {
        (void)CartBulk_ReadRangeAbort();
        RestoreMapper(&Info);
        (void)TransactionOk(kCartLinkOp_Exit, 0, 0, &Response);
    }
    if (BulkSessionOpen)
    {
        CartBulk_End();
    }
    if (Result != ESP_OK)
    {
        if (RomTemp[0] != '\0') (void)unlink(RomTemp);
        if (SaveTemp[0] != '\0') (void)unlink(SaveTemp);
        if (RomPublished) (void)unlink(RomFinal);
        if (SavePublished) (void)unlink(SaveFinal);
        if (RomStaged) (void)rename(RomOld, RomFinal);
        if (SaveStaged) (void)rename(SaveOld, SaveFinal);
    }
    if (Mounted)
    {
        const esp_err_t UnmountResult = SDCard_Unmount(pCard);
        if (Result == ESP_OK && UnmountResult != ESP_OK)
        {
            Result = UnmountResult;
        }
    }

    if (Result == ESP_OK)
    {
        printf("CARTBACKUP_ROM=%s\n", RomFinal);
        if (Info.RamSize > 0) printf("CARTBACKUP_SAVE=%s\n", SaveFinal);
        printf("CARTBACKUP=PASS title=\"%s\" rom=%lu save=%lu\n",
               Info.Title, (unsigned long)Info.RomSize,
               (unsigned long)Info.RamSize);
        CartBackupUI_SetComplete(RomFinal);
    }
    else
    {
        printf("CARTBACKUP=FAIL error=%s\n", esp_err_to_name(Result));
        CartBackupUI_SetError(ErrorDetail[0] != '\0'
                                  ? ErrorDetail : esp_err_to_name(Result));
    }
    return Result;
}

static bool BeginRun(void)
{
    bool Started = false;
    portENTER_CRITICAL(&StateLock);
    if (!Running)
    {
        Running = true;
        Started = true;
    }
    portEXIT_CRITICAL(&StateLock);
    return Started;
}

static void EndRun(void)
{
    portENTER_CRITICAL(&StateLock);
    Running = false;
    portEXIT_CRITICAL(&StateLock);
}

static void BackupTask(void *pArg)
{
    (void)pArg;
    PwrMgr_InhibitSleep();
    (void)RunBackup();
    PwrMgr_AllowSleep();
    EndRun();
    vTaskDelete(NULL);
}

esp_err_t CartBackup_Start(void)
{
    if (PCBackup_IsEnabled() || CartBackup_IsPCModeActive())
    {
        return ESP_ERR_INVALID_STATE;
    }
    if (!BeginRun())
    {
        return ESP_ERR_INVALID_STATE;
    }
    if (xTaskCreate(BackupTask, "cart_backup", kBackupTaskStack, NULL,
                    kBackupTaskPriority, NULL) != pdPASS)
    {
        EndRun();
        return ESP_ERR_NO_MEM;
    }
    return ESP_OK;
}

static int BackupCommand(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    const esp_err_t Result = CartBackup_Start();
    if (Result != ESP_OK)
    {
        printf("CARTBACKUP_LAUNCH=FAIL error=%s\n", esp_err_to_name(Result));
        return 1;
    }
    printf("CARTBACKUP_LAUNCH=PASS\n");
    return 0;
}

esp_err_t CartBackup_Init(void)
{
    CartBackupUI_RegisterStartCallback(CartBackup_Start);
    return ESP_OK;
}

esp_err_t CartBackup_RegisterConsoleCommand(void)
{
    const esp_console_cmd_t Command = {
        .command = "cartbackup",
        .help = "Back up the inserted supported cartridge ROM and save to SD",
        .hint = NULL,
        .func = BackupCommand,
        .argtable = NULL,
    };
    return esp_console_cmd_register(&Command);
}
