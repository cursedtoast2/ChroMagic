#pragma once

#include "esp_err.h"
#include "osd_shared.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct RomBrowserDataSource {
    esp_err_t (*Open)(size_t *pCount);
    const char *(*NameAt)(size_t Index);
    void (*Close)(void);
    esp_err_t (*Start)(const char *pName);
    bool (*IsDirectory)(size_t Index);
    esp_err_t (*Enter)(size_t Index, size_t *pCount);
    esp_err_t (*Parent)(size_t *pCount, size_t *pSelected);
    bool (*AtRoot)(void);
} RomBrowserDataSource_t;

OSD_Result_t RomBrowserUI_Draw(void *pArg);
OSD_Result_t RomBrowserUI_OnButton(Button_t Button, ButtonState_t State,
                                   void *pArg);
OSD_Result_t RomBrowserUI_OnTransition(void *pArg);

void RomBrowserUI_RegisterDataSource(const RomBrowserDataSource_t *pSource);
void RomBrowserUI_SetProgress(uint32_t Completed, uint32_t Total);
bool RomBrowserUI_SetComplete(void);
void RomBrowserUI_SetError(esp_err_t Error);
