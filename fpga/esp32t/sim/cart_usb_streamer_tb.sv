`timescale 1ns/1ps
`default_nettype none

module cart_usb_streamer_tb;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg enabled = 1'b1;
    reg event_valid = 1'b0;
    reg [7:0] event_sequence = 8'd0;
    reg [1:0] block_ready = 2'b00;
    wire [10:0] ram_address;
    reg [7:0] ram_data;
    wire tx_valid;
    reg tx_ready = 1'b1;
    wire [7:0] tx_data;
    wire busy;
    wire event_complete;

    reg [7:0] memory [0:2047];
    reg [7:0] captured [0:4095];
    integer captured_count = 0;
    integer cycle_count = 0;
    integer i;

    always #5 clk = ~clk;
    always @(posedge clk)
    begin
        ram_data <= memory[ram_address];
        cycle_count <= cycle_count + 1;
        tx_ready <= (cycle_count % 7) != 3;
        if (tx_valid && tx_ready)
        begin
            captured[captured_count] <= tx_data;
            captured_count <= captured_count + 1;
        end
    end

    cart_usb_streamer dut (
        .clk(clk),
        .reset(reset),
        .enabled(enabled),
        .event_valid(event_valid),
        .event_sequence(event_sequence),
        .block_ready(block_ready),
        .ram_address(ram_address),
        .ram_data(ram_data),
        .tx_valid(tx_valid),
        .tx_ready(tx_ready),
        .tx_data(tx_data),
        .busy(busy),
        .event_complete(event_complete)
    );

    task automatic pulse_event;
        input [7:0] seq_value;
        begin
            @(negedge clk);
            event_sequence = seq_value;
            event_valid = 1'b1;
        end
    endtask

    initial begin
        for (i = 0; i < 2048; i = i + 1)
            memory[i] = i[7:0] ^ {7'd0, i[10]};

        repeat (4) @(posedge clk);
        reset = 1'b0;
        repeat (2) @(posedge clk);

        block_ready = 2'b11;
        pulse_event(8'h31);
        wait (busy);
        wait (!busy);
        @(negedge clk);
        if (!event_complete)
            $fatal(1, "event was not marked complete after two-block stream");
        event_valid = 1'b0;
        repeat (3) @(posedge clk);

        if (captured_count != 2048)
            $fatal(1, "two-block byte count %0d", captured_count);
        for (i = 0; i < 1024; i = i + 1)
            if (captured[i] !== memory[i])
                $fatal(1, "slot 0 mismatch at %0d", i);
        for (i = 0; i < 1024; i = i + 1)
            if (captured[1024 + i] !== memory[1024 + i])
                $fatal(1, "slot 1 mismatch at %0d", i);

        captured_count = 0;
        block_ready = 2'b01;
        pulse_event(8'h32);
        wait (busy);
        wait (!busy);
        @(negedge clk);
        event_valid = 1'b0;
        repeat (3) @(posedge clk);

        if (captured_count != 1024)
            $fatal(1, "single-block byte count %0d", captured_count);
        for (i = 0; i < 1024; i = i + 1)
            if (captured[i] !== memory[i])
                $fatal(1, "single-slot mismatch at %0d", i);

        $display("PASS: direct USB streamer preserves raw block order");
        $finish;
    end
endmodule

`default_nettype wire
