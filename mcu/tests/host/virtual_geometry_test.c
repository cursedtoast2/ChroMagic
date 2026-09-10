#include <assert.h>
#include <stdlib.h>
#include "../../main/virtual_cart.c"

static uint8_t *ExpectedImage;
static uint32_t ImageSize, DecodeSize, Uploaded;
static uint32_t Progress, ProgressTotal;

esp_err_t CartBulk_WritePSRAMBlock(uint32_t address, const uint8_t *data)
{
    assert(address == kRomBase + Uploaded);
    assert(Uploaded + kCartBulkBlockSize <= DecodeSize);
    for (unsigned i = 0; i < kCartBulkBlockSize; ++i) {
        uint32_t offset = Uploaded + i;
        assert(data[i] == (offset < ImageSize ? ExpectedImage[offset] : 0xff));
    }
    Uploaded += kCartBulkBlockSize;
    return ESP_OK;
}
void RomBrowserUI_SetProgress(uint32_t value, uint32_t total)
{
    assert(value <= total && value >= Progress);
    Progress = value; ProgressTotal = total;
}

static FILE *MakeImage(uint8_t type, uint8_t rom_code, uint8_t ram_code,
                       uint32_t size)
{
    free(ExpectedImage); ExpectedImage = malloc(size); assert(ExpectedImage);
    for (uint32_t i = 0; i < size; ++i)
        ExpectedImage[i] = (uint8_t)((i / 16384) * 7 + i * 3);
    memcpy(ExpectedImage + 0x104, NintendoLogo, sizeof(NintendoLogo));
    memset(ExpectedImage + 0x134, 0, 25);
    ExpectedImage[0x147] = type; ExpectedImage[0x148] = rom_code;
    ExpectedImage[0x149] = ram_code;
    uint8_t header_sum = 0;
    for (unsigned i = 0x134; i <= 0x14c; ++i)
        header_sum = (uint8_t)(header_sum - ExpectedImage[i] - 1);
    ExpectedImage[0x14d] = header_sum;
    uint16_t sum = 0;
    for (uint32_t i = 0; i < size; ++i)
        if (i != 0x14e && i != 0x14f) sum += ExpectedImage[i];
    ExpectedImage[0x14e] = sum >> 8; ExpectedImage[0x14f] = sum;
    FILE *file = tmpfile(); assert(file);
    assert(fwrite(ExpectedImage, size, 1, file) == 1); rewind(file);
    ImageSize = size; Uploaded = Progress = ProgressTotal = 0;
    return file;
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "paths")) {
        char Rom[kPathSize], Save[kPathSize], Rtc[kPathSize], Sidecar[kPathSize];
        assert(ResolvePath("Japan.v1/Deeper/Pokemon.gbc", Rom) == ESP_OK);
        assert(!strcmp(Rom, "/sdcard/CHROMAGIC/BACKUPS/Japan.v1/Deeper/Pokemon.gbc"));
        assert(MakeSavePath(Rom, true, Save) == ESP_OK);
        assert(!strcmp(Save, "/sdcard/CHROMAGIC/BACKUPS/Japan.v1/Deeper/Pokemon.sav"));
        assert(MakeRtcPath(Rom, true, Rtc) == ESP_OK);
        assert(!strcmp(Rtc, "/sdcard/CHROMAGIC/BACKUPS/Japan.v1/Deeper/Pokemon.rtc"));
        assert(ResolvePath("/sdcard/CHROMATIC/Europe/Pokemon.gb", Rom) == ESP_OK);
        assert(MakeSavePath(Rom, false, Save) == ESP_OK);
        assert(!strcmp(Save, "/sdcard/CHROMATIC/Europe/Pokemon.SAV"));
        assert(MakeSidecarPath(Save, ".tmp", Sidecar) == ESP_OK);
        assert(!strcmp(Sidecar, "/sdcard/CHROMATIC/Europe/Pokemon.SAV.tmp"));
        puts("PASS: unchanged loader resolves nested ROM/save/RTC paths without crossing folders");
        return 0;
    }
    if (!strcmp(argv[1], "ram")) {
        const uint8_t types[] = {9, 3, 0x13, 0x1b};
        for (unsigned i = 0; i < sizeof(types); ++i) {
            FILE *file = MakeImage(types[i], 0, 1, 32768);
            VirtualCartInfo_t info = {0};
            assert(DecodeHeader(file, &info) == ESP_OK);
            assert(info.RamSize == 2048);
            assert((info.ConfigurationHigh >> 4) == 1);
            fclose(file);
        }
    } else {
        const uint32_t sizes[] = {32768, 72*16384, 80*16384, 96*16384, 4194304};
        const uint32_t decodes[] = {32768, 2097152, 2097152, 2097152, 4194304};
        const uint8_t codes[] = {0, 0x52, 0x53, 0x54, 7};
        for (unsigned i = 0; i < sizeof(codes); ++i) {
            FILE *file = MakeImage(0x19, codes[i], 0, sizes[i]);
            VirtualCartInfo_t info = {0}; DecodeSize = decodes[i];
            assert(DecodeHeader(file, &info) == ESP_OK);
            unsigned mask = (info.Configuration >> 11) | ((info.ConfigurationHigh & 15) << 5);
            assert(mask == decodes[i] / 16384 - 1);
            assert(UploadRom(file, &info) == ESP_OK);
            assert(Uploaded == DecodeSize && Progress == DecodeSize && ProgressTotal == DecodeSize);
            fclose(file);
        }
        FILE *file = MakeImage(0x19, 2, 0, 131072);
        ExpectedImage[0x2345] ^= 1;
        assert(fseek(file, 0x2345, SEEK_SET) == 0);
        assert(fputc(ExpectedImage[0x2345], file) != EOF);
        VirtualCartInfo_t info = {0}; DecodeSize = 131072;
        assert(DecodeHeader(file, &info) == ESP_OK);
        assert(UploadRom(file, &info) == ESP_ERR_INVALID_CRC);
        fclose(file);
    }
    free(ExpectedImage); puts("PASS: actual MCU geometry and upload bytes");
    return 0;
}
