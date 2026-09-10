#pragma once
#include <stdint.h>
typedef int esp_err_t;
enum { ESP_OK = 0, ESP_FAIL = -1, ESP_ERR_NO_MEM = 0x101, ESP_ERR_INVALID_ARG, ESP_ERR_INVALID_STATE, ESP_ERR_INVALID_SIZE, ESP_ERR_NOT_FOUND, ESP_ERR_NOT_SUPPORTED, ESP_ERR_TIMEOUT, ESP_ERR_INVALID_RESPONSE, ESP_ERR_INVALID_CRC, ESP_ERR_NOT_FINISHED };
static inline const char *esp_err_to_name(int e) { return e == ESP_OK ? "ESP_OK" : "ESP_FAIL"; }
