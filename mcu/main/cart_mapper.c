#include "cart_mapper.h"

#include <string.h>

enum {
    kRomBankSize = 16 * 1024,
    kKiB = 1024,
};

static void InitPlan(CartMapperPlan_t *pPlan, uint16_t WindowAddress)
{
    memset(pPlan, 0, sizeof(*pPlan));
    pPlan->WindowAddress = WindowAddress;
}

static bool AddWrite(CartMapperPlan_t *pPlan, uint16_t Address, uint8_t Value)
{
    if (pPlan->WriteCount >= kCartMapperMaxWrites)
    {
        return false;
    }
    pPlan->Writes[pPlan->WriteCount++] = (CartMapperWrite_t) {
        .Address = Address,
        .Value = Value,
    };
    return true;
}

bool CartMapper_Decode(uint8_t Type, CartMapperInfo_t *pInfo)
{
    if (pInfo == NULL)
    {
        return false;
    }
    *pInfo = (CartMapperInfo_t) {.Type = Type};

    switch (Type)
    {
        case 0x00:
            pInfo->Kind = kCartMapper_RomOnly;
            return true;
        case 0x08:
        case 0x09:
            pInfo->Kind = kCartMapper_RomOnly;
            pInfo->HasRam = true;
            pInfo->HasBattery = Type == 0x09;
            return true;

        case 0x01:
        case 0x02:
        case 0x03:
            pInfo->Kind = kCartMapper_Mbc1;
            pInfo->HasRam = Type >= 0x02;
            pInfo->HasBattery = Type == 0x03;
            return true;

        case 0x05:
        case 0x06:
            pInfo->Kind = kCartMapper_Mbc2;
            pInfo->HasRam = true;
            pInfo->HasBattery = Type == 0x06;
            return true;

        case 0x0f:
        case 0x10:
        case 0x11:
        case 0x12:
        case 0x13:
            pInfo->Kind = kCartMapper_Mbc3;
            pInfo->HasRam = Type == 0x10 || Type == 0x12 || Type == 0x13;
            pInfo->HasBattery = Type == 0x0f || Type == 0x10 || Type == 0x13;
            pInfo->HasRtc = Type == 0x0f || Type == 0x10;
            return true;

        case 0x19:
        case 0x1a:
        case 0x1b:
        case 0x1c:
        case 0x1d:
        case 0x1e:
            pInfo->Kind = kCartMapper_Mbc5;
            pInfo->HasRam = Type == 0x1a || Type == 0x1b ||
                            Type == 0x1d || Type == 0x1e;
            pInfo->HasBattery = Type == 0x1b || Type == 0x1e;
            pInfo->HasRumble = Type >= 0x1c;
            return true;

        case 0xff:
            pInfo->Kind = kCartMapper_Huc1;
            pInfo->HasRam = true;
            pInfo->HasBattery = true;
            return true;

        default:
            return false;
    }
}

const char *CartMapper_TypeName(uint8_t Type)
{
    switch (Type)
    {
        case 0x00: return "ROM ONLY";
        case 0x01: return "MBC1";
        case 0x02: return "MBC1+RAM";
        case 0x03: return "MBC1+RAM+BATTERY";
        case 0x05: return "MBC2";
        case 0x06: return "MBC2+BATTERY";
        case 0x08: return "ROM+RAM";
        case 0x09: return "ROM+RAM+BATTERY";
        case 0x0b: return "MMM01";
        case 0x0c: return "MMM01+RAM";
        case 0x0d: return "MMM01+RAM+BATTERY";
        case 0x0f: return "MBC3+RTC+BATTERY";
        case 0x10: return "MBC3+RTC+RAM+BATTERY";
        case 0x11: return "MBC3";
        case 0x12: return "MBC3+RAM";
        case 0x13: return "MBC3+RAM+BATTERY";
        case 0x19: return "MBC5";
        case 0x1a: return "MBC5+RAM";
        case 0x1b: return "MBC5+RAM+BATTERY";
        case 0x1c: return "MBC5+RUMBLE";
        case 0x1d: return "MBC5+RUMBLE+RAM";
        case 0x1e: return "MBC5+RUMBLE+RAM+BATTERY";
        case 0x20: return "MBC6";
        case 0x22: return "MBC7+SENSOR+RUMBLE+RAM";
        case 0xfc: return "GAME BOY CAMERA";
        case 0xfd: return "TAMA5";
        case 0xfe: return "HuC3";
        case 0xff: return "HuC1+RAM+BATTERY";
        default: return "UNKNOWN MAPPER";
    }
}

bool CartMapper_ResolveGeometry(CartMapperInfo_t *pInfo,
                                uint32_t RomSize, uint32_t HeaderRamSize,
                                uint32_t *pRamSize)
{
    if (pInfo == NULL || pRamSize == NULL ||
        RomSize < 2u * kRomBankSize || RomSize % kRomBankSize != 0)
    {
        return false;
    }

    uint32_t MaximumRomSize;
    uint32_t MaximumRamSize;
    const bool IsMbc30 = pInfo->Kind == kCartMapper_Mbc3 &&
        (RomSize == 4u * 1024u * kKiB || HeaderRamSize == 64u * kKiB);
    switch (pInfo->Kind)
    {
        case kCartMapper_RomOnly:
            MaximumRomSize = 32u * kKiB;
            MaximumRamSize = 8u * kKiB;
            break;
        case kCartMapper_Mbc1:
            MaximumRomSize = 2u * 1024u * kKiB;
            MaximumRamSize = 32u * kKiB;
            break;
        case kCartMapper_Mbc2:
            MaximumRomSize = 256u * kKiB;
            MaximumRamSize = 512u;
            break;
        case kCartMapper_Mbc3:
            MaximumRomSize = (IsMbc30 ? 4u : 2u) * 1024u * kKiB;
            MaximumRamSize = (IsMbc30 ? 64u : 32u) * kKiB;
            break;
        case kCartMapper_Mbc5:
            MaximumRomSize = 8u * 1024u * kKiB;
            MaximumRamSize = pInfo->HasRumble ? 64u * kKiB : 128u * kKiB;
            break;
        case kCartMapper_Huc1:
            MaximumRomSize = 1024u * kKiB;
            MaximumRamSize = 32u * kKiB;
            break;
        default:
            return false;
    }
    if (RomSize > MaximumRomSize)
    {
        return false;
    }

    uint32_t RamSize = 0;
    if (pInfo->Kind == kCartMapper_Mbc2)
    {
        RamSize = 512;
    }
    else if (pInfo->HasRam)
    {
        if (HeaderRamSize == 0 || HeaderRamSize > MaximumRamSize)
        {
            return false;
        }
        RamSize = HeaderRamSize;
    }
    *pRamSize = RamSize;
    pInfo->IsMbc30 = IsMbc30;
    return true;
}

bool CartMapper_PlanRomBank(const CartMapperInfo_t *pInfo, uint32_t Bank,
                            CartMapperPlan_t *pPlan)
{
    if (pInfo == NULL || pPlan == NULL)
    {
        return false;
    }
    InitPlan(pPlan, Bank == 0 ? 0x0000 : 0x4000);

    switch (pInfo->Kind)
    {
        case kCartMapper_RomOnly:
            return Bank <= 1;

        case kCartMapper_Mbc1:
            if (Bank > 0x7f)
            {
                return false;
            }
            if (Bank == 0)
            {
                return AddWrite(pPlan, 0x6000, 0) &&
                       AddWrite(pPlan, 0x4000, 0) &&
                       AddWrite(pPlan, 0x2000, 1);
            }
            if ((Bank & 0x1f) == 0)
            {
                pPlan->WindowAddress = 0x0000;
                return AddWrite(pPlan, 0x6000, 1) &&
                       AddWrite(pPlan, 0x4000, (Bank >> 5) & 3);
            }
            return AddWrite(pPlan, 0x6000, 0) &&
                   AddWrite(pPlan, 0x4000, (Bank >> 5) & 3) &&
                   AddWrite(pPlan, 0x2000, Bank & 0x1f);

        case kCartMapper_Mbc2:
            if (Bank > 0x0f)
            {
                return false;
            }
            return Bank == 0 || AddWrite(pPlan, 0x2100, Bank & 0x0f);

        case kCartMapper_Mbc3:
            if (Bank > (pInfo->IsMbc30 ? 0xffu : 0x7fu))
            {
                return false;
            }
            return Bank == 0 || AddWrite(pPlan, 0x2000, Bank);

        case kCartMapper_Mbc5:
            if (Bank > 0x1ff)
            {
                return false;
            }
            return Bank == 0 ||
                   (AddWrite(pPlan, 0x2000, Bank & 0xff) &&
                    AddWrite(pPlan, 0x3000, (Bank >> 8) & 1));

        case kCartMapper_Huc1:
            return Bank <= 0x3f &&
                   (Bank == 0 || AddWrite(pPlan, 0x2000, Bank));

        default:
            return false;
    }
}

bool CartMapper_PlanRamEnable(const CartMapperInfo_t *pInfo,
                              CartMapperPlan_t *pPlan)
{
    if (pInfo == NULL || pPlan == NULL || !pInfo->HasRam)
    {
        return false;
    }
    InitPlan(pPlan, 0xa000);
    if (pInfo->Kind == kCartMapper_RomOnly)
    {
        return true;
    }
    return AddWrite(pPlan, 0x0000, 0x0a);
}

bool CartMapper_PlanRamBank(const CartMapperInfo_t *pInfo, uint32_t Bank,
                            CartMapperPlan_t *pPlan)
{
    if (pInfo == NULL || pPlan == NULL || !pInfo->HasRam)
    {
        return false;
    }
    InitPlan(pPlan, 0xa000);
    switch (pInfo->Kind)
    {
        case kCartMapper_RomOnly:
        case kCartMapper_Mbc2:
            return Bank == 0;
        case kCartMapper_Mbc1:
            return Bank <= 3 && AddWrite(pPlan, 0x6000, 1) &&
                   AddWrite(pPlan, 0x4000, Bank);
        case kCartMapper_Mbc3:
            return Bank <= (pInfo->IsMbc30 ? 7u : 3u) &&
                   AddWrite(pPlan, 0x4000, Bank);
        case kCartMapper_Huc1:
            return Bank <= 3 && AddWrite(pPlan, 0x4000, Bank);
        case kCartMapper_Mbc5:
            if (Bank > (pInfo->HasRumble ? 7u : 15u))
            {
                return false;
            }
            return AddWrite(pPlan, 0x4000, Bank & 0x0f);
        default:
            return false;
    }
}

bool CartMapper_PlanRestore(const CartMapperInfo_t *pInfo,
                            CartMapperPlan_t *pPlan)
{
    if (pInfo == NULL || pPlan == NULL)
    {
        return false;
    }
    InitPlan(pPlan, 0x0000);
    switch (pInfo->Kind)
    {
        case kCartMapper_RomOnly:
            return true;
        case kCartMapper_Mbc1:
            return AddWrite(pPlan, 0x0000, 0) &&
                   AddWrite(pPlan, 0x6000, 0) &&
                   AddWrite(pPlan, 0x4000, 0) &&
                   AddWrite(pPlan, 0x2000, 1);
        case kCartMapper_Mbc2:
            return AddWrite(pPlan, 0x0000, 0) &&
                   AddWrite(pPlan, 0x2100, 1);
        case kCartMapper_Mbc3:
            return AddWrite(pPlan, 0x0000, 0) &&
                   AddWrite(pPlan, 0x4000, 0) &&
                   AddWrite(pPlan, 0x2000, 1);
        case kCartMapper_Mbc5:
            return AddWrite(pPlan, 0x0000, 0) &&
                   AddWrite(pPlan, 0x4000, 0) &&
                   AddWrite(pPlan, 0x3000, 0) &&
                   AddWrite(pPlan, 0x2000, 1);
        case kCartMapper_Huc1:
            return AddWrite(pPlan, 0x0000, 0x0e) &&
                   AddWrite(pPlan, 0xa000, 0) &&
                   AddWrite(pPlan, 0x4000, 0) &&
                   AddWrite(pPlan, 0x2000, 1);
        default:
            return false;
    }
}
