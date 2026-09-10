`timescale 1ns/1ps

module uart_packet_wrapper_tx_sleep_tb;
    reg clk=0, reset=1, write=0, menu_disabled=0;
    reg busy=0;
    integer busy_cycles=0;
    wire [7:0] data, position;
    wire valid, done;
    wire uart_busy=busy | valid;
    integer launched=0;
    reg [7:0] captured [0:63];
    always #5 clk=~clk;
    uart_packet_wrapper_tx dut(
        .clk(clk), .reset(reset), .uart_tx_busy(uart_busy),
        .uart_tx_data(data), .uart_tx_val(valid), .write_done(done),
        .write(write), .menuDisabled(menu_disabled), .uartDisabled(1'b0),
        .tx_address(7'h0a), .tx_byteCount(8'd4), .tx_bytepos(position),
        .tx_senddata(position ^ 8'h5a));
    always @(posedge clk) begin
        if (reset) begin busy<=0; busy_cycles=0; end
        else if (busy) begin
            if (busy_cycles==1) begin busy<=0; busy_cycles=0; end
            else busy_cycles=busy_cycles-1;
        end else if (valid) begin
            captured[launched]=data;
            launched=launched+1;
            busy<=1;
            busy_cycles=20;
        end
    end
    function automatic [7:0] crc_byte(input [7:0] old_crc, input [7:0] value);
        reg [7:0] crc;
        begin
            crc=old_crc ^ value;
            for (integer i=0; i<8; i=i+1)
                crc=crc[7] ? ((crc << 1) ^ 8'h1d) : (crc << 1);
            crc_byte=crc;
        end
    endfunction
    task automatic check_packet(input integer base);
        reg [7:0] crc;
        begin
            if (launched != base+29 || captured[base+21] !== 8'h8f ||
                captured[base+22] !== 8'h0a || captured[base+23] !== 8'd4)
                $fatal(1,"missing packet framing after wake preamble: count=%0d bytes=%02x/%02x/%02x",launched,captured[base+21],captured[base+22],captured[base+23]);
            for (integer i=0; i<4; i=i+1)
                if (captured[base+24+i] !== (8'h5a ^ i[7:0]))
                    $fatal(1,"wake packet payload mismatch");
            crc=8'hff;
            for (integer i=21; i<28; i=i+1) crc=crc_byte(crc,captured[base+i]);
            if (captured[base+28] !== crc) $fatal(1,"wake packet CRC mismatch");
        end
    endtask
    initial begin
        repeat (4) @(negedge clk);
        reset=0;
        repeat (3) @(negedge clk);
        write=1;
        menu_disabled=1;
        @(negedge clk); write=0;
        @(negedge clk);
        while (!done) @(negedge clk);
        check_packet(0);
        wait(dut.tx_state == 7);
        @(negedge clk); write=1;
        @(negedge clk); write=0;
        @(negedge clk);
        while (!done) @(negedge clk);
        check_packet(29);
        $display("PASS: maintenance launch at/during menu sleep preserves payload and CRC");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"packet lost at menu sleep: state=%0d launched=%0d",dut.tx_state,launched);
    end
endmodule
