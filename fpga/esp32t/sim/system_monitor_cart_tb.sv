`timescale 1ns/1ps

module system_monitor_cart_tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;
    reg [7:0] uart_rx_data = 8'd0;
    reg uart_rx_val = 1'b0;
    wire [7:0] uart_tx_data;
    wire uart_tx_val;
    wire cart_request_valid;
    reg cart_request_ready = 1'b0;
    wire [2:0] cart_request_operation;
    wire [7:0] cart_request_tag;
    wire [15:0] cart_request_address;
    wire [7:0] cart_request_value;
    wire [15:0] cart_request_aux_address;
    wire [7:0] cart_request_aux_value;
    reg cart_response_valid = 1'b0;
    wire cart_response_ready;
    reg [2:0] cart_response_operation = 3'd0;
    reg [7:0] cart_response_tag = 8'd0;
    reg [3:0] cart_response_status = 4'd0;
    reg [2:0] cart_response_count = 3'd0;
    reg [31:0] cart_response_data = 32'd0;
    reg cart_stream_event_valid = 1'b0;
    wire cart_stream_event_ready;
    reg [7:0] cart_stream_event_sequence = 8'd0;
    reg [31:0] cart_stream_event_crc32 = 32'd0;
    wire cart_stream_ack_valid;
    wire [7:0] cart_stream_ack_sequence;
    reg audio_snapshot_toggle = 1'b0;
    reg audio_snapshot_ready = 1'b0;
    reg [79:0] audio_snapshot_status = 80'd0;
    reg [79:0] audio_snapshot_codec = 80'd0;
    reg cart_session_active = 1'b1;
    reg button_a = 1'b0;
    reg [2:0] expected_operation = 3'd0;
    reg [7:0] expected_tag = 8'h42;
    reg [15:0] expected_address = 16'h1234;
    reg [7:0] expected_value = 8'h04;
    reg [15:0] expected_aux_address = 16'h0000;
    reg [7:0] expected_aux_value = 8'h00;

    wire menuDisabled;
    wire ADC_SEL;
    wire hAdcReq_ext;
    wire LCD_PWM;
    wire LCD_BACKLIGHT_INIT;
    wire [8:0] MCU_buttons;
    wire low_battery;
    wire LED_Green, LED_Red, LED_Yellow, LED_White;
    wire [15:0] system_control;
    wire [31:0] debug_system;
    wire [63:0] paletteBGIn, paletteOBJ0In, paletteOBJ1In;

    system_monitor dut(
        .clk(clk), .reset(reset),
        .BTN_A(button_a), .BTN_B(1'b0), .BTN_DPAD_DOWN(1'b0),
        .BTN_DPAD_LEFT(1'b0), .BTN_DPAD_RIGHT(1'b0),
        .BTN_DPAD_UP(1'b0), .BTN_MENU(1'b1), .BTN_SEL(1'b0),
        .BTN_START(1'b0), .menuDisabled(menuDisabled), .ADC_SEL(ADC_SEL),
        .hAdcReq_ext(hAdcReq_ext), .LCD_INIT_DONE(1'b1), .LCD_PWM(LCD_PWM),
        .LCD_BACKLIGHT_INIT(LCD_BACKLIGHT_INIT), .hAdcReady_r1(1'b0),
        .hAdcValue_r1(14'd0), .hButtons(9'd0), .MCU_buttons(MCU_buttons),
        .hVolume(7'd0), .pmic_sys_status(8'd0), .hHeadphones(1'b0),
        .gSecondEna(1'b0), .gHalfSecondEna(1'b0), .low_battery(low_battery),
        .LED_Green(LED_Green), .LED_Red(LED_Red), .LED_Yellow(LED_Yellow),
        .LED_White(LED_White), .system_control(system_control),
        .debug_system(debug_system), .paletteBGIn(paletteBGIn),
        .paletteOBJ0In(paletteOBJ0In), .paletteOBJ1In(paletteOBJ1In),
        .gbc_mode(1'b0), .gpd(64'd0), .uart_rx_data(uart_rx_data),
        .uart_rx_val(uart_rx_val), .uart_tx_busy(1'b0),
        .uart_tx_data(uart_tx_data), .uart_tx_val(uart_tx_val),
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
        .cart_stream_event_valid(cart_stream_event_valid),
        .cart_stream_event_ready(cart_stream_event_ready),
        .cart_stream_event_sequence(cart_stream_event_sequence),
        .cart_stream_event_crc32(cart_stream_event_crc32),
        .cart_stream_ack_valid(cart_stream_ack_valid),
        .cart_stream_ack_sequence(cart_stream_ack_sequence),
        .cart_session_active(cart_session_active),
        .audio_snapshot_toggle_x(audio_snapshot_toggle),
        .audio_snapshot_ready_x(audio_snapshot_ready),
        .audio_snapshot_status_x(audio_snapshot_status),
        .audio_snapshot_codec_x(audio_snapshot_codec)
    );

    function automatic [7:0] crc_byte;
        input [7:0] old_crc;
        input [7:0] data;
        integer i;
        reg [7:0] value;
        begin
            value = old_crc ^ data;
            for (i = 0; i < 8; i = i + 1)
                value = value[7] ? ({value[6:0], 1'b0} ^ 8'h1d)
                                 : {value[6:0], 1'b0};
            crc_byte = value;
        end
    endfunction

    task automatic send_byte;
        input [7:0] value;
        begin
            @(negedge clk);
            uart_rx_data = value;
            uart_rx_val = 1'b1;
            @(negedge clk);
            uart_rx_val = 1'b0;
            repeat (10) @(negedge clk);
        end
    endtask

    task automatic receive_byte;
        output [7:0] value;
        begin : wait_loop
            forever begin
                @(negedge clk);
                if (uart_tx_val) begin
                    value = uart_tx_data;
                    disable wait_loop;
                end
            end
        end
    endtask

    task automatic receive_cart_start;
        reg [7:0] value;
        reg [7:0] byte_count;
        integer skip;
        begin : search
            forever begin
                value = 8'h00;
                while (value != 8'h8f)
                    receive_byte(value);
                receive_byte(value);
                if (value == 8'h0a)
                    disable search;
                receive_byte(byte_count);
                for (skip = 0; skip < byte_count + 1; skip = skip + 1)
                    receive_byte(value);
            end
        end
    endtask

    task automatic receive_audio_packet;
        output [7:0] address;
        output [79:0] data;
        reg [7:0] value;
        reg [7:0] byte_count;
        integer byte_index;
        begin
            value = 8'h00;
            while (value != 8'h8f)
                receive_byte(value);
            receive_byte(address);
            receive_byte(byte_count);
            if (byte_count !== 8'd10)
                $fatal(1, "wrong audio diagnostic packet length");
            data = 80'd0;
            for (byte_index = 0; byte_index < 10; byte_index = byte_index + 1)
            begin
                receive_byte(value);
                data[79 - (byte_index * 8) -: 8] = value;
            end
            receive_byte(value);
    end
    endtask

    task automatic receive_stream_start;
        reg [7:0] value;
        reg [7:0] byte_count;
        integer skip;
        begin : search
            forever begin
                value = 8'h00;
                while (value != 8'h8f)
                    receive_byte(value);
                receive_byte(value);
                if (value == 8'h0d)
                    disable search;
                receive_byte(byte_count);
                for (skip = 0; skip < byte_count + 1; skip = skip + 1)
                    receive_byte(value);
            end
    end
    endtask

    task automatic receive_button_packet;
        output [7:0] high;
        output [7:0] low;
        reg [7:0] value;
        reg [7:0] byte_count;
        integer skip;
        begin : search
            forever begin
                value = 8'h00;
                while (value != 8'h8f)
                    receive_byte(value);
                receive_byte(value);
                receive_byte(byte_count);
                if (value == 8'h02 && byte_count == 8'h02) begin
                    receive_byte(high);
                    receive_byte(low);
                    receive_byte(value);
                    disable search;
                end
                for (skip = 0; skip < byte_count + 1; skip = skip + 1)
                    receive_byte(value);
            end
        end
    endtask

    reg [7:0] crc;
    reg [7:0] received;
    integer i;
    reg [7:0] payload [0:7];
    reg [7:0] audio_address_0;
    reg [7:0] audio_address_1;
    reg [79:0] audio_payload_0;
    reg [79:0] audio_payload_1;
    reg [7:0] button_high;
    reg [7:0] button_low;

    always @(posedge clk) begin
        if (reset)
            cart_response_valid <= 1'b0;
        else if (cart_request_valid && cart_request_ready) begin
            if (cart_request_operation !== expected_operation ||
                cart_request_tag !== expected_tag ||
                cart_request_address !== expected_address ||
                cart_request_value !== expected_value ||
                cart_request_aux_address !== expected_aux_address ||
                cart_request_aux_value !== expected_aux_value)
                $fatal(1, "decoded request fields are incorrect");
            cart_response_operation <= cart_request_operation;
            cart_response_tag <= cart_request_tag;
            cart_response_status <= 4'd0;
            cart_response_count <= 3'd4;
            cart_response_data <= 32'h44332211;
            cart_response_valid <= 1'b1;
        end else if (cart_response_ready)
            cart_response_valid <= 1'b0;
    end

    initial begin
        payload[0] = 8'h00;
        payload[1] = 8'h42;
        payload[2] = 8'h12;
        payload[3] = 8'h34;
        payload[4] = 8'h04;
        payload[5] = 8'h00;
        payload[6] = 8'h00;
        payload[7] = 8'h00;

        repeat (4) @(negedge clk);
        reset = 1'b0;
        repeat (4) @(negedge clk);

        crc = 8'hff;
        crc = crc_byte(crc, 8'h8f); send_byte(8'h8f);
        crc = crc_byte(crc, 8'h0e); send_byte(8'h0e);
        crc = crc_byte(crc, 8'h08); send_byte(8'h08);
        for (i = 0; i < 8; i = i + 1) begin
            crc = crc_byte(crc, payload[i]);
            send_byte(payload[i]);
        end
        fork
            begin
                repeat (2) @(negedge clk);
                send_byte(crc);
            end
            begin
                receive_cart_start();
                receive_byte(received); if (received !== 8'h08) $fatal(1, "wrong response length");
                receive_byte(received); if (received !== 8'h00) $fatal(1, "wrong response operation");
                receive_byte(received); if (received !== 8'h42) $fatal(1, "wrong response tag");
                receive_byte(received); if (received !== 8'h00) $fatal(1, "wrong response status");
                receive_byte(received); if (received !== 8'h04) $fatal(1, "wrong response count");
                receive_byte(received); if (received !== 8'h11) $fatal(1, "wrong response byte 0");
                receive_byte(received); if (received !== 8'h22) $fatal(1, "wrong response byte 1");
                receive_byte(received); if (received !== 8'h33) $fatal(1, "wrong response byte 2");
                receive_byte(received); if (received !== 8'h44) $fatal(1, "wrong response byte 3");
                receive_byte(received);
            end
            begin
                wait (cart_request_valid);
                repeat (4) begin
                    @(negedge clk);
                    if (!cart_request_valid)
                        $fatal(1, "request did not hold under back-pressure");
                    if (cart_request_operation !== 3'd0 ||
                        cart_request_tag !== 8'h42 ||
                        cart_request_address !== 16'h1234 ||
                        cart_request_value !== 8'h04)
                        $fatal(1, "held request fields changed");
                end
                cart_request_ready = 1'b1;
                @(negedge clk);
                cart_request_ready = 1'b0;
            end
        join

        wait (!cart_response_valid);

        expected_operation = 3'h7;
        expected_tag = 8'h43;
        expected_address = 16'h4000;
        expected_value = 8'h10;
        expected_aux_address = 16'h2000;
        expected_aux_value = 8'h05;
        payload[0] = 8'h07;
        payload[1] = expected_tag;
        payload[2] = expected_address[15:8];
        payload[3] = expected_address[7:0];
        payload[4] = expected_value;
        payload[5] = expected_aux_address[15:8];
        payload[6] = expected_aux_address[7:0];
        payload[7] = expected_aux_value;
        crc = 8'hff;
        crc = crc_byte(crc, 8'h8f); send_byte(8'h8f);
        crc = crc_byte(crc, 8'h0e); send_byte(8'h0e);
        crc = crc_byte(crc, 8'h08); send_byte(8'h08);
        for (i = 0; i < 8; i = i + 1) begin
            crc = crc_byte(crc, payload[i]);
            send_byte(payload[i]);
        end
        send_byte(crc);
        wait (cart_request_valid);
        if (cart_request_aux_address !== expected_aux_address ||
            cart_request_aux_value !== expected_aux_value)
            $fatal(1, "combined request auxiliary fields are incorrect");
        @(negedge clk);
        cart_request_ready = 1'b1;
        @(negedge clk);
        cart_request_ready = 1'b0;
        receive_cart_start();
        receive_byte(received);
        if (received !== 8'h08) $fatal(1, "wrong combined response length");
        for (i = 0; i < 9; i = i + 1)
            receive_byte(received);
        wait (!cart_response_valid);

        crc = 8'hff;
        crc = crc_byte(crc, 8'h8f); send_byte(8'h8f);
        crc = crc_byte(crc, 8'h10); send_byte(8'h10);
        crc = crc_byte(crc, 8'h01); send_byte(8'h01);
        crc = crc_byte(crc, 8'h7a); send_byte(8'h7a);
        fork
            send_byte(crc);
            begin
                wait (cart_stream_ack_valid);
                if (cart_stream_ack_sequence !== 8'h7a)
                    $fatal(1, "compact stream ACK sequence mismatch");
            end
        join

        cart_stream_event_sequence = 8'h7a;
        cart_stream_event_crc32 = 32'h44332211;
        cart_stream_event_valid = 1'b1;
        fork
            begin
                receive_stream_start();
                receive_byte(received); if (received !== 8'h01) $fatal(1, "wrong stream event length");
                receive_byte(received); if (received !== 8'h7a) $fatal(1, "wrong stream event sequence");
                receive_byte(received);
            end
            begin
                wait (cart_stream_event_ready);
                @(negedge clk);
                cart_stream_event_valid = 1'b0;
            end
        join

        force dut.menuDisabled = 1'b0;
        button_a = 1'b1;
        receive_button_packet(button_high, button_low);
        if (button_high !== 8'h00 || button_low !== 8'h08)
            $fatal(1, "button channel unavailable during maintenance");
        button_a = 1'b0;
        force dut.menuDisabled = 1'b1;
        repeat (200) @(negedge clk);

        crc = 8'hff;
        crc = crc_byte(crc, 8'h8f); send_byte(8'h8f);
        crc = crc_byte(crc, 8'h0f); send_byte(8'h0f);
        crc = crc_byte(crc, 8'h02); send_byte(8'h02);
        crc = crc_byte(crc, 8'h00); send_byte(8'h00);
        crc = crc_byte(crc, 8'h00); send_byte(8'h00);
        send_byte(crc);

        cart_session_active = 1'b0;
        audio_snapshot_status = 80'h01_a5_55_83_1122_3344_5566;
        audio_snapshot_codec = 80'h01_21_01_d4_1020_c0_80_09_00;
        audio_snapshot_ready = 1'b1;
        @(negedge clk);
        audio_snapshot_toggle = ~audio_snapshot_toggle;
        receive_audio_packet(audio_address_0, audio_payload_0);
        receive_audio_packet(audio_address_1, audio_payload_1);

        if (audio_address_0 === 8'h0b)
        begin
            if (audio_payload_0 !== audio_snapshot_status ||
                audio_address_1 !== 8'h0c ||
                audio_payload_1 !== audio_snapshot_codec)
                $fatal(1, "audio diagnostic payload/channel mismatch");
        end
        else if (audio_address_0 === 8'h0c)
        begin
            if (audio_payload_0 !== audio_snapshot_codec ||
                audio_address_1 !== 8'h0b ||
                audio_payload_1 !== audio_snapshot_status)
                $fatal(1, "audio diagnostic payload/channel mismatch");
        end
        else
            $fatal(1, "unexpected audio diagnostic channel");

        $display("PASS: UART cart response, stream channels, and audio boot channels");
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "timeout");
    end
endmodule
