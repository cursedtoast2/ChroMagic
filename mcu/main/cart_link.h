#pragma once

#include "esp_err.h"

#include <stddef.h>
#include <stdint.h>

typedef enum {
    kCartLinkOp_Ping = 0,
    kCartLinkOp_Enter = 1,
    kCartLinkOp_ReadBlock = 2,
    kCartLinkOp_Write = 3,
    kCartLinkOp_Exit = 4,
    kCartLinkOp_Ack = 5,
    kCartLinkOp_ReadRange = 6,
    kCartLinkOp_WriteReadRange = 7,
} CartLinkOperation_t;

typedef struct {
    CartLinkOperation_t Operation;
    uint8_t Tag;
    uint8_t Status;
    uint8_t Count;
    uint8_t Data[4];
} CartLinkResponse_t;

esp_err_t CartLink_Init(void);
esp_err_t CartLink_Transaction(CartLinkOperation_t Operation,
                               uint16_t Address,
                               uint8_t ValueOrCount,
                               CartLinkResponse_t *pResponse);

esp_err_t CartLink_WriteOnce(uint16_t Address, uint8_t Value);
esp_err_t CartLink_TransactionOnce(CartLinkOperation_t Operation,
                                  uint16_t Address, uint8_t Value,
                                  CartLinkResponse_t *pResponse);
esp_err_t CartLink_WriteReadRange(uint16_t ReadAddress,
                                  uint8_t BlockCount,
                                  uint16_t WriteAddress,
                                  uint8_t WriteValue,
                                  CartLinkResponse_t *pResponse);

esp_err_t CartLink_VirtualCommand(uint8_t Command,
                                  uint16_t Configuration,
                                  uint8_t ConfigurationHigh,
                                  CartLinkResponse_t *pResponse);

void CartLink_OnResponse(const uint8_t *pPayload, size_t Length);
