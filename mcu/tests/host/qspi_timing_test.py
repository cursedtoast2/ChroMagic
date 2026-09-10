"""Check the production QSPI configuration against the installed ESP-IDF HAL.

ESP32 TRM, GP-SPI Timing: native pins at APB/2 require MISO_DELAY_MODE=0.
Compile the real HAL calculation/configuration statements, not a copy of their
formula. This checks register selection; it does not simulate board timing.
"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile


def function(source, name):
    start = source.index("void " + name + "(")
    body = source.index("{", start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    root = Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--idf", type=Path,
                        default=Path(os.environ.get("IDF_PATH", Path.home() / "esp-idf")))
    parser.add_argument("--main-source", type=Path, default=root / "main/main.c")
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    args = parser.parse_args()

    board = (root / "main/board.h").read_text()
    pins = dict(re.findall(r"#define PIN_NUM_QSPI_(\w+)\s+GPIO_NUM_(\d+)", board))
    assert pins == {"CS": "5", "CLK": "18", "MOSI": "23", "MISO": "19",
                    "WP": "22", "HD": "21"}, "Recheck timing for non-native pins"
    source = args.main_source.read_text()
    config = re.search(r"spi_device_interface_config_t devcfg\s*=\s*(\{.*?\n    \});",
                       source, re.S).group(1)
    hal = args.idf / "components/hal"
    calculation = function((hal / "spi_hal.c").read_text(), "spi_hal_cal_timing")
    setup = function((hal / "spi_hal_iram.c").read_text(), "spi_hal_setup_trans")
    start = setup.index("    int extra_dummy = 0;")
    end = setup.index("    spi_ll_set_mosi_bitlen(", start)
    setup = setup[start:end]
    prefix = r'''
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stddef.h>
#define HAL_LOGD(...) ((void)0)
#define GPIO_MATRIX_DELAY_NS 25
#define PIN_NUM_QSPI_CS 5
#define NUMTRANS 45
#define SPI_DEVICE_HALFDUPLEX 1
#define notify_lvgl_flush_ready NULL
typedef struct {
    int clock_speed_hz, input_delay_ns, mode, spics_io_num, queue_size, flags;
    int cs_ena_pretrans, cs_ena_posttrans, command_bits, address_bits, dummy_bits;
    void *pre_cb, *post_cb;
} spi_device_interface_config_t;
typedef struct { int dummy, delay_mode, delay_num; } registers_t;
static void spi_ll_set_dummy(registers_t *hw, int n) { hw->dummy = n; }
static void spi_ll_set_miso_delay(registers_t *hw, int mode, int n) {
    hw->delay_mode = mode; hw->delay_num = n;
}
'''
    harness = r'''
static registers_t configure(spi_device_interface_config_t config, bool read) {
    struct {
        int mode, no_compensate, half_duplex;
        struct { int timing_dummy, timing_miso_delay; } timing_conf;
    } device = {.mode=config.mode,
                .half_duplex=!!(config.flags & SPI_DEVICE_HALFDUPLEX)}, *dev=&device;
    struct { void *rcv_buffer; int dummy_bits; } transaction = {
        .rcv_buffer=read ? &device : NULL, .dummy_bits=config.dummy_bits
    }, *trans=&transaction;
    registers_t registers = {0}, *hw=&registers;
    spi_hal_cal_timing(80000000, config.clock_speed_hz, false, config.input_delay_ns,
                      &dev->timing_conf.timing_dummy, &dev->timing_conf.timing_miso_delay);
    HAL_SETUP
    return registers;
}
int main(void) {
    spi_device_interface_config_t config = MCU_CONFIG;
    assert(config.clock_speed_hz == 40000000 && config.mode == 0);
    assert(config.command_bits == 11 && config.address_bits == 32);
    assert(config.cs_ena_pretrans == 3 && config.cs_ena_posttrans == 3);
    registers_t read = configure(config, true), write = configure(config, false);
    printf("40 MHz native QSPI: MISO delay mode=%d cycles=%d, read dummy=%d write dummy=%d\n",
           read.delay_mode, read.delay_num, read.dummy, write.dummy);
    fflush(stdout);
    // APB/2 with native IO requires no additional MISO sampling delay.
    // Keep the FPGA's fixed three dummy clocks in both directions.
    if (read.delay_mode != 0 || read.delay_num != 0 || read.dummy != 3 || write.dummy != 3) {
        fputs("FAIL: QSPI receive timing does not meet ESP32 native-pin APB/2 requirements\n", stderr);
        return 1;
    }
    puts("PASS: production configuration selects native mode-0 receive timing without extra clocks");
}
'''
    harness = harness.replace("HAL_SETUP", setup).replace("MCU_CONFIG", config)
    with tempfile.TemporaryDirectory(prefix="chromagic-qspi-timing-") as temp:
        c_source = Path(temp) / "timing.c"
        executable = Path(temp) / "timing"
        c_source.write_text(prefix + calculation + harness)
        subprocess.run([args.cc, "-std=gnu11", "-Wall", "-Wextra", "-Werror",
                        str(c_source), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
