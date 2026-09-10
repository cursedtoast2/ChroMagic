#include "cart_bulk.h"

#include "cart_link.h"
#include "esp_attr.h"
#include "esp_check.h"
#include "esp_console.h"
#include "esp_log.h"
#include "esp_rom_crc.h"
#include "esp_timer.h"
#include "fpga_tx.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "pwrmgr.h"

#include <stdio.h>
#include <string.h>

enum {
    kCartReadCommand = 0x155,
    kCartReadAddress = 0x43420000,
    kCartBulkProtocol = 1,
    kCartBulkStatusReady = 1,
    kQspiAttempts = 3,
    kQspiTimeout_ms = 500,
    kStreamMaximumBlocks = 16,
    kStreamEventQueueDepth = 4,
    kStreamEventTimeout_ms = 20,
    kStreamAckRetries = 3,
    kVirtualReadPolls = 100,
    kMaintenanceDisplayPeriod_ms = 100,
    kUploadStatusAddress = kCartReadAddress | 0x00000800,
    kVirtualBlockAddress = kCartReadAddress | 0x00001000,
    kCartWriteAddress = 0x80000000,
    kUploadSequenceMaximum = 0x7f,
    kUploadCompletionTimeout_us = 500000,
};

typedef struct {
    uint8_t Sequence;
} StreamEvent_t;

static const char *TAG = "CartBulk";
static spi_device_handle_t Qspi;
static StaticSemaphore_t QspiGateStorage;
static SemaphoreHandle_t QspiGate;
static StaticQueue_t StreamEventQueueStorage;
static uint8_t StreamEventQueueBuffer[kStreamEventQueueDepth *
                                      sizeof(StreamEvent_t)];
static QueueHandle_t StreamEventQueue;
static volatile bool SessionActive;
static bool StreamActive;
static uint8_t StreamExpectedSequence;
static bool StreamLastAckValid;
static uint8_t StreamLastAckSequence;
static bool StreamPendingValid;
static uint8_t StreamPendingSequence;
static uint8_t StreamBlocksRemaining;
static size_t DisplayTransactionsOutstanding;
static uint8_t UploadSequence;
static int64_t LastMaintenanceDisplay_us;
static bool MeasureStressTiming;
static uint64_t StressEventWait_us;
static uint64_t StressDisplayWait_us;
static uint64_t StressQspi_us;
static uint64_t StressAck_us;
static DMA_ATTR uint8_t QspiResponse[kCartBulkMetadataSize +
                                     kCartBulkBlockSize];
static DMA_ATTR uint8_t QspiUpload[kCartBulkBlockSize];
static DMA_ATTR uint8_t QspiUploadStatus[8];
static DRAM_ATTR uint8_t DiagnosticBlock[kCartBulkBlockSize];
static DRAM_ATTR uint8_t StreamPendingBlock[kCartBulkBlockSize];

static uint32_t Crc32Byte(uint32_t Crc, uint8_t Data)
{
    Crc ^= Data;
    for (unsigned Bit = 0; Bit < 8; ++Bit)
    {
        Crc = (Crc & 1) ? ((Crc >> 1) ^ 0xedb88320u) : (Crc >> 1);
    }
    return Crc;
}

static uint32_t BlockCrc32(const uint8_t *pResponse)
{
    const uint8_t CoveredMetadata[] = {
        pResponse[3],
        pResponse[4],
        pResponse[6],
        pResponse[7],
    };
    uint32_t Crc = esp_rom_crc32_le(0, CoveredMetadata,
                                    sizeof(CoveredMetadata));
    return esp_rom_crc32_le(Crc,
                            &pResponse[kCartBulkMetadataSize],
                            kCartBulkBlockSize);
}

static uint32_t ReadLittleEndian32(const uint8_t *pData)
{
    return (uint32_t)pData[0] |
           ((uint32_t)pData[1] << 8) |
           ((uint32_t)pData[2] << 16) |
           ((uint32_t)pData[3] << 24);
}

static esp_err_t DrainDisplayTransactions(void)
{
    while (DisplayTransactionsOutstanding > 0)
    {
        spi_transaction_t *pCompleted = NULL;
        const esp_err_t Result = spi_device_get_trans_result(
            Qspi, &pCompleted, portMAX_DELAY);
        if (Result != ESP_OK)
        {
            return Result;
        }
        if (pCompleted == NULL || (pCompleted->cmd & 0x400) == 0)
        {
            return ESP_ERR_INVALID_STATE;
        }
        --DisplayTransactionsOutstanding;
    }
    return ESP_OK;
}

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

static esp_err_t ReadUploadStatus(bool *pReady, uint8_t *pSequence)
{
    spi_transaction_t Transaction = {
        .flags = SPI_TRANS_MODE_QIO,
        .cmd = kCartReadCommand,
        .addr = kUploadStatusAddress,
        .rxlength = sizeof(QspiUploadStatus) * 8,
        .rx_buffer = QspiUploadStatus,
    };
    ESP_RETURN_ON_ERROR(spi_device_polling_transmit(Qspi, &Transaction),
                        TAG, "read QSPI upload status");
    if (QspiUploadStatus[0] != 'C' || QspiUploadStatus[1] != 'B' ||
        QspiUploadStatus[2] != kCartBulkProtocol ||
        QspiUploadStatus[3] > 1 || QspiUploadStatus[5] != 0 ||
        QspiUploadStatus[6] != 0x00 || QspiUploadStatus[7] != 0x04)
    {
        return ESP_ERR_INVALID_RESPONSE;
    }
    *pReady = QspiUploadStatus[3] != 0;
    *pSequence = QspiUploadStatus[4];
    return ESP_OK;
}

static esp_err_t WaitForPSRAMWriter(bool RequireSequence,
                                    uint8_t ExpectedSequence)
{
    const int64_t Deadline = esp_timer_get_time() +
                             kUploadCompletionTimeout_us;
    do
    {
        bool Ready = false;
        uint8_t Sequence = 0;
        ESP_RETURN_ON_ERROR(ReadUploadStatus(&Ready, &Sequence), TAG,
                            "QSPI upload completion");
        if (Ready && (!RequireSequence || Sequence == ExpectedSequence))
        {
            return ESP_OK;
        }
    } while (esp_timer_get_time() < Deadline);
    return ESP_ERR_TIMEOUT;
}

static esp_err_t ReadQspiResponseAt(uint32_t Address)
{
    spi_transaction_t Transaction = {
        .flags = SPI_TRANS_MODE_QIO,
        .cmd = kCartReadCommand,
        .addr = Address,
        .rxlength = sizeof(QspiResponse) * 8,
        .rx_buffer = QspiResponse,
    };

    ESP_RETURN_ON_ERROR(spi_device_polling_start(Qspi, &Transaction,
                                                 portMAX_DELAY),
                        TAG, "start QSPI block read");
    return spi_device_polling_end(Qspi, pdMS_TO_TICKS(kQspiTimeout_ms));
}

static esp_err_t ValidateVirtualQspiResponse(uint16_t Sequence)
{
    if (QspiResponse[0] != 'C' || QspiResponse[1] != 'B' ||
        QspiResponse[2] != kCartBulkProtocol ||
        QspiResponse[3] != kCartBulkStatusReady ||
        QspiResponse[4] != (uint8_t)Sequence ||
        QspiResponse[5] != (uint8_t)(Sequence >> 8) ||
        QspiResponse[6] != 0x00 || QspiResponse[7] != 0x04)
    {
        return ESP_ERR_INVALID_RESPONSE;
    }
    return ESP_OK;
}

static esp_err_t ValidateQspiResponse(uint8_t Sequence,
                                      bool HasExpectedCrc,
                                      uint32_t ExpectedCrc)
{
    if (QspiResponse[0] != 'C' || QspiResponse[1] != 'B' ||
        QspiResponse[2] != kCartBulkProtocol ||
        QspiResponse[3] != kCartBulkStatusReady ||
        QspiResponse[4] != Sequence || QspiResponse[5] != 0 ||
        QspiResponse[6] != 0x00 || QspiResponse[7] != 0x04)
    {
        return ESP_ERR_INVALID_RESPONSE;
    }

    const uint32_t QspiCrc = ReadLittleEndian32(&QspiResponse[8]);
    if ((HasExpectedCrc && QspiCrc != ExpectedCrc) ||
        BlockCrc32(QspiResponse) != QspiCrc)
    {
        return ESP_ERR_INVALID_CRC;
    }
    return ESP_OK;
}

esp_err_t CartBulk_Init(spi_device_handle_t Spi)
{
    if (Spi == NULL)
    {
        return ESP_ERR_INVALID_ARG;
    }
    if (QspiGate != NULL)
    {
        return ESP_ERR_INVALID_STATE;
    }
    QspiGate = xSemaphoreCreateMutexStatic(&QspiGateStorage);
    StreamEventQueue = xQueueCreateStatic(kStreamEventQueueDepth,
                                           sizeof(StreamEvent_t),
                                           StreamEventQueueBuffer,
                                           &StreamEventQueueStorage);
    if (QspiGate == NULL || StreamEventQueue == NULL)
    {
        return ESP_ERR_NO_MEM;
    }

    Qspi = Spi;
    SessionActive = false;
    StreamActive = false;
    StreamLastAckValid = false;
    StreamPendingValid = false;
    StreamBlocksRemaining = 0;
    DisplayTransactionsOutstanding = 0;
    UploadSequence = 0;
    LastMaintenanceDisplay_us = 0;

    static const uint8_t Check[] = "123456789";
    uint32_t Crc = 0xffffffffu;
    for (size_t i = 0; i < sizeof(Check) - 1; ++i)
    {
        Crc = Crc32Byte(Crc, Check[i]);
    }
    const uint32_t Reference = Crc ^ 0xffffffffu;
    return Reference == 0xcbf43926u &&
           esp_rom_crc32_le(0, Check, sizeof(Check) - 1) == Reference
        ? ESP_OK : ESP_ERR_INVALID_CRC;
}

esp_err_t CartBulk_Begin(void)
{
    if (Qspi == NULL || QspiGate == NULL)
    {
        return ESP_ERR_INVALID_STATE;
    }
    if (SessionActive)
    {
        return ESP_ERR_INVALID_STATE;
    }
    PwrMgr_InhibitSleep();
    SessionActive = true;
    LastMaintenanceDisplay_us = 0;
    return ESP_OK;
}

void CartBulk_End(void)
{
    StreamActive = false;
    StreamLastAckValid = false;
    StreamPendingValid = false;
    StreamBlocksRemaining = 0;
    if (StreamEventQueue != NULL)
    {
        xQueueReset(StreamEventQueue);
    }
    if (SessionActive)
    {
        SessionActive = false;
        PwrMgr_AllowSleep();
    }
}

bool CartBulk_DisplayTransferBegin(void)
{
    if (SessionActive && LastMaintenanceDisplay_us != 0)
    {
        const int64_t Period_us = kMaintenanceDisplayPeriod_ms * 1000LL;
        const int64_t Elapsed_us = esp_timer_get_time() -
                                   LastMaintenanceDisplay_us;
        if (Elapsed_us < Period_us)
        {
            const TickType_t Delay = pdMS_TO_TICKS(
                (Period_us - Elapsed_us + 999) / 1000);
            if (Delay > 0)
            {
                vTaskDelay(Delay);
            }
        }
    }
    if (QspiGate == NULL ||
        xSemaphoreTake(QspiGate, portMAX_DELAY) != pdTRUE)
    {
        return false;
    }
    const esp_err_t Result = DrainDisplayTransactions();
    if (Result != ESP_OK)
    {
        ESP_LOGE(TAG, "cannot reap prior display frame: %s",
                 esp_err_to_name(Result));
        (void)xSemaphoreGive(QspiGate);
        return false;
    }
    if (SessionActive)
    {
        LastMaintenanceDisplay_us = esp_timer_get_time();
    }
    return true;
}

void CartBulk_DisplayTransactionQueued(void)
{
    ++DisplayTransactionsOutstanding;
}

void CartBulk_DisplayTransferEnd(void)
{
    if (QspiGate != NULL)
    {
        (void)xSemaphoreGive(QspiGate);
    }
}

esp_err_t CartBulk_ReadBlock(uint16_t Address,
                             uint8_t Data[kCartBulkBlockSize])
{
    if (!SessionActive || Data == NULL)
    {
        return ESP_ERR_INVALID_STATE;
    }

    CartLinkResponse_t Response = {0};
    esp_err_t Result = TransactionOk(kCartLinkOp_ReadBlock, Address, 0,
                                     &Response);
    if (Result != ESP_OK)
    {
        printf("CARTBULK_FAIL stage=request address=%04x error=%s status=%u count=%u\n",
               Address, esp_err_to_name(Result), Response.Status,
               Response.Count);
        return Result;
    }
    if (Response.Count != 4)
    {
        printf("CARTBULK_FAIL stage=request-metadata address=%04x count=%u\n",
               Address, Response.Count);
        return ESP_ERR_INVALID_RESPONSE;
    }

    const uint8_t Sequence = Response.Tag;
    const uint32_t ExpectedCrc = ReadLittleEndian32(Response.Data);
    if (xSemaphoreTake(QspiGate, portMAX_DELAY) != pdTRUE)
    {
        return ESP_ERR_TIMEOUT;
    }

    Result = DrainDisplayTransactions();
    if (Result == ESP_OK)
    {
        Result = ESP_FAIL;
        for (unsigned Attempt = 0; Attempt < kQspiAttempts; ++Attempt)
        {
            Result = ReadQspiResponseAt(kCartReadAddress);
            if (Result == ESP_OK)
            {
                Result = ValidateQspiResponse(Sequence, true, ExpectedCrc);
            }
            if (Result == ESP_OK)
            {
                break;
            }
            ESP_LOGW(TAG, "QSPI block validation attempt %u failed: %s",
                     Attempt + 1, esp_err_to_name(Result));
        }
    }

    if (Result == ESP_OK)
    {
        memcpy(Data, &QspiResponse[kCartBulkMetadataSize],
               kCartBulkBlockSize);
    }
    (void)xSemaphoreGive(QspiGate);

    if (Result != ESP_OK)
    {
        printf("CARTBULK_FAIL stage=qspi address=%04x sequence=%u error=%s\n",
               Address, Sequence, esp_err_to_name(Result));
        return Result;
    }

    CartLinkResponse_t Ack = {0};
    Result = TransactionOk(kCartLinkOp_Ack, 0, Sequence, &Ack);
    if (Result != ESP_OK)
    {
        printf("CARTBULK_FAIL stage=ack address=%04x sequence=%u error=%s status=%u\n",
               Address, Sequence, esp_err_to_name(Result), Ack.Status);
    }
    return Result;
}

esp_err_t CartBulk_ReadVirtualBlock(
    uint16_t Sequence, uint8_t Data[kCartBulkBlockSize])
{
    if (!SessionActive || Data == NULL)
    {
        return ESP_ERR_INVALID_STATE;
    }
    if (xSemaphoreTake(QspiGate, portMAX_DELAY) != pdTRUE)
    {
        return ESP_ERR_TIMEOUT;
    }

    esp_err_t Result = DrainDisplayTransactions();
    if (Result == ESP_OK)
    {
        Result = ESP_ERR_TIMEOUT;
        for (unsigned Poll = 0; Poll < kVirtualReadPolls; ++Poll)
        {
            Result = ReadQspiResponseAt(kVirtualBlockAddress);
            if (Result == ESP_OK)
            {
                Result = ValidateVirtualQspiResponse(Sequence);
            }
            if (Result == ESP_OK)
            {
                memcpy(Data, &QspiResponse[kCartBulkMetadataSize],
                       kCartBulkBlockSize);

                Result = ReadQspiResponseAt(kVirtualBlockAddress);
                if (Result == ESP_OK)
                {
                    Result = ValidateVirtualQspiResponse(Sequence);
                }
                if (Result == ESP_OK &&
                    memcmp(Data, &QspiResponse[kCartBulkMetadataSize],
                           kCartBulkBlockSize) != 0)
                {
                    Result = ESP_ERR_INVALID_CRC;
                }
                if (Result == ESP_OK)
                {
                    break;
                }
            }
            vTaskDelay(1);
        }
    }
    (void)xSemaphoreGive(QspiGate);
    return Result;
}

esp_err_t CartBulk_WritePSRAMBlock(
    uint32_t Address, const uint8_t Data[kCartBulkBlockSize])
{
    if (!SessionActive || Data == NULL ||
        (Address & (kCartBulkBlockSize - 1u)) != 0 || Address >= (8u << 20))
    {
        return ESP_ERR_INVALID_ARG;
    }
    if (xSemaphoreTake(QspiGate, portMAX_DELAY) != pdTRUE)
    {
        return ESP_ERR_TIMEOUT;
    }

    const bool HadDisplayTransactions = DisplayTransactionsOutstanding != 0;
    esp_err_t Result = DrainDisplayTransactions();
    if (Result == ESP_OK && HadDisplayTransactions)
    {
        Result = WaitForPSRAMWriter(true, 0);
    }
    if (Result == ESP_OK)
    {
        ++UploadSequence;
        if (UploadSequence > kUploadSequenceMaximum)
        {
            UploadSequence = 1;
        }
        memcpy(QspiUpload, Data, sizeof(QspiUpload));
        spi_transaction_t Transaction = {
            .flags = SPI_TRANS_MODE_QIO,
            .cmd = 0x400 | (kCartBulkBlockSize - 1),
            .addr = Address | ((uint32_t)UploadSequence << 24),
            .length = kCartBulkBlockSize * 8,
            .tx_buffer = QspiUpload,
        };
        Result = spi_device_polling_transmit(Qspi, &Transaction);

        if (Result == ESP_OK)
        {
            Result = WaitForPSRAMWriter(true, UploadSequence);
        }
    }

    (void)xSemaphoreGive(QspiGate);
    return Result;
}

static esp_err_t WriteStagedCartBlock(uint16_t Address, const uint8_t *pData,
                                      size_t Size, uint8_t Mode)
{
    if (xSemaphoreTake(QspiGate, portMAX_DELAY) != pdTRUE)
    {
        return ESP_ERR_TIMEOUT;
    }

    esp_err_t Result = DrainDisplayTransactions();
    if (Result == ESP_OK)
    {
        memcpy(QspiUpload, pData, Size);
        if (Size != sizeof(QspiUpload))
        {
            memset(&QspiUpload[Size], 0xff, sizeof(QspiUpload) - Size);
        }
        spi_transaction_t Transaction = {
            .flags = SPI_TRANS_MODE_QIO,
            .cmd = 0x400 | (kCartBulkBlockSize - 1),
            .addr = kCartWriteAddress,
            .length = kCartBulkBlockSize * 8,
            .tx_buffer = QspiUpload,
        };
        Result = spi_device_polling_transmit(Qspi, &Transaction);
        if (Result == ESP_OK && Mode >= 0x82)
        {
            Result = ReadQspiResponseAt(kCartReadAddress);
            if (Result == ESP_OK &&
                memcmp(pData, &QspiResponse[kCartBulkMetadataSize], Size) != 0)
                Result = ESP_ERR_INVALID_CRC;
        }
    }
    (void)xSemaphoreGive(QspiGate);

    if (Result == ESP_OK)
    {
        CartLinkResponse_t Response = {0};
        Result = Mode >= 0x82
            ? CartLink_TransactionOnce(kCartLinkOp_ReadRange, Address, Mode,
                                       &Response)
            : CartLink_Transaction(kCartLinkOp_ReadRange, Address, Mode,
                                   &Response);
        if (Result == ESP_OK && Response.Status != 0)
        {
            Result = ESP_ERR_INVALID_RESPONSE;
        }
    }
    return Result;
}

esp_err_t CartBulk_WriteCartBlock(uint16_t Address, const uint8_t *pData,
                                  size_t Size)
{
    if (!SessionActive || pData == NULL ||
        (Size != 512 && Size != kCartBulkBlockSize) ||
        Address < 0xa000u || (uint32_t)Address + Size > 0xc000u ||
        (Address & 0x03ffu) != 0)
        return ESP_ERR_INVALID_ARG;
    return WriteStagedCartBlock(Address, pData, Size,
                                Size == 1024 ? 0x81 : 0x80);
}

esp_err_t CartBulk_ProgramCartBlock(uint16_t Address, const uint8_t *pData,
                                    uint8_t Mode)
{
    if (!SessionActive || pData == NULL || Address < 0x4000u ||
        Address > 0x7c00u || (Address & 0x03ffu) != 0 ||
        (Mode != 0x82 && Mode != 0x83 && Mode != 0x85))
        return ESP_ERR_INVALID_ARG;
    return WriteStagedCartBlock(Address, pData, kCartBulkBlockSize, Mode);
}

esp_err_t CartBulk_SendUSBBlock(const uint8_t *pData, size_t Size, uint8_t Sequence)
{
    if (!SessionActive || pData == NULL || Size == 0 || Size > kCartBulkBlockSize)
        return ESP_ERR_INVALID_ARG;
    Sequence &= 0xfe;
    xQueueReset(StreamEventQueue);
    esp_err_t Result = WriteStagedCartBlock(Sequence, pData, Size, 0x84);
    if (Result != ESP_OK) return Result;
    StreamEvent_t Event;
    if (xQueueReceive(StreamEventQueue, &Event, pdMS_TO_TICKS(5000)) != pdTRUE)
        return ESP_ERR_TIMEOUT;
    if (Event.Sequence != Sequence) return ESP_ERR_INVALID_RESPONSE;
    CartLinkResponse_t Response;
    return TransactionOk(kCartLinkOp_Ack, 0, Sequence, &Response);
}

void CartBulk_OnStreamEvent(const uint8_t *pPayload, size_t Length)
{
    if (StreamEventQueue == NULL || pPayload == NULL || Length != 1)
    {
        ESP_LOGW(TAG, "Discarding malformed stream event, len=%u",
                 (unsigned)Length);
        return;
    }
    const StreamEvent_t Event = {
        .Sequence = pPayload[0],
    };
    if (xQueueSend(StreamEventQueue, &Event, 0) != pdTRUE)
    {
        ESP_LOGE(TAG, "Stream event queue overflow, sequence=%u",
                 Event.Sequence);
    }
}

static esp_err_t BeginRange(uint16_t Address, uint8_t BlockCount,
                            bool HasWrite, uint16_t WriteAddress,
                            uint8_t WriteValue)
{
    const uint32_t End = (uint32_t)Address +
                         (uint32_t)BlockCount * kCartBulkBlockSize;
    if (!SessionActive || StreamActive || StreamEventQueue == NULL)
    {
        return ESP_ERR_INVALID_STATE;
    }
    if (BlockCount == 0 || BlockCount > kStreamMaximumBlocks ||
        End > 0x10000u)
    {
        return ESP_ERR_INVALID_ARG;
    }

    xQueueReset(StreamEventQueue);
    CartLinkResponse_t Response = {0};
    esp_err_t Result;
    if (HasWrite)
    {
        Result = CartLink_WriteReadRange(Address, BlockCount, WriteAddress,
                                         WriteValue, &Response);
        if (Result == ESP_OK && Response.Status != 0)
        {
            Result = ESP_ERR_INVALID_RESPONSE;
        }
    }
    else
    {
        Result = TransactionOk(kCartLinkOp_ReadRange, Address, BlockCount,
                               &Response);
    }
    if (Result != ESP_OK)
    {
        printf("CARTSTREAM_FAIL stage=begin address=%04x blocks=%u error=%s status=%u\n",
               Address, BlockCount, esp_err_to_name(Result), Response.Status);
        return Result;
    }
    if (Response.Count != 0)
    {
        return ESP_ERR_INVALID_RESPONSE;
    }

    StreamExpectedSequence = Response.Tag;
    StreamBlocksRemaining = BlockCount;
    StreamLastAckValid = false;
    StreamPendingValid = false;
    StreamActive = true;
    return ESP_OK;
}

esp_err_t CartBulk_ReadRangeBegin(uint16_t Address, uint8_t BlockCount)
{
    return BeginRange(Address, BlockCount, false, 0, 0);
}

esp_err_t CartBulk_ReadMappedRangeBegin(uint16_t ReadAddress,
                                        uint8_t BlockCount,
                                        uint16_t WriteAddress,
                                        uint8_t WriteValue)
{
    return BeginRange(ReadAddress, BlockCount, true, WriteAddress,
                      WriteValue);
}

esp_err_t CartBulk_ReadRangeNext(uint8_t Data[kCartBulkBlockSize])
{
    if (!SessionActive || !StreamActive || Data == NULL ||
        StreamBlocksRemaining == 0)
    {
        return ESP_ERR_INVALID_STATE;
    }

    if (StreamPendingValid)
    {
        if (StreamPendingSequence != StreamExpectedSequence)
        {
            return ESP_ERR_INVALID_STATE;
        }
        memcpy(Data, StreamPendingBlock, kCartBulkBlockSize);
        StreamPendingValid = false;
        ++StreamExpectedSequence;
        --StreamBlocksRemaining;
        return ESP_OK;
    }

    const unsigned BatchCount = StreamBlocksRemaining >= 2 ? 2 : 1;
    const uint8_t CompletionSequence =
        StreamExpectedSequence + BatchCount - 1u;

    const int64_t EventStart_us = esp_timer_get_time();
    StreamEvent_t Event = {0};
    bool Received = false;
    for (unsigned Attempt = 0; Attempt < kStreamAckRetries; ++Attempt)
    {
        if (xQueueReceive(StreamEventQueue, &Event,
                          pdMS_TO_TICKS(kStreamEventTimeout_ms)) == pdTRUE)
        {
            Received = true;
            break;
        }
        if (StreamLastAckValid)
        {
            (void)FPGA_Tx_CartStreamAck(StreamLastAckSequence);
        }
    }
    if (!Received)
    {
        printf("CARTSTREAM_FAIL stage=event expected=%u\n",
               CompletionSequence);
        return ESP_ERR_TIMEOUT;
    }
    const int64_t EventDone_us = esp_timer_get_time();
    if (Event.Sequence != CompletionSequence)
    {
        printf("CARTSTREAM_FAIL stage=sequence expected=%u actual=%u\n",
               CompletionSequence, Event.Sequence);
        return ESP_ERR_INVALID_RESPONSE;
    }

    esp_err_t Result = ESP_ERR_TIMEOUT;
    const int64_t DisplayStart_us = esp_timer_get_time();
    if (xSemaphoreTake(QspiGate, portMAX_DELAY) != pdTRUE)
    {
        return ESP_ERR_TIMEOUT;
    }
    Result = DrainDisplayTransactions();
    const int64_t DisplayDone_us = esp_timer_get_time();
    if (Result == ESP_OK)
    {
        for (unsigned Block = 0; Block < BatchCount && Result == ESP_OK;
             ++Block)
        {
            const uint8_t Sequence = StreamExpectedSequence + Block;
            for (unsigned Attempt = 0; Attempt < kQspiAttempts; ++Attempt)
            {
                Result = ReadQspiResponseAt(
                    kCartReadAddress | ((Sequence & 1u) << 10));
                if (Result == ESP_OK)
                {
                    Result = ValidateQspiResponse(Sequence, false, 0);
                }
                if (Result == ESP_OK)
                {
                    uint8_t *const pDestination = Block == 0
                        ? Data : StreamPendingBlock;
                    memcpy(pDestination,
                           &QspiResponse[kCartBulkMetadataSize],
                           kCartBulkBlockSize);
                    break;
                }
                ESP_LOGW(TAG,
                         "Stream QSPI validation attempt %u failed: %s",
                         Attempt + 1, esp_err_to_name(Result));
            }
        }
    }
    (void)xSemaphoreGive(QspiGate);
    const int64_t QspiDone_us = esp_timer_get_time();
    if (Result != ESP_OK)
    {
        printf("CARTSTREAM_FAIL stage=qspi sequence=%u error=%s\n",
               CompletionSequence, esp_err_to_name(Result));
        return Result;
    }

    Result = FPGA_Tx_CartStreamAck(CompletionSequence);
    const int64_t AckDone_us = esp_timer_get_time();
    if (Result != ESP_OK)
    {
        return Result;
    }
    StreamLastAckSequence = CompletionSequence;
    StreamLastAckValid = true;
    if (BatchCount == 2)
    {
        StreamPendingSequence = StreamExpectedSequence + 1u;
        StreamPendingValid = true;
    }
    if (MeasureStressTiming)
    {
        StressEventWait_us += EventDone_us - EventStart_us;
        StressDisplayWait_us += DisplayDone_us - DisplayStart_us;
        StressQspi_us += QspiDone_us - DisplayDone_us;
        StressAck_us += AckDone_us - QspiDone_us;
    }
    ++StreamExpectedSequence;
    --StreamBlocksRemaining;
    return ESP_OK;
}

esp_err_t CartBulk_ReadRangeEnd(void)
{
    if (!SessionActive || !StreamActive || !StreamLastAckValid ||
        StreamPendingValid || StreamBlocksRemaining != 0)
    {
        return ESP_ERR_INVALID_STATE;
    }

    StreamActive = false;
    StreamLastAckValid = false;
    return ESP_OK;
}

esp_err_t CartBulk_ReadRangeAbort(void)
{
    if (!StreamActive)
    {
        return ESP_OK;
    }
    CartLinkResponse_t Response = {0};
    const esp_err_t Result = TransactionOk(kCartLinkOp_ReadRange, 0, 0,
                                            &Response);
    if (Result == ESP_OK)
    {
        StreamActive = false;
        StreamLastAckValid = false;
        StreamPendingValid = false;
        StreamBlocksRemaining = 0;
        xQueueReset(StreamEventQueue);
    }
    return Result;
}

static int ConsoleProbe(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    esp_err_t Result = CartBulk_Begin();
    bool Entered = false;
    CartLinkResponse_t Response = {0};

    if (Result == ESP_OK)
    {
        Result = TransactionOk(kCartLinkOp_Ping, 0, 0, &Response);
    }
    if (Result == ESP_OK)
    {
        printf("CARTPROBE_PING=PASS protocol=%u present=%u active=%u block_log2=%u\n",
               Response.Data[2], (Response.Data[1] >> 1) & 1,
               Response.Data[1] & 1, Response.Data[3]);
        Result = TransactionOk(kCartLinkOp_Enter, 0, 0, &Response);
        Entered = Result == ESP_OK;
    }
    if (Result == ESP_OK)
    {
        Result = CartBulk_ReadBlock(0, DiagnosticBlock);
    }

    if (Entered)
    {
        CartLinkResponse_t ExitResponse = {0};
        const esp_err_t ExitResult = TransactionOk(kCartLinkOp_Exit, 0, 0,
                                                    &ExitResponse);
        if (Result == ESP_OK)
        {
            Result = ExitResult;
        }
    }
    CartBulk_End();

    if (Result != ESP_OK)
    {
        printf("CARTPROBE=FAIL error=%s status=%u\n",
               esp_err_to_name(Result), Response.Status);
        return 1;
    }
    printf("CARTPROBE_HEADER=");
    for (size_t i = 0x100; i < 0x150; ++i)
    {
        printf("%02x", DiagnosticBlock[i]);
    }
    printf("\nCARTPROBE=PASS\n");
    return 0;
}

static int ConsoleStress(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    esp_err_t Result = CartBulk_Begin();
    bool Entered = false;
    CartLinkResponse_t Response = {0};
    uint32_t Sum = 0;
    const int64_t Start_us = esp_timer_get_time();
    StressEventWait_us = 0;
    StressDisplayWait_us = 0;
    StressQspi_us = 0;
    StressAck_us = 0;
    MeasureStressTiming = true;

    if (Result == ESP_OK)
    {
        Result = TransactionOk(kCartLinkOp_Ping, 0, 0, &Response);
    }
    if (Result == ESP_OK)
    {
        Result = TransactionOk(kCartLinkOp_Enter, 0, 0, &Response);
        Entered = Result == ESP_OK;
    }
    if (Result == ESP_OK)
    {
        Result = CartBulk_ReadRangeBegin(0, 16);
    }
    for (uint16_t Address = 0; Result == ESP_OK && Address < 0x4000;
         Address += kCartBulkBlockSize)
    {
        Result = CartBulk_ReadRangeNext(DiagnosticBlock);
        for (size_t i = 0; Result == ESP_OK && i < kCartBulkBlockSize; ++i)
        {
            Sum += DiagnosticBlock[i];
        }
    }
    if (Result == ESP_OK)
    {
        Result = CartBulk_ReadRangeEnd();
    }

    if (Entered)
    {
        CartLinkResponse_t ExitResponse = {0};
        const esp_err_t ExitResult = TransactionOk(kCartLinkOp_Exit, 0, 0,
                                                    &ExitResponse);
        if (Result == ESP_OK)
        {
            Result = ExitResult;
        }
    }
    CartBulk_End();
    MeasureStressTiming = false;
    printf("CARTSTRESS=%s elapsed_ms=%lld sum=%08lx error=%s event_us=%llu display_us=%llu qspi_us=%llu ack_us=%llu\n",
           Result == ESP_OK ? "PASS" : "FAIL",
           (long long)((esp_timer_get_time() - Start_us) / 1000),
           (unsigned long)Sum, esp_err_to_name(Result),
           (unsigned long long)StressEventWait_us,
           (unsigned long long)StressDisplayWait_us,
           (unsigned long long)StressQspi_us,
           (unsigned long long)StressAck_us);
    return Result == ESP_OK ? 0 : 1;
}

esp_err_t CartBulk_RegisterConsoleCommand(void)
{
    const esp_console_cmd_t ProbeCommand = {
        .command = "cartprobe",
        .help = "Read one validated 1 KiB cartridge block over QSPI",
        .hint = NULL,
        .func = ConsoleProbe,
        .argtable = NULL,
    };
    ESP_RETURN_ON_ERROR(esp_console_cmd_register(&ProbeCommand), TAG,
                        "register cartprobe");

    const esp_console_cmd_t StressCommand = {
        .command = "cartstress",
        .help = "Read 16 validated blocks in one cartridge session",
        .hint = NULL,
        .func = ConsoleStress,
        .argtable = NULL,
    };
    return esp_console_cmd_register(&StressCommand);
}
