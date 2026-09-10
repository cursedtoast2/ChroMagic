#include "cart_rtc.h"

#include <string.h>

bool CartRtc_IsStateValid(uint32_t State)
{
    const uint32_t Seconds = State & 0x3fu;
    const uint32_t Minutes = (State >> 6) & 0x3fu;
    const uint32_t Hours = (State >> 12) & 0x1fu;
    const uint32_t Days = (State >> 17) & 0x3ffu;
    return (State & 0xe0000000u) == 0 && Seconds <= 59 &&
           Minutes <= 59 && Hours <= 23 && Days <= 511;
}

uint32_t CartRtc_FromRegisters(const uint8_t Registers[5])
{
    const uint32_t Days = Registers[3] |
                          ((uint32_t)(Registers[4] & 1u) << 8);
    return (Registers[0] & 0x3fu) |
           ((uint32_t)(Registers[1] & 0x3fu) << 6) |
           ((uint32_t)(Registers[2] & 0x1fu) << 12) |
           (Days << 17) |
           ((uint32_t)(Registers[4] & 0x80u) << 20) |
           ((uint32_t)(Registers[4] & 0x40u) << 22);
}

void CartRtc_ToRegisters(uint32_t State, uint8_t Registers[5])
{
    Registers[0] = State & 0x3fu;
    Registers[1] = (State >> 6) & 0x3fu;
    Registers[2] = (State >> 12) & 0x1fu;
    Registers[3] = (State >> 17) & 0xffu;
    Registers[4] = ((State >> 25) & 1u) |
                   ((State >> 20) & 0x80u) |
                   ((State >> 22) & 0x40u);
}

uint32_t CartRtc_AdvanceOneSecond(uint32_t State)
{
    if ((State & (1u << 28)) != 0)
    {
        return State;
    }
    uint32_t Seconds = State & 0x3fu;
    uint32_t Minutes = (State >> 6) & 0x3fu;
    uint32_t Hours = (State >> 12) & 0x1fu;
    uint32_t Days = (State >> 17) & 0x1ffu;
    if (++Seconds == 60)
    {
        Seconds = 0;
        if (++Minutes == 60)
        {
            Minutes = 0;
            if (++Hours == 24)
            {
                Hours = 0;
                if (++Days == 512)
                {
                    Days = 0;
                    State |= 1u << 27;
                }
            }
        }
    }
    return (State & ((1u << 27) | (1u << 28))) |
           Seconds | (Minutes << 6) | (Hours << 12) | (Days << 17);
}

static bool Latch(const CartRtcBus_t *pBus)
{
    return pBus->Write(pBus->pContext, 0x0000, 0x0a) &&
           pBus->Write(pBus->pContext, 0x6000, 0x00) &&
           pBus->Write(pBus->pContext, 0x6000, 0x01);
}

static CartRtcResult_t Finish(const CartRtcBus_t *pBus, CartRtcResult_t Result)
{
    const bool Bank = pBus->Write(pBus->pContext, 0x4000, 0x00);
    const bool Disable = pBus->Write(pBus->pContext, 0x0000, 0x00);
    return Bank && Disable ? Result : kCartRtc_IoError;
}

static bool ValidBus(const CartRtcBus_t *pBus)
{
    return pBus != NULL && pBus->Write != NULL && pBus->ReadBlock != NULL &&
           pBus->pBuffer != NULL && pBus->BufferSize >= 256 &&
           pBus->BufferSize <= 1024;
}

static bool Mirrored(const CartRtcBus_t *pBus, uint8_t Register,
                     uint16_t Address, CartRtcProbeDetail_t *pDetail)
{
    for (size_t Index = 1; Index < 256; ++Index)
    {
        if (pBus->pBuffer[Index] != pBus->pBuffer[0])
        {
            if (pDetail != NULL)
            {
                *pDetail = (CartRtcProbeDetail_t) {
                    .Register = Register,
                    .Address = Address + Index,
                    .FirstValue = pBus->pBuffer[0],
                    .DifferentValue = pBus->pBuffer[Index],
                };
            }
            return false;
        }
    }
    return true;
}

CartRtcResult_t CartRtc_Probe(const CartRtcBus_t *pBus,
                             CartRtcProbeDetail_t *pDetail)
{
    if (!ValidBus(pBus)) return kCartRtc_IoError;
    if (pDetail != NULL) memset(pDetail, 0, sizeof(*pDetail));
    if (!Latch(pBus)) return Finish(pBus, kCartRtc_IoError);

    bool SawRegister = false;
    for (uint8_t Register = 0x08; Register <= 0x0c; ++Register)
    {
        if (!pBus->Write(pBus->pContext, 0x4000, Register) ||
            !pBus->ReadBlock(pBus->pContext, 0xa880, pBus->pBuffer))
            return Finish(pBus, kCartRtc_IoError);
        if (!Mirrored(pBus, Register, 0xa880, pDetail))
            return Finish(pBus, kCartRtc_NotPresent);
        SawRegister |= pBus->pBuffer[0] != 0 && pBus->pBuffer[0] != 0xff;
    }
    return Finish(pBus, SawRegister ? kCartRtc_Ok : kCartRtc_Unconfirmed);
}

CartRtcResult_t CartRtc_Read(const CartRtcBus_t *pBus, uint32_t *pState)
{
    if (!ValidBus(pBus) || pState == NULL) return kCartRtc_IoError;
    if (!Latch(pBus)) return Finish(pBus, kCartRtc_IoError);
    uint8_t Registers[5];
    for (uint8_t Index = 0; Index < sizeof(Registers); ++Index)
    {
        if (!pBus->Write(pBus->pContext, 0x4000, 0x08 + Index) ||
            !pBus->ReadBlock(pBus->pContext, 0xa000, pBus->pBuffer))
            return Finish(pBus, kCartRtc_IoError);
        if (!Mirrored(pBus, 0x08 + Index, 0xa000, NULL))
            return Finish(pBus, kCartRtc_NotPresent);
        Registers[Index] = pBus->pBuffer[0];
    }
    const uint32_t State = CartRtc_FromRegisters(Registers);
    if (!CartRtc_IsStateValid(State)) return Finish(pBus, kCartRtc_InvalidState);
    *pState = State;
    return Finish(pBus, kCartRtc_Ok);
}

CartRtcResult_t CartRtc_WriteAndVerify(const CartRtcBus_t *pBus, uint32_t State)
{
    if (!CartRtc_IsStateValid(State)) return kCartRtc_InvalidState;
    CartRtcResult_t Result = CartRtc_Probe(pBus, NULL);
    if (Result != kCartRtc_Ok) return Result;
    if (!Latch(pBus)) return Finish(pBus, kCartRtc_IoError);
    uint8_t Registers[5];
    CartRtc_ToRegisters(State, Registers);
    if (!pBus->Write(pBus->pContext, 0x4000, 0x0c) ||
        !pBus->Write(pBus->pContext, 0xa000, Registers[4] | 0x40))
        return Finish(pBus, kCartRtc_IoError);
    for (uint8_t Index = 0; Index < 4; ++Index)
    {
        if (!pBus->Write(pBus->pContext, 0x4000, 0x08 + Index) ||
            !pBus->Write(pBus->pContext, 0xa000, Registers[Index]))
            return Finish(pBus, kCartRtc_IoError);
    }
    if (!pBus->Write(pBus->pContext, 0x4000, 0x0c) ||
        !pBus->Write(pBus->pContext, 0xa000, Registers[4]))
        return Finish(pBus, kCartRtc_IoError);
    uint32_t Verified;
    Result = CartRtc_Read(pBus, &Verified);
    if (Result != kCartRtc_Ok) return Result;
    return Verified == State || Verified == CartRtc_AdvanceOneSecond(State)
        ? kCartRtc_Ok : kCartRtc_VerifyFailed;
}
