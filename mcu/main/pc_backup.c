#include "pc_backup.h"
#include "pc_sd.h"

#include "cart_backup.h"
#include "cart_bulk.h"
#include "cart_link.h"
#include "cart_mapper.h"
#include "driver/uart.h"
#include "driver/uart_vfs.h"
#include "esp_check.h"
#include "esp_console.h"
#include "esp_log.h"
#include "esp_rom_crc.h"
#include "fpga_tx.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "mbedtls/base64.h"
#include "pc_backup_mode.h"
#include "pwrmgr.h"
#include "virtual_cart.h"

#include <stdbool.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

enum {
    kConsoleUart = UART_NUM_0,
    kLineBufferSize = 1536,
    kUploadRxBufferSize = 4096,
    kKeepalivePeriod_ms = 250,
    kKeepaliveStack = 6 * 1024,
    kKeepalivePriority = 3,
};

typedef struct {
    bool ArtifactOpen;
    CartBackupArtifact_t Artifact;
    uint32_t Sequence;
    uint32_t Size;
    uint32_t Crc;
} StreamContext_t;

typedef struct {
    CartSaveImportPhase_t Phase;
    uint32_t SaveRemaining;
    uint32_t SaveOffset;
    uint32_t Sequence;
    bool HasRtc;
    bool RtcPending;
} ImportContext_t;

static const char *TAG = "PCBackup";
static StaticSemaphore_t GateStorage;
static SemaphoreHandle_t Gate;
static bool TransportReady;
static bool ConsoleReady;
static bool SleepInhibited;
static TaskHandle_t ModeTask;
static bool ModeApplied;
static bool AppliedEnabled;
static char LineBuffer[kLineBufferSize];
static uint8_t FlashReadBuffer[kCartBulkBlockSize];

static esp_err_t ApplyModeLocked(void);

static void KeepaliveTask(void *pArg)
{
    (void)pArg;
    for (;;)
    {
        (void)ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(kKeepalivePeriod_ms));
        if (!TransportReady || Gate == NULL ||
            xSemaphoreTake(Gate, 0) != pdTRUE)
        {
            continue;
        }

        const bool Enabled = PCBackup_IsEnabled();
        if (!ModeApplied || AppliedEnabled != Enabled)
        {
            const esp_err_t Result = ApplyModeLocked();
            if (Result != ESP_OK)
            {
                ESP_LOGW(TAG, "PC mode transition pending: %s",
                         esp_err_to_name(Result));
            }
        }
        else if (Enabled)
        {
            (void)CartBackup_SetPCMode(true);
        }
        xSemaphoreGive(Gate);
    }
}

static const char *ArtifactName(CartBackupArtifact_t Artifact)
{
    switch (Artifact)
    {
        case kCartBackupArtifact_Rom: return "rom";
        case kCartBackupArtifact_Save: return "sav";
        case kCartBackupArtifact_Rtc: return "rtc";
        default: return "invalid";
    }
}

static void SetConsoleBaud(uint32_t Baud)
{
    if (!ConsoleReady)
    {
        return;
    }
    fflush(stdout);
    (void)uart_wait_tx_done(kConsoleUart, pdMS_TO_TICKS(100));
    const uart_config_t Config = {
        .baud_rate = Baud,
        .data_bits = UART_DATA_8_BITS,
        .parity = UART_PARITY_DISABLE,
        .stop_bits = UART_STOP_BITS_1,
        .flow_ctrl = UART_HW_FLOWCTRL_DISABLE,
        .source_clk = Baud > 1000000 ? UART_SCLK_DEFAULT : UART_SCLK_REF_TICK,
    };
    const esp_err_t Result = uart_param_config(kConsoleUart, &Config);
    if (Result != ESP_OK)
    {
        ESP_LOGE(TAG, "Console baud change failed: %s",
                 esp_err_to_name(Result));
    }
}

static esp_err_t EnableLocked(void)
{
    if (VirtualCart_IsBusy())
    {
        return ESP_ERR_INVALID_STATE;
    }
    if (!SleepInhibited)
    {
        PwrMgr_InhibitSleep();
        SleepInhibited = true;
    }
    if (VirtualCart_IsActive())
    {
        ESP_RETURN_ON_ERROR(VirtualCart_Stop(), TAG,
                            "stop virtual cartridge for PC mode");
    }
    return CartBackup_SetPCMode(true);
}

static esp_err_t ApplyModeLocked(void)
{
    const bool Enabled = PCBackup_IsEnabled();
    esp_err_t Result;
    if (Enabled)
    {
        Result = EnableLocked();
        SetConsoleBaud(kPCBackupConsoleBaud);
    }
    else
    {
        Result = CartBackup_IsPCModeActive()
                                 ? CartBackup_SetPCMode(false)
                                 : ESP_OK;
        SetConsoleBaud(kPCBackupNormalConsoleBaud);
        if (Result == ESP_OK && SleepInhibited)
        {
            PwrMgr_AllowSleep();
            SleepInhibited = false;
        }
    }
    ModeApplied = Result == ESP_OK;
    AppliedEnabled = Enabled;
    return Result;
}

static void ModeChanged(void)
{
    if (TransportReady) FPGA_Tx_SendSysCtl();
    if (ModeTask != NULL)
    {
        xTaskNotifyGive(ModeTask);
    }
}

static esp_err_t StreamInfo(void *pContext,
                            const CartBackupMetadata_t *pMetadata)
{
    (void)pContext;
    char TitleHex[sizeof(pMetadata->Title) * 2 + 1];
    size_t TitleLength = strnlen(pMetadata->Title,
                                 sizeof(pMetadata->Title));
    for (size_t Index = 0; Index < TitleLength; ++Index)
    {
        (void)snprintf(&TitleHex[Index * 2], 3, "%02x",
                       (unsigned)(uint8_t)pMetadata->Title[Index]);
    }
    TitleHex[TitleLength * 2] = '\0';
    printf("PCBACKUP INFO protocol=2 transport=usb-bulk title=%s type=%02x color=%u rom=%lu sav=%lu rtc=%u\n",
           TitleHex, pMetadata->Type, pMetadata->IsColor ? 1u : 0u,
           (unsigned long)pMetadata->RomSize,
           (unsigned long)pMetadata->SaveSize,
           pMetadata->HasRtc ? 1u : 0u);
    fflush(stdout);
    return ESP_OK;
}

static esp_err_t StreamBegin(void *pContext, CartBackupArtifact_t Artifact,
                             uint32_t Size)
{
    StreamContext_t *const pStream = pContext;
    if (pStream->ArtifactOpen)
    {
        return ESP_ERR_INVALID_STATE;
    }
    pStream->ArtifactOpen = true;
    pStream->Artifact = Artifact;
    pStream->Sequence = 0;
    pStream->Size = 0;
    pStream->Crc = 0;
    printf("PCBACKUP BEGIN kind=%s size=%lu\n", ArtifactName(Artifact),
           (unsigned long)Size);
    fflush(stdout);
    if (Artifact == kCartBackupArtifact_Rom ||
        Artifact == kCartBackupArtifact_Save)
    {
        ESP_RETURN_ON_ERROR(
            uart_wait_tx_done(kConsoleUart, pdMS_TO_TICKS(100)), TAG,
            "flush PC backup BEGIN");
    }
    return ESP_OK;
}

static esp_err_t StreamData(void *pContext, CartBackupArtifact_t Artifact,
                            const uint8_t *pData, size_t Size)
{
    StreamContext_t *const pStream = pContext;
    if (!pStream->ArtifactOpen || pStream->Artifact != Artifact ||
        pData == NULL || Size == 0)
    {
        return ESP_ERR_INVALID_STATE;
    }

    if (Artifact == kCartBackupArtifact_Rtc)
    {
        const uint32_t BlockCrc = esp_rom_crc32_le(0, pData, Size);
        const int PrefixLength = snprintf(
            LineBuffer, sizeof(LineBuffer),
            "PCBACKUP DATA kind=%s seq=%lu size=%u crc=%08lx data=",
            ArtifactName(Artifact), (unsigned long)pStream->Sequence,
            (unsigned)Size, (unsigned long)BlockCrc);
        if (PrefixLength < 0 || (size_t)PrefixLength >= sizeof(LineBuffer))
        {
            return ESP_ERR_INVALID_SIZE;
        }

        size_t EncodedLength = 0;
        const int EncodeResult = mbedtls_base64_encode(
            (unsigned char *)&LineBuffer[PrefixLength],
            sizeof(LineBuffer) - (size_t)PrefixLength - 2,
            &EncodedLength, pData, Size);
        if (EncodeResult != 0)
        {
            return ESP_ERR_INVALID_SIZE;
        }
        LineBuffer[PrefixLength + EncodedLength] = '\n';
        LineBuffer[PrefixLength + EncodedLength + 1] = '\0';
        if (fwrite(LineBuffer, PrefixLength + EncodedLength + 1, 1,
                   stdout) != 1)
        {
            return ESP_FAIL;
        }
        fflush(stdout);
    }

    pStream->Crc = esp_rom_crc32_le(pStream->Crc, pData, Size);
    pStream->Size += Size;
    ++pStream->Sequence;
    return ESP_OK;
}

static esp_err_t StreamEnd(void *pContext, CartBackupArtifact_t Artifact)
{
    StreamContext_t *const pStream = pContext;
    if (!pStream->ArtifactOpen || pStream->Artifact != Artifact)
    {
        return ESP_ERR_INVALID_STATE;
    }
    printf("PCBACKUP END kind=%s size=%lu crc=%08lx\n",
           ArtifactName(Artifact), (unsigned long)pStream->Size,
           (unsigned long)pStream->Crc);
    fflush(stdout);
    pStream->ArtifactOpen = false;
    return ESP_OK;
}

static int BackupCommand(int argc, char **argv)
{
    uint32_t Selection = 0;
    for (int Index = 1; Index < argc; ++Index)
    {
        if (strcmp(argv[Index], "--rom") == 0)
        {
            Selection |= kCartBackupSelectRom;
        }
        else if (strcmp(argv[Index], "--sav") == 0)
        {
            Selection |= kCartBackupSelectSave;
        }
        else
        {
            printf("PCBACKUP FAIL error=ESP_ERR_INVALID_ARG\n");
            return 1;
        }
    }
    if (Selection == 0 ||
        PCBackupMode_GetState() != kPCBackupModeState_On || Gate == NULL)
    {
        printf("PCBACKUP FAIL error=ESP_ERR_INVALID_STATE\n");
        return 1;
    }
    if (xSemaphoreTake(Gate, portMAX_DELAY) != pdTRUE)
    {
        printf("PCBACKUP FAIL error=ESP_ERR_TIMEOUT\n");
        return 1;
    }

    esp_err_t Result = EnableLocked();
    StreamContext_t Context = {0};
    if (Result == ESP_OK)
    {
        const CartBackupStreamSink_t Sink = {
            .OnInfo = StreamInfo,
            .OnBegin = StreamBegin,
            .OnData = StreamData,
            .OnEnd = StreamEnd,
        };
        Result = CartBackup_StreamToPC(Selection, &Sink, &Context);
    }
    xSemaphoreGive(Gate);

    printf("PCBACKUP %s error=%s\n", Result == ESP_OK ? "PASS" : "FAIL",
           esp_err_to_name(Result));
    fflush(stdout);
    return Result == ESP_OK ? 0 : 1;
}

static esp_err_t ImportInfo(void *pContext,
                            const CartBackupMetadata_t *pMetadata)
{
    (void)pContext;
    char TitleHex[sizeof(pMetadata->Title) * 2 + 1];
    const size_t TitleLength = strnlen(pMetadata->Title,
                                       sizeof(pMetadata->Title));
    for (size_t Index = 0; Index < TitleLength; ++Index)
    {
        (void)snprintf(&TitleHex[Index * 2], 3, "%02x",
                       (unsigned)(uint8_t)pMetadata->Title[Index]);
    }
    TitleHex[TitleLength * 2] = '\0';
    printf("PCIMPORT INFO protocol=1 transport=usb-bulk title=%s type=%02x color=%u rom=%lu sav=%lu rtc=%u\n",
           TitleHex, pMetadata->Type, pMetadata->IsColor ? 1u : 0u,
           (unsigned long)pMetadata->RomSize,
           (unsigned long)pMetadata->SaveSize,
           pMetadata->HasRtc ? 1u : 0u);
    fflush(stdout);
    return ESP_OK;
}

static const char *ImportPhaseName(CartSaveImportPhase_t Phase)
{
    return Phase == kCartSaveImportPhase_Validate ? "validate" : "write";
}

esp_err_t PCBackup_ReadUpload(uint8_t *pData, size_t Size)
{
    size_t Received = 0;
    const TickType_t Deadline = xTaskGetTickCount() + pdMS_TO_TICKS(5000);
    while (Received < Size && xTaskGetTickCount() < Deadline)
    {
        const int Count = uart_read_bytes(
            kConsoleUart, &pData[Received], Size - Received,
            pdMS_TO_TICKS(100));
        if (Count < 0)
        {
            return ESP_FAIL;
        }
        Received += (size_t)Count;
    }
    if (Received != Size)
    {
        return ESP_ERR_TIMEOUT;
    }

    return ESP_OK;
}

static esp_err_t ImportReady(void *pContext, CartSaveImportPhase_t Phase,
                             uint32_t SaveSize, bool HasRtc)
{
    ImportContext_t *const pImport = pContext;
    pImport->Phase = Phase;
    pImport->SaveRemaining = SaveSize;
    pImport->SaveOffset = 0;
    pImport->Sequence = 0;
    pImport->HasRtc = HasRtc;
    pImport->RtcPending = HasRtc;
    (void)uart_flush_input(kConsoleUart);
    printf("PCIMPORT READY phase=%s sav=%lu rtc=%u\n",
           ImportPhaseName(Phase), (unsigned long)SaveSize,
           HasRtc ? 1u : 0u);
    fflush(stdout);
    return uart_wait_tx_done(kConsoleUart, pdMS_TO_TICKS(100));
}

static esp_err_t ImportRead(void *pContext, uint8_t *pData, size_t Size)
{
    ImportContext_t *const pImport = pContext;
    const bool IsSave = pImport->SaveRemaining != 0;
    if (pData == NULL || Size == 0 ||
        (IsSave && Size > pImport->SaveRemaining) ||
        (!IsSave && (!pImport->RtcPending || Size != 4)))
    {
        return ESP_ERR_INVALID_STATE;
    }

    printf("PCIMPORT SEND phase=%s kind=%s seq=%lu offset=%lu size=%u\n",
           ImportPhaseName(pImport->Phase), IsSave ? "sav" : "rtc",
           (unsigned long)pImport->Sequence,
           (unsigned long)(IsSave ? pImport->SaveOffset : 0),
           (unsigned)Size);
    fflush(stdout);
    ESP_RETURN_ON_ERROR(
        uart_wait_tx_done(kConsoleUart, pdMS_TO_TICKS(100)), TAG,
        "flush save-import block request");

    ESP_RETURN_ON_ERROR(PCBackup_ReadUpload(pData, Size), TAG, "receive upload");

    if (IsSave)
    {
        pImport->SaveRemaining -= Size;
        pImport->SaveOffset += Size;
    }
    else
    {
        pImport->RtcPending = false;
    }
    ++pImport->Sequence;
    return ESP_OK;
}

static void ImportProgress(void *pContext, uint32_t Written, uint32_t Total)
{
    ImportContext_t *const pImport = pContext;
    printf("PCIMPORT PROGRESS phase=%s written=%lu total=%lu\n",
           ImportPhaseName(pImport->Phase), (unsigned long)Written,
           (unsigned long)Total);
    fflush(stdout);
}

static bool ParseUnsigned(const char *pText, int Base, uint32_t *pValue)
{
    if (pText == NULL || pValue == NULL || *pText == '\0')
    {
        return false;
    }
    errno = 0;
    char *pEnd = NULL;
    const unsigned long Value = strtoul(pText, &pEnd, Base);
    if (errno != 0 || pEnd == pText || *pEnd != '\0' ||
        Value > UINT32_MAX)
    {
        return false;
    }
    *pValue = (uint32_t)Value;
    return true;
}

static int ImportCommand(int argc, char **argv)
{
    uint32_t SaveSize = UINT32_MAX;
    uint32_t SaveCrc = 0;
    uint32_t RtcCrc = 0;
    bool HaveSaveCrc = false;
    bool HasRtc = false;
    for (int Index = 1; Index < argc; ++Index)
    {
        if (Index + 1 >= argc)
        {
            printf("PCIMPORT FAIL error=ESP_ERR_INVALID_ARG\n");
            return 1;
        }
        if (strcmp(argv[Index], "--size") == 0)
        {
            if (!ParseUnsigned(argv[++Index], 10, &SaveSize))
            {
                printf("PCIMPORT FAIL error=ESP_ERR_INVALID_ARG\n");
                return 1;
            }
        }
        else if (strcmp(argv[Index], "--crc") == 0)
        {
            HaveSaveCrc = ParseUnsigned(argv[++Index], 16, &SaveCrc);
            if (!HaveSaveCrc)
            {
                printf("PCIMPORT FAIL error=ESP_ERR_INVALID_ARG\n");
                return 1;
            }
        }
        else if (strcmp(argv[Index], "--rtc-crc") == 0)
        {
            HasRtc = ParseUnsigned(argv[++Index], 16, &RtcCrc);
            if (!HasRtc)
            {
                printf("PCIMPORT FAIL error=ESP_ERR_INVALID_ARG\n");
                return 1;
            }
        }
        else
        {
            printf("PCIMPORT FAIL error=ESP_ERR_INVALID_ARG\n");
            return 1;
        }
    }
    if (SaveSize == UINT32_MAX || !HaveSaveCrc ||
        PCBackupMode_GetState() != kPCBackupModeState_On || Gate == NULL)
    {
        printf("PCIMPORT FAIL error=ESP_ERR_INVALID_STATE\n");
        return 1;
    }
    if (xSemaphoreTake(Gate, portMAX_DELAY) != pdTRUE)
    {
        printf("PCIMPORT FAIL error=ESP_ERR_TIMEOUT\n");
        return 1;
    }

    esp_err_t Result = EnableLocked();
    ImportContext_t Context = {0};
    if (Result == ESP_OK)
    {
        const CartSaveImportSource_t Source = {
            .OnInfo = ImportInfo,
            .OnReady = ImportReady,
            .Read = ImportRead,
            .OnProgress = ImportProgress,
        };
        Result = CartBackup_ImportSaveFromPC(
            SaveSize, SaveCrc, HasRtc, RtcCrc, &Source, &Context);
    }
    xSemaphoreGive(Gate);

    printf("PCIMPORT %s error=%s\n", Result == ESP_OK ? "PASS" : "FAIL",
           esp_err_to_name(Result));
    fflush(stdout);
    return Result == ESP_OK ? 0 : 1;
}

static uint32_t ReadLE32(const uint8_t *pData)
{
    return (uint32_t)pData[0] | ((uint32_t)pData[1] << 8) |
           ((uint32_t)pData[2] << 16) | ((uint32_t)pData[3] << 24);
}

static uint16_t ReadLE16(const uint8_t *pData)
{
    return (uint16_t)pData[0] | ((uint16_t)pData[1] << 8);
}

static esp_err_t FlashWrites(const uint8_t *pData, size_t Count)
{
    for (size_t Index = 0; Index < Count; ++Index)
    {
        if (ReadLE16(&pData[Index * 3]) >= 0x8000u)
        {
            return ESP_ERR_INVALID_ARG;
        }
    }
    for (size_t Index = 0; Index < Count; ++Index)
    {
        ESP_RETURN_ON_ERROR(CartLink_WriteOnce(ReadLE16(&pData[Index * 3]),
                                               pData[Index * 3 + 2]),
                            TAG, "flash bus write");
    }
    return ESP_OK;
}

static esp_err_t FlashRequest(const CartMapperInfo_t *pMapper,
                              const uint8_t *pData, size_t Size,
                              size_t *pReplySize)
{
    *pReplySize = 0;
    switch (pData[0])
    {
        case 0:
            return Size == 1 ? ESP_OK : ESP_ERR_INVALID_SIZE;
        case 1:
        {
            if (Size != 3 || ReadLE16(&pData[1]) > 0x7c00u)
                return ESP_ERR_INVALID_ARG;
            ESP_RETURN_ON_ERROR(CartBulk_ReadBlock(ReadLE16(&pData[1]),
                                                   FlashReadBuffer),
                                TAG, "flash read");
            *pReplySize = sizeof(FlashReadBuffer);
            return ESP_OK;
        }
        case 2:
            if (Size < 4 || (Size - 1) % 3 != 0)
                return ESP_ERR_INVALID_SIZE;
            return FlashWrites(&pData[1], (Size - 1) / 3);
        case 3:
        {
            if (Size != 5) return ESP_ERR_INVALID_SIZE;
            CartMapperPlan_t Plan;
            if (!CartMapper_PlanRomBank(pMapper, ReadLE32(&pData[1]), &Plan))
                return ESP_ERR_NOT_SUPPORTED;
            for (size_t Index = 0; Index < Plan.WriteCount; ++Index)
            {
                ESP_RETURN_ON_ERROR(CartLink_WriteOnce(Plan.Writes[Index].Address,
                                                       Plan.Writes[Index].Value),
                                    TAG, "flash mapper bank");
            }
            if (pMapper->Kind != kCartMapper_Mbc5) return ESP_ERR_NOT_SUPPORTED;
            if (ReadLE32(&pData[1]) == 0)
            {
                ESP_RETURN_ON_ERROR(CartLink_WriteOnce(0x2000, 0), TAG, "MBC5 bank zero");
                ESP_RETURN_ON_ERROR(CartLink_WriteOnce(0x3000, 0), TAG, "MBC5 bank zero high");
            }
            Plan.WindowAddress = 0x4000;
            FlashReadBuffer[0] = Plan.WindowAddress;
            FlashReadBuffer[1] = Plan.WindowAddress >> 8;
            *pReplySize = 2;
            return ESP_OK;
        }
        case 4:
        {
            if (Size != 4 + kCartBulkBlockSize) return ESP_ERR_INVALID_SIZE;
            return CartBulk_ProgramCartBlock(ReadLE16(&pData[1]), &pData[4],
                                             pData[3]);
        }
        case 5:
        {
            if (Size != 4 || pData[3] == 0 || pData[3] > 16)
                return ESP_ERR_INVALID_SIZE;
            const uint16_t Address = ReadLE16(&pData[1]);
            const uint8_t Blocks = pData[3];
            if ((uint32_t)Address + Blocks * kCartBulkBlockSize > 0x8000u)
                return ESP_ERR_INVALID_ARG;
            printf("PCFLASH BULK size=%u\n", Blocks * kCartBulkBlockSize);
            fflush(stdout);
            ESP_RETURN_ON_ERROR(uart_wait_tx_done(kConsoleUart, pdMS_TO_TICKS(100)),
                                TAG, "flush flash bulk header");
            ESP_RETURN_ON_ERROR(CartBulk_ReadRangeBegin(Address, Blocks),
                                TAG, "flash verify range");
            uint32_t Crc = 0;
            for (uint8_t Index = 0; Index < Blocks; ++Index)
            {
                ESP_RETURN_ON_ERROR(CartBulk_ReadRangeNext(FlashReadBuffer),
                                    TAG, "flash verify block");
                Crc = esp_rom_crc32_le(Crc, FlashReadBuffer, kCartBulkBlockSize);
            }
            ESP_RETURN_ON_ERROR(CartBulk_ReadRangeEnd(), TAG, "flash verify end");
            for (unsigned Index = 0; Index < 4; ++Index)
                FlashReadBuffer[Index] = Crc >> (Index * 8);
            *pReplySize = 4;
            return ESP_OK;
        }
        default:
            return ESP_ERR_NOT_SUPPORTED;
    }
}

static esp_err_t FlashRun(void *pContext)
{
    const CartMapperInfo_t *const pMapper = pContext;
    (void)uart_flush_input(kConsoleUart);
    CartLinkResponse_t Capabilities = {0};
    ESP_RETURN_ON_ERROR(CartLink_TransactionOnce(kCartLinkOp_Ping, 0, 0,
                                                &Capabilities), TAG, "bulk writer capability");
    if (Capabilities.Status != 0 || Capabilities.Count != 4 ||
        Capabilities.Data[2] != 3)
        return ESP_ERR_NOT_SUPPORTED;
    printf("PCFLASH READY protocol=2 block=1024 bulk=3\n");
    fflush(stdout);
    ESP_RETURN_ON_ERROR(uart_wait_tx_done(kConsoleUart, pdMS_TO_TICKS(100)),
                        TAG, "flash ready");
    for (uint32_t Sequence = 0;; ++Sequence)
    {
        uint8_t Header[16];
        ESP_RETURN_ON_ERROR(PCBackup_ReadUpload(Header, sizeof(Header)), TAG,
                            "receive flash header");
        const uint32_t Size = ReadLE32(&Header[8]);
        if (memcmp(Header, "CF01", 4) != 0 ||
            ReadLE32(&Header[4]) != Sequence ||
            Size == 0 || Size > sizeof(LineBuffer))
            return ESP_ERR_INVALID_ARG;
        uint8_t *const pData = (uint8_t *)LineBuffer;
        ESP_RETURN_ON_ERROR(PCBackup_ReadUpload(pData, Size), TAG, "receive flash payload");
        if (esp_rom_crc32_le(0, pData, Size) != ReadLE32(&Header[12]))
            return ESP_ERR_INVALID_CRC;
        const bool Done = pData[0] == 0;
        size_t ReplySize;
        ESP_RETURN_ON_ERROR(FlashRequest(pMapper, pData, Size, &ReplySize),
                            TAG, "execute flash request");
        const uint32_t Crc = esp_rom_crc32_le(0, FlashReadBuffer, ReplySize);
        size_t EncodedSize = 0;
        if (ReplySize != 0 && mbedtls_base64_encode(
                (unsigned char *)LineBuffer, sizeof(LineBuffer) - 1,
                &EncodedSize, FlashReadBuffer, ReplySize) != 0)
            return ESP_ERR_INVALID_SIZE;
        LineBuffer[EncodedSize] = '\0';
        printf("PCFLASH OK seq=%lu size=%u crc=%08lx data=%s\n",
               (unsigned long)Sequence, (unsigned)ReplySize,
               (unsigned long)Crc, ReplySize == 0 ? "-" : LineBuffer);
        fflush(stdout);
        if (Done) return ESP_OK;
    }
}

static int FlashCommand(int argc, char **argv)
{
    uint32_t MapperType;
    CartMapperInfo_t Mapper;
    if (argc != 3 || strcmp(argv[1], "--mapper") != 0 ||
        !ParseUnsigned(argv[2], 16, &MapperType) || MapperType > UINT8_MAX ||
        !CartMapper_Decode(MapperType, &Mapper))
    {
        printf("PCFLASH FAIL error=ESP_ERR_INVALID_ARG\n");
        return 1;
    }
    if (!PCBackup_IsEnabled() || Gate == NULL)
    {
        printf("PCFLASH FAIL error=ESP_ERR_INVALID_STATE\n");
        return 1;
    }
    if (xSemaphoreTake(Gate, portMAX_DELAY) != pdTRUE)
    {
        printf("PCFLASH FAIL error=ESP_ERR_TIMEOUT\n");
        return 1;
    }
    esp_err_t Result = EnableLocked();
    if (Result == ESP_OK)
        Result = CartBackup_FlashSession(MapperType, FlashRun, &Mapper);
    (void)uart_flush_input(kConsoleUart);
    xSemaphoreGive(Gate);
    printf("PCFLASH %s error=%s\n", Result == ESP_OK ? "PASS" : "FAIL",
           esp_err_to_name(Result));
    fflush(stdout);
    return Result == ESP_OK ? 0 : 1;
}

esp_err_t PCBackup_Init(void)
{
    Gate = xSemaphoreCreateMutexStatic(&GateStorage);
    if (Gate == NULL)
    {
        return ESP_ERR_NO_MEM;
    }
    PCBackupMode_RegisterOnUpdateCb(ModeChanged);
    return xTaskCreate(KeepaliveTask, "pc_backup_keepalive",
                       kKeepaliveStack, NULL, kKeepalivePriority, &ModeTask) == pdPASS
               ? ESP_OK : ESP_ERR_NO_MEM;
}

uint32_t PCBackup_GetConsoleBaud(void)
{
    return PCBackup_IsEnabled()
               ? kPCBackupConsoleBaud
               : kPCBackupNormalConsoleBaud;
}

bool PCBackup_IsEnabled(void)
{
    return PCBackupMode_GetState() == kPCBackupModeState_On;
}

void PCBackup_TransportReady(void)
{
    if (Gate == NULL || xSemaphoreTake(Gate, portMAX_DELAY) != pdTRUE)
    {
        return;
    }
    TransportReady = true;
    const esp_err_t Result = ApplyModeLocked();
    xSemaphoreGive(Gate);
    if (Result != ESP_OK)
    {
        ESP_LOGE(TAG, "Saved PC backup mode could not start: %s",
                 esp_err_to_name(Result));
    }
}

void PCBackup_ConsoleReady(void)
{
    if (Gate == NULL || xSemaphoreTake(Gate, portMAX_DELAY) != pdTRUE)
    {
        return;
    }
    ConsoleReady = true;
    SetConsoleBaud(PCBackup_GetConsoleBaud());
    xSemaphoreGive(Gate);
}

esp_err_t PCBackup_ConfigureConsoleInput(void)
{
    fflush(stdout);
    ESP_RETURN_ON_ERROR(uart_wait_tx_done(kConsoleUart, pdMS_TO_TICKS(100)),
                        TAG, "drain console before RX resize");
    uart_vfs_dev_use_nonblocking(kConsoleUart);
    ESP_RETURN_ON_ERROR(uart_driver_delete(kConsoleUart), TAG,
                        "replace console RX ring");
    ESP_RETURN_ON_ERROR(uart_driver_install(kConsoleUart, kUploadRxBufferSize,
                                           0, 0, NULL, 0), TAG,
                        "install binary upload RX ring");
    uart_vfs_dev_use_driver(kConsoleUart);
    return ESP_OK;
}

static int SDCommand(int argc, char **argv)
{
    (void)argv;
    esp_err_t Result = ESP_ERR_INVALID_STATE;
    bool Ran = false;
    if (argc == 1 && PCBackup_IsEnabled() && Gate != NULL &&
        xSemaphoreTake(Gate, portMAX_DELAY) == pdTRUE)
    {
        Result = VirtualCart_IsBusy() ? ESP_ERR_INVALID_STATE : ESP_OK;
        if (Result == ESP_OK && VirtualCart_IsActive()) Result = VirtualCart_Stop();
        if (Result == ESP_OK) { Ran = true; Result = PCSD_Run(); }
        (void)uart_flush_input(kConsoleUart);
        xSemaphoreGive(Gate);
    }
    if (!Ran) printf("PCSD FAIL error=%s\n", esp_err_to_name(Result));
    fflush(stdout);
    return Result == ESP_OK ? 0 : 1;
}

static int StatusCommand(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    const bool Enabled = PCBackup_IsEnabled();
    int Present = -1;
    if (Enabled && Gate != NULL && xSemaphoreTake(Gate, pdMS_TO_TICKS(250)) == pdTRUE)
    {
        CartLinkResponse_t Reply = {0};
        if (CartLink_TransactionOnce(kCartLinkOp_Ping, 0, 0, &Reply) == ESP_OK &&
            Reply.Status == 0 && Reply.Count == 4)
            Present = (Reply.Data[1] & 2u) != 0;
        xSemaphoreGive(Gate);
    }
    printf("PCSTATUS enabled=%u cartridge=%d\n", Enabled ? 1 : 0, Present);
    fflush(stdout);
    return 0;
}

esp_err_t PCBackup_RegisterConsoleCommand(void)
{
    const esp_console_cmd_t Command = {
        .command = "pcbackup",
        .help = "Stream inserted cartridge data to the PC",
        .hint = "[--rom] [--sav]",
        .func = BackupCommand,
        .argtable = NULL,
    };
    ESP_RETURN_ON_ERROR(esp_console_cmd_register(&Command), TAG,
                        "register PC backup command");
    const esp_console_cmd_t Import = {
        .command = "pcimport",
        .help = "Import save RAM and optional RTC into inserted cartridge",
        .hint = "--size BYTES --crc HEX [--rtc-crc HEX]",
        .func = ImportCommand,
        .argtable = NULL,
    };
    ESP_RETURN_ON_ERROR(esp_console_cmd_register(&Import), TAG,
                        "register save import command");
    const esp_console_cmd_t Flash = {
        .command = "pcflash",
        .help = "PC-controlled flash cartridge access using the existing bus",
        .hint = "--mapper HEX",
        .func = FlashCommand,
        .argtable = NULL,
    };
    ESP_RETURN_ON_ERROR(esp_console_cmd_register(&Flash), TAG, "register flash");
    const esp_console_cmd_t SD = {
        .command = "pcsd", .help = "ChroMagician SD file access", .func = SDCommand,
    };
    ESP_RETURN_ON_ERROR(esp_console_cmd_register(&SD), TAG, "register SD access");
    const esp_console_cmd_t Status = {
        .command = "pcstatus", .help = "Report PC mode and physical cartridge presence",
        .func = StatusCommand,
    };
    return esp_console_cmd_register(&Status);
}
