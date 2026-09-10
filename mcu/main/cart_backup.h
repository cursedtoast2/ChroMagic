#pragma once

#include "esp_err.h"

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    kCartBackupArtifact_Rom,
    kCartBackupArtifact_Save,
    kCartBackupArtifact_Rtc,
} CartBackupArtifact_t;

enum {
    kCartBackupSelectRom = 1u << kCartBackupArtifact_Rom,
    kCartBackupSelectSave = 1u << kCartBackupArtifact_Save,
};

typedef struct {
    char Title[17];
    uint8_t Type;
    uint32_t RomSize;
    uint32_t SaveSize;
    bool IsColor;
    bool HasRtc;
} CartBackupMetadata_t;

typedef struct {
    esp_err_t (*OnInfo)(void *pContext,
                        const CartBackupMetadata_t *pMetadata);
    esp_err_t (*OnBegin)(void *pContext, CartBackupArtifact_t Artifact,
                         uint32_t Size);
    esp_err_t (*OnData)(void *pContext, CartBackupArtifact_t Artifact,
                        const uint8_t *pData, size_t Size);
    esp_err_t (*OnEnd)(void *pContext, CartBackupArtifact_t Artifact);
} CartBackupStreamSink_t;

typedef enum {
    kCartSaveImportPhase_Validate,
    kCartSaveImportPhase_Write,
} CartSaveImportPhase_t;

typedef struct {
    esp_err_t (*OnInfo)(void *pContext,
                        const CartBackupMetadata_t *pMetadata);
    esp_err_t (*OnReady)(void *pContext, CartSaveImportPhase_t Phase,
                         uint32_t SaveSize, bool HasRtc);
    esp_err_t (*Read)(void *pContext, uint8_t *pData, size_t Size);
    void (*OnProgress)(void *pContext, uint32_t Written, uint32_t Total);
} CartSaveImportSource_t;

esp_err_t CartBackup_Init(void);
esp_err_t CartBackup_RegisterConsoleCommand(void);
esp_err_t CartBackup_Start(void);

esp_err_t CartBackup_SetPCMode(bool Enabled);
bool CartBackup_IsPCModeActive(void);

esp_err_t CartBackup_FlashSession(uint8_t MapperType,
                                 esp_err_t (*Run)(void *pContext),
                                 void *pContext);

esp_err_t CartBackup_StreamToPC(uint32_t Selection,
                                const CartBackupStreamSink_t *pSink,
                                void *pContext);
esp_err_t CartBackup_StreamToSD(uint32_t Selection,
                                const CartBackupStreamSink_t *pSink,
                                void *pContext);

esp_err_t CartBackup_ImportSaveFromPC(
    uint32_t SaveSize, uint32_t SaveCrc, bool HasRtc, uint32_t RtcCrc,
    const CartSaveImportSource_t *pSource, void *pContext);
