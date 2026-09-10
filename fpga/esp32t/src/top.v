// top.v

module top #(parameter ISSIMU=0)
(
    output              ADC_SEL,
    output              AUD_BCLK,
    output              AUD_DIN,
    output              AUD_MCLK,
    output              AUD_RESET,
    output              AUD_WCLK,

    input               BTN_A,
    input               BTN_B,
    input               BTN_DPAD_DOWN,
    input               BTN_DPAD_LEFT,
    input               BTN_DPAD_RIGHT,
    input               BTN_DPAD_UP,
    input               BTN_MENU,
    input               BTN_SEL,
    input               BTN_START,

    output  [15:0]      CART_A,
    output              CART_CLK,
    output              CART_CS,
    inout   [7:0]       CART_D,
    output              CART_RD,
    inout               CART_RST,
    output              CART_WR,
    output              CART_DATA_DIR_E,

    input               CART_DET,
    input               CART_AUDIN,

    input               CLK_FPGA,       // 33.55432MHz
    input               CLK_27MHz,
    input               CLK_24MHz,

    output reg          ESP32_EN,

    output              SDIO_LS,
    input               POWER_ON_FPGA,
    output              POWER_DOWN_IO,
    input               VBUS_DET,

    output reg          ESP32_IO0,

    output              I2S_BCLK,       // D16 IO33
    input               I2S_WS,         // D15 IO25 CC
    input               I2S_DIN,        // D14 IO26
    input               I2S_DOUT,       // D13 IO27
    input               ESP32_MCU_D12,  // D12 IO9
    output              ESP32_MCU_D11,  // D11 IO10 CC
    input               QSPI_CS,        // CS D10 IO5 CC
    input               QSPI_CLK,       // CLK D9 IO18 CC
    inout               QSPI_MOSI,      // D D8 IO23
    inout               QSPI_MISO,      // Q D7 IO19
    inout               QSPI_WP,        // WP D6 IO22
    inout               QSPI_HD,        // HD D5 IO21 CC
    output  reg         ESP32_MCU_D4,   // RXD
    input               ESP32_MCU_D3,   // TXD

    output              FPGA_LED_EN,
    output  reg         FPGA_LED_R,
    output  reg         FPGA_LED_G,
    output  reg         FPGA_LED_B,

    output  [2:0]       HDMI_D_P,
    output  [2:0]       HDMI_D_N,
    output              HDMI_CLK_P,
    output              HDMI_CLK_N,
    input               HDMI_SBU1_HPD,
    output              HDMI_SBU2_CEC,

    input               IR_RX,
    output              IR_LED,

    output              LCD_PWM,

    output [5:0]        LCD_DB,
    output              LCD_DOTCLK,
    output              LCD_ENABLE,
    output              LCD_HSYNC,
    output              LCD_RESET,
    output              LCD_SPI_CSX,
    output              LCD_SPI_SCLK,
    output              LCD_SPI_SDA,
    input               LCD_TE,
    output              LCD_VSYNC,

    inout               LINK_CLK,
    input               LINK_IN,
    output              LINK_OUT,
    output              LINK_SD,

    output              PS_CE_N,
    output              PS_CLK,
    inout   [7:0]       PS_DQ,
    inout               PS_DQS,

    inout               SCL,
    inout               SDA,

    input               USBC_FLIP,
    inout               usb_dxp_io,
    inout               usb_dxn_io,
    input               usb_rxdp_i,
    input               usb_rxdn_i,
    output              usb_pullup_en_o,
    inout               usb_term_dp_io,
    inout               usb_term_dn_io,

    input               VBAT_ADC_P,
    input               VBAT_ADC_N
);

    assign POWER_DOWN_IO = 1'bZ;
    assign SDIO_LS = 1'd1;

    wire    BIST_failed;
    wire    BIST_finished;

    assign FPGA_LED_EN = 1'd1;

    wire lock_o;

    wire fClk;
    wire pClk;
    wire hClk;
    wire gClk;
    wire xClk;

    Gowin_PLL u_Gowin_PLL(
        .reset(1'd0),//input reset
        .clkout0(fClk), //output clkout0 ~150MHz
        .clkout1(pClk), //output clkout1 ~33.554MHz
        .clkout2(hClk), //output clkout2 ~16.777MHz
        .clkout3(gClk), //output clkout3 ~8.388MHz
        .clkout4(xClk), //output clkout4 ~75MHz
//        .clkout5(hdmiclk), //output clkout4 ~75MHz
        .lock(lock_o), //output lock
        .clkin(CLK_FPGA) //input clkin
    );

    reg [13:0] voltageSim = 14'd1500;
    reg voltageSimDir = 1'b0;

    reg [22:0] secondCounter = 'd0;
    reg secondEna;
    reg halfSecondEna;
    reg [16:0] percentCounter = 'd0;
    reg percentEna;

    always@(posedge gClk) begin
        percentEna <= 1'b0;
        if (percentCounter == 83886) begin
            percentEna     <= 1'b1;
            percentCounter <= 17'd0;
        end else begin
            percentCounter <= percentCounter + 1'd1;
        end

        secondEna      <= 1'b0;
        halfSecondEna  <= 1'b0;
        if (secondCounter == 4194303) begin
            halfSecondEna  <= 1'b1;
        end
        if (secondCounter == 8388607) begin
            secondEna      <= 1'b1;
            halfSecondEna  <= 1'b1;
            secondCounter  <= 23'd0;
            percentCounter <= 17'd0;
        end else begin
            secondCounter <= secondCounter + 1'd1;
        end

        if (secondEna) begin
            if (voltageSimDir) begin
                voltageSim <= voltageSim + 50;
                if (voltageSim > 1800) begin
                  voltageSimDir <= 1'b0;
                end
            end else begin
                voltageSim <= voltageSim - 50;
                if (voltageSim < 950) begin
                  voltageSimDir <= 1'b1;
                end
            end
        end
    end

    wire low_battery;
    wire boot_rom_enabled;
    wire LED_Green;
    wire LED_Red;
    wire LED_Yellow;
    wire LED_White;
    wire [7:0]  pmic_sys_status;

    always@(posedge xClk)
    begin
        if (LED_White) begin
            FPGA_LED_R <= 1'd0;
            FPGA_LED_B <= 1'd0;
            FPGA_LED_G <= 1'd0;
        end else if (LED_Green) begin
            FPGA_LED_R <= 1'd1;
            FPGA_LED_B <= 1'd1;
            FPGA_LED_G <= 1'd0;
        end else if (LED_Yellow) begin
            FPGA_LED_R <= 1'd0;
            FPGA_LED_B <= 1'd1;
            FPGA_LED_G <= secondCounter[4];
        end else if (LED_Red) begin
            FPGA_LED_R <= 1'd0;
            FPGA_LED_B <= 1'd1;
            FPGA_LED_G <= 1'd1;
        end else begin
            FPGA_LED_R <= 1'd1;
            FPGA_LED_B <= 1'd1;
            FPGA_LED_G <= 1'd1;
        end
    end

    wire [15:0]       hWrBurstQ;
    wire [15:0]       hWrBurstQ2;
    wire              hValid;
    wire              hHsync;
    wire              hVsync;

    wire core_gb_lcd_clkena;
    wire [14:0] core_gb_lcd_data;
    wire [1:0] core_gb_lcd_mode;
    wire core_gb_lcd_on;
    wire core_gb_lcd_vsync;
    wire display_gb_lcd_clkena;
    wire [14:0] display_gb_lcd_data;
    wire [1:0] display_gb_lcd_mode;
    wire display_gb_lcd_on;
    wire display_gb_lcd_vsync;
    wire core_frame_valid_h;
    wire cart_maintenance_request_g;
    wire cart_ownership_ack_g;
    wire cart_maintenance_active_h;
    wire cart_maintenance_reset_h;
    wire cart_video_selected;
    wire virtual_attempt_reset_h;
    wire virtual_quiesce_h;
    wire virtual_quiesced_h;
    wire virtual_quiesced_g;
    wire [79:0] audio_boot_status = 80'd0;
    wire [79:0] audio_boot_codec = 80'd0;
    wire audio_boot_snapshot_toggle = 1'b0;
    wire audio_boot_snapshot_ready = 1'b0;
    wire LCD_INIT_DONE;

    (* ASYNC_REG = "TRUE" *) reg cart_video_selected_g_meta = 1'b0;
    (* ASYNC_REG = "TRUE" *) reg cart_video_selected_g_sync = 1'b0;
    always @(posedge gClk or negedge lock_o)
    begin
        if (!lock_o)
        begin
            cart_video_selected_g_meta <= 1'b0;
            cart_video_selected_g_sync <= 1'b0;
        end
        else
        begin
            cart_video_selected_g_meta <= cart_video_selected;
            cart_video_selected_g_sync <= cart_video_selected_g_meta;
        end
    end

    wire              hGBNewLine;
    wire [22:0]       hGBAddress;
    wire              hGBWrite;
    wire [15:0]       hGBData;
    wire              LCD_ENABLE_UVC;


    reg LCD_VSYNC_r1;
    always@(posedge gClk)
        LCD_VSYNC_r1 <= LCD_VSYNC;

    reg memrst = 1'd0;

    (* ASYNC_REG = "TRUE" *) reg [1:0] memrst_fclk_sync = 2'b11;
    always @(posedge fClk or posedge memrst)
    begin
        if (memrst)
            memrst_fclk_sync <= 2'b11;
        else
            memrst_fclk_sync <= {memrst_fclk_sync[0], 1'b0};
    end
    wire memrst_fclk = memrst_fclk_sync[1];

    (* ASYNC_REG = "TRUE" *) reg [1:0] memrst_hclk_sync = 2'b11;
    always @(posedge hClk or posedge memrst)
    begin
        if (memrst)
            memrst_hclk_sync <= 2'b11;
        else
            memrst_hclk_sync <= {memrst_hclk_sync[0], 1'b0};
    end
    wire memrst_hclk = memrst_hclk_sync[1];

    reg LCD_EN1;
    reg LCD_EN0;
    reg LCD_EN;
    wire qMenuInit;
    wire LCD_BACKLIGHT_INIT;
    always@(posedge gClk or posedge memrst) begin
        if(memrst) begin
            LCD_EN <= 1'd0;
            LCD_EN0 <= 1'd0;
            LCD_EN1 <= 1'd0;
        end else begin
            if(LCD_VSYNC&~LCD_VSYNC_r1) begin
                LCD_EN0 <= LCD_INIT_DONE & LCD_BACKLIGHT_INIT;
                LCD_EN1 <= LCD_EN0;
                LCD_EN  <= LCD_EN1;
            end
            // synthesis translate_off
            LCD_EN  <= 1'd1;
            // synthesis translate_on
        end
    end

    wire [31:0] debug_system;
    wire [15:0] system_control;
    wire [17:0] LCD_DB_UVC;
    wire menuDisabled;
    wire slideOutActive;
    wire hDrawOSD;

    maintenance_video_mux u_maintenance_video_mux (
        .hclk(hClk),
        .reset_h(~lock_o),
        .maintenance_active_h(cart_maintenance_active_h |
                              virtual_attempt_reset_h),
        .core_lcd_clkena(core_gb_lcd_clkena),
        .core_lcd_mode(core_gb_lcd_mode),
        .core_lcd_on(core_gb_lcd_on),
        .core_lcd_vsync(core_gb_lcd_vsync),
        .core_lcd_data(core_gb_lcd_data),
        .core_display_ready(~boot_rom_enabled),
        .lcd_clkena(display_gb_lcd_clkena),
        .lcd_mode(display_gb_lcd_mode),
        .lcd_on(display_gb_lcd_on),
        .lcd_vsync(display_gb_lcd_vsync),
        .lcd_data(display_gb_lcd_data),
        .maintenance_selected(cart_video_selected),
        .core_frame_valid(core_frame_valid_h)
    );

    vid_system_top #(ISSIMU)
    u_vid_system_top(
        .gClk(gClk),
        .hClk(hClk),
        .pClk(pClk),
        .reset(memrst),

        .BTN_MENU(menuDisabled),
        .slideOutActive(slideOutActive),

        .LCD_DB(LCD_DB),
        .LCD_ENABLE_UVC(LCD_ENABLE_UVC),
        .LCD_DB_UVC(LCD_DB_UVC),
        .LCD_DOTCLK(LCD_DOTCLK),
        .LCD_ENABLE(LCD_ENABLE),
        .LCD_HSYNC(LCD_HSYNC),
        .LCD_EN(LCD_EN),
        .LCD_RESET(LCD_RESET),
        .LCD_SPI_CSX(LCD_SPI_CSX),
        .LCD_SPI_SCLK(LCD_SPI_SCLK),
        .LCD_SPI_SDA(LCD_SPI_SDA),
        .LCD_TE(LCD_TE),
        .LCD_VSYNC(LCD_VSYNC),
        .LCD_GENLOCK(),

        .frameBlendEnable(system_control[1]),
        .colorCorrectionEnableLCD(system_control[2]),
        .colorCorrectionEnableUVC(system_control[3]),
        .voltageLow(low_battery),
        .lowBattDispMode(system_control[14:13]),
        .showTimer(1'b0), //system_control[8]),
        .runTimer(system_control[9]),
        .resetTimer(system_control[10]),
        .gSecondEna(secondEna),
        .gPercentEna(percentEna),
        .debug_system(debug_system),
        .debug_system_on(1'b0),

        .hDrawOSD(hDrawOSD),
        .hGBNewLine(hGBNewLine),
        .hGBAddress(hGBAddress),
        .hGBWrite(hGBWrite),
        .hGBData(hGBData),

        .hValid(hValid),
        .hHsync(hHsync),
        .hVsync(hVsync),
        .hWrBurstQ(hWrBurstQ),
        .hWrBurstQ2(hWrBurstQ2),

        .LCD_INIT_DONE(LCD_INIT_DONE),
        .gb_lcd_clkena(display_gb_lcd_clkena),
        .gb_lcd_mode(display_gb_lcd_mode),
        .gb_lcd_on(display_gb_lcd_on),
        .gb_lcd_vsync(display_gb_lcd_vsync),
        .gb_lcd_data(display_gb_lcd_data)
    );

    wire [15:0] left, right;
    wire [7:0]  volume;
    wire        hHeadphones;

    aud_system_top u_aud_system_top(
        .gClk(gClk),
        .hClk(hClk),
        .reset_n(lock_o),
        .left(left),
        .right(right),
        .AUD_BCLK(AUD_BCLK),
        .AUD_DIN(AUD_DIN),
        .AUD_DOUT(),
        .AUD_MCLK(AUD_MCLK),
        .AUD_RESET(AUD_RESET),
        .AUD_WCLK(AUD_WCLK),

        .software_mute(system_control[0]),
        .pmic_sys_status(pmic_sys_status),
        .volume(volume),
        .hHeadphones(hHeadphones),
        .SCL(SCL),
        .SDA(SDA)
    );

    wire virtual_enable_g;
    wire virtual_start_pending_g;
    wire virtual_prepared_g;
    reg [17:0] CART_DET_sr;
    always@(posedge xClk)
        CART_DET_sr <= {CART_DET_sr[16:0], CART_DET};

    wire virtual_session_g = virtual_enable_g | virtual_start_pending_g |
                             virtual_prepared_g;
    (* ASYNC_REG = "TRUE" *) reg [1:0] virtual_session_x = 2'b00;
    always @(posedge xClk or negedge lock_o)
        if (!lock_o)
            virtual_session_x <= 2'b00;
        else
            virtual_session_x <= {virtual_session_x[0], virtual_session_g};

    // CART_DET = 0 (no cart inserted)
    always@(posedge xClk or negedge lock_o)
        if(~lock_o)
            memrst <= 1'd1;
        else
            memrst <= !virtual_session_x[1] &&
                (CART_DET_sr[17:2] == 16'h7FFF || CART_DET_sr[17:2] == 16'h8000);

    wire        cart_block_write;
    wire [10:0] cart_block_write_address;
    wire [7:0]  cart_block_write_data;
    wire [1:0]  cart_block_ready;
    wire [15:0] cart_block_sequence;
    wire [63:0] cart_block_crc32;
    wire        cart_pc_usb_mode;
    wire [10:0] cart_usb_ram_address;
    wire [7:0]  cart_usb_ram_data;
    wire [7:0]  cart_usb_tx_data;
    wire        cart_usb_tx_valid;
    wire        cart_usb_tx_ready;
    wire        cart_usb_tx_busy;
    wire        cart_usb_event_complete;
    wire        cart_stream_event_for_monitor;
    wire [10:0] qspi_cart_read_address;
    wire [7:0]  qspi_cart_read_data;
    wire [10:0] qspi_cart_write_address;
    wire [7:0]  qspi_cart_write_data;
    wire        qspi_cart_write_enable;
    wire [7:0]  qspi_virtual_read_data;
    wire        virtual_xrequest;
    wire        virtual_xread;
    wire [22:0] virtual_xaddress;
    wire [15:0] virtual_xwritedata;
    wire [10:0] virtual_xlength;
    wire        virtual_xwrite_next;
    wire        virtual_xdone;
    wire        virtual_xread_valid;
    wire [15:0] virtual_xreaddata;
    wire        virtual_snapshot_ready_x;
    wire [15:0] virtual_snapshot_ready_sequence_x;
    wire        qspi_write_busy_x;
    wire [7:0]  qspi_write_completion_sequence_x;

    mem_system_top #(ISSIMU)
    u_mem_system_top
    (
        .xClk(xClk),
        .fClk(fClk),
        .hClk(hClk),
        .reset(memrst),
        .resetF(memrst_fclk),

        .QSPI_CLK(QSPI_CLK),
        .QSPI_MOSI(QSPI_MOSI),
        .QSPI_MISO(QSPI_MISO),
        .QSPI_CS(QSPI_CS),
        .QSPI_WP(QSPI_WP),
        .QSPI_HD(QSPI_HD),

        .cartBlockReady(cart_block_ready),
        .cartBlockSequence(cart_block_sequence),
        .cartBlockCRC32(cart_block_crc32),
        .qCartReadData(qspi_cart_read_data),
        .qCartReadAddress(qspi_cart_read_address),
        .qCartWriteAddress(qspi_cart_write_address),
        .qCartWriteData(qspi_cart_write_data),
        .qCartWriteEnable(qspi_cart_write_enable),
        .virtualBlockReady(virtual_snapshot_ready_x),
        .virtualBlockSequence(virtual_snapshot_ready_sequence_x),
        .qVirtualReadData(qspi_virtual_read_data),

        .PS_CE_N(PS_CE_N),
        .PS_CLK(PS_CLK),
        .PS_DQ(PS_DQ),
        .PS_DQS(PS_DQS),

        .BIST_failed(BIST_failed),
        .BIST_finished(BIST_finished),
        .qMenuInit(qMenuInit),
        .hGBNewLine(hGBNewLine),
        .hGBAddress(hGBAddress),
        .hGBWrite(hGBWrite),
        .hGBData(hGBData),

        // mm_burst_read_to_stream
        .hValid(display_gb_lcd_clkena),
        .hHsync(display_gb_lcd_mode[1]),
        .hVsync(display_gb_lcd_vsync),
        .hWrBurstQ(hWrBurstQ),
        .hWrBurstQ2(hWrBurstQ2),

        .xVirtualRequest(virtual_xrequest),
        .xVirtualRead(virtual_xread),
        .xVirtualAddress(virtual_xaddress),
        .xVirtualWriteData(virtual_xwritedata),
        .xVirtualLength(virtual_xlength),
        .xVirtualWriteNext(virtual_xwrite_next),
        .xVirtualDone(virtual_xdone),
        .xVirtualReadValid(virtual_xread_valid),
        .xVirtualReadData(virtual_xreaddata),
        .xQspiWriteBusy(qspi_write_busy_x),
        .xQspiWriteCompletionSequence(
            qspi_write_completion_sequence_x)
    );

    wire IR_RX_FILTER;

    wire lcd_on_int;
    wire lcd_off_overwrite;

    wire [8:0] MCU_buttons;

    wire BTN_MENU_ored = BTN_MENU & ~MCU_buttons[8]; // BTN_MENU is low active


    wire BTN_A_filtered;
    wire BTN_B_filtered;
    wire BTN_DPAD_DOWN_filtered;
    wire BTN_DPAD_LEFT_filtered;
    wire BTN_DPAD_RIGHT_filtered;
    wire BTN_DPAD_UP_filtered;
    wire BTN_SEL_filtered;
    wire BTN_START_filtered;

    button_debouncer debouncer_A         (gClk, BTN_A         , BTN_A_filtered         );
    button_debouncer debouncer_B         (gClk, BTN_B         , BTN_B_filtered         );
    button_debouncer debouncer_DPAD_DOWN (gClk, BTN_DPAD_DOWN , BTN_DPAD_DOWN_filtered );
    button_debouncer debouncer_DPAD_LEFT (gClk, BTN_DPAD_LEFT , BTN_DPAD_LEFT_filtered );
    button_debouncer debouncer_DPAD_RIGHT(gClk, BTN_DPAD_RIGHT, BTN_DPAD_RIGHT_filtered);
    button_debouncer debouncer_DPAD_UP   (gClk, BTN_DPAD_UP   , BTN_DPAD_UP_filtered   );
    button_debouncer debouncer_SEL       (gClk, BTN_SEL       , BTN_SEL_filtered       );
    button_debouncer debouncer_START     (gClk, BTN_START     , BTN_START_filtered     );

    wire [63:0] paletteBGIn;
    wire [63:0] paletteOBJ0In;
    wire [63:0] paletteOBJ1In;
    wire gbc_mode;
    wire [63:0] gpd;

    wire [15:0] core_cart_address;
    wire        core_cart_clock;
    wire        core_cart_cs_n;
    wire        core_cart_read_n;
    wire        core_cart_write_n;
    wire [7:0]  core_cart_data_out;
    wire        core_cart_data_oe;

    wire        cart_request_valid;
    wire        cart_request_ready;
    wire [2:0]  cart_request_operation;
    wire [7:0]  cart_request_tag;
    wire [15:0] cart_request_address;
    wire [7:0]  cart_request_value;
    wire [15:0] cart_request_aux_address;
    wire [7:0]  cart_request_aux_value;
    wire        cart_response_valid;
    wire        cart_response_ready;
    wire [2:0]  cart_response_operation;
    wire [7:0]  cart_response_tag;
    wire [3:0]  cart_response_status;
    wire [2:0]  cart_response_count;
    wire [31:0] cart_response_data;
    wire        maintenance_request_ready;
    wire        maintenance_response_valid;
    wire [2:0]  maintenance_response_operation;
    wire [7:0]  maintenance_response_tag;
    wire [3:0]  maintenance_response_status;
    wire [2:0]  maintenance_response_count;
    wire [31:0] maintenance_response_data;
    wire        maintenance_response_ready;

    localparam [15:0] VIRTUAL_CART_MAGIC = 16'h5643;
    localparam [7:0]  VIRTUAL_CART_STOP = 8'd0;
    localparam [7:0]  VIRTUAL_CART_START = 8'd1;
    localparam [7:0]  VIRTUAL_CART_STATUS = 8'd2;
    localparam [7:0]  VIRTUAL_CART_PREPARE = 8'd3;
    localparam [7:0]  VIRTUAL_CART_SAVE_BLOCK = 8'd4;
    localparam [7:0]  VIRTUAL_CART_RTC_RESTORE_LOW = 8'd5;
    localparam [7:0]  VIRTUAL_CART_RTC_RESTORE_HIGH = 8'd6;
    localparam [7:0]  VIRTUAL_CART_RTC_SNAPSHOT = 8'd7;
    localparam [7:0]  VIRTUAL_CART_QUIESCE = 8'd8;
    localparam [7:0]  VIRTUAL_CART_RESUME = 8'd9;
    wire virtual_request_selected = cart_request_operation == 3'h7 &&
                                    cart_request_address == VIRTUAL_CART_MAGIC;
    reg virtual_response_valid;
    reg [2:0] virtual_response_operation;
    reg [7:0] virtual_response_tag;
    reg [3:0] virtual_response_status;
    reg [2:0] virtual_response_count;
    reg [31:0] virtual_response_data;
    wire virtual_rtc_busy_g;
    wire virtual_rtc_done_g;
    wire virtual_request_ready = !virtual_response_valid &&
                                 !maintenance_response_valid &&
                                 !virtual_rtc_busy_g &&
                                 !virtual_rtc_done_g;
    wire virtual_request_accepted = cart_request_valid &&
                                    virtual_request_selected &&
                                    virtual_request_ready;

    wire virtual_enable_h;
    wire virtual_core_reset_h;
    wire [5:0] virtual_lifecycle_g;
    reg [2:0] virtual_mapper_select_g;
    reg virtual_mbc1m_g;
    reg virtual_mbc30_g;
    reg [7:0] virtual_cart_type_g;
    reg virtual_has_ram_g;
    reg [3:0] virtual_ram_mask_g;
    reg [8:0] virtual_rom_mask_g;
    reg virtual_rtc_timestamp_toggle_g;
    reg virtual_snapshot_request_toggle_g;
    reg [6:0] virtual_snapshot_block_g;
    reg [15:0] virtual_snapshot_sequence_g;
    wire [28:0] virtual_rtc_state_h;
    wire [28:0] virtual_rtc_snapshot_g;
    wire virtual_rtc_restore_write_h;
    wire [2:0] virtual_rtc_restore_address_h;
    wire [15:0] virtual_rtc_restore_data_h;

    reg [2:0] virtual_mapper_select_h_meta;
    reg [2:0] virtual_mapper_select_h;
    reg virtual_mbc1m_h_meta;
    reg virtual_mbc1m_h;
    reg virtual_mbc30_h_meta;
    reg virtual_mbc30_h;
    reg [7:0] virtual_cart_type_h_meta;
    reg [7:0] virtual_cart_type_h;
    reg virtual_has_ram_h_meta;
    reg virtual_has_ram_h;
    reg [3:0] virtual_ram_mask_h_meta;
    reg [3:0] virtual_ram_mask_h;
    reg [8:0] virtual_rom_mask_h_meta;
    reg [8:0] virtual_rom_mask_h;
    reg virtual_rtc_timestamp_toggle_h_meta;
    reg virtual_rtc_timestamp_toggle_h;
    wire virtual_initialized_h;
    wire virtual_save_dirty_h;
    reg virtual_initialized_g_meta;
    reg virtual_initialized_g;
    reg virtual_save_dirty_g_meta;
    reg virtual_save_dirty_g;
    wire virtual_stop_request_g = virtual_request_accepted &&
        cart_request_value[6:0] == VIRTUAL_CART_STOP;
    wire virtual_prepare_request_g = virtual_request_accepted &&
        cart_request_value[6:0] == VIRTUAL_CART_PREPARE &&
        !cart_maintenance_request_g && !virtual_start_pending_g &&
        !virtual_prepared_g;
    wire virtual_start_request_g = virtual_request_accepted &&
        cart_request_value[6:0] == VIRTUAL_CART_START &&
        !cart_maintenance_request_g && !virtual_start_pending_g &&
        virtual_prepared_g;

    wire virtual_pause_allowed_g = virtual_enable_g &&
        !cart_maintenance_request_g && !virtual_start_pending_g && !virtual_prepared_g;
    wire virtual_quiesce_request_g = virtual_request_accepted &&
        cart_request_value[6:0] == VIRTUAL_CART_QUIESCE && virtual_pause_allowed_g;
    wire virtual_resume_request_g = virtual_request_accepted &&
        cart_request_value[6:0] == VIRTUAL_CART_RESUME && virtual_pause_allowed_g;

    virtual_cart_session_cdc u_virtual_cart_session_cdc (
        .gclk(gClk),
        .hclk(hClk),
        .reset_g(~lock_o),
        .reset_h(~lock_o),
        .prepare_g(virtual_prepare_request_g),
        .start_g(virtual_start_request_g),
        .stop_g(virtual_stop_request_g),
        .quiesce_g(virtual_quiesce_request_g),
        .resume_g(virtual_resume_request_g),
        .core_quiesced_h(virtual_quiesced_h),
        .quiesce_h(virtual_quiesce_h),
        .quiesced_g(virtual_quiesced_g),
        .core_reset_h(virtual_core_reset_h),
        .boot_rom_enabled_h(boot_rom_enabled),
        .core_frame_valid_h(core_frame_valid_h),
        .enable_g(virtual_enable_g),
        .enable_h(virtual_enable_h),
        .attempt_reset_h(virtual_attempt_reset_h),
        .start_pending_g(virtual_start_pending_g),
        .prepared_g(virtual_prepared_g),
        .lifecycle_g(virtual_lifecycle_g)
    );

    function automatic CartTypeHasRam;
        input [7:0] cart_type;
        begin
            case (cart_type)
                8'h02, 8'h03, 8'h05, 8'h06, 8'h08, 8'h09,
                8'h10, 8'h12, 8'h13,
                8'h1a, 8'h1b, 8'h1d, 8'h1e, 8'hff:
                    CartTypeHasRam = 1'b1;
                default:
                    CartTypeHasRam = 1'b0;
            endcase
        end
    endfunction

    wire virtual_rtc_restore_allowed = virtual_prepared_g;
    wire virtual_rtc_snapshot_allowed = virtual_enable_g;
    wire virtual_rtc_restore_low_request = virtual_request_accepted &&
        cart_request_value[6:0] == VIRTUAL_CART_RTC_RESTORE_LOW &&
        virtual_rtc_restore_allowed;
    wire virtual_rtc_restore_high_request = virtual_request_accepted &&
        cart_request_value[6:0] == VIRTUAL_CART_RTC_RESTORE_HIGH &&
        virtual_rtc_restore_allowed;
    wire virtual_rtc_snapshot_request = virtual_request_accepted &&
        cart_request_value[6:0] == VIRTUAL_CART_RTC_SNAPSHOT &&
        virtual_rtc_snapshot_allowed;
    wire virtual_rtc_request_g = virtual_rtc_restore_low_request ||
        virtual_rtc_restore_high_request || virtual_rtc_snapshot_request;
    wire [1:0] virtual_rtc_operation_g = virtual_rtc_snapshot_request
        ? 2'd2 : virtual_rtc_restore_high_request ? 2'd1 : 2'd0;

    virtual_cart_rtc_cdc u_virtual_cart_rtc_cdc (
        .gclk(gClk),
        .hclk(hClk),
        .reset_g(~lock_o),
        .reset_h(~lock_o),
        .request_g(virtual_rtc_request_g),
        .operation_g(virtual_rtc_operation_g),
        .write_data_g(virtual_response_data[15:0]),
        .busy_g(virtual_rtc_busy_g),
        .done_g(virtual_rtc_done_g),
        .snapshot_g(virtual_rtc_snapshot_g),
        .rtc_state_h(virtual_rtc_state_h),
        .bk_rtc_wr_h(virtual_rtc_restore_write_h),
        .bk_addr_h(virtual_rtc_restore_address_h),
        .bk_data_h(virtual_rtc_restore_data_h));

    wire [31:0] virtual_status_data_g = {
        8'd0, virtual_cart_type_g,
        1'b1, 5'd0, virtual_quiesced_g,
        virtual_lifecycle_g[5:0], virtual_save_dirty_g,
        virtual_initialized_g, virtual_enable_g};

    assign cart_request_ready = virtual_request_selected
        ? virtual_request_ready : maintenance_request_ready;
    assign cart_response_valid = virtual_response_valid |
                                 maintenance_response_valid;
    assign cart_response_operation = virtual_response_valid
        ? virtual_response_operation : maintenance_response_operation;
    assign cart_response_tag = virtual_response_valid
        ? virtual_response_tag : maintenance_response_tag;
    assign cart_response_status = virtual_response_valid
        ? virtual_response_status : maintenance_response_status;
    assign cart_response_count = virtual_response_valid
        ? virtual_response_count : maintenance_response_count;
    assign cart_response_data = virtual_response_valid
        ? virtual_response_data : maintenance_response_data;
    assign maintenance_response_ready = cart_response_ready &&
                                        !virtual_response_valid;
    always @(posedge gClk or negedge lock_o) begin
        if (!lock_o) begin
            virtual_response_valid <= 1'b0;
            virtual_response_operation <= 3'd0;
            virtual_response_tag <= 8'd0;
            virtual_response_status <= 4'd0;
            virtual_response_count <= 3'd0;
            virtual_response_data <= 32'd0;
            virtual_mapper_select_g <= 3'd0;
            virtual_mbc1m_g <= 1'b0;
            virtual_mbc30_g <= 1'b0;
            virtual_cart_type_g <= 8'd0;
            virtual_has_ram_g <= 1'b0;
            virtual_ram_mask_g <= 4'd0;
            virtual_rom_mask_g <= 9'd0;
            virtual_rtc_timestamp_toggle_g <= 1'b0;
            virtual_snapshot_request_toggle_g <= 1'b0;
            virtual_snapshot_block_g <= 7'd0;
            virtual_snapshot_sequence_g <= 16'd0;
        end else begin
            if (virtual_response_valid && cart_response_ready)
                virtual_response_valid <= 1'b0;

            if (virtual_rtc_done_g) begin
                virtual_response_valid <= 1'b1;
                virtual_response_status <= 4'd0;
                virtual_response_count <= 3'd4;
                virtual_response_data <= {3'd0, virtual_rtc_snapshot_g};
            end

            if (virtual_request_accepted) begin
                virtual_response_valid <= 1'b1;
                virtual_response_operation <= cart_request_operation;
                virtual_response_tag <= cart_request_tag;
                virtual_response_status <= 4'd0;
                virtual_response_count <= 3'd4;
                virtual_response_data <= virtual_status_data_g;
                case (cart_request_value[6:0])
                    VIRTUAL_CART_STOP: ;
                    VIRTUAL_CART_PREPARE: begin
                        if (cart_maintenance_request_g ||
                            virtual_start_pending_g ||
                            virtual_prepared_g) begin
                            virtual_response_status <= 4'h3;
                        end else begin
                            virtual_mapper_select_g <=
                                cart_request_aux_address[2:0];
                            virtual_cart_type_g <=
                                cart_request_aux_address[10:3];
                            virtual_rom_mask_g <= {
                                cart_request_aux_value[3:0],
                                cart_request_aux_address[15:11]};
                            virtual_ram_mask_g <=
                                cart_request_aux_value[7:4];
                            virtual_has_ram_g <= CartTypeHasRam(
                                cart_request_aux_address[10:3]);
                            virtual_mbc1m_g <= cart_request_value[7];
                            virtual_mbc30_g <=
                                cart_request_aux_address[2:0] == 3'd3 &&
                                (cart_request_aux_value[2] ||
                                 cart_request_aux_value[7:4] == 4'd7);
                        end
                    end
                    VIRTUAL_CART_START: begin
                        if (cart_maintenance_request_g ||
                            virtual_start_pending_g ||
                            !virtual_prepared_g) begin
                            virtual_response_status <= 4'h3;
                        end
                    end
                    VIRTUAL_CART_STATUS: ;
                    VIRTUAL_CART_QUIESCE, VIRTUAL_CART_RESUME: begin
                        if (!virtual_pause_allowed_g)
                            virtual_response_status <= 4'h3;
                    end
                    VIRTUAL_CART_SAVE_BLOCK: begin
                        if (!virtual_enable_g ||
                            cart_request_aux_value[7] != 0) begin
                            virtual_response_status <= 4'h3;
                        end else begin
                            virtual_snapshot_block_g <=
                                cart_request_aux_value[6:0];
                            virtual_snapshot_sequence_g <=
                                cart_request_aux_address;
                            virtual_snapshot_request_toggle_g <=
                                !virtual_snapshot_request_toggle_g;
                        end
                    end
                    VIRTUAL_CART_RTC_RESTORE_LOW,
                    VIRTUAL_CART_RTC_RESTORE_HIGH,
                    VIRTUAL_CART_RTC_SNAPSHOT: begin
                        if (!virtual_rtc_request_g) begin
                            virtual_response_status <= 4'h3;
                        end else begin
                            virtual_response_data <=
                                {16'd0, cart_request_aux_address};
                            if (cart_request_value[6:0] ==
                                VIRTUAL_CART_RTC_RESTORE_LOW) begin
                                virtual_rtc_timestamp_toggle_g <=
                                    !virtual_rtc_timestamp_toggle_g;
                            end
                            virtual_response_valid <= 1'b0;
                        end
                    end
                    default: virtual_response_status <= 4'h1;
                endcase
            end
        end
    end

    always @(posedge hClk or negedge lock_o) begin
        if (!lock_o) begin
            virtual_mapper_select_h_meta <= 3'd0;
            virtual_mapper_select_h <= 3'd0;
            virtual_mbc1m_h_meta <= 1'b0;
            virtual_mbc1m_h <= 1'b0;
            virtual_mbc30_h_meta <= 1'b0;
            virtual_mbc30_h <= 1'b0;
            virtual_cart_type_h_meta <= 8'd0;
            virtual_cart_type_h <= 8'd0;
            virtual_has_ram_h_meta <= 1'b0;
            virtual_has_ram_h <= 1'b0;
            virtual_ram_mask_h_meta <= 4'd0;
            virtual_ram_mask_h <= 4'd0;
            virtual_rom_mask_h_meta <= 9'd0;
            virtual_rom_mask_h <= 9'd0;
            virtual_rtc_timestamp_toggle_h_meta <= 1'b0;
            virtual_rtc_timestamp_toggle_h <= 1'b0;
        end else begin
            virtual_mapper_select_h_meta <= virtual_mapper_select_g;
            virtual_mapper_select_h <= virtual_mapper_select_h_meta;
            virtual_mbc1m_h_meta <= virtual_mbc1m_g;
            virtual_mbc1m_h <= virtual_mbc1m_h_meta;
            virtual_mbc30_h_meta <= virtual_mbc30_g;
            virtual_mbc30_h <= virtual_mbc30_h_meta;
            virtual_cart_type_h_meta <= virtual_cart_type_g;
            virtual_cart_type_h <= virtual_cart_type_h_meta;
            virtual_has_ram_h_meta <= virtual_has_ram_g;
            virtual_has_ram_h <= virtual_has_ram_h_meta;
            virtual_ram_mask_h_meta <= virtual_ram_mask_g;
            virtual_ram_mask_h <= virtual_ram_mask_h_meta;
            virtual_rom_mask_h_meta <= virtual_rom_mask_g;
            virtual_rom_mask_h <= virtual_rom_mask_h_meta;
            virtual_rtc_timestamp_toggle_h_meta <=
                virtual_rtc_timestamp_toggle_g;
            virtual_rtc_timestamp_toggle_h <=
                virtual_rtc_timestamp_toggle_h_meta;
        end
    end

    always @(posedge gClk or negedge lock_o) begin
        if (!lock_o) begin
            virtual_initialized_g_meta <= 1'b0;
            virtual_initialized_g <= 1'b0;
            virtual_save_dirty_g_meta <= 1'b0;
            virtual_save_dirty_g <= 1'b0;
        end else begin
            virtual_initialized_g_meta <= virtual_initialized_h;
            virtual_initialized_g <= virtual_initialized_g_meta;
            virtual_save_dirty_g_meta <= virtual_save_dirty_h;
            virtual_save_dirty_g <= virtual_save_dirty_g_meta;
        end
    end
    wire        cart_stream_event_valid;
    wire        cart_stream_event_ready;
    wire [7:0]  cart_stream_event_sequence;
    wire [31:0] cart_stream_event_crc32;
    wire        cart_stream_ack_valid;
    wire [7:0]  cart_stream_ack_sequence;

    wire [15:0] maintenance_cart_address;
    wire        maintenance_cart_clock;
    wire        maintenance_cart_cs_n;
    wire        maintenance_cart_read_n;
    wire        maintenance_cart_write_n;
    wire [7:0]  maintenance_cart_data_out;
    wire        maintenance_cart_data_oe;
    wire [7:0]  physical_cart_data_out;
    wire        physical_cart_data_oe;
    wire [7:0]  physical_cart_data_in = CART_D;

    assign CART_D = physical_cart_data_oe ? physical_cart_data_out : 8'hzz;
    assign CART_DATA_DIR_E = ~physical_cart_data_oe;

    cart_bus_owner_mux u_cart_bus_owner_mux(
        .maintenance_active(cart_ownership_ack_g),
        .core_address(virtual_enable_h ? 16'hffff : core_cart_address),
        .core_clock(virtual_enable_h ? 1'b0 : core_cart_clock),
        .core_cs_n(virtual_enable_h ? 1'b1 : core_cart_cs_n),
        .core_read_n(virtual_enable_h ? 1'b1 : core_cart_read_n),
        .core_write_n(virtual_enable_h ? 1'b1 : core_cart_write_n),
        .core_data_out(core_cart_data_out),
        .core_data_oe(virtual_enable_h ? 1'b0 : core_cart_data_oe),
        .maintenance_address(maintenance_cart_address),
        .maintenance_clock(maintenance_cart_clock),
        .maintenance_cs_n(maintenance_cart_cs_n),
        .maintenance_read_n(maintenance_cart_read_n),
        .maintenance_write_n(maintenance_cart_write_n),
        .maintenance_data_out(maintenance_cart_data_out),
        .maintenance_data_oe(maintenance_cart_data_oe),
        .physical_address(CART_A),
        .physical_clock(CART_CLK),
        .physical_cs_n(CART_CS),
        .physical_read_n(CART_RD),
        .physical_write_n(CART_WR),
        .physical_data_out(physical_cart_data_out),
        .physical_data_oe(physical_cart_data_oe)
    );

    cart_maintenance_engine u_cart_maintenance_engine(
        .clk(gClk),
        .reset(~lock_o),
        .cart_present(CART_DET_sr[6:3] == 4'b1111),
        .request_valid(cart_request_valid && !virtual_request_selected),
        .request_ready(maintenance_request_ready),
        .request_operation(cart_request_operation),
        .request_tag(cart_request_tag),
        .request_address(cart_request_address),
        .request_value(cart_request_value),
        .request_aux_address(cart_request_aux_address),
        .request_aux_value(cart_request_aux_value),
        .response_valid(maintenance_response_valid),
        .response_ready(maintenance_response_ready),
        .response_operation(maintenance_response_operation),
        .response_tag(maintenance_response_tag),
        .response_status(maintenance_response_status),
        .response_count(maintenance_response_count),
        .response_data(maintenance_response_data),
        .block_write(cart_block_write),
        .block_write_address(cart_block_write_address),
        .block_write_data(cart_block_write_data),
        .block_read_data(cart_usb_ram_data),
        .block_ready(cart_block_ready),
        .block_sequence(cart_block_sequence),
        .block_crc32(cart_block_crc32),
        .pc_usb_mode(cart_pc_usb_mode),
        .stream_event_valid(cart_stream_event_valid),
        .stream_event_ready(cart_stream_event_ready),
        .stream_event_sequence(cart_stream_event_sequence),
        .stream_event_crc32(cart_stream_event_crc32),
        .stream_ack_valid(cart_stream_ack_valid),
        .stream_ack_sequence(cart_stream_ack_sequence),
        .active(cart_maintenance_request_g),
        .ownership_ack(cart_ownership_ack_g),
        .cart_address(maintenance_cart_address),
        .cart_clock(maintenance_cart_clock),
        .cart_cs_n(maintenance_cart_cs_n),
        .cart_read_n(maintenance_cart_read_n),
        .cart_write_n(maintenance_cart_write_n),
        .cart_data_out(maintenance_cart_data_out),
        .cart_data_oe(maintenance_cart_data_oe),
        .cart_data_in(physical_cart_data_in)
    );

    cart_usb_streamer u_cart_usb_streamer (
        .clk(gClk),
        .reset(~lock_o),
        .enabled(cart_pc_usb_mode),
        .event_valid(cart_stream_event_valid),
        .event_sequence(cart_stream_event_sequence),
        .block_ready(cart_block_ready),
        .ram_address(cart_usb_ram_address),
        .ram_data(cart_usb_ram_data),
        .tx_valid(cart_usb_tx_valid),
        .tx_ready(cart_usb_tx_ready),
        .tx_data(cart_usb_tx_data),
        .busy(cart_usb_tx_busy),
        .event_complete(cart_usb_event_complete)
    );

    assign cart_stream_event_for_monitor =
        cart_stream_event_valid &&
        (!cart_pc_usb_mode || cart_usb_event_complete);

    cart_maintenance_cdc u_cart_maintenance_cdc (
        .gclk(gClk),
        .hclk(hClk),
        .reset_g(~lock_o),
        .reset_h(~lock_o),
        .ownership_request_g(cart_maintenance_request_g),
        .ownership_ack_g(cart_ownership_ack_g),
        .maintenance_active_h(cart_maintenance_active_h),
        .maintenance_reset_h(cart_maintenance_reset_h)
    );

    gowin_dpb_cache_byte u_cart_block_ram (
        .clock_a(gClk),
        .address_a(cart_usb_tx_busy ? cart_usb_ram_address
                                    : cart_block_write_address),
        .data_a(cart_block_write_data),
        .wren_a(cart_block_write),
        .q_a(cart_usb_ram_data),
        .clock_b(QSPI_CLK),
        .address_b(qspi_cart_write_enable ? qspi_cart_write_address
                                          : qspi_cart_read_address),
        .data_b(qspi_cart_write_data),
        .wren_b(qspi_cart_write_enable),
        .q_b(qspi_cart_read_data)
    );

    emu_system_top u_emu_system_top(
        .hclk(hClk),
        .pclk(pClk),
        .xclk(xClk),
        .reset_n(~memrst_hclk),//lock_o),
        .xreset(memrst),
        .POWER_GOOD(~POWER_ON_FPGA),
        .maintenance_reset_h(cart_maintenance_reset_h),
        .virtual_attempt_reset_h(virtual_attempt_reset_h),
        .virtual_quiesce_h(virtual_quiesce_h),
        .virtual_quiesced_h(virtual_quiesced_h),
        .virtual_core_reset_h(virtual_core_reset_h),

        .customPaletteEna(paletteBGIn[63]),
        .paletteOff(system_control[12]),
        .paletteBGIn(paletteBGIn),
        .paletteOBJ0In(paletteOBJ0In),
        .paletteOBJ1In(paletteOBJ1In),
        .gbc_mode(gbc_mode),
        .gpd(gpd),

        .BTN_NODIAGONAL(system_control[11]),
        .BTN_A(BTN_A_filtered | MCU_buttons[3]),
        .BTN_B(BTN_B_filtered | MCU_buttons[2]),
        .BTN_DPAD_DOWN(BTN_DPAD_DOWN_filtered | MCU_buttons[7]),
        .BTN_DPAD_LEFT(BTN_DPAD_LEFT_filtered | MCU_buttons[6]),
        .BTN_DPAD_RIGHT(BTN_DPAD_RIGHT_filtered | MCU_buttons[5]),
        .BTN_DPAD_UP(BTN_DPAD_UP_filtered | MCU_buttons[4]),
        .BTN_MENU(~BTN_MENU_ored),
        .BTN_SEL(BTN_SEL_filtered | MCU_buttons[1]),
        .BTN_START(BTN_START_filtered | MCU_buttons[0]),
        .MENU_CLOSED(menuDisabled & ~slideOutActive),

        .CART_A(core_cart_address),
        .CART_CLK(core_cart_clock),
        .CART_CS(core_cart_cs_n),
        .CART_D_IN(physical_cart_data_in),
        .CART_D_OUT(core_cart_data_out),
        .CART_D_OE(core_cart_data_oe),
        .CART_RD(core_cart_read_n),
        .CART_RST(CART_RST),
        .CART_WR(core_cart_write_n),

        .virtual_enable(virtual_enable_h),
        .virtual_mapper_select(virtual_mapper_select_h),
        .virtual_mbc1m(virtual_mbc1m_h),
        .virtual_mbc30(virtual_mbc30_h),
        .virtual_cart_type(virtual_cart_type_h),
        .virtual_has_ram(virtual_has_ram_h),
        .virtual_ram_mask(virtual_ram_mask_h),
        .virtual_rom_mask(virtual_rom_mask_h),
        .virtual_rtc_time({virtual_rtc_timestamp_toggle_h, 32'd0}),
        .virtual_rtc_restore_write(virtual_rtc_restore_write_h),
        .virtual_rtc_restore_address(virtual_rtc_restore_address_h),
        .virtual_rtc_restore_data(virtual_rtc_restore_data_h),
        .virtual_rtc_state(virtual_rtc_state_h),
        .virtual_initialized(virtual_initialized_h),
        .virtual_save_dirty(virtual_save_dirty_h),
        .virtual_xrequest(virtual_xrequest),
        .virtual_xread(virtual_xread),
        .virtual_xaddress(virtual_xaddress),
        .virtual_xwritedata(virtual_xwritedata),
        .virtual_xlength(virtual_xlength),
        .virtual_xwrite_next(virtual_xwrite_next),
        .virtual_xdone(virtual_xdone),
        .virtual_xread_valid(virtual_xread_valid),
        .virtual_xreaddata(virtual_xreaddata),
        .virtual_snapshot_request_toggle(
            virtual_snapshot_request_toggle_g),
        .virtual_snapshot_block(virtual_snapshot_block_g),
        .virtual_snapshot_sequence(virtual_snapshot_sequence_g),
        .virtual_snapshot_ready(virtual_snapshot_ready_x),
        .virtual_snapshot_ready_sequence(
            virtual_snapshot_ready_sequence_x),
        .virtual_snapshot_qclk(QSPI_CLK),
        .virtual_snapshot_qaddress(qspi_cart_read_address[9:0]),
        .virtual_snapshot_qdata(qspi_virtual_read_data),

        .IR_RX(IR_RX),
        .IR_LED(IR_LED),

        .LINK_CLK(LINK_CLK),
        .LINK_IN(LINK_IN),
        .LINK_OUT(LINK_OUT),

        .lcd_on_int(lcd_on_int),
        .lcd_off_overwrite(lcd_off_overwrite),

        .boot_rom_enabled(boot_rom_enabled),

        // audio
        .left(left),
        .right(right),
        // video
        .LCD_INIT_DONE(LCD_INIT_DONE),
        .gb_lcd_clkena(core_gb_lcd_clkena),
        .gb_lcd_mode(core_gb_lcd_mode),
        .gb_lcd_on(core_gb_lcd_on),
        .gb_lcd_vsync(core_gb_lcd_vsync),
        .gb_lcd_data(core_gb_lcd_data)
    );

    reg UART_TXD;
    wire UART_RXD;
    wire PHY_CLKOUT;
    wire usblocked;
    always@(posedge PHY_CLKOUT or negedge usblocked)
    begin
        if(~usblocked)
        begin
            UART_TXD     <= 1'd1;
            ESP32_MCU_D4 <= 1'd1;
        end
        else
        begin
            UART_TXD     <= ESP32_MCU_D3;
            ESP32_MCU_D4 <= UART_RXD;
        end
    end
    wire UART_DTR;
    wire UART_RTS;
    wire [1:0] DTRRTS = {UART_DTR, UART_RTS};



    reg [11:0] ESP_BOOT_DELAY_COUNTER = 0;
    reg [7:0] ESP_BOOT_DELAY_SHIFT = 0;


    reg ESP32_EN_INT = 1;
    reg ESP32_IO0_INT = 1;

    // 8MHz clock
    always@(posedge gClk) begin

        ESP32_IO0 <= ESP32_IO0_INT;

        ESP_BOOT_DELAY_COUNTER <= ESP_BOOT_DELAY_COUNTER + 1'b1;

        if(ESP_BOOT_DELAY_COUNTER == 0) begin
            ESP_BOOT_DELAY_SHIFT <= {ESP_BOOT_DELAY_SHIFT[6:0], ESP32_EN_INT};
            ESP32_EN <= ESP_BOOT_DELAY_SHIFT[7];
           end

        if(~ESP32_EN_INT) begin
            ESP_BOOT_DELAY_SHIFT <= 8'b0;
            ESP32_EN <= 0;
        end
    end

    always@(posedge PHY_CLKOUT or negedge usblocked)
    begin
        if(~usblocked)
        begin
            ESP32_EN_INT <= 1'd1;
            ESP32_IO0_INT <= 1'd1;
        end
        else
        begin
            ESP32_EN_INT <= ~UART_RTS;
            ESP32_IO0_INT <= (DTRRTS == 2'b00);
        end
    end

    wire clk24;
    wire [7:0] debugs;

    assign HDMI_D_P[2] = lcd_on_int;
    assign HDMI_D_N[2] = hDrawOSD;
    assign HDMI_D_P[1] = lcd_off_overwrite;
    assign HDMI_D_N[1] = display_gb_lcd_on;
    assign HDMI_D_P[0] = display_gb_lcd_vsync;
    assign HDMI_D_N[0] = display_gb_lcd_mode[1];
    assign HDMI_CLK_P = display_gb_lcd_clkena;
    assign HDMI_CLK_N = hGBWrite;

    reg hr1;
    reg vr1;
    reg he1;
    reg [17:0] d1;

    always@(posedge gClk or posedge memrst)
    begin
        if(memrst)
        begin
            hr1 <= 'd0;
            vr1 <= 'd0;
            he1 <= 'd0;
            d1  <= 'd0;
        end
        else
        begin
            hr1 <= LCD_HSYNC;
            vr1 <= LCD_VSYNC;
            he1 <= LCD_ENABLE_UVC;
            d1  <= LCD_DB_UVC;
        end
    end

    reg [23:0] usbinitcnt;
    reg usbrst = 1'd1;

    // 8388607 = 1s
    always@(posedge gClk or negedge lock_o)
        if(~lock_o)
        begin
            usbinitcnt <= 'd0;
            usbrst     <= 1'd1;
        end
        else
            if(usbinitcnt < 8388607)
            begin
                usbinitcnt <= usbinitcnt + 1'd1;
                usbrst <= 1'd1;
            end
            else
                usbrst <= 1'd0;

    usbuvcuart_top u_usb_top(
        .CLK_24MHz(CLK_24MHz),
        .ERST(usbrst),
        .pClk(PHY_CLKOUT),
        .usblocked(usblocked),
        .hClk(gClk),

        .UART_TXD(UART_RXD), // output
        .UART_RXD(UART_TXD), // input
        .E_UART_DTR(UART_DTR), // used for ESP32_EN
        .E_UART_RTS(UART_RTS), // used for ESP32_IO0 (bootloader select)

        .PC_STREAM_DATA(cart_usb_tx_data),
        .PC_STREAM_VALID(cart_usb_tx_valid),
        .PC_STREAM_READY(cart_usb_tx_ready),

        .left(left),
        .right(right),

        .hLineValid(hr1),
        .hEnable(he1),
        .hFrameValid(vr1),
        .hData(d1),
        .debugs(debugs),
        .playerNum({4'd0, system_control[7:4]}),
        .usb_dxp_io(usb_dxp_io),
        .usb_dxn_io(usb_dxn_io),
        .usb_rxdp_i(usb_rxdp_i),
        .usb_rxdn_i(usb_rxdn_i),
        .usb_pullup_en_o(usb_pullup_en_o),
        .usb_term_dp_io(usb_term_dp_io),
        .usb_term_dn_io(usb_term_dn_io)
    );

    wire [13:0] hAdcValue_r1;
    wire hAdcReq_ext;
    wire hAdcReady_r1;
    adc_wrap u_adc_wrap(
        .clk(gClk),
        .reset_n(lock_o),
        .hAdcReq_ext(hAdcReq_ext),
        .hAdcValue_r1(hAdcValue_r1),
        .hAdcReady_r1(hAdcReady_r1),
        .VBAT_ADC_P(VBAT_ADC_P),
        .VBAT_ADC_N(VBAT_ADC_N)
    );

    wire [7:0]  uart_tx_data;
    wire        uart_tx_busy;
    wire        uart_tx_val;

    wire [15:0] uart_rx_data;
    wire        uart_rx_val;

    wire menu_gated = qMenuInit &&
        (virtual_enable_g || CART_DET_sr[6:3] == 4'b1111)
        ? BTN_MENU_ored : 1'b1;

    system_monitor u_system_monitor(
        .clk(gClk),
        .reset(~lock_o),
        .BTN_A(BTN_A_filtered),
        .BTN_B(BTN_B_filtered),
        .BTN_DPAD_DOWN(BTN_DPAD_DOWN_filtered),
        .BTN_DPAD_LEFT(BTN_DPAD_LEFT_filtered),
        .BTN_DPAD_RIGHT(BTN_DPAD_RIGHT_filtered),
        .BTN_DPAD_UP(BTN_DPAD_UP_filtered),
        .BTN_MENU(menu_gated),
        .BTN_SEL(BTN_SEL_filtered),
        .BTN_START(BTN_START_filtered),
        .menuDisabled(menuDisabled),
        .LCD_BACKLIGHT_INIT(LCD_BACKLIGHT_INIT),
        .LCD_INIT_DONE(LCD_INIT_DONE &
                       (~boot_rom_enabled | cart_maintenance_request_g |
                        cart_video_selected_g_sync)),
        .LCD_PWM(LCD_PWM),
        .hAdcReq_ext(hAdcReq_ext),
        //.hAdcValue_r1(voltageSim),
        .hAdcValue_r1(hAdcValue_r1),
        .hAdcReady_r1(hAdcReady_r1),
        .ADC_SEL(ADC_SEL),
        .hButtons(9'd0),
        .MCU_buttons(MCU_buttons),
        .hVolume(volume[6:0]),
        .pmic_sys_status(pmic_sys_status),
        .hHeadphones(hHeadphones),
        .gSecondEna(secondEna),
        .gHalfSecondEna(halfSecondEna),
        .debug_system(debug_system),
        .low_battery(low_battery),
        .LED_Green(LED_Green),
        .LED_Red(LED_Red),
        .LED_Yellow(LED_Yellow),
        .LED_White(LED_White),
        .system_control(system_control),
        .paletteBGIn(paletteBGIn),
        .paletteOBJ0In(paletteOBJ0In),
        .paletteOBJ1In(paletteOBJ1In),
        .gbc_mode(gbc_mode),
        .gpd(gpd),
        .uart_rx_data(uart_rx_data[7:0]),
        .uart_rx_val(uart_rx_val),
        .uart_tx_busy(uart_tx_busy),
        .uart_tx_data(uart_tx_data),
        .uart_tx_val(uart_tx_val),
        .cart_request_valid(cart_request_valid),
        .cart_request_ready(cart_request_ready),
        .cart_request_operation(cart_request_operation),
        .cart_request_tag(cart_request_tag),
        .cart_request_address(cart_request_address),
        .cart_request_value(cart_request_value),
        .cart_request_aux_address(cart_request_aux_address),
        .cart_request_aux_value(cart_request_aux_value),
        .cart_response_valid(cart_response_valid),
        .cart_response_ready(cart_response_ready),
        .cart_response_operation(cart_response_operation),
        .cart_response_tag(cart_response_tag),
        .cart_response_status(cart_response_status),
        .cart_response_count(cart_response_count),
        .cart_response_data(cart_response_data),
        .cart_stream_event_valid(cart_stream_event_for_monitor),
        .cart_stream_event_ready(cart_stream_event_ready),
        .cart_stream_event_sequence(cart_stream_event_sequence),
        .cart_stream_event_crc32(cart_stream_event_crc32),
        .cart_stream_ack_valid(cart_stream_ack_valid),
        .cart_stream_ack_sequence(cart_stream_ack_sequence),
        .cart_session_active(cart_maintenance_request_g),
        .audio_snapshot_toggle_x(audio_boot_snapshot_toggle),
        .audio_snapshot_ready_x(audio_boot_snapshot_ready),
        .audio_snapshot_status_x(audio_boot_status),
        .audio_snapshot_codec_x(audio_boot_codec)
    );

    UART2
    #(.CLK_FREQ(30'd8388608))
    u_UART2
    (
        .CLK(gClk), // clock
        .RST(~lock_o), // reset
        // UART INTERFACE
        .UART_TXD(ESP32_MCU_D11), //output
        .UART_RXD(ESP32_MCU_D12), //input
        .UART_RTS(), //output // when UART_RTS = 0, UART This Device Ready to receive.
        .UART_CTS(1'd0), //input// when UART_CTS = 0, UART Opposite Device Ready to receive.
        // UART Control Reg
        .BAUD_RATE(32'd115200), //input 32
        .PARITY_BIT(8'd0), // input 8
        .STOP_BIT(8'd0), // input 8
        .DATA_BITS(8'd8), // input 8
        // USER DATA INPUT INTERFACE
        .TX_DATA({8'd0, uart_tx_data}), //input 16
        .TX_DATA_VAL(uart_tx_val), //input 1 when TX_DATA_VAL = 1, data on TX_DATA will be transmit, DATA_SEND can set to 1 only when BUSY = 0
        .TX_BUSY(uart_tx_busy), //output when BUSY = 1 transiever is busy, you must not set DATA_SEND to 1
        // USER FIFO CONTROL INTERFACE
        .RX_DATA(uart_rx_data), //output 16
        .RX_DATA_VAL(uart_rx_val)//output
    );

    assign I2S_BCLK = menuDisabled;

endmodule
