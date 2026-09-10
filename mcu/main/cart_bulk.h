#pragma once

#include "driver/spi_master.h"
#include "esp_err.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum {
    kCartBulkBlockSize = 1024,
    kCartBulkMetadataSize = 12,
};

esp_err_t CartBulk_Init(spi_device_handle_t Spi);

esp_err_t CartBulk_Begin(void);
void CartBulk_End(void);

bool CartBulk_DisplayTransferBegin(void);
void CartBulk_DisplayTransactionQueued(void);
void CartBulk_DisplayTransferEnd(void);

esp_err_t CartBulk_ReadBlock(uint16_t Address,
                             uint8_t Data[kCartBulkBlockSize]);

esp_err_t CartBulk_ReadVirtualBlock(uint16_t Sequence,
                                    uint8_t Data[kCartBulkBlockSize]);

esp_err_t CartBulk_WritePSRAMBlock(uint32_t Address,
                                   const uint8_t Data[kCartBulkBlockSize]);

esp_err_t CartBulk_WriteCartBlock(uint16_t Address, const uint8_t *pData,
                                  size_t Size);
esp_err_t CartBulk_ProgramCartBlock(uint16_t Address, const uint8_t *pData,
                                    uint8_t Mode);

esp_err_t CartBulk_ReadRangeBegin(uint16_t Address, uint8_t BlockCount);
esp_err_t CartBulk_ReadMappedRangeBegin(uint16_t ReadAddress,
                                        uint8_t BlockCount,
                                        uint16_t WriteAddress,
                                        uint8_t WriteValue);
esp_err_t CartBulk_ReadRangeNext(uint8_t Data[kCartBulkBlockSize]);
esp_err_t CartBulk_ReadRangeEnd(void);
esp_err_t CartBulk_ReadRangeAbort(void);

void CartBulk_OnStreamEvent(const uint8_t *pPayload, size_t Length);

esp_err_t CartBulk_RegisterConsoleCommand(void);

esp_err_t CartBulk_SendUSBBlock(const uint8_t *pData, size_t Size, uint8_t Sequence);
