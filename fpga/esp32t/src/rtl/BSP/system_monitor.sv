// system_monitor.v

module system_monitor(
    input               clk,
    input               reset,
    input               BTN_A,
    input               BTN_B,
    input               BTN_DPAD_DOWN,
    input               BTN_DPAD_LEFT,
    input               BTN_DPAD_RIGHT,
    input               BTN_DPAD_UP,
    input               BTN_MENU, // pressed = 0
    input               BTN_SEL,
    input               BTN_START,
    // Controls external mux into ADC
    output  reg         menuDisabled,
    output  reg         ADC_SEL,
    output  reg         hAdcReq_ext,
    input               LCD_INIT_DONE,
    output  reg         LCD_PWM,
    output  reg         LCD_BACKLIGHT_INIT = 1'd0,
    input               hAdcReady_r1,
    input   [13:0]      hAdcValue_r1,
    input   [8:0]       hButtons,
    output  reg [8:0]   MCU_buttons,
    input   [6:0]       hVolume,
    input   [7:0]       pmic_sys_status,
    input               hHeadphones,
    input               gSecondEna,
    input               gHalfSecondEna,
    output  reg         low_battery,
    output  reg         LED_Green,
    output  reg         LED_Red,
    output  reg         LED_Yellow,
    output  reg         LED_White,
    output  reg [15:0]  system_control,
    output  reg [31:0]  debug_system,
    output  reg [63:0]  paletteBGIn,
    output  reg [63:0]  paletteOBJ0In,
    output  reg [63:0]  paletteOBJ1In,
    input               gbc_mode,
    input   [63:0]      gpd,
    input   [7:0]       uart_rx_data,
    input               uart_rx_val,
    input               uart_tx_busy,
    output  [7:0]       uart_tx_data,
    output              uart_tx_val,

    output              cart_request_valid,
    input               cart_request_ready,
    output  [2:0]       cart_request_operation,
    output  [7:0]       cart_request_tag,
    output  [15:0]      cart_request_address,
    output  [7:0]       cart_request_value,
    output  [15:0]      cart_request_aux_address,
    output  [7:0]       cart_request_aux_value,

    input               cart_response_valid,
    output              cart_response_ready,
    input   [2:0]       cart_response_operation,
    input   [7:0]       cart_response_tag,
    input   [3:0]       cart_response_status,
    input   [2:0]       cart_response_count,
    input   [31:0]      cart_response_data,
    input               cart_stream_event_valid,
    output              cart_stream_event_ready,
    input   [7:0]       cart_stream_event_sequence,
    input   [31:0]      cart_stream_event_crc32,
    output              cart_stream_ack_valid,
    output  [7:0]       cart_stream_ack_sequence,
    input               cart_session_active,

    input               audio_snapshot_toggle_x,
    input               audio_snapshot_ready_x,
    input [79:0]        audio_snapshot_status_x,
    input [79:0]        audio_snapshot_codec_x
);

    wire    [6:0]   rx_address;
    wire    [79:0]  rx_data;
    wire            rx_data_val;
    localparam integer NUM_CH = 14;
    wire [$clog2(NUM_CH)-1:0] tx_channel;
    wire write_done;

    wire cart_request_is_write_range = rx_data[58:56] == 3'h7;
    wire cart_request_encoding_valid =
        (rx_data[63:59] == 5'd0) &&
        (cart_request_is_write_range || (rx_data[23:0] == 24'd0));
    reg cart_request_pending = 1'b0;
    reg [2:0] cart_request_operation_reg = 3'd0;
    reg [7:0] cart_request_tag_reg = 8'd0;
    reg [15:0] cart_request_address_reg = 16'd0;
    reg [7:0] cart_request_value_reg = 8'd0;
    reg [15:0] cart_request_aux_address_reg = 16'd0;
    reg [7:0] cart_request_aux_value_reg = 8'd0;

    assign cart_request_valid = cart_request_pending;
    assign cart_request_operation = cart_request_operation_reg;
    assign cart_request_tag = cart_request_tag_reg;
    assign cart_request_address = cart_request_address_reg;
    assign cart_request_value = cart_request_value_reg;
    assign cart_request_aux_address = cart_request_aux_address_reg;
    assign cart_request_aux_value = cart_request_aux_value_reg;
    assign cart_stream_ack_valid = rx_data_val && (rx_address == 7'h10);
    assign cart_stream_ack_sequence = rx_data[7:0];

    always @(posedge clk or posedge reset)
    begin
        if (reset)
        begin
            cart_request_pending <= 1'b0;
            cart_request_operation_reg <= 3'd0;
            cart_request_tag_reg <= 8'd0;
            cart_request_address_reg <= 16'd0;
            cart_request_value_reg <= 8'd0;
            cart_request_aux_address_reg <= 16'd0;
            cart_request_aux_value_reg <= 8'd0;
        end
        else
        begin
            if (cart_request_pending && cart_request_ready)
                cart_request_pending <= 1'b0;
            if (rx_data_val && (rx_address == 7'h0e) &&
                (!cart_request_pending || cart_request_ready))
            begin
                cart_request_operation_reg <= cart_request_encoding_valid
                    ? rx_data[58:56] : 3'h7;
                cart_request_tag_reg <= rx_data[55:48];
                cart_request_address_reg <= rx_data[47:32];
                cart_request_value_reg <= rx_data[31:24];
                cart_request_aux_address_reg <= rx_data[23:8];
                cart_request_aux_value_reg <= rx_data[7:0];
                cart_request_pending <= 1'b1;
            end
        end
    end
    assign cart_response_ready = write_done && (tx_channel == 10);

    reg cart_response_valid_d = 1'b0;
    always @(posedge clk or posedge reset)
        if (reset)
            cart_response_valid_d <= 1'b0;
        else
            cart_response_valid_d <= cart_response_valid;
    wire cart_response_new = cart_response_valid & ~cart_response_valid_d;

    assign cart_stream_event_ready = write_done && (tx_channel == 13);
    reg cart_stream_event_valid_d = 1'b0;
    always @(posedge clk or posedge reset)
        if (reset)
            cart_stream_event_valid_d <= 1'b0;
        else
            cart_stream_event_valid_d <= cart_stream_event_valid;
    wire cart_stream_event_new = cart_stream_event_valid &
                                 ~cart_stream_event_valid_d;

    reg audio_snapshot_toggle_meta = 1'b0;
    reg audio_snapshot_toggle_sync = 1'b0;
    reg audio_snapshot_toggle_seen = 1'b0;
    reg audio_snapshot_ready_meta = 1'b0;
    reg audio_snapshot_ready_sync = 1'b0;
    reg [79:0] audio_snapshot_status = 80'd0;
    reg [79:0] audio_snapshot_codec = 80'd0;
    always @(posedge clk or posedge reset)
    begin
        if (reset)
        begin
            audio_snapshot_toggle_meta <= 1'b0;
            audio_snapshot_toggle_sync <= 1'b0;
            audio_snapshot_toggle_seen <= 1'b0;
            audio_snapshot_ready_meta <= 1'b0;
            audio_snapshot_ready_sync <= 1'b0;
            audio_snapshot_status <= 80'd0;
            audio_snapshot_codec <= 80'd0;
        end
        else
        begin
            audio_snapshot_toggle_meta <= audio_snapshot_toggle_x;
            audio_snapshot_toggle_sync <= audio_snapshot_toggle_meta;
            audio_snapshot_ready_meta <= audio_snapshot_ready_x;
            audio_snapshot_ready_sync <= audio_snapshot_ready_meta;
            if (audio_snapshot_toggle_sync != audio_snapshot_toggle_seen)
            begin
                audio_snapshot_toggle_seen <= audio_snapshot_toggle_sync;
                audio_snapshot_status <= audio_snapshot_status_x;
                audio_snapshot_codec <= audio_snapshot_codec_x;
            end
        end
    end

    reg [15:0] btnMenu_sr;
    reg btnMenu_r1;
    reg btnMenu_r2;

    reg [15:0] btnDown_sr;
    reg btnDown_r1;
    reg btnDown_r2;

    reg [15:0] btnUp_sr;
    reg btnUp_r1;
    reg btnUp_r2;

    reg [15:0] btnLeft_sr;
    reg btnLeft_r1;
    reg btnLeft_r2;

    reg [15:0] btnRight_sr;
    reg btnRight_r1;
    reg btnRight_r2;

    reg btnStart_r1;
    reg btnStart_r2;
    reg btnSelect_r1;
    reg btnSelect_r2;
    reg btnA_r1;
    reg btnA_r2;
    reg btnB_r1;
    reg btnB_r2;

    reg pressed;
    reg [3:0] brightness = 4'd3;
    reg [1:0] blockBrightnessReceive;

    reg request_buttons  = 1'b0;
    reg request_version  = 1'b0;
    reg updateBrightness = 1'b0;
    reg request_gpd     = 1'b0;

    reg lowpowerBacklight = 1'b0;
    reg [3:0] lowerpowerOldBL;
    reg request_SystemStatusExtended = 1'b0;

    reg [13:0] volt;
    wire       bat_is_LI;

    always@(posedge clk or posedge reset)
    begin
        if(reset) begin
            system_control <= 16'd0;
            MCU_buttons    <= 9'd0;
            request_gpd   <= 1'b0;
        end else begin
            request_buttons              <= 1'b0;
            request_version              <= 1'b0;
            updateBrightness             <= 1'b0;
            request_SystemStatusExtended <= 1'b0;

            if (gHalfSecondEna) begin
               LCD_BACKLIGHT_INIT  <= 1'd1;
            end

            if(rx_data_val)
            begin
                if(rx_address == 7'hD) begin
                    request_gpd <= 1'b1;
                end
                if(rx_address == 7'hC) begin
                    if (rx_data[63]) begin
                        paletteOBJ1In <= rx_data[63:0];
                    end else begin
                        paletteOBJ0In <= rx_data[63:0];
                    end
                end
                if(rx_address == 7'hB) begin
                    paletteBGIn <= rx_data[63:0];
                end
                if(rx_address == 7'd9) begin
                    MCU_buttons <= rx_data[8:0];
                end
                if(rx_address == 7'd6) begin
                    request_version <= 1'b1;
                end
                if(rx_address == 7'd5) begin
                    if (blockBrightnessReceive == 2'd0) begin
                        brightness      <=  rx_data[13:0];
                    end else begin
                        blockBrightnessReceive <= blockBrightnessReceive - 1;
                    end
                end
                if(rx_address == 7'd4) begin
                    system_control  <=  rx_data[15:0];
                end
                if(rx_address == 7'd2) begin
                    request_buttons <= 1'b1;
                end
            end

            if (menuDisabled) begin
                if((btnLeft_sr[15:0] == 16'h8000)&&~btnMenu_r2) begin
                    if(brightness >= 1)
                    begin
                        brightness <= brightness - 9'd1;
                        pressed <= 1'd0;
                        blockBrightnessReceive <= 2'd3;
                        updateBrightness <= 1'b1;
                    end
                end
                if((btnRight_sr[15:0] == 16'h8000)&&~btnMenu_r2) begin
                    if(brightness != 15)
                    begin
                        pressed <= 1'd0;
                        brightness <= brightness + 9'd1;
                        blockBrightnessReceive <= 2'd3;
                        updateBrightness <= 1'b1;
                    end
                end
            end

            if (lowpowerBacklight) begin
               brightness       <= 4'd0;
               updateBrightness <= 1'b0;
            end

            if (volt >= 700) begin // ~1.8V
               if (~lowpowerBacklight && ~bat_is_LI && volt < 979) begin // below 2.55 V
                  request_SystemStatusExtended <= 1'b1;
                  lowpowerBacklight            <= 1'b1;
                  lowerpowerOldBL              <= brightness;
               end

               if (lowpowerBacklight && ~bat_is_LI && volt > 1293) begin // above 3.4 V
                  request_SystemStatusExtended <= 1'b1;
                  lowpowerBacklight            <= 1'b0;
                  brightness                   <= lowerpowerOldBL;
               end
            end

            if (write_done && tx_channel == 9 && request_gpd) begin
                request_gpd <= 1'b0; // Clear after sending once
            end

        end
    end

    reg menuDown = 1'b0;
    always@(posedge clk)
    begin
        if(reset) begin
            menuDisabled <= 1'b1;
        end else begin
            btnMenu_r1 <= BTN_MENU;
            btnMenu_r2 <= btnMenu_r1;
            btnMenu_sr <= {btnMenu_sr[14:0], btnMenu_r2};
            if(btnMenu_sr[15:0] == 16'h8000) begin
               menuDown <= 1'b1;
            end
            if(btnMenu_sr[15:0] == 16'h7FFF && menuDown) begin
               menuDisabled <= ~menuDisabled;
               menuDown     <= 1'b0;
            end

            if (btnA_r2 | btnB_r2 | btnDown_r2 | btnUp_r2 | btnLeft_r2 | btnRight_r2 | btnSelect_r2 | btnStart_r2) menuDown <= 1'b0;

            btnDown_r1 <= BTN_DPAD_DOWN;
            btnDown_r2 <= btnDown_r1;
            btnDown_sr <= {btnDown_sr[14:0], btnDown_r2};

            btnUp_r1 <= BTN_DPAD_UP;
            btnUp_r2 <= btnUp_r1;
            btnUp_sr <= {btnUp_sr[14:0], btnUp_r2};

            btnLeft_r1 <= BTN_DPAD_LEFT;
            btnLeft_r2 <= btnLeft_r1;
            btnLeft_sr <= {btnLeft_sr[14:0], btnLeft_r2};

            btnRight_r1 <= BTN_DPAD_RIGHT;
            btnRight_r2 <= btnRight_r1;
            btnRight_sr <= {btnRight_sr[14:0], btnRight_r2};

            btnSelect_r1 <= BTN_SEL;
            btnSelect_r2 <= btnSelect_r1;

            btnStart_r1 <= BTN_START;
            btnStart_r2 <= btnStart_r1;

            btnA_r1 <= BTN_A;
            btnA_r2 <= btnA_r1;

            btnB_r1 <= BTN_B;
            btnB_r2 <= btnB_r1;

        end
    end

    reg [7:0] lcdcount;
    always@(posedge clk)
        if(lcdcount < 448)
            lcdcount <= lcdcount + 1'd1;
        else
            lcdcount <= 'd0;

    assign LCD_PWM = LCD_INIT_DONE&LCD_BACKLIGHT_INIT ? (lcdcount <= {brightness[3:0], 4'd0}) : 1'd0;


    // 8.388608Mhz clock -> ~119.2ns
    // 0.005s / 119.2ns = 41946

    localparam ADC_INTERVAL_CYCLES = 'd41946;
    reg [15:0] adc_timer;
    reg [9:0] startup_cnt;            // wait for ~4 seconds to have stable measurements
    reg signed [10:0] startup_select; // measure if AA or lithium is used, negative -> LI, positive -> AA
    reg startup_done = 1'b0;

    always@(posedge clk) begin
        if(adc_timer < ADC_INTERVAL_CYCLES) begin
            adc_timer <= adc_timer + 1'd1;
            hAdcReq_ext <= 'd0;
            // Toggle the mux slightly ahead of starting the measurement
            if (startup_done) begin
                ADC_SEL <= startup_select[10];
            end else if(adc_timer == ADC_INTERVAL_CYCLES - 1000) begin
                ADC_SEL <= ~ADC_SEL;
            end
        end else begin
            adc_timer <= 'd0;
            hAdcReq_ext <= 'd1;
        end
    end

   assign     bat_is_LI = startup_select[10];
   reg [21:0] volt_sum;
   reg [8:0]  volt_cnt;
   reg        transmitVolt;

   wire [13:0] VOLTAGE_FULL   = bat_is_LI ? 14'd1423 : 14'd1367; //  3.75V LI : 3.6V AA
   wire [13:0] VOLTAGE_CRIT   = bat_is_LI ? 14'd1145 : 14'd997;  //  3.0V  LI : 2.6V AA
   wire [13:0] VOLTAGE_RED    = bat_is_LI ? 14'd1182 : 14'd1071; //  3.1V  LI : 2.8V AA

   reg blink;

   always@(posedge clk or posedge reset) begin

      if(reset) begin
         low_battery    <= 1'd0;
         LED_Red        <= 1'd0;
         LED_Green      <= 1'd0;
         LED_Yellow     <= 1'd0;
         blink          <= 1'd0;
         volt           <= 14'd0;
         volt_sum       <= 22'd0;
         volt_cnt       <=  9'd0;
         startup_cnt    <= 11'd0;
         startup_select <= 11'd0;
         startup_done   <= 1'b0;
         transmitVolt   <= 1'b0;
      end else begin

         transmitVolt <= 1'b0;

         debug_system <= {1'd0 , startup_select,  6'd0, volt };

         if(hAdcReady_r1) begin
            if (~startup_cnt[9]) begin // wait for ~4 seconds to have stable measurements
               startup_cnt <= startup_cnt + 1'd1;
            end

            if (startup_done) begin // average values for determined type only
               volt_sum <= volt_sum + hAdcValue_r1;
               volt_cnt <= volt_cnt + 1;
            end else if (startup_cnt[9] && hAdcValue_r1 >= 700) begin // measure if AA or lithium is used, negative -> LI, positive -> AA
               if (ADC_SEL) begin
                  startup_select <= startup_select - 1'd1;
               end else begin
                  startup_select <= startup_select + 1'd1;
               end
            end

            if (startup_select > 11'sd127 || startup_select < -11'sd127) begin // determine type based on which delivered higher values for some seconds
               startup_done <= 1'b1;
            end
         end

         if (volt_cnt[8]) begin
            volt_sum    <= 22'd0;
            volt_cnt    <=  9'd0;
            volt        <= volt_sum[21:8];
            transmitVolt <= 1'b1;
         end

         if (gSecondEna) blink <= ~blink;

         low_battery <= 1'd0;
         LED_Red     <= 1'd0;
         LED_Green   <= 1'd0;
         LED_Yellow  <= 1'd0;
         LED_White   <= 1'd0;

         if (volt >= 700) begin // ~1.8V

            if (pmic_sys_status[2]) begin // charging

               if(bat_is_LI && volt < VOLTAGE_FULL) begin
                  LED_White   <= 1'd1;
               end

            end else begin

               if(volt < VOLTAGE_RED) begin
                  low_battery <= 1'd1;
                  if (blink) LED_Red <= 1'd1;
               end

            end

         end
      end
   end

    wire [6:0] tx_address;
    wire       write;

    wire [13:0] buttons = {
        4'd0,
        menuDisabled,
        ~BTN_MENU,
        BTN_DPAD_DOWN,
        BTN_DPAD_LEFT,
        BTN_DPAD_RIGHT,
        BTN_DPAD_UP,
        BTN_A,
        BTN_B,
        BTN_SEL,
        BTN_START
    };

    reg [13:0] version = {
        1'd0,  // 1 bit reserved
        1'd0,  // 1 bit debug,
        6'd38, // 6 bits minor version
        6'd18  // 6 bits major version
    };

    wire [9:0] stockChannelsNewDataValid =
    {
        request_gpd,                                  // Game Palette Data
        ~menuDisabled | request_SystemStatusExtended, // System Status Extended
        ~menuDisabled,                                // reserved
        ~menuDisabled | request_version,              // version info
        ~menuDisabled,                                // pmic sys status
        ~menuDisabled,                                // System Control
        ~menuDisabled | updateBrightness,             // Audio + Brightness
        ~menuDisabled | request_buttons,              // Buttons
        (~menuDisabled & transmitVolt & bat_is_LI),   // Lithium
        (~menuDisabled & transmitVolt & ~bat_is_LI)   // AA
    };

    wire audio_snapshot_request_new = rx_data_val && (rx_address == 7'h0f);
    reg audio_snapshot_request_pending = 1'b0;
    reg audio_snapshot_new = 1'b0;
    always @(posedge clk or posedge reset)
    begin
        if (reset)
        begin
            audio_snapshot_request_pending <= 1'b0;
            audio_snapshot_new <= 1'b0;
        end
        else
        begin
            audio_snapshot_new <= 1'b0;
            if (audio_snapshot_request_new)
                audio_snapshot_request_pending <= 1'b1;
            if (audio_snapshot_request_pending && audio_snapshot_ready_sync)
            begin
                audio_snapshot_request_pending <= 1'b0;
                audio_snapshot_new <= 1'b1;
            end
        end
    end

    wire [9:0] maintenance_stock_mask =
        {{7{~cart_session_active}}, 1'b1, {2{~cart_session_active}}};
    wire [NUM_CH-1:0] channelsNewDataValid =
    {
        cart_stream_event_new,
        audio_snapshot_new,
        audio_snapshot_new,
        cart_response_new,
        stockChannelsNewDataValid & maintenance_stock_mask
    };

    wire [13:0] audio_brightness = {2'd0, brightness, hHeadphones, hVolume};
    wire [13:0] mic_sys_status = {6'd0 , pmic_sys_status};

    wire [7:0] tx_byteCount = (tx_channel == 0) ? 8'd2 : // AA
                              (tx_channel == 1) ? 8'd2 : // Lithium
                              (tx_channel == 2) ? 8'd2 : // Buttons
                              (tx_channel == 3) ? 8'd2 : // Audio + Brightness
                              (tx_channel == 4) ? 8'd2 : // System Control
                              (tx_channel == 5) ? 8'd2 : // pmic sys status
                              (tx_channel == 6) ? 8'd2 : // version info
                              (tx_channel == 7) ? 8'd4 : // reserved
                              (tx_channel == 8) ? 8'd4 : // System Status Extended
                              (tx_channel == 9) ? 8'd8 : // BG Palette Data
                              (tx_channel == 10) ? {5'd0, cart_response_count} + 8'd4 :
                              (tx_channel == 11) ? 8'd10 :
                              (tx_channel == 12) ? 8'd10 :
                              (tx_channel == 13) ? 8'd1 :
                              8'd1;

    wire [7:0] tx_bytepos;

    reg [13:0] telemetry_data;
    always @* begin
        case (tx_channel)
            0, 1: telemetry_data = volt;
            2: telemetry_data = buttons;
            3: telemetry_data = audio_brightness;
            4: telemetry_data = system_control[13:0];
            5: telemetry_data = mic_sys_status;
            6: telemetry_data = version;
            default: telemetry_data = 14'd0;
        endcase
    end
    wire [79:0] audio_tx_snapshot = (tx_channel == 11)
        ? audio_snapshot_status : audio_snapshot_codec;
    reg [7:0] tx_senddata;
    always @* begin
        tx_senddata = 8'd0;
        case (tx_channel)
            0, 1, 2, 3, 4, 5, 6:
                case (tx_bytepos)
                    0: tx_senddata = {2'd0, telemetry_data[13:8]};
                    1: tx_senddata = telemetry_data[7:0];
                    default: tx_senddata = 8'd0;
                endcase
            8: if (tx_bytepos == 0)
                tx_senddata = {6'd0, gbc_mode, lowpowerBacklight};
            9: if (tx_bytepos < 8)
                tx_senddata = gpd[{tx_bytepos[2:0], 3'b000} +: 8];
            10:
                case (tx_bytepos)
                    0: tx_senddata = {5'd0, cart_response_operation};
                    1: tx_senddata = cart_response_tag;
                    2: tx_senddata = {4'd0, cart_response_status};
                    3: tx_senddata = {5'd0, cart_response_count};
                    4: tx_senddata = cart_response_data[7:0];
                    5: tx_senddata = cart_response_data[15:8];
                    6: tx_senddata = cart_response_data[23:16];
                    7: tx_senddata = cart_response_data[31:24];
                    default: tx_senddata = 8'd0;
                endcase
            11, 12:
                case (tx_bytepos)
                    0: tx_senddata = audio_tx_snapshot[79:72];
                    1: tx_senddata = audio_tx_snapshot[71:64];
                    2: tx_senddata = audio_tx_snapshot[63:56];
                    3: tx_senddata = audio_tx_snapshot[55:48];
                    4: tx_senddata = audio_tx_snapshot[47:40];
                    5: tx_senddata = audio_tx_snapshot[39:32];
                    6: tx_senddata = audio_tx_snapshot[31:24];
                    7: tx_senddata = audio_tx_snapshot[23:16];
                    8: tx_senddata = audio_tx_snapshot[15:8];
                    9: tx_senddata = audio_tx_snapshot[7:0];
                    default: tx_senddata = 8'd0;
                endcase
            13: if (tx_bytepos == 0)
                tx_senddata = cart_stream_event_sequence;
            default: tx_senddata = 8'd0;
        endcase
    end

    wire uartDisabled;
    wire transport_menu_disabled = menuDisabled && !cart_session_active;

    system_monitor_arbiter
    #(
        .NUM_CH(NUM_CH)
    ) u_system_monitor_arbiter
    (
        .clk(clk),
        .reset(reset),
        .uartDisabled(uartDisabled),
        .menuDisabled(transport_menu_disabled),
        .channelsNewDataValid(channelsNewDataValid),
        .uart_tx_busy(uart_tx_busy),
        .tx_address(tx_address),
        .tx_channel(tx_channel),
        .write_done(write_done),
        .write(write)
    );

    uart_packet_wrapper_tx u_uart_packet_wrapper_tx
    (
        .clk(clk),
        .reset(reset),
        .uart_tx_busy(uart_tx_busy),
        .uart_tx_data(uart_tx_data),
        .uart_tx_val(uart_tx_val),
        .uartDisabled(uartDisabled),
        .menuDisabled(transport_menu_disabled),
        .write(write),
        .write_done(write_done),
        .tx_address(tx_address),
        .tx_byteCount(tx_byteCount),
        .tx_bytepos(tx_bytepos),
        .tx_senddata(tx_senddata)
    );

    uart_packet_wrapper_rx u_uart_packet_wrapper_rx
    (
        .clk(clk),
        .reset(reset),
        .uart_rx_val(uart_rx_val),
        .uart_rx_data(uart_rx_data),
        .uartDisabled(uartDisabled),
        .rx_address(rx_address),
        .rx_data(rx_data),
        .rx_data_val(rx_data_val)
    );

endmodule
