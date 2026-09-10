#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    kCartMapper_RomOnly,
    kCartMapper_Mbc1,
    kCartMapper_Mbc2,
    kCartMapper_Mbc3,
    kCartMapper_Mbc5,
    kCartMapper_Huc1,
} CartMapperKind_t;

typedef struct {
    uint8_t Type;
    CartMapperKind_t Kind;
    bool HasRam;
    bool HasBattery;
    bool HasRtc;
    bool HasRumble;
    bool IsMbc30;
} CartMapperInfo_t;

typedef struct {
    uint16_t Address;
    uint8_t Value;
} CartMapperWrite_t;

enum {
    kCartMapperMaxWrites = 4,
};

typedef struct {
    CartMapperWrite_t Writes[kCartMapperMaxWrites];
    size_t WriteCount;
    uint16_t WindowAddress;
} CartMapperPlan_t;

bool CartMapper_Decode(uint8_t Type, CartMapperInfo_t *pInfo);

const char *CartMapper_TypeName(uint8_t Type);

bool CartMapper_ResolveGeometry(CartMapperInfo_t *pInfo,
                                uint32_t RomSize, uint32_t HeaderRamSize,
                                uint32_t *pRamSize);

bool CartMapper_PlanRomBank(const CartMapperInfo_t *pInfo, uint32_t Bank,
                            CartMapperPlan_t *pPlan);
bool CartMapper_PlanRamEnable(const CartMapperInfo_t *pInfo,
                              CartMapperPlan_t *pPlan);
bool CartMapper_PlanRamBank(const CartMapperInfo_t *pInfo, uint32_t Bank,
                            CartMapperPlan_t *pPlan);
bool CartMapper_PlanRestore(const CartMapperInfo_t *pInfo,
                            CartMapperPlan_t *pPlan);
