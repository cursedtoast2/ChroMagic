`timescale 1ns/1ps
`default_nettype none

module tlv320_synth_sequence_tb;
    reg hclk = 1'b0;
    reg reset = 1'b1;
    reg i2c_busy = 1'b0;
    wire init_done;
    wire i2c_enable;
    wire [6:0] register_address;
    wire [7:0] write_data;
    wire device_address_bit4;

    integer transaction_count = 0;
    reg enable_d = 1'b0;

    GSR GSR (.GSRI(1'b1));

    always #10 hclk = ~hclk;

    tlv320_init dut (
        .hClk(hclk),
        .n1221_6(reset),
        .i2c_busy(i2c_busy),
        .tlv320_init_done_Z(init_done),
        .tlv320_i2c_enable(i2c_enable),
        .tlv320_i2c_register_address(register_address),
        .tlv320_i2c_mosi_data(write_data),
        .tlv320_i2c_device_address(device_address_bit4)
    );

    always @(posedge hclk)
    begin
        enable_d <= i2c_enable;
        if (reset)
            i2c_busy <= 1'b0;
        else if (i2c_enable && !enable_d && !i2c_busy)
        begin
            transaction_count <= transaction_count + 1;
            $display("TLV_TX index=%0d reg=%02x data=%02x",
                     transaction_count, {1'b0, register_address}, write_data);
            i2c_busy <= 1'b1;
        end
        else if (i2c_busy)
            i2c_busy <= 1'b0;
    end

    initial
    begin
        repeat (4) @(posedge hclk);
        reset = 1'b0;
        wait (init_done);
        repeat (4) @(posedge hclk);
        if (transaction_count != 65)
            $fatal(1, "expected 65 synthesized writes, got %0d",
                   transaction_count);
        $display("PASS: synthesized initializer performs %0d writes",
                 transaction_count);
        $finish;
    end

    initial
    begin
        #1000000;
        $fatal(1, "timeout");
    end
endmodule

`default_nettype wire
