`timescale 1ns/1ps

module uart_packet_wrapper_tx_tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset = 1'b1;
    reg write = 1'b0;
    reg [6:0] tx_address = 7'h0a;
    reg [7:0] tx_byteCount = 8'd2;
    wire [7:0] tx_bytepos;
    reg [7:0] first_data [0:1];
    reg [7:0] second_data [0:1];
    reg second_packet = 1'b0;
    wire [7:0] tx_senddata = second_packet
        ? second_data[tx_bytepos] : first_data[tx_bytepos];
    wire [7:0] uart_tx_data;
    wire uart_tx_val;
    wire write_done;
    reg transmitter_busy = 1'b0;
    wire uart_tx_busy = transmitter_busy | uart_tx_val;
    integer busy_cycles = 0;

    uart_packet_wrapper_tx dut(
        .clk(clk), .reset(reset), .uart_tx_busy(uart_tx_busy),
        .uart_tx_data(uart_tx_data), .uart_tx_val(uart_tx_val),
        .write_done(write_done), .write(write), .menuDisabled(1'b0),
        .uartDisabled(1'b0), .tx_address(tx_address),
        .tx_byteCount(tx_byteCount), .tx_bytepos(tx_bytepos),
        .tx_senddata(tx_senddata)
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

    reg [7:0] captured [0:11];
    integer captured_count = 0;
    integer cycle_count = 0;
    integer last_launch_cycle = -1000;
    always @(posedge clk) begin
        cycle_count = cycle_count + 1;
        if (reset) begin
            transmitter_busy <= 1'b0;
            busy_cycles = 0;
        end else if (transmitter_busy) begin
            if (busy_cycles == 1) begin
                transmitter_busy <= 1'b0;
                busy_cycles = 0;
            end else begin
                busy_cycles = busy_cycles - 1;
            end
        end else if (uart_tx_val) begin
            if (captured_count != 0 &&
                cycle_count - last_launch_cycle < 100)
                $fatal(1, "cartridge response byte launched without stop-bit guard");
            captured[captured_count] = uart_tx_data;
            captured_count = captured_count + 1;
            last_launch_cycle = cycle_count;
            transmitter_busy <= 1'b1;
            busy_cycles = 20;
        end
    end

    reg [7:0] expected_crc;
    integer packet;
    integer base;
    initial begin
        first_data[0] = 8'ha1;
        first_data[1] = 8'hb2;
        second_data[0] = 8'hc3;
        second_data[1] = 8'hd4;

        repeat (4) @(negedge clk);
        reset = 1'b0;
        @(negedge clk);
        write = 1'b1;
        @(negedge clk);
        write = 1'b0;

        @(posedge write_done);
        @(negedge clk);
        second_packet = 1'b1;
        tx_address = 7'h0a;
        write = 1'b1;
        wait (dut.tx_state == 4'd2);
        @(negedge clk);
        write = 1'b0;

        wait (captured_count == 12);
        for (packet = 0; packet < 2; packet = packet + 1) begin
            base = packet * 6;
            if (captured[base] !== 8'h8f) $fatal(1, "header mismatch");
            if (captured[base + 1] !== 8'h0a)
                $fatal(1, "address mismatch");
            if (captured[base + 2] !== 8'h02) $fatal(1, "length mismatch");
            expected_crc = 8'hff;
            expected_crc = crc_byte(expected_crc, captured[base]);
            expected_crc = crc_byte(expected_crc, captured[base + 1]);
            expected_crc = crc_byte(expected_crc, captured[base + 2]);
            expected_crc = crc_byte(expected_crc, captured[base + 3]);
            expected_crc = crc_byte(expected_crc, captured[base + 4]);
            if (captured[base + 5] !== expected_crc)
                $fatal(1, "packet %0d CRC mismatch: got %02x expected %02x",
                       packet, captured[base + 5], expected_crc);
        end
        $display("PASS: back-to-back UART packets independently initialize CRC");
        $finish;
    end

    initial begin
        #200000;
        $fatal(1, "timeout captured=%0d state=%0d busy=%0d idle_count=%0d second=%0d",
               captured_count, dut.tx_state, uart_tx_busy,
               dut.cart_uart_idle_count, second_packet);
    end
endmodule
