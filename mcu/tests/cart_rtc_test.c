#include "cart_rtc.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    bool HasRtc;
    bool Enabled;
    bool FailRead;
    bool DropRtcWrites;
    bool TickAfterWrite;
    uint8_t Selected;
    uint8_t LastLatch;
    uint8_t Clock[5];
    uint8_t Latched[5];
    uint8_t Ram[32768];
    unsigned RamWrites;
    unsigned RtcWrites;
} Cartridge;

static bool Write(void *pContext, uint16_t Address, uint8_t Value)
{
    Cartridge *p = pContext;
    switch (Address)
    {
        case 0x0000: p->Enabled = (Value & 15) == 10; return true;
        case 0x4000: p->Selected = Value; return true;
        case 0x6000:
            if (p->LastLatch == 0 && Value == 1)
                memcpy(p->Latched, p->Clock, 5);
            p->LastLatch = Value;
            return true;
        case 0xa000:
            assert(p->Enabled);
            if (p->HasRtc && p->Selected >= 8 && p->Selected <= 12)
            {
                ++p->RtcWrites;
                if (p->DropRtcWrites) return true;
                if (p->Selected != 12) assert(p->Clock[4] & 0x40);
                p->Clock[p->Selected - 8] = Value;
                if (p->TickAfterWrite && p->RtcWrites == 6)
                {
                    uint32_t State = CartRtc_FromRegisters(p->Clock);
                    CartRtc_ToRegisters(CartRtc_AdvanceOneSecond(State), p->Clock);
                }
            }
            else
            {
                ++p->RamWrites;
                p->Ram[(p->Selected & 3) * 8192] = Value;
            }
            return true;
        default: assert(!"unexpected bus write"); return false;
    }
}

static bool ReadBlock(void *pContext, uint16_t Address, uint8_t *pData)
{
    Cartridge *p = pContext;
    assert(p->Enabled);
    if (p->FailRead) return false;
    assert(Address >= 0xa000 && Address + 1024 <= 0xc000);
    if (p->HasRtc && p->Selected >= 8 && p->Selected <= 12)
        memset(pData, p->Latched[p->Selected - 8], 1024);
    else
        memcpy(pData, p->Ram + (p->Selected & 3) * 8192 + Address - 0xa000, 1024);
    return true;
}

static Cartridge Cart;
static uint8_t Buffer[1024];
static uint8_t OriginalRam[32768];
static const CartRtcBus_t Bus = {
    .pContext = &Cart, .Write = Write, .ReadBlock = ReadBlock,
    .pBuffer = Buffer, .BufferSize = sizeof(Buffer),
};

static void Initialize(bool HasRtc)
{
    memset(&Cart, 0, sizeof(Cart));
    Cart.HasRtc = HasRtc;
    for (size_t i = 0; i < sizeof(Cart.Ram); ++i)
        Cart.Ram[i] = (uint8_t)(i * 31 + (i >> 8));
    Cart.Ram[0] = 0;
    Cart.Ram[8192] = 1;
    Cart.Ram[16384] = 3;
    Cart.Ram[24576] = 110;
    memcpy(OriginalRam, Cart.Ram, sizeof(OriginalRam));
    CartRtc_ToRegisters(0x00dc3629, Cart.Clock);
}

static void AssertClean(void)
{
    assert(Cart.RamWrites == 0);
    assert(memcmp(Cart.Ram, OriginalRam, sizeof(OriginalRam)) == 0);
    assert(!Cart.Enabled && Cart.Selected == 0);
}

int main(void)
{
    Initialize(false);
    CartRtcProbeDetail_t Detail;
    assert(CartRtc_Probe(&Bus, &Detail) == kCartRtc_NotPresent);
    assert(Detail.Register == 8 && Detail.FirstValue != Detail.DifferentValue);
    assert(CartRtc_WriteAndVerify(&Bus, 0x00dc3629) == kCartRtc_NotPresent);
    assert(Cart.RtcWrites == 0);
    AssertClean();

    for (unsigned fill = 0; fill <= 255; fill += 255)
    {
        Initialize(false);
        memset(Cart.Ram, fill, sizeof(Cart.Ram));
        memcpy(OriginalRam, Cart.Ram, sizeof(OriginalRam));
        assert(CartRtc_Probe(&Bus, NULL) == kCartRtc_Unconfirmed);
        assert(CartRtc_WriteAndVerify(&Bus, 0x00dc3629) == kCartRtc_Unconfirmed);
        AssertClean();
    }

    const uint32_t States[] = {0, 0x00dc3629, 0x10000000, 0x18000000,
        59 | (59u << 6) | (23u << 12) | (511u << 17)};
    for (size_t i = 0; i < sizeof(States) / sizeof(States[0]); ++i)
    {
        Initialize(true);
        assert(CartRtc_Probe(&Bus, NULL) == kCartRtc_Ok);
        assert(CartRtc_WriteAndVerify(&Bus, States[i]) == kCartRtc_Ok);
        uint32_t Actual;
        assert(CartRtc_Read(&Bus, &Actual) == kCartRtc_Ok);
        assert(Actual == States[i]);
        assert(Cart.RtcWrites == 6);
        AssertClean();
    }
    Initialize(true);
    Cart.TickAfterWrite = true;
    const uint32_t Rollover = 59 | (59u << 6) | (23u << 12) | (511u << 17);
    assert(CartRtc_WriteAndVerify(&Bus, Rollover) == kCartRtc_Ok);
    assert(CartRtc_FromRegisters(Cart.Clock) == (1u << 27));
    AssertClean();

    Initialize(true);
    Cart.DropRtcWrites = true;
    assert(CartRtc_WriteAndVerify(&Bus, 1) == kCartRtc_VerifyFailed);
    AssertClean();
    Initialize(true);
    Cart.FailRead = true;
    assert(CartRtc_WriteAndVerify(&Bus, 1) == kCartRtc_IoError);
    assert(Cart.RtcWrites == 0);
    AssertClean();
    assert(CartRtc_WriteAndVerify(&Bus, 63) == kCartRtc_InvalidState);
    puts("cart_rtc_test: PASS (real clock restore, rollover/halt, RAM alias, blank RAM, I/O and verification failure)");
    return 0;
}
