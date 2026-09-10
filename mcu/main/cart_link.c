#include "cart_link.h"

#include "esp_log.h"
#include "fpga_rx.h"
#include "fpga_tx.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

enum {
    kResponseTimeout_ms = 50,
    kTransactionAttempts = 3,
};

static const char *TAG = "CartLink";
static StaticSemaphore_t TransactionMutexStorage;
static SemaphoreHandle_t TransactionMutex;
static StaticQueue_t ResponseQueueStorage;
static uint8_t ResponseQueueBuffer[sizeof(CartLinkResponse_t)];
static QueueHandle_t ResponseQueue;
static uint8_t NextTag = 1;

static esp_err_t CartLink_TransactionRequest(
    const uint8_t RequestTemplate[8], CartLinkResponse_t *pResponse,
    unsigned Attempts);

esp_err_t CartLink_Init(void)
{
    TransactionMutex = xSemaphoreCreateMutexStatic(&TransactionMutexStorage);
    ResponseQueue = xQueueCreateStatic(1, sizeof(CartLinkResponse_t),
                                       ResponseQueueBuffer,
                                       &ResponseQueueStorage);
    return (TransactionMutex != NULL && ResponseQueue != NULL)
        ? ESP_OK : ESP_ERR_NO_MEM;
}

void CartLink_OnResponse(const uint8_t *pPayload, size_t Length)
{
    if (ResponseQueue == NULL || pPayload == NULL ||
        Length < 4 || Length > 8 || pPayload[3] > 4 ||
        Length != (size_t)(4 + pPayload[3]))
    {
        ESP_LOGW(TAG, "Discarding malformed response, len=%u",
                 (unsigned)Length);
        return;
    }

    CartLinkResponse_t Response = {
        .Operation = (CartLinkOperation_t)(pPayload[0] & 0x07),
        .Tag = pPayload[1],
        .Status = pPayload[2] & 0x0f,
        .Count = pPayload[3],
        .Data = {0},
    };
    memcpy(Response.Data, &pPayload[4], Response.Count);
    (void)xQueueOverwrite(ResponseQueue, &Response);
}

esp_err_t CartLink_Transaction(CartLinkOperation_t Operation,
                               uint16_t Address,
                               uint8_t ValueOrCount,
                               CartLinkResponse_t *pResponse)
{
    const uint8_t Request[8] = {
        (uint8_t)Operation,
        0,
        (uint8_t)(Address >> 8),
        (uint8_t)Address,
        ValueOrCount,
        0, 0, 0,
    };
    return CartLink_TransactionRequest(Request, pResponse, kTransactionAttempts);
}

esp_err_t CartLink_TransactionOnce(CartLinkOperation_t Operation,
                                  uint16_t Address, uint8_t Value,
                                  CartLinkResponse_t *pResponse)
{
    const uint8_t Request[8] = {
        Operation, 0, Address >> 8, Address, Value, 0, 0, 0,
    };
    return CartLink_TransactionRequest(Request, pResponse, 1);
}

esp_err_t CartLink_WriteOnce(uint16_t Address, uint8_t Value)
{
    const uint8_t Request[8] = {
        kCartLinkOp_Write, 0, Address >> 8, Address, Value, 0, 0, 0,
    };
    CartLinkResponse_t Response = {0};
    const esp_err_t Result = CartLink_TransactionRequest(Request, &Response, 1);
    return Result != ESP_OK ? Result
        : Response.Status == 0 ? ESP_OK : ESP_ERR_INVALID_RESPONSE;
}

esp_err_t CartLink_WriteReadRange(uint16_t ReadAddress,
                                  uint8_t BlockCount,
                                  uint16_t WriteAddress,
                                  uint8_t WriteValue,
                                  CartLinkResponse_t *pResponse)
{
    const uint8_t Request[8] = {
        kCartLinkOp_WriteReadRange,
        0,
        (uint8_t)(ReadAddress >> 8),
        (uint8_t)ReadAddress,
        BlockCount,
        (uint8_t)(WriteAddress >> 8),
        (uint8_t)WriteAddress,
        WriteValue,
    };
    return CartLink_TransactionRequest(Request, pResponse, kTransactionAttempts);
}

esp_err_t CartLink_VirtualCommand(uint8_t Command,
                                  uint16_t Configuration,
                                  uint8_t ConfigurationHigh,
                                  CartLinkResponse_t *pResponse)
{
    const uint8_t Request[8] = {
        kCartLinkOp_WriteReadRange,
        0,
        0x56,
        0x43,
        Command,
        (uint8_t)(Configuration >> 8),
        (uint8_t)Configuration,
        ConfigurationHigh,
    };
    return CartLink_TransactionRequest(Request, pResponse, kTransactionAttempts);
}

static esp_err_t CartLink_TransactionRequest(
    const uint8_t RequestTemplate[8], CartLinkResponse_t *pResponse,
    unsigned Attempts)
{
    if (TransactionMutex == NULL || ResponseQueue == NULL ||
        RequestTemplate == NULL || pResponse == NULL ||
        RequestTemplate[0] > kCartLinkOp_WriteReadRange)
    {
        return ESP_ERR_INVALID_STATE;
    }

    if (xSemaphoreTake(TransactionMutex, pdMS_TO_TICKS(kResponseTimeout_ms)) != pdTRUE)
    {
        return ESP_ERR_TIMEOUT;
    }

    const CartLinkOperation_t Operation =
        (CartLinkOperation_t)RequestTemplate[0];
    const unsigned Timeout_ms = Operation == kCartLinkOp_ReadRange &&
        (RequestTemplate[4] == 0x82 || RequestTemplate[4] == 0x83 || RequestTemplate[4] == 0x85)
            ? 5000 : kResponseTimeout_ms;
    const uint8_t Tag = NextTag++;
    uint8_t Request[8];
    memcpy(Request, RequestTemplate, sizeof(Request));
    Request[1] = Tag;

    esp_err_t Result = ESP_ERR_TIMEOUT;
    bool Matched = false;
    for (unsigned Attempt = 0;
         Attempt < Attempts && !Matched;
         ++Attempt)
    {
        xQueueReset(ResponseQueue);
        const uint32_t TraceStart = FPGA_Rx_GetTracePosition();
        Result = Attempts == 1
            ? FPGA_Tx_QueueCartRequest(Request) : FPGA_Tx_CartRequest(Request);
        if (Result != ESP_OK && Result != ESP_ERR_TIMEOUT)
        {
            printf("CARTLINK_SEND_FAIL op=%u tag=%u attempt=%u error=%s\n",
                   Operation, Tag, Attempt + 1, esp_err_to_name(Result));
            break;
        }

        Result = ESP_ERR_TIMEOUT;
        const TickType_t Start = xTaskGetTickCount();
        while ((xTaskGetTickCount() - Start) < pdMS_TO_TICKS(Timeout_ms))
        {
            const TickType_t Elapsed = xTaskGetTickCount() - Start;
            const TickType_t Remaining = pdMS_TO_TICKS(Timeout_ms) - Elapsed;
            if (xQueueReceive(ResponseQueue, pResponse, Remaining) != pdTRUE)
            {
                Result = ESP_ERR_TIMEOUT;
                printf("CARTLINK_RESPONSE_TIMEOUT op=%u tag=%u attempt=%u\n",
                       Operation, Tag, Attempt + 1);
                uint8_t Trace[32];
                const size_t TraceLength = FPGA_Rx_CopyTraceSince(
                    TraceStart, Trace, sizeof(Trace));
                printf("CARTLINK_RESPONSE_RAW bytes=%u data=",
                       (unsigned)TraceLength);
                for (size_t i = 0; i < TraceLength; ++i)
                {
                    printf("%02x", Trace[i]);
                }
                printf("\n");
                break;
            }
            if (pResponse->Tag == Tag && pResponse->Operation == Operation)
            {
                Matched = true;
                break;
            }
            printf("CARTLINK_RESPONSE_MISMATCH got_op=%u got_tag=%u expected_op=%u expected_tag=%u attempt=%u\n",
                   pResponse->Operation, pResponse->Tag, Operation, Tag,
                   Attempt + 1);
        }
        if (!Matched && Attempt + 1 < Attempts)
        {
            printf("CARTLINK_RETRY op=%u tag=%u next_attempt=%u\n",
                   Operation, Tag, Attempt + 2);
        }
    }
    Result = Matched ? ESP_OK : Result;

    (void)xSemaphoreGive(TransactionMutex);
    return Result;
}
