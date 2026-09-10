#include <assert.h>
#include "../../main/sd_card.c"

static esp_err_t MountResult, CommandResult, CommandError;
static bool Responds, MissingResponseFlag;
static sdmmc_card_t Card;
SemaphoreHandle_t xSemaphoreCreateMutexStatic(StaticSemaphore_t *p) { return p; }
int xSemaphoreTake(SemaphoreHandle_t p, TickType_t wait) {
    if (p->held) return 0;
    p->held = 1; return pdTRUE;
}
int xSemaphoreGive(SemaphoreHandle_t p) { assert(p->held); p->held = 0; return pdTRUE; }
esp_err_t sdmmc_host_do_transaction(int slot, sdmmc_command_t *cmd) {
    cmd->error = CommandError;
    return CommandResult;
}
esp_err_t esp_vfs_fat_sdmmc_mount(const char *path, const sdmmc_host_t *host,
    const sdmmc_slot_config_t *slot, const esp_vfs_fat_sdmmc_mount_config_t *config,
    sdmmc_card_t **out) {
    assert(!config->format_if_mount_failed && slot->width == 1);
    sdmmc_command_t cmd = {.opcode = 8, .flags = MissingResponseFlag ? 0 : SCF_RSP_PRESENT};
    if (Responds) host->do_transaction(1, &cmd);
    *out = MountResult == ESP_OK ? &Card : NULL;
    return MountResult;
}
esp_err_t esp_vfs_fat_sdcard_unmount(const char *path, sdmmc_card_t *card) { assert(card == &Card); return ESP_OK; }
void sdmmc_card_print_info(FILE *f, const sdmmc_card_t *card) {}
int esp_console_cmd_register(const esp_console_cmd_t *c) { return ESP_OK; }
int main(void) {
    sdmmc_card_t *card;
    MountResult = ESP_ERR_TIMEOUT;
    assert(SDCard_Mount(&card) == ESP_ERR_NOT_FOUND && card == NULL);
    Responds = true;
    assert(SDCard_Mount(&card) == ESP_ERR_TIMEOUT && CardResponded);
    CommandError = ESP_ERR_TIMEOUT;
    assert(SDCard_Mount(&card) == ESP_ERR_NOT_FOUND && !CardResponded);
    CommandError = ESP_OK; MissingResponseFlag = true;
    assert(SDCard_Mount(&card) == ESP_ERR_NOT_FOUND);
    MissingResponseFlag = false;
    MountResult = ESP_FAIL;
    assert(SDCard_Mount(&card) == ESP_FAIL);
    MountResult = ESP_OK;
    assert(SDCard_Mount(&card) == ESP_OK && card == &Card);
    sdmmc_card_t *other;
    assert(SDCard_Mount(&other) == ESP_ERR_INVALID_STATE);
    assert(SDCard_Unmount(card) == ESP_OK);
    assert(SDCard_Mount(&card) == ESP_OK);
    assert(SDCard_Unmount(card) == ESP_OK);
    return 0;
}
