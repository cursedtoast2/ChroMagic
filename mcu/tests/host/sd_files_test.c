#include <assert.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
static char TestRoot[] = "/tmp/chromagician-sd-test-XXXXXX";
#define SDCARD_MOUNT_POINT TestRoot
#define rename TestRename
#include "../../main/pc_sd.c"
#undef rename
extern int rename(const char *, const char *);
static bool FailPublish;
int TestRename(const char *From, const char *To) {
    if (FailPublish && strstr(From, ".TMP") && strstr(To, ".sav")) {
        FailPublish = false; errno = EIO; return -1;
    }
    return rename(From, To);
}

static uint8_t Wire[16384], Input[32768];
static size_t WireSize, InputSize, InputOffset;
static bool Active;
static unsigned Commands, ModeChanges, BulkBegins, BulkEnds, Enters, Exits;
static unsigned BackupCalls;
static bool FailRtc;
static uint8_t BackupSeed;
static bool NoSave;
static sdmmc_card_t TestCard;
uint32_t esp_random(void) { static uint32_t n; return ++n; }
uint32_t esp_rom_crc32_le(uint32_t crc, const uint8_t *data, size_t size) {
    crc = ~crc;
    for (size_t i = 0; i < size; ++i) {
        crc ^= data[i];
        for (unsigned b = 0; b < 8; ++b) crc = (crc >> 1) ^ (crc & 1 ? 0xedb88320u : 0);
    }
    return ~crc;
}
int64_t esp_timer_get_time(void) { static int64_t time; return time += 100000; }
esp_err_t uart_wait_tx_done(int port, TickType_t timeout) { return ESP_OK; }
esp_err_t uart_flush_input(int port) { return ESP_OK; }
esp_err_t SDCard_Mount(sdmmc_card_t **card) { *card = &TestCard; return ESP_OK; }
esp_err_t SDCard_Unmount(sdmmc_card_t *card) { assert(card == &TestCard); return ESP_OK; }
esp_err_t CartBackup_SetPCMode(bool enabled) { if (!enabled) ++ModeChanges; Active = enabled; return ESP_OK; }
esp_err_t CartBackup_StreamToSD(uint32_t selection, const CartBackupStreamSink_t *sink, void *context) {
    ++BackupCalls;
    assert(Active);
    assert(selection == kCartBackupSelectSave || selection == (kCartBackupSelectRom | kCartBackupSelectSave));
    const CartBackupMetadata_t info = {.RomSize = 4099, .SaveSize = NoSave ? 0 : 1031, .HasRtc = !NoSave};
    esp_err_t result = sink->OnInfo(context, &info);
    for (unsigned kind = 0; result == ESP_OK && kind <= kCartBackupArtifact_Save; ++kind) {
        if (!(selection & (1u << kind))) continue;
        const uint32_t size = kind == kCartBackupArtifact_Rom ? info.RomSize : info.SaveSize;
        if (size == 0) continue;
        result = sink->OnBegin(context, kind, size);
        uint8_t data[1024];
        for (uint32_t offset = 0; result == ESP_OK && offset < size;) {
            size_t n = size - offset < sizeof(data) ? size - offset : sizeof(data);
            for (size_t i = 0; i < n; ++i) data[i] = (offset + i + BackupSeed) % 251;
            result = sink->OnData(context, kind, data, n); offset += n;
        }
        if (result == ESP_OK) result = sink->OnEnd(context, kind);
    }
    if (result == ESP_OK && info.HasRtc) {
        result = sink->OnBegin(context, kCartBackupArtifact_Rtc, 4);
        if (result == ESP_OK) result = FailRtc ? ESP_ERR_TIMEOUT : sink->OnData(context, kCartBackupArtifact_Rtc, (uint8_t[]){1, 2, 3, 4}, 4);
        if (result == ESP_OK) result = sink->OnEnd(context, kCartBackupArtifact_Rtc);
    }
    return result;
}
esp_err_t CartBulk_Begin(void) { ++BulkBegins; return ESP_OK; }
void CartBulk_End(void) { assert(!Active); ++BulkEnds; }
esp_err_t CartLink_Transaction(CartLinkOperation_t op, uint16_t address, uint8_t value, CartLinkResponse_t *reply) {
    memset(reply, 0, sizeof(*reply)); ++Commands;
    assert(op == kCartLinkOp_Enter || op == kCartLinkOp_Exit || op == kCartLinkOp_Ping);
    if (op == kCartLinkOp_Enter) { assert(value == 3); Active = true; ++Enters; }
    if (op == kCartLinkOp_Exit) { Active = false; ++Exits; }
    if (op == kCartLinkOp_Ping) { reply->Count = 4; reply->Data[1] = Active; }
    return ESP_OK;
}
esp_err_t CartBulk_SendUSBBlock(const uint8_t *data, size_t size, uint8_t seq) {
    assert(Active && size > 0 && size <= 1024 && seq == (uint8_t)(WireSize / 1024 * 2));
    memcpy(Wire + WireSize, data, size);
    memset(Wire + WireSize + size, 0xff, 1024 - size);
    WireSize += 1024;
    return ESP_OK;
}
esp_err_t PCBackup_ReadUpload(uint8_t *data, size_t size) {
    if (InputOffset + size > InputSize) return ESP_ERR_TIMEOUT;
    memcpy(data, Input + InputOffset, size); InputOffset += size; return ESP_OK;
}
static void put32(uint8_t *p, uint32_t v) { for (unsigned i = 0; i < 4; ++i) p[i] = v >> (i * 8); }
static void frame(unsigned seq, const uint8_t *data, size_t size) {
    assert(InputSize + 16 + size <= sizeof(Input));
    uint8_t *p = Input + InputSize;
    memcpy(p, "CF01", 4); put32(p + 4, seq); put32(p + 8, size);
    put32(p + 12, esp_rom_crc32_le(0, data, size)); memcpy(p + 16, data, size);
    InputSize += 16 + size;
}
static void reset_input(void) { InputSize = InputOffset = WireSize = 0; }
static void upload(const char *name, const uint8_t *data, size_t size, bool finish, bool bad_crc) {
    reset_input();
    uint8_t begin[256] = {7}; put32(begin + 1, size);
    put32(begin + 5, esp_rom_crc32_le(0, data, size) ^ bad_crc);
    memcpy(begin + 9, name, strlen(name)); frame(0, begin, 9 + strlen(name));
    unsigned seq = 1;
    for (size_t off = 0; off < size; ) {
        uint8_t part[1025] = {8}; size_t n = size - off > 1024 ? 1024 : size - off;
        memcpy(part + 1, data + off, n); frame(seq++, part, n + 1); off += n;
    }
    if (finish) { frame(seq++, (uint8_t[]){9}, 1); frame(seq, (uint8_t[]){0}, 1); }
}
static bool exists(const char *name) {
    char path[1024]; snprintf(path, sizeof(path), "%s%s", TestRoot, name);
    return access(path, F_OK) == 0;
}
static void check_backup(const char *name, unsigned size, unsigned seed) {
    char path[1024]; snprintf(path, sizeof(path), "%s%s", TestRoot, name);
    FILE *f = fopen(path, "rb"); assert(f);
    for (unsigned i = 0; i < size; ++i) assert(fgetc(f) == (int)((i + seed) % 251));
    assert(fgetc(f) == EOF); fclose(f);
}
int main(void) {
    assert(mkdtemp(TestRoot));
    for (unsigned Present = 0; Present < 2; ++Present) {
        Active = Present;
        for (unsigned Poll = 0; Poll < 10; ++Poll) {
            reset_input();
            frame(0, (uint8_t[]){1}, 1);
            frame(1, (uint8_t[]){2, '/'}, 2);
            frame(2, (uint8_t[]){0}, 1);
            assert(PCSD_Run() == ESP_OK && Active == (bool)Present);
        }
    }
    assert(ModeChanges == 0 && BulkBegins == 0 && BulkEnds == 0 && Enters == 0 && Exits == 0);
    uint8_t data[4099]; for (size_t i = 0; i < sizeof(data); ++i) data[i] = (i * 37) ^ (i >> 5);
    upload("/ボンバーマン test.gbc", data, sizeof(data), true, false);
    assert(PCSD_Run() == ESP_OK && exists("/ボンバーマン test.gbc"));
    assert(Active && ModeChanges == 0 && BulkBegins == 0 && Enters == 0 && Exits == 0);
    reset_input();
    const uint8_t get[] = "\6/ボンバーマン test.gbc";
    frame(0, get, sizeof(get) - 1); frame(1, (uint8_t[]){0}, 1);
    assert(PCSD_Run() == ESP_OK && WireSize == 5120);
    assert(!Active && ModeChanges == 1 && BulkBegins == 1 && BulkEnds == 1 && Enters == 1 && Exits == 1);
    assert(memcmp(data, Wire, sizeof(data)) == 0);
    for (size_t i = sizeof(data); i < WireSize; ++i) assert(Wire[i] == 0xff);
    upload("/bad.gbc", data, sizeof(data), true, true);
    assert(PCSD_Run() == ESP_ERR_INVALID_CRC && !exists("/bad.gbc"));
    upload("/interrupted.gbc", data, sizeof(data), false, false);
    assert(PCSD_Run() == ESP_ERR_TIMEOUT && !exists("/interrupted.gbc"));
    upload("/ボンバーマン test.gbc", data, 1, true, false);
    assert(PCSD_Run() == ESP_ERR_INVALID_STATE && exists("/ボンバーマン test.gbc"));
    upload("/empty", data, 0, true, false);
    assert(PCSD_Run() == ESP_OK && exists("/empty"));
    const char *invalid[] = {"/../foo", "/a/./b", "/foo.", "/foo ", "/a//b", "/a\\b", "/a:b"};
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(*invalid); ++i)
        assert(!MakePath(Path, (const uint8_t *)invalid[i], strlen(invalid[i])));
    reset_input();
    const uint8_t mkdir_cmd[] = "\4/folder";
    const uint8_t rename_cmd[] = "\3/ボンバーマン test.gbc\0/folder/game.gbc";
    const uint8_t delete_nonempty[] = "\5/folder";
    frame(0, mkdir_cmd, sizeof(mkdir_cmd) - 1);
    frame(1, rename_cmd, sizeof(rename_cmd) - 1);
    frame(2, delete_nonempty, sizeof(delete_nonempty) - 1);
    assert(PCSD_Run() != ESP_OK && exists("/folder/game.gbc"));
    reset_input();
    const uint8_t rmgame[] = "\5/folder/game.gbc", rmempty[] = "\5/empty";
    frame(0, rmgame, sizeof(rmgame) - 1); frame(1, delete_nonempty, sizeof(delete_nonempty) - 1);
    frame(2, rmempty, sizeof(rmempty) - 1); frame(3, (uint8_t[]){0}, 1);
    assert(PCSD_Run() == ESP_OK);
    assert(rmdir(TestRoot) == 0);
    assert(mkdir(TestRoot, 0700) == 0);
    assert(Commands > 0 && !Active);
    assert(ModeChanges == 1 && BulkBegins == 1 && BulkEnds == 1 && Enters == 1 && Exits == 1);
    reset_input();
    const uint8_t rom_backup[] = "\12/Pokemon - Red (Japan).gb";
    const uint8_t save_backup[] = "\13/Pokemon - Red (Japan).sav";
    frame(0, rom_backup, sizeof(rom_backup) - 1);
    frame(1, save_backup, sizeof(save_backup) - 1);
    frame(2, (uint8_t[]){0}, 1);
    assert(PCSD_Run() == ESP_OK && BackupCalls == 2);
    char rom_path[1024]; snprintf(rom_path, sizeof(rom_path), "%s/Pokemon - Red (Japan).gb", TestRoot);
    FILE *rom = fopen(rom_path, "rb"); assert(rom);
    for (unsigned i = 0; i < 4099; ++i) assert(fgetc(rom) == (int)(i % 251));
    assert(fgetc(rom) == EOF); fclose(rom);
    assert(exists("/Pokemon - Red (Japan).sav") && exists("/Pokemon - Red (Japan).rtc"));
    BackupSeed = 17;
    reset_input(); frame(0, save_backup, sizeof(save_backup) - 1); frame(1, (uint8_t[]){0}, 1);
    assert(PCSD_Run() == ESP_OK && exists("/Pokemon - Red (Japan).sav"));
    check_backup("/Pokemon - Red (Japan).sav", 1031, 17);
    check_backup("/Pokemon - Red (Japan).gb", 4099, 0);
    FailRtc = true;
    BackupSeed = 30;
    reset_input(); frame(0, rom_backup, sizeof(rom_backup) - 1);
    assert(PCSD_Run() == ESP_ERR_TIMEOUT);
    check_backup("/Pokemon - Red (Japan).sav", 1031, 17);
    check_backup("/Pokemon - Red (Japan).gb", 4099, 0);
    reset_input(); const uint8_t fail_backup[] = "\13/failed.sav";
    frame(0, fail_backup, sizeof(fail_backup) - 1);
    assert(PCSD_Run() == ESP_ERR_TIMEOUT && !exists("/failed.sav") && !exists("/failed.rtc"));
    FailRtc = false;
    FailPublish = true;
    reset_input(); frame(0, rom_backup, sizeof(rom_backup) - 1);
    assert(PCSD_Run() == ESP_FAIL && !FailPublish);
    check_backup("/Pokemon - Red (Japan).sav", 1031, 17);
    check_backup("/Pokemon - Red (Japan).gb", 4099, 0);
    reset_input(); frame(0, rom_backup, sizeof(rom_backup) - 1); frame(1, (uint8_t[]){0}, 1);
    assert(PCSD_Run() == ESP_OK);
    check_backup("/Pokemon - Red (Japan).sav", 1031, 30);
    check_backup("/Pokemon - Red (Japan).gb", 4099, 30);
    NoSave = true;
    reset_input(); const uint8_t plain_backup[] = "\12/plain.gb";
    frame(0, plain_backup, sizeof(plain_backup) - 1); frame(1, (uint8_t[]){0}, 1);
    assert(PCSD_Run() == ESP_OK && exists("/plain.gb"));
    assert(!exists("/plain.sav") && !exists("/plain.rtc"));
    NoSave = false;
    reset_input(); const uint8_t rmplain[] = "\5/plain.gb";
    frame(0, rmplain, sizeof(rmplain) - 1); frame(1, (uint8_t[]){0}, 1);
    assert(PCSD_Run() == ESP_OK);
    reset_input();
    const uint8_t rmrom[] = "\5/Pokemon - Red (Japan).gb", rmsave[] = "\5/Pokemon - Red (Japan).sav", rmrtc[] = "\5/Pokemon - Red (Japan).rtc";
    frame(0, rmrom, sizeof(rmrom)-1); frame(1, rmsave, sizeof(rmsave)-1); frame(2, rmrtc, sizeof(rmrtc)-1); frame(3, (uint8_t[]){0}, 1);
    assert(PCSD_Run() == ESP_OK && rmdir(TestRoot) == 0);
    puts("PASS: SD binary sessions, CRC, padding, interruptions, names, rename and deletion");
}
