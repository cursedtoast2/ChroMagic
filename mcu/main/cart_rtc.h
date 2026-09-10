#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

bool CartRtc_IsStateValid(uint32_t State);
uint32_t CartRtc_FromRegisters(const uint8_t Registers[5]);
void CartRtc_ToRegisters(uint32_t State, uint8_t Registers[5]);
uint32_t CartRtc_AdvanceOneSecond(uint32_t State);

typedef enum {
    kCartRtc_Ok,
    kCartRtc_NotPresent,
    kCartRtc_Unconfirmed,
    kCartRtc_IoError,
    kCartRtc_InvalidState,
    kCartRtc_VerifyFailed,
} CartRtcResult_t;

typedef struct {
    void *pContext;
    bool (*Write)(void *pContext, uint16_t Address, uint8_t Value);
    bool (*ReadBlock)(void *pContext, uint16_t Address, uint8_t *pData);
    uint8_t *pBuffer;
    size_t BufferSize;
} CartRtcBus_t;

typedef struct {
    uint8_t Register;
    uint16_t Address;
    uint8_t FirstValue;
    uint8_t DifferentValue;
} CartRtcProbeDetail_t;

CartRtcResult_t CartRtc_Probe(const CartRtcBus_t *pBus,
                             CartRtcProbeDetail_t *pDetail);
CartRtcResult_t CartRtc_Read(const CartRtcBus_t *pBus, uint32_t *pState);
CartRtcResult_t CartRtc_WriteAndVerify(const CartRtcBus_t *pBus, uint32_t State);
