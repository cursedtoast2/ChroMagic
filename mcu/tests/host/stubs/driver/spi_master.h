#pragma once
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
typedef void *spi_device_handle_t;
enum { SPI_TRANS_MODE_QIO = 1 };
typedef struct {
    unsigned flags;
    uint16_t cmd;
    uint64_t addr;
    size_t length, rxlength;
    const void *tx_buffer;
    void *rx_buffer;
} spi_transaction_t;
esp_err_t spi_device_get_trans_result(spi_device_handle_t, spi_transaction_t **, TickType_t);
esp_err_t spi_device_polling_transmit(spi_device_handle_t, spi_transaction_t *);
esp_err_t spi_device_polling_start(spi_device_handle_t, spi_transaction_t *, TickType_t);
esp_err_t spi_device_polling_end(spi_device_handle_t, TickType_t);
