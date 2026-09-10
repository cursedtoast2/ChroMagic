`timescale 1ns/1ps
`default_nettype none

module qspi_cart_block_tb;
    reg qspi_clk = 1'b0;
    reg qspi_cs = 1'b1;
    reg mcu_drive = 1'b0;
    reg [3:0] mcu_pins = 4'd0;

    tri qspi_mosi;
    tri qspi_miso;
    tri qspi_wp;
    tri qspi_hd;
    assign qspi_mosi = mcu_drive ? mcu_pins[0] : 1'bz;
    assign qspi_miso = mcu_drive ? mcu_pins[1] : 1'bz;
    assign qspi_wp   = mcu_drive ? mcu_pins[2] : 1'bz;
    assign qspi_hd   = mcu_drive ? mcu_pins[3] : 1'bz;

    wire q_menu_init;
    wire q_data_valid;
    wire [15:0] q_data;
    wire [31:0] q_address;
    wire [9:0] q_length;
    wire q_command;
    wire [10:0] cart_read_address;
    wire [10:0] cart_write_address;
    wire [7:0] cart_write_data;
    wire cart_write_enable;
    reg [7:0] cart_read_data = 8'd0;
    reg [7:0] memory [0:2047];

    QSPI_Slave dut (
        .QSPI_CLK(qspi_clk),
        .QSPI_CS(qspi_cs),
        .QSPI_MOSI(qspi_mosi),
        .QSPI_MISO(qspi_miso),
        .QSPI_WP(qspi_wp),
        .QSPI_HD(qspi_hd),
        .cartBlockReady(2'b11),
        .cartBlockSequence(16'ha55a),
        .cartBlockCRC32(64'h0badf00d78563412),
        .qCartReadData(cart_read_data),
        .qCartReadAddress(cart_read_address),
        .qCartWriteAddress(cart_write_address),
        .qCartWriteData(cart_write_data),
        .qCartWriteEnable(cart_write_enable),
        .virtualBlockReady(1'b0),
        .virtualBlockSequence(16'd0),
        .qVirtualReadData(8'd0),
        .qUploadBusy(1'b0),
        .qUploadCompletionSequence(8'd0),
        .qMenuInit(q_menu_init),
        .qDataValid(q_data_valid),
        .qData(q_data),
        .qAddress(q_address),
        .qLength(q_length),
        .qCommand(q_command)
    );

    always @(posedge qspi_clk) begin
        if (cart_write_enable)
            memory[cart_write_address] <= cart_write_data;
        cart_read_data <= memory[cart_read_address];
    end

    task automatic clock_single_bit;
        input bit_value;
    begin
        mcu_drive = 1'b1;
        mcu_pins = {3'd0, bit_value};
        #5 qspi_clk = 1'b1;
        #5 qspi_clk = 1'b0;
    end
    endtask

    task automatic clock_quad_nibble;
        input [3:0] value;
    begin
        mcu_drive = 1'b1;
        mcu_pins = value;
        #5 qspi_clk = 1'b1;
        #5 qspi_clk = 1'b0;
    end
    endtask

    task automatic send_header;
        input [10:0] command;
        input [31:0] address;
        integer i;
    begin
        qspi_cs = 1'b0;
        for (i = 10; i >= 0; i = i - 1)
            clock_single_bit(command[i]);
        for (i = 31; i >= 0; i = i - 1)
            clock_single_bit(address[i]);
    end
    endtask

    task automatic send_dummy;
        integer i;
    begin
        mcu_drive = 1'b0;
        for (i = 0; i < 3; i = i + 1)
        begin
            #5 qspi_clk = 1'b1;
            #5 qspi_clk = 1'b0;
        end
    end
    endtask

    task automatic receive_nibble;
        output [3:0] value;
    begin
        mcu_drive = 1'b0;
        #5 qspi_clk = 1'b1;
        value = {qspi_hd, qspi_wp, qspi_miso, qspi_mosi};
        #5 qspi_clk = 1'b0;
    end
    endtask

    task automatic receive_byte;
        output [7:0] value;
        reg [3:0] high_nibble;
        reg [3:0] low_nibble;
    begin
        receive_nibble(high_nibble);
        receive_nibble(low_nibble);
        value = {high_nibble, low_nibble};
    end
    endtask

    integer i;
    integer stock_word_count = 0;
    reg [7:0] received;

    always @(posedge qspi_clk)
        if (q_data_valid)
            stock_word_count = stock_word_count + 1;

    initial begin
        for (i = 0; i < 1024; i = i + 1)
        begin
            memory[i] = i[7:0] ^ 8'h5a;
            memory[1024 + i] = i[7:0] ^ 8'ha5;
        end

        #10;
        if (dut.qReadOutputEnable !== 1'b0)
            $fatal(1, "QSPI outputs driven while deselected");

        send_header(11'h154, 32'h43420000);
        send_dummy();
        repeat (4) begin
            receive_nibble(received[3:0]);
            if (dut.qReadOutputEnable)
                $fatal(1, "invalid read token drove QSPI pins");
        end
        qspi_cs = 1'b1;
        #10;

        stock_word_count = 0;
        send_header(11'h7ff, 32'h00000000);
        send_dummy();
        clock_quad_nibble(4'h1);
        clock_quad_nibble(4'h2);
        clock_quad_nibble(4'h3);
        clock_quad_nibble(4'h4);
        clock_quad_nibble(4'h5);
        clock_quad_nibble(4'h6);
        clock_quad_nibble(4'h7);
        clock_quad_nibble(4'h8);
        if (dut.qReadOutputEnable)
            $fatal(1, "stock framebuffer write enabled QSPI read drivers");
        qspi_cs = 1'b1;
        #10;
        if (stock_word_count == 0)
            $fatal(1, "stock write path produced no words");

        stock_word_count = 0;
        send_header(11'h7ff, 32'h80000000);
        send_dummy();
        for (i = 0; i < 1024; i = i + 1)
        begin
            clock_quad_nibble((i[7:0] ^ 8'h96) >> 4);
            clock_quad_nibble((i[7:0] ^ 8'h96) & 4'hf);
        end
        qspi_cs = 1'b1;
        #10;
        if (stock_word_count != 0)
            $fatal(1, "save-import write leaked into framebuffer writer");
        for (i = 0; i < 1024; i = i + 1)
            if (memory[i] !== (i[7:0] ^ 8'h96))
                $fatal(1, "save-import RAM byte %0d mismatch: %02x",
                       i, memory[i]);
        for (i = 0; i < 1024; i = i + 1)
            memory[i] = i[7:0] ^ 8'h5a;

        send_header(11'h155, 32'h43420000);
        send_dummy();
        receive_byte(received); if (received !== 8'h43) $fatal(1, "magic byte 0");
        receive_byte(received); if (received !== 8'h42) $fatal(1, "magic byte 1");
        receive_byte(received); if (received !== 8'h01) $fatal(1, "protocol");
        receive_byte(received); if (received !== 8'h01) $fatal(1, "ready status");
        receive_byte(received); if (received !== 8'h5a) $fatal(1, "sequence");
        receive_byte(received); if (received !== 8'h00) $fatal(1, "reserved");
        receive_byte(received); if (received !== 8'h00) $fatal(1, "length low");
        receive_byte(received); if (received !== 8'h04) $fatal(1, "length high");
        receive_byte(received); if (received !== 8'h12) $fatal(1, "CRC byte 0");
        receive_byte(received); if (received !== 8'h34) $fatal(1, "CRC byte 1");
        receive_byte(received); if (received !== 8'h56) $fatal(1, "CRC byte 2");
        receive_byte(received); if (received !== 8'h78) $fatal(1, "CRC byte 3");
        for (i = 0; i < 1024; i = i + 1)
        begin
            receive_byte(received);
            if (received !== (i[7:0] ^ 8'h5a))
                $fatal(1, "RAM byte %0d mismatch: %02x", i, received);
        end
        qspi_cs = 1'b1;
        #10;
        if (dut.qReadOutputEnable !== 1'b0 ||
            qspi_mosi !== 1'bz || qspi_miso !== 1'bz ||
            qspi_wp !== 1'bz || qspi_hd !== 1'bz)
            $fatal(1, "QSPI pins not high impedance after response");

        send_header(11'h155, 32'h43420400);
        send_dummy();
        receive_byte(received); if (received !== 8'h43) $fatal(1, "slot 1 magic byte 0");
        receive_byte(received); if (received !== 8'h42) $fatal(1, "slot 1 magic byte 1");
        receive_byte(received); if (received !== 8'h01) $fatal(1, "slot 1 protocol");
        receive_byte(received); if (received !== 8'h01) $fatal(1, "slot 1 ready status");
        receive_byte(received); if (received !== 8'ha5) $fatal(1, "slot 1 sequence");
        receive_byte(received); if (received !== 8'h00) $fatal(1, "slot 1 reserved");
        receive_byte(received); if (received !== 8'h00) $fatal(1, "slot 1 length low");
        receive_byte(received); if (received !== 8'h04) $fatal(1, "slot 1 length high");
        receive_byte(received); if (received !== 8'h0d) $fatal(1, "slot 1 CRC byte 0");
        receive_byte(received); if (received !== 8'hf0) $fatal(1, "slot 1 CRC byte 1");
        receive_byte(received); if (received !== 8'had) $fatal(1, "slot 1 CRC byte 2");
        receive_byte(received); if (received !== 8'h0b) $fatal(1, "slot 1 CRC byte 3");
        for (i = 0; i < 1024; i = i + 1)
        begin
            receive_byte(received);
            if (received !== (i[7:0] ^ 8'ha5))
                $fatal(1, "slot 1 RAM byte %0d mismatch: %02x", i, received);
        end
        qspi_cs = 1'b1;
        #10;
        if (dut.qReadOutputEnable !== 1'b0 ||
            qspi_mosi !== 1'bz || qspi_miso !== 1'bz ||
            qspi_wp !== 1'bz || qspi_hd !== 1'bz)
            $fatal(1, "QSPI pins not high impedance after slot 1 response");

        $display("PASS: physical cartridge QSPI transfers");
        $finish;
    end

    initial begin
        #500000;
        $fatal(1, "timeout");
    end
endmodule

`default_nettype wire
