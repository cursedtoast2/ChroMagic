#pragma once
#include "esp_err.h"
typedef struct { const char *command, *help, *hint; int (*func)(int, char **); void *argtable; } esp_console_cmd_t;
int esp_console_cmd_register(const esp_console_cmd_t *);
