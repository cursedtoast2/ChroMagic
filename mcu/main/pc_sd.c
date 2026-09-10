#include "pc_sd.h"
#include "pc_backup.h"
#include "cart_backup.h"
#include "cart_bulk.h"
#include "cart_link.h"
#include "sd_card.h"
#include "sd_publish.h"
#include "virtual_cart.h"
#include "driver/uart.h"
#include "esp_rom_crc.h"
#include "esp_timer.h"
#include "esp_random.h"
#include "cJSON.h"
#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { kPathSize = 768, kPayloadSize = 1536 };
static uint8_t Payload[kPayloadSize];
static uint8_t Block[kCartBulkBlockSize];
static char Path[kPathSize], Other[kPathSize], Temporary[kPathSize];
static FILE *Upload;
static int64_t LastPing;
static bool BulkOpen;
static int FailureErrno;
static unsigned FailedOp;
static uint32_t UploadSize, UploadExpectedCrc, UploadReceived, UploadCrc;

static uint32_t LE32(const uint8_t *p)
{
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

static bool MakePath(char *Out, const uint8_t *p, size_t Size)
{
    const size_t RootSize = strlen(SDCARD_MOUNT_POINT);
    if (Size == 0 || Size + RootSize >= kPathSize || p[0] != '/' ||
        memchr(p, 0, Size) != NULL) return false;
    if (Size > 1 && p[Size - 1] == '/') return false;
    size_t Start = 1;
    for (size_t i = 1; i <= Size; ++i)
    {
        if (i == Size || p[i] == '/')
        {
            size_t n = i - Start;
            if (Size != 1 && (n == 0 || n > 255 || p[i - 1] == '.' || p[i - 1] == ' '))
                return false;
            Start = i + 1;
        }
        else if (p[i] < 32 || strchr("\\:*?\"<>|", p[i]) != NULL)
            return false;
    }
    memcpy(Out, SDCARD_MOUNT_POINT, RootSize);
    memcpy(Out + RootSize, p, Size);
    Out[Size + RootSize] = 0;
    return true;
}

static esp_err_t JsonLine(const char *Kind, cJSON *Object)
{
    if (Object == NULL) return ESP_ERR_NO_MEM;
    char *Text = cJSON_PrintUnformatted(Object);
    cJSON_Delete(Object);
    if (Text == NULL) return ESP_ERR_NO_MEM;
    printf("PCSD %s %s\n", Kind, Text);
    free(Text);
    return ESP_OK;
}

static esp_err_t List(const char *Directory)
{
    DIR *Dir = opendir(Directory);
    if (Dir == NULL) return ESP_FAIL;
    esp_err_t Result = ESP_OK;
    struct dirent *Entry;
    while ((Entry = readdir(Dir)) != NULL)
    {
        if (strcmp(Entry->d_name, ".") == 0 || strcmp(Entry->d_name, "..") == 0) continue;
        if (snprintf(Other, sizeof(Other), "%s%s%s", Directory,
                     Directory[strlen(Directory) - 1] == '/' ? "" : "/",
                     Entry->d_name) >= sizeof(Other)) { Result = ESP_ERR_INVALID_SIZE; break; }
        struct stat Info;
        if (stat(Other, &Info) != 0) { Result = ESP_FAIL; break; }
        cJSON *Object = cJSON_CreateObject();
        cJSON_AddStringToObject(Object, "name", Entry->d_name);
        cJSON_AddBoolToObject(Object, "directory", S_ISDIR(Info.st_mode));
        cJSON_AddNumberToObject(Object, "size", Info.st_size);
        Result = JsonLine("ENTRY", Object);
        if (Result != ESP_OK) break;
    }
    closedir(Dir);
    return Result;
}

static esp_err_t BeginDownload(void)
{
    if (BulkOpen) return ESP_OK;
    esp_err_t Result = CartBackup_SetPCMode(false);
    if (Result != ESP_OK) return Result;
    Result = CartBulk_Begin();
    if (Result != ESP_OK) return Result;
    BulkOpen = true;
    CartLinkResponse_t Reply;
    Result = CartLink_Transaction(kCartLinkOp_Enter, 0, 3, &Reply);
    if (Result == ESP_OK && Reply.Status != 0) Result = ESP_ERR_INVALID_RESPONSE;
    return Result;
}

static esp_err_t Download(void)
{
    struct stat Info;
    if (stat(Path, &Info) != 0 || !S_ISREG(Info.st_mode) || Info.st_size < 0)
        return ESP_ERR_INVALID_ARG;
    FILE *File = fopen(Path, "rb");
    if (File == NULL) return ESP_FAIL;
    esp_err_t Result = BeginDownload();
    const uint32_t Size = Info.st_size;
    uint32_t Crc = 0;
    if (Result == ESP_OK)
    {
        printf("PCSD BULK size=%lu\n", (unsigned long)Size);
        fflush(stdout);
        Result = uart_wait_tx_done(UART_NUM_0, pdMS_TO_TICKS(100));
    }
    uint32_t Offset = 0;
    while (Result == ESP_OK && Offset < Size)
    {
        const size_t Count = Size - Offset < sizeof(Block) ? Size - Offset : sizeof(Block);
        if (fread(Block, 1, Count, File) != Count) { Result = ESP_FAIL; break; }
        Crc = esp_rom_crc32_le(Crc, Block, Count);
        Result = CartBulk_SendUSBBlock(Block, Count, (Offset / sizeof(Block)) * 2);
        Offset += Count;
    }
    if (fclose(File) != 0 && Result == ESP_OK) Result = ESP_FAIL;
    if (Result == ESP_OK) printf("PCSD CRC crc=%08lx\n", (unsigned long)Crc);
    return Result;
}

static void AbortUpload(void)
{
    if (Upload != NULL) { fclose(Upload); Upload = NULL; }
    if (Temporary[0] != 0) { unlink(Temporary); Temporary[0] = 0; }
}

static esp_err_t Keepalive(void)
{
    if (esp_timer_get_time() - LastPing < 250000) return ESP_OK;
    CartLinkResponse_t Reply;
    esp_err_t Result = CartLink_Transaction(kCartLinkOp_Ping, 0, 0, &Reply);
    if (Result == ESP_OK && (Reply.Status != 0 ||
        (BulkOpen && !(Reply.Data[1] & 1))))
        Result = ESP_ERR_INVALID_STATE;
    LastPing = esp_timer_get_time();
    return Result;
}

static esp_err_t BeginUpload(uint32_t Size, uint32_t Crc, bool Replace)
{
    struct stat Existing;
    if (stat(Path, &Existing) == 0)
    {
        if (!Replace || !S_ISREG(Existing.st_mode)) return ESP_ERR_INVALID_STATE;
    }
    else if (errno != ENOENT) return ESP_FAIL;
    char *Slash = strrchr(Path, '/');
    size_t Parent = Slash - Path + 1;
    if (Parent + 15 > sizeof(Temporary)) return ESP_ERR_INVALID_SIZE;
    memcpy(Temporary, Path, Parent);
    for (unsigned Attempt = 0; Attempt < 8; ++Attempt)
    {
        snprintf(Temporary + Parent, sizeof(Temporary) - Parent,
                 "CM%08lx.TMP", (unsigned long)esp_random());
        Upload = fopen(Temporary, "wbx");
        if (Upload != NULL || errno != EEXIST) break;
    }
    if (Upload == NULL) { Temporary[0] = 0; return ESP_FAIL; }
    UploadSize = Size;
    UploadExpectedCrc = Crc;
    UploadReceived = UploadCrc = 0;
    return ESP_OK;
}

static esp_err_t VerifyUpload(void)
{
    if (Upload == NULL || UploadReceived != UploadSize ||
        UploadCrc != UploadExpectedCrc) return ESP_ERR_INVALID_CRC;
    if (fflush(Upload) != 0 || fsync(fileno(Upload)) != 0) return ESP_FAIL;
    int Closed = fclose(Upload); Upload = NULL;
    if (Closed != 0) return ESP_FAIL;
    FILE *Verify = fopen(Temporary, "rb");
    if (Verify == NULL) return ESP_FAIL;
    uint32_t Crc = 0, Read = 0;
    size_t Count;
    while ((Count = fread(Block, 1, sizeof(Block), Verify)) != 0)
    {
        Crc = esp_rom_crc32_le(Crc, Block, Count); Read += Count;
        if (Keepalive() != ESP_OK) { fclose(Verify); return ESP_ERR_TIMEOUT; }
    }
    bool Valid = !ferror(Verify) && Read == UploadSize && Crc == UploadExpectedCrc;
    if (fclose(Verify) != 0) Valid = false;
    if (!Valid) return ESP_ERR_INVALID_CRC;
    return ESP_OK;
}

static esp_err_t CommitUpload(void)
{
    esp_err_t Result = VerifyUpload();
    if (Result != ESP_OK) return Result;
    struct stat Existing;
    if (stat(Path, &Existing) == 0 || errno != ENOENT || rename(Temporary, Path) != 0)
        return ESP_FAIL;
    Temporary[0] = 0;
    return ESP_OK;
}

static uint32_t BackupTotal, BackupCompleted, BackupReady, BackupExpected;
static char BackupTemps[3][16], BackupScratch[kPathSize];

static void BackupPath(CartBackupArtifact_t Artifact)
{
    strcpy(Path, Other);
    if (Artifact == kCartBackupArtifact_Rtc)
        strcpy(strrchr(Path, '.'), ".rtc");
    else if (Artifact == kCartBackupArtifact_Save)
        strcpy(strrchr(Path, '.'), ".sav");
}

static void BackupTempPath(unsigned Artifact)
{
    size_t Parent = strrchr(Other, '/') - Other + 1;
    memcpy(BackupScratch, Other, Parent);
    strcpy(BackupScratch + Parent, BackupTemps[Artifact]);
}

static bool BackupOldPath(void)
{
    const char *Name = strrchr(Path, '/') + 1;
    return strlen(Name) + 4 <= 255 &&
        snprintf(BackupScratch, sizeof(BackupScratch), "%s.old", Path) < sizeof(BackupScratch);
}

static esp_err_t BackupInfo(void *pContext, const CartBackupMetadata_t *pInfo)
{
    const bool Save = *(const bool *)pContext;
    BackupTotal = (Save ? 0 : pInfo->RomSize) + pInfo->SaveSize + (pInfo->HasRtc ? 4 : 0);
    BackupExpected = (Save ? 0 : 1u << kCartBackupArtifact_Rom) |
        (pInfo->SaveSize ? 1u << kCartBackupArtifact_Save : 0) |
        (pInfo->HasRtc ? 1u << kCartBackupArtifact_Rtc : 0);
    for (unsigned Artifact = 0; Artifact < 3; ++Artifact)
    {
        if (!(BackupExpected & (1u << Artifact))) continue;
        BackupPath(Artifact);
        if (!BackupOldPath()) return ESP_ERR_INVALID_SIZE;
        esp_err_t Result = SDPublish_Recover(Path, BackupScratch);
        if (Result != ESP_OK) return Result;
        struct stat Existing;
        if (stat(Path, &Existing) == 0)
        {
            if (!S_ISREG(Existing.st_mode)) return ESP_ERR_INVALID_STATE;
        }
        else if (errno != ENOENT) return ESP_FAIL;
    }
    return ESP_OK;
}

static esp_err_t BackupBegin(void *pContext, CartBackupArtifact_t Artifact, uint32_t Size)
{
    BackupPath(Artifact);
    return BeginUpload(Size, 0, true);
}

static esp_err_t BackupData(void *pContext, CartBackupArtifact_t Artifact,
                           const uint8_t *pData, size_t Size)
{
    if (Upload == NULL || Size > UploadSize - UploadReceived) return ESP_ERR_INVALID_SIZE;
    if (fwrite(pData, 1, Size, Upload) != Size) return ESP_FAIL;
    UploadReceived += Size;
    UploadCrc = esp_rom_crc32_le(UploadCrc, pData, Size);
    BackupCompleted += Size;
    if (UploadReceived % 16384 == 0 || UploadReceived == UploadSize)
    {
        printf("PCSD PROGRESS completed=%lu total=%lu\n",
               (unsigned long)BackupCompleted, (unsigned long)BackupTotal);
        fflush(stdout);
    }
    return ESP_OK;
}

static esp_err_t BackupEnd(void *pContext, CartBackupArtifact_t Artifact)
{
    UploadExpectedCrc = UploadCrc;
    printf("PCSD VERIFY completed=%lu total=%lu\n",
           (unsigned long)BackupCompleted, (unsigned long)BackupTotal);
    fflush(stdout);
    esp_err_t Result = VerifyUpload();
    if (Result == ESP_OK)
    {
        snprintf(BackupTemps[Artifact], sizeof(BackupTemps[Artifact]), "%s",
                 strrchr(Temporary, '/') + 1);
        Temporary[0] = 0;
        BackupReady |= 1u << Artifact;
    }
    return Result;
}

static esp_err_t BackupCart(bool Save)
{
    if (BulkOpen) return ESP_ERR_INVALID_STATE;
    const char *Extension = strrchr(Path, '.');
    if (Extension == NULL || (Save ? strcmp(Extension, ".sav") != 0
        : strcmp(Extension, ".gb") != 0 && strcmp(Extension, ".gbc") != 0))
        return ESP_ERR_INVALID_ARG;
    strcpy(Other, Path);
    BackupCompleted = BackupReady = BackupExpected = 0;
    memset(BackupTemps, 0, sizeof(BackupTemps));
    esp_err_t Result = CartBackup_SetPCMode(true);
    const CartBackupStreamSink_t Sink = {BackupInfo, BackupBegin, BackupData, BackupEnd};
    if (Result == ESP_OK)
        Result = CartBackup_StreamToSD(Save ? kCartBackupSelectSave :
                                       kCartBackupSelectRom | kCartBackupSelectSave,
                                       &Sink, &Save);
    if (Result == ESP_OK && BackupReady != BackupExpected) Result = ESP_ERR_INVALID_SIZE;
    uint32_t Staged = 0, Published = 0;
    for (unsigned Artifact = 0; Result == ESP_OK && Artifact < 3; ++Artifact)
    {
        if (!(BackupReady & (1u << Artifact))) continue;
        BackupPath(Artifact);
        if (!BackupOldPath()) { Result = ESP_ERR_INVALID_SIZE; break; }
        bool Moved = false;
        Result = SDPublish_Stage(Path, BackupScratch, &Moved);
        if (Moved) Staged |= 1u << Artifact;
    }
    for (unsigned Artifact = 0; Result == ESP_OK && Artifact < 3; ++Artifact)
    {
        if (!(BackupReady & (1u << Artifact))) continue;
        BackupPath(Artifact);
        BackupTempPath(Artifact);
        if (rename(BackupScratch, Path) != 0) Result = ESP_FAIL;
        else Published |= 1u << Artifact;
    }
    if (Result != ESP_OK)
    {
        AbortUpload();
        for (unsigned Artifact = 0; Artifact < 3; ++Artifact)
        {
            BackupPath(Artifact);
            if (Published & (1u << Artifact)) (void)unlink(Path);
            if ((Staged & (1u << Artifact)) && BackupOldPath())
                (void)rename(BackupScratch, Path);
            if (BackupReady & (1u << Artifact))
            { BackupTempPath(Artifact); (void)unlink(BackupScratch); }
        }
    }
    else
    {
        for (unsigned Artifact = 0; Artifact < 3; ++Artifact)
        {
            if (!(Published & (1u << Artifact))) continue;
            BackupPath(Artifact);
            if ((Staged & (1u << Artifact)) && BackupOldPath()) (void)unlink(BackupScratch);
            printf("PCSD SAVED %s\n", Path + strlen(SDCARD_MOUNT_POINT));
        }
        fflush(stdout);
    }
    return Result;
}

static esp_err_t Request(size_t Size, esp_err_t Mount)
{
    const uint8_t Op = Payload[0];
    if (Op == 0 || Op == 1)
    {
        if (Size != 1 || Upload != NULL) return ESP_ERR_INVALID_ARG;
        if (Op == 1) printf("PCSD STATUS present=%u error=%s\n",
                            Mount == ESP_OK ? 1 : 0, esp_err_to_name(Mount));
        return ESP_OK;
    }
    if (Mount != ESP_OK) return Mount;
    if (Op == 8)
    {
        if (Upload == NULL || Size <= 1 || Size - 1 > UploadSize - UploadReceived)
            return ESP_ERR_INVALID_ARG;
        if (fwrite(Payload + 1, 1, Size - 1, Upload) != Size - 1) return ESP_FAIL;
        UploadCrc = esp_rom_crc32_le(UploadCrc, Payload + 1, Size - 1);
        UploadReceived += Size - 1;
        return ESP_OK;
    }
    if (Op == 9)
    {
        return Size == 1 ? CommitUpload() : ESP_ERR_INVALID_ARG;
    }
    if (Upload != NULL) return ESP_ERR_INVALID_STATE;
    size_t PathOffset = Op == 7 ? 9 : 1;
    if (Size <= PathOffset) return ESP_ERR_INVALID_ARG;
    const uint8_t *Separator = Op == 3 ? memchr(Payload + 1, 0, Size - 1) : NULL;
    size_t PathLength = Separator ? (size_t)(Separator - Payload - 1) : Size - PathOffset;
    if (!MakePath(Path, Payload + PathOffset, PathLength)) return ESP_ERR_INVALID_ARG;
    if (Op != 2 && strlen(Path) == strlen(SDCARD_MOUNT_POINT) + 1) return ESP_ERR_INVALID_ARG;
    switch (Op)
    {
        case 2: return List(Path);
        case 3:
        {
            if (Separator == NULL || !MakePath(Other, Separator + 1, Payload + Size - Separator - 1) ||
                strlen(Other) == strlen(SDCARD_MOUNT_POINT) + 1) return ESP_ERR_INVALID_ARG;
            struct stat Existing;
            if (stat(Other, &Existing) == 0 || errno != ENOENT) return ESP_ERR_INVALID_STATE;
            return rename(Path, Other) == 0 ? ESP_OK : ESP_FAIL;
        }
        case 4: return mkdir(Path, 0777) == 0 ? ESP_OK : ESP_FAIL;
        case 5:
        {
            struct stat Info;
            if (stat(Path, &Info) != 0) return ESP_FAIL;
            return (S_ISDIR(Info.st_mode) ? rmdir(Path) : unlink(Path)) == 0 ? ESP_OK : ESP_FAIL;
        }
        case 6: return Download();
        case 10: return BackupCart(false);
        case 11: return BackupCart(true);
        case 7:
        {
            return BeginUpload(LE32(Payload + 1), LE32(Payload + 5), false);
        }
        default: return ESP_ERR_NOT_SUPPORTED;
    }
}

static esp_err_t Run(void)
{
    BulkOpen = false;
    esp_err_t Result;
    LastPing = esp_timer_get_time();
    sdmmc_card_t *Card = NULL;
    esp_err_t Mount = SDCard_Mount(&Card);
    Upload = NULL; Temporary[0] = 0;
    (void)uart_flush_input(UART_NUM_0);
    printf("PCSD READY protocol=1 block=1024\n");
    fflush(stdout);
    Result = ESP_OK;
    for (uint32_t Sequence = 0; Result == ESP_OK; ++Sequence)
    {
        uint8_t Header[16];
        Result = PCBackup_ReadUpload(Header, sizeof(Header));
        if (Result != ESP_OK) break;
        uint32_t Size = LE32(Header + 8);
        if (memcmp(Header, "CF01", 4) != 0 || LE32(Header + 4) != Sequence ||
            Size == 0 || Size > sizeof(Payload)) { Result = ESP_ERR_INVALID_ARG; break; }
        Result = PCBackup_ReadUpload(Payload, Size);
        if (Result != ESP_OK) break;
        if (esp_rom_crc32_le(0, Payload, Size) != LE32(Header + 12))
        { Result = ESP_ERR_INVALID_CRC; break; }
        FailedOp = Payload[0];
        errno = 0;
        Result = Keepalive();
        if (Result == ESP_OK) Result = Request(Size, Mount);
        if (Result != ESP_OK) break;
        printf("PCSD OK seq=%lu\n", (unsigned long)Sequence);
        fflush(stdout);
        if (Payload[0] == 0) break;
    }
    if (Result != ESP_OK) FailureErrno = errno;
    AbortUpload();
    if (Card != NULL)
    {
        esp_err_t Unmount = SDCard_Unmount(Card);
        if (Result == ESP_OK) Result = Unmount;
    }
    if (BulkOpen)
    {
        CartLinkResponse_t Reply;
        esp_err_t Release = CartLink_Transaction(kCartLinkOp_Exit, 0, 0, &Reply);
        if (Result == ESP_OK && (Release != ESP_OK || Reply.Status != 0)) Result = ESP_FAIL;
        CartBulk_End();
        BulkOpen = false;
    }
    return Result;
}

esp_err_t PCSD_Run(void)
{
    FailureErrno = 0; FailedOp = 0;
    esp_err_t Result = Run();
    if (Result == ESP_OK) printf("PCSD PASS error=ESP_OK\n");
    else printf("PCSD FAIL error=%s op=%u errno=%d\n", esp_err_to_name(Result), FailedOp, FailureErrno);
    fflush(stdout);
    return Result;
}
