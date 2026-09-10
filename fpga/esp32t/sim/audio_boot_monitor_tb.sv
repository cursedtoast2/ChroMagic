`timescale 1ns/1ps
`default_nettype none

module audio_boot_monitor_tb;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg aud_mclk = 1'b0;
    reg aud_bclk = 1'b0;
    reg aud_wclk = 1'b0;
    reg scl = 1'b1;
    reg sda = 1'b1;
    wire [79:0] status;
    wire [79:0] codec;
    wire snapshot_toggle;

    always #5 clk = ~clk;
    always #20 aud_mclk = ~aud_mclk;
    always #40 aud_bclk = ~aud_bclk;
    always #160 aud_wclk = ~aud_wclk;

    audio_boot_monitor #(
        .REFERENCE_WINDOW_CYCLES(128),
        .SNAPSHOT_WINDOWS(200)
    ) dut (
        .clk(clk),
        .reset(reset),
        .pll_lock(1'b1),
        .aud_reset(1'b1),
        .aud_mclk(aud_mclk),
        .aud_bclk(aud_bclk),
        .aud_wclk(aud_wclk),
        .i2c_scl(scl),
        .i2c_sda(sda),
        .volume(8'h42),
        .headphones(1'b1),
        .mute(1'b0),
        .snapshot_status(status),
        .snapshot_codec(codec),
        .snapshot_toggle(snapshot_toggle)
    );

    task automatic bus_wait;
    begin
        repeat (4) @(posedge clk);
    end
    endtask

    task automatic i2c_start;
    begin
        scl = 1'b1;
        sda = 1'b1;
        bus_wait();
        sda = 1'b0;
        bus_wait();
    end
    endtask

    task automatic i2c_bit;
        input value;
    begin
        scl = 1'b0;
        sda = value;
        bus_wait();
        scl = 1'b1;
        bus_wait();
    end
    endtask

    task automatic i2c_byte;
        input [7:0] value;
        input ack;
        integer index;
    begin
        for (index = 7; index >= 0; index = index - 1)
            i2c_bit(value[index]);
        i2c_bit(ack);
    end
    endtask

    task automatic i2c_stop;
    begin
        scl = 1'b0;
        sda = 1'b0;
        bus_wait();
        scl = 1'b1;
        bus_wait();
        sda = 1'b1;
        bus_wait();
    end
    endtask

    task automatic codec_write;
        input [7:0] address_value;
        input [7:0] data_value;
    begin
        i2c_start();
        i2c_byte(8'h30, 1'b0);
        i2c_byte(address_value, 1'b0);
        i2c_byte(data_value, 1'b0);
        i2c_stop();
    end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        reset = 1'b0;

        codec_write(8'h00, 8'h00);
        codec_write(8'h3f, 8'hd4);
        codec_write(8'h40, 8'h11);
        codec_write(8'h41, 8'h22);
        codec_write(8'h00, 8'h01);
        codec_write(8'h1f, 8'hc4);
        codec_write(8'h26, 8'h7f);
        codec_write(8'h2e, 8'h80);

        i2c_start();
        i2c_byte(8'h31, 1'b0);
        i2c_stop();

        i2c_start();
        i2c_byte(8'h30, 1'b1);
        i2c_stop();

        wait (snapshot_toggle);
        #1;
        if (status[79:72] !== 8'h01 || status[63:56] !== 8'h42)
            $fatal(1, "status identity/volume mismatch");
        if (!status[66] || !status[67])
            $fatal(1, "init or I2C error flag missing: %02x", status[71:64]);
        if (!status[55] || status[54:48] == 0)
            $fatal(1, "headphone/NACK count missing");
        if (status[47:32] == 0 || status[31:16] == 0 ||
            status[15:0] == 0)
            $fatal(1, "audio clock edge capture missing");
        if (codec[55:48] !== 8'hd4 || codec[47:40] !== 8'h11 ||
            codec[39:32] !== 8'h22 || codec[31:24] !== 8'hc4 ||
            codec[23:16] !== 8'h7f || codec[15:8] !== 8'h80)
            $fatal(1, "codec register reconstruction mismatch");

        $display("PASS: passive audio boot clock/I2C snapshot");
        $finish;
    end

    initial begin
        #1000000;
        $fatal(1, "timeout");
    end
endmodule

`default_nettype wire
