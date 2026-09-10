#pragma once
#define ESP_RETURN_ON_ERROR(expr, ...) do { const esp_err_t r = (expr); if (r != ESP_OK) return r; } while (0)
