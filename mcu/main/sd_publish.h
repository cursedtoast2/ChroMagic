#pragma once
#include "esp_err.h"
#include <stdbool.h>

esp_err_t SDPublish_Recover(const char *pFinal, const char *pOld);
esp_err_t SDPublish_Stage(const char *pFinal, const char *pOld, bool *pStaged);
