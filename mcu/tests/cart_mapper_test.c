#include "cart_mapper.h"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static CartMapperInfo_t Decode(uint8_t Type)
{
    CartMapperInfo_t Info;
    assert(CartMapper_Decode(Type, &Info));
    return Info;
}

static void TestDecode(void)
{
    static const uint8_t Supported[] = {
        0x00, 0x01, 0x02, 0x03, 0x05, 0x06, 0x08, 0x09,
        0x0f, 0x10, 0x11, 0x12, 0x13,
        0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e,
    };
    CartMapperInfo_t Info;
    for (size_t i = 0; i < sizeof(Supported); ++i)
    {
        assert(CartMapper_Decode(Supported[i], &Info));
        assert(Info.Type == Supported[i]);
    }
    assert(!CartMapper_Decode(0x0b, &Info));
    assert(!CartMapper_Decode(0x20, &Info));
    assert(!CartMapper_Decode(0x22, &Info));
    assert(!CartMapper_Decode(0xfc, &Info));
    assert(strcmp(CartMapper_TypeName(0x22),
                  "MBC7+SENSOR+RUMBLE+RAM") == 0);
}

static void TestGeometry(void)
{
    uint32_t RamSize;
    CartMapperInfo_t Info = Decode(0x06);
    assert(CartMapper_ResolveGeometry(&Info, 256 * 1024, 0, &RamSize));
    assert(RamSize == 512);
    assert(!CartMapper_ResolveGeometry(&Info, 512 * 1024, 0, &RamSize));

    Info = Decode(0x1b);
    assert(CartMapper_ResolveGeometry(&Info, 8 * 1024 * 1024,
                                      128 * 1024, &RamSize));
    assert(RamSize == 128 * 1024);

    Info = Decode(0x1e);
    assert(CartMapper_ResolveGeometry(&Info, 4 * 1024 * 1024,
                                      64 * 1024, &RamSize));
    assert(!CartMapper_ResolveGeometry(&Info, 4 * 1024 * 1024,
                                       128 * 1024, &RamSize));

    Info = Decode(0x09);
    assert(CartMapper_ResolveGeometry(&Info, 32 * 1024, 8 * 1024,
                                      &RamSize));
    assert(!CartMapper_ResolveGeometry(&Info, 32 * 1024, 32 * 1024,
                                       &RamSize));
}

static void TestRomPlans(void)
{
    CartMapperPlan_t Plan;
    CartMapperInfo_t Info = Decode(0x1b);
    assert(CartMapper_PlanRomBank(&Info, 0x101, &Plan));
    assert(Plan.WindowAddress == 0x4000 && Plan.WriteCount == 2);
    assert(Plan.Writes[0].Address == 0x2000 && Plan.Writes[0].Value == 1);
    assert(Plan.Writes[1].Address == 0x3000 && Plan.Writes[1].Value == 1);
    assert(CartMapper_PlanRomBank(&Info, 0, &Plan));
    assert(Plan.WindowAddress == 0 && Plan.WriteCount == 0);

    Info = Decode(0x06);
    assert(CartMapper_PlanRomBank(&Info, 15, &Plan));
    assert(Plan.WriteCount == 1 && Plan.Writes[0].Address == 0x2100 &&
           Plan.Writes[0].Value == 15);
    assert(!CartMapper_PlanRomBank(&Info, 16, &Plan));

    Info = Decode(0x03);
    assert(CartMapper_PlanRomBank(&Info, 0x20, &Plan));
    assert(Plan.WindowAddress == 0 && Plan.WriteCount == 2);
    assert(Plan.Writes[0].Address == 0x6000 && Plan.Writes[0].Value == 1);
    assert(Plan.Writes[1].Address == 0x4000 && Plan.Writes[1].Value == 1);
}

static void TestRamAndRestorePlans(void)
{
    CartMapperPlan_t Plan;
    CartMapperInfo_t Info = Decode(0x1e);
    assert(CartMapper_PlanRamBank(&Info, 7, &Plan));
    assert(Plan.WriteCount == 1 && Plan.Writes[0].Address == 0x4000 &&
           Plan.Writes[0].Value == 7);
    assert(!CartMapper_PlanRamBank(&Info, 8, &Plan));
    assert(CartMapper_PlanRestore(&Info, &Plan));
    assert(Plan.WriteCount == 4);
    assert(Plan.Writes[2].Address == 0x3000 && Plan.Writes[2].Value == 0);
    assert(Plan.Writes[3].Address == 0x2000 && Plan.Writes[3].Value == 1);

    Info = Decode(0x1b);
    assert(CartMapper_PlanRamBank(&Info, 15, &Plan));

    Info = Decode(0x06);
    assert(CartMapper_PlanRamBank(&Info, 0, &Plan));
    assert(Plan.WriteCount == 0);
    assert(!CartMapper_PlanRamBank(&Info, 1, &Plan));
    assert(CartMapper_PlanRestore(&Info, &Plan));
    assert(Plan.WriteCount == 2 && Plan.Writes[1].Address == 0x2100);
}

int main(void)
{
    TestDecode();
    TestGeometry();
    TestRomPlans();
    TestRamAndRestorePlans();
    puts("cart_mapper_test: PASS");
    return 0;
}
