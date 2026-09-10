#include "sd_publish.h"
#include <errno.h>
#include <stdio.h>
#include <sys/stat.h>
#include <unistd.h>

esp_err_t SDPublish_Recover(const char *pFinal, const char *pOld)
{
    struct stat Stat;
    if (stat(pOld, &Stat) != 0)
        return errno == ENOENT ? ESP_OK : ESP_FAIL;
    if (!S_ISREG(Stat.st_mode)) return ESP_ERR_INVALID_STATE;
    if (stat(pFinal, &Stat) == 0)
    {
        if (!S_ISREG(Stat.st_mode)) return ESP_ERR_INVALID_STATE;
        return unlink(pOld) == 0 ? ESP_OK : ESP_FAIL;
    }
    if (errno != ENOENT) return ESP_FAIL;
    return rename(pOld, pFinal) == 0 ? ESP_OK : ESP_FAIL;
}

esp_err_t SDPublish_Stage(const char *pFinal, const char *pOld, bool *pStaged)
{
    *pStaged = false;
    struct stat Stat;
    if (stat(pFinal, &Stat) != 0)
        return errno == ENOENT ? ESP_OK : ESP_FAIL;
    if (!S_ISREG(Stat.st_mode)) return ESP_ERR_INVALID_STATE;
    if (rename(pFinal, pOld) != 0) return ESP_FAIL;
    *pStaged = true;
    return ESP_OK;
}
