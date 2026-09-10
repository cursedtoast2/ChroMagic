#pragma once
#include "esp_err.h"
#include "freertos/FreeRTOS.h"
enum { UART_NUM_0, UART_DATA_8_BITS, UART_PARITY_DISABLE, UART_STOP_BITS_1, UART_HW_FLOWCTRL_DISABLE, UART_SCLK_DEFAULT, UART_SCLK_REF_TICK };
typedef struct { int baud_rate, data_bits, parity, stop_bits, flow_ctrl, source_clk; } uart_config_t;
esp_err_t uart_wait_tx_done(int, TickType_t);
esp_err_t uart_param_config(int, const uart_config_t *);
esp_err_t uart_flush_input(int);
int uart_read_bytes(int, void *, uint32_t, TickType_t);
esp_err_t uart_driver_delete(int);
esp_err_t uart_driver_install(int, int, int, int, void *, int);
