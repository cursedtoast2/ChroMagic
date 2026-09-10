#include <assert.h>
#include <stdlib.h>
#ifndef CM_VIRTUAL_CART_SOURCE
#define CM_VIRTUAL_CART_SOURCE "../../main/virtual_cart.c"
#endif
#include CM_VIRTUAL_CART_SOURCE

static uint8_t Ram[8192], Snapshot[8192];
static bool Paused, Requested, Dirty, FailRead;
static unsigned Polls, Resumes, Blocks;
static uint8_t Block;
static uint16_t Sequence;
static void GameTick(void) { if (!Paused) { ++Ram[0]; Dirty = true; } }
void vTaskDelay(TickType_t ticks) { (void)ticks; GameTick(); }
TickType_t xTaskGetTickCount(void) { return 0; }
esp_err_t CartLink_VirtualCommand(uint8_t command, uint16_t config,
                                 uint8_t high, CartLinkResponse_t *response)
{
    if (command == 8) { Requested = true; Polls = 0; }
    if (command == 9) { Requested = Paused = false; ++Resumes; }
    if (command == 2 && Requested && ++Polls == 3) Paused = true;
    GameTick();
    memset(response, 0, sizeof(*response)); response->Count = 4;
    response->Data[0] = 1 | (Dirty ? 4 : 0);
    response->Data[1] = Paused ? 2 : 0;
    if (command == 4) {
        Block = high; Sequence = config; ++Blocks;
        if (Block == 0) { memcpy(Snapshot, Ram, sizeof(Ram)); Dirty = false; }
    }
    return ESP_OK;
}
esp_err_t CartBulk_ReadVirtualBlock(uint16_t sequence, uint8_t *data)
{
    assert(sequence == Sequence && Block < 8);
    GameTick();
    if (FailRead) return ESP_ERR_TIMEOUT;
    memcpy(data, Snapshot + 1024 * Block, 1024);
    return ESP_OK;
}
int main(void)
{
    char directory[] = "/tmp/chromagic-transition-XXXXXX"; assert(mkdtemp(directory));
    Active = true; ActiveInfo.RamSize = sizeof(Ram);
    ActiveInfo.Mapper.Kind = kCartMapper_Mbc5; ActiveInfo.Mapper.HasBattery = true;
    snprintf(ActiveSavePath, sizeof(ActiveSavePath), "%s/game.sav", directory);
    for (unsigned i = 0; i < sizeof(Ram); ++i) Ram[i] = i * 7 + 3;
    Dirty = true;
    assert(PersistActiveDataForTransition() == ESP_OK);
    assert(Paused && Blocks == 8 && Resumes == 0);
    FILE *file = fopen(ActiveSavePath, "rb"); assert(file);
    uint8_t published[8192]; assert(fread(published, sizeof(published), 1, file) == 1);
    assert(fgetc(file) == EOF); fclose(file);
    assert(!memcmp(published, Ram, sizeof(Ram)));
    Paused = Requested = false; GameTick(); FailRead = true;
    assert(PersistActiveDataForTransition() == ESP_ERR_TIMEOUT);
    assert(!Paused && Resumes == 1 && Active);
    file = fopen(ActiveSavePath, "rb"); assert(file);
    uint8_t retained[8192]; assert(fread(retained, sizeof(retained), 1, file) == 1); fclose(file);
    assert(!memcmp(retained, published, sizeof(retained)));
    assert(unlink(ActiveSavePath) == 0); assert(rmdir(directory) == 0);
    puts("PASS: final snapshot stops live writes; export failure preserves file and resumes old game");
    return 0;
}
