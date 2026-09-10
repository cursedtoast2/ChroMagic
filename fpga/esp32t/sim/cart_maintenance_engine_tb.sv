`timescale 1ns/1ps
`default_nettype none

module cart_maintenance_engine_tb #(parameter READ_RECOVERY_TEST = 1);
    localparam [2:0] OP_PING       = 3'h0;
    localparam [2:0] OP_ENTER      = 3'h1;
    localparam [2:0] OP_READ_BLOCK = 3'h2;
    localparam [2:0] OP_WRITE      = 3'h3;
    localparam [2:0] OP_EXIT       = 3'h4;
    localparam [2:0] OP_ACK        = 3'h5;
    localparam [2:0] OP_READ_RANGE = 3'h6;
    localparam [2:0] OP_WRITE_READ_RANGE = 3'h7;

    localparam [3:0] STATUS_OK             = 4'h0;
    localparam [3:0] STATUS_NOT_ACTIVE     = 4'h2;
    localparam [3:0] STATUS_ALREADY_ACTIVE = 4'h3;
    localparam [3:0] STATUS_NO_CARTRIDGE   = 4'h5;
    localparam [3:0] STATUS_ADDRESS_WRAP   = 4'h6;
    localparam [3:0] STATUS_BLOCK_BUSY      = 4'h7;
    localparam [3:0] STATUS_SEQUENCE        = 4'h8;

    reg clk = 1'b0;
    reg reset = 1'b1;
    reg cart_present = 1'b1;
    reg request_valid = 1'b0;
    wire request_ready;
    reg [2:0] request_operation = OP_PING;
    reg [7:0] request_tag = 8'd0;
    reg [15:0] request_address = 16'd0;
    reg [7:0] request_value = 8'd0;
    reg [15:0] request_aux_address = 16'd0;
    reg [7:0] request_aux_value = 8'd0;
    wire response_valid;
    reg response_ready = 1'b0;
    wire [2:0] response_operation;
    wire [7:0] response_tag;
    wire [3:0] response_status;
    wire [2:0] response_count;
    wire [31:0] response_data;
    wire block_write;
    wire [10:0] block_write_address;
    wire [7:0] block_write_data;
    reg [7:0] block_read_data = 8'd0;
    wire [1:0] block_ready;
    wire [15:0] block_sequence;
    wire [63:0] block_crc32;
    wire pc_usb_mode;
    wire stream_event_valid;
    reg stream_event_ready = 1'b0;
    wire [7:0] stream_event_sequence;
    wire [31:0] stream_event_crc32;
    reg stream_ack_valid = 1'b0;
    reg [7:0] stream_ack_sequence = 8'd0;
    wire active;
    reg ownership_ack_meta = 1'b0;
    reg ownership_ack = 1'b0;
    wire [15:0] cart_address;
    wire cart_clock;
    wire cart_cs_n;
    wire cart_read_n;
    wire cart_write_n;
    wire [7:0] cart_data_out;
    wire cart_data_oe;
    reg [7:0] staged_block [0:2047];
    reg flash_model = 0;
    reg flash_buffer_model = 0;
    reg flash_stuck = 0;
    integer flash_page_size = 32;
    integer flash_writes = 0;
    integer flash_busy = 0;
    integer flash_last = 0;
    reg [7:0] flash_memory [0:1023];
    reg [7:0] flash_read_data = 8'hff;
    wire [7:0] cart_data_in = !flash_model ? (cart_address[7:0] ^ 8'ha5) :
        flash_read_data;

    always @(negedge cart_read_n) if (flash_model)
        flash_read_data <= (flash_busy != 0 || flash_stuck)
            ? (staged_block[flash_last] ^ 8'h80)
            : flash_memory[cart_address[9:0]];

    always #5 clk = ~clk;

    cart_maintenance_engine #(
        .ADDRESS_SETUP_CYCLES(2),
        .READ_STROBE_CYCLES(4),
        .WRITE_LOW_CYCLES(2),
        .WRITE_CLOCK_HIGH_CYCLES(1),
        .WRITE_RECOVERY_CYCLES(2),
        .READ_RECOVERY_CYCLES(READ_RECOVERY_TEST),
        .WATCHDOG_CYCLES(64),
        .FLASH_POLL_CYCLES(32)
    ) dut (
        .clk(clk),
        .reset(reset),
        .cart_present(cart_present),
        .request_valid(request_valid),
        .request_ready(request_ready),
        .request_operation(request_operation),
        .request_tag(request_tag),
        .request_address(request_address),
        .request_value(request_value),
        .request_aux_address(request_aux_address),
        .request_aux_value(request_aux_value),
        .response_valid(response_valid),
        .response_ready(response_ready),
        .response_operation(response_operation),
        .response_tag(response_tag),
        .response_status(response_status),
        .response_count(response_count),
        .response_data(response_data),
        .block_write(block_write),
        .block_write_address(block_write_address),
        .block_write_data(block_write_data),
        .block_read_data(block_read_data),
        .block_ready(block_ready),
        .block_sequence(block_sequence),
        .block_crc32(block_crc32),
        .pc_usb_mode(pc_usb_mode),
        .stream_event_valid(stream_event_valid),
        .stream_event_ready(stream_event_ready),
        .stream_event_sequence(stream_event_sequence),
        .stream_event_crc32(stream_event_crc32),
        .stream_ack_valid(stream_ack_valid),
        .stream_ack_sequence(stream_ack_sequence),
        .active(active),
        .ownership_ack(ownership_ack),
        .cart_address(cart_address),
        .cart_clock(cart_clock),
        .cart_cs_n(cart_cs_n),
        .cart_read_n(cart_read_n),
        .cart_write_n(cart_write_n),
        .cart_data_out(cart_data_out),
        .cart_data_oe(cart_data_oe),
        .cart_data_in(cart_data_in)
    );

    always @(posedge clk or posedge reset)
    begin
        if (reset)
        begin
            ownership_ack_meta <= 1'b0;
            ownership_ack <= 1'b0;
        end
        else
        begin
            ownership_ack_meta <= active;
            ownership_ack <= ownership_ack_meta;
        end
    end

    task automatic send_request;
        input [2:0] operation;
        input [7:0] tag;
        input [15:0] address;
        input [7:0] value;
    begin
        while (!request_ready) @(posedge clk);
        @(negedge clk);
        request_operation = operation;
        request_tag       = tag;
        request_address   = address;
        request_value     = value;
        request_aux_address = 16'd0;
        request_aux_value = 8'd0;
        request_valid     = 1'b1;
        @(negedge clk);
        request_valid     = 1'b0;
    end
    endtask

    task automatic send_write_range_request;
        input [7:0] tag;
        input [15:0] read_address;
        input [7:0] count;
        input [15:0] write_address;
        input [7:0] write_value;
    begin
        while (!request_ready) @(posedge clk);
        @(negedge clk);
        request_operation = OP_WRITE_READ_RANGE;
        request_tag = tag;
        request_address = read_address;
        request_value = count;
        request_aux_address = write_address;
        request_aux_value = write_value;
        request_valid = 1'b1;
        @(negedge clk);
        request_valid = 1'b0;
    end
    endtask

    task automatic expect_response;
        input [2:0] operation;
        input [7:0] tag;
        input [3:0] status;
        input [2:0] count;
        input [31:0] data;
    begin
        while (!response_valid) @(posedge clk);
        if (response_operation !== operation) $fatal(1, "operation mismatch");
        if (response_tag !== tag) $fatal(1, "tag mismatch");
        if (response_status !== status) $fatal(1, "status mismatch: %0d", response_status);
        if (response_count !== count) $fatal(1, "count mismatch: %0d", response_count);
        if (response_data !== data) $fatal(1, "data mismatch: %08x", response_data);
        @(negedge clk);
        response_ready = 1'b1;
        @(negedge clk);
        response_ready = 1'b0;
    end
    endtask

    task automatic expect_stream_event;
        input [7:0] expected_sequence;
    begin
        while (!stream_event_valid) @(posedge clk);
        if (stream_event_sequence !== expected_sequence)
            $fatal(1, "stream sequence mismatch: %02x", stream_event_sequence);
        if (!block_ready[expected_sequence[0]])
            $fatal(1, "stream event references an unready slot");
        if (block_sequence[expected_sequence[0] * 8 +: 8] !==
            expected_sequence)
            $fatal(1, "stream slot sequence mismatch");
        if (block_crc32[expected_sequence[0] * 32 +: 32] !==
            stream_event_crc32)
            $fatal(1, "stream UART/QSPI CRC metadata mismatch");
        case (expected_sequence)
            8'h71: if (stream_event_crc32 !== 32'haa140b0d)
                $fatal(1, "stream CRC differs from zlib reference");
            8'h72: if (stream_event_crc32 !== 32'h2a080d11)
                $fatal(1, "stream CRC differs from zlib reference");
            8'h34: if (stream_event_crc32 !== 32'h60121684)
                $fatal(1, "stream CRC differs from zlib reference");
        endcase
        @(negedge clk);
        stream_event_ready = 1'b1;
        @(negedge clk);
        stream_event_ready = 1'b0;
    end
    endtask

    task automatic send_stream_ack;
        input [7:0] ack_sequence;
    begin
        @(negedge clk);
        stream_ack_sequence = ack_sequence;
        stream_ack_valid = 1'b1;
        @(negedge clk);
        stream_ack_valid = 1'b0;
    end
    endtask

    task automatic expect_safe_bus;
    begin
        if (cart_cs_n !== 1'b1) $fatal(1, "CS not safe");
        if (cart_read_n !== 1'b1) $fatal(1, "RD not safe");
        if (cart_write_n !== 1'b1) $fatal(1, "WR not safe");
        if (cart_data_oe !== 1'b0) $fatal(1, "data bus still driven");
    end
    endtask

    integer low_cycles;
    integer setup_cycles;
    integer recovery_cycles;
    reg saw_clock_high_while_write;
    integer block_write_count = 0;
    reg check_staged_write = 1'b0;
    integer physical_write_count = 0;

    always @(posedge clk)
    begin
        block_read_data <= staged_block[block_write_address];
        if (check_staged_write && !cart_write_n && cart_clock)
        begin
            if (cart_address !== (16'ha000 + physical_write_count))
                $fatal(1, "staged write address %0d mismatch: %04x",
                       physical_write_count, cart_address);
            if (cart_data_out !== (physical_write_count[7:0] ^ 8'h6c))
                $fatal(1, "staged write byte %0d mismatch: %02x",
                       physical_write_count, cart_data_out);
            physical_write_count = physical_write_count + 1;
        end
    end

    always @(negedge clk)
    begin
        if (block_write)
        begin
            if (block_write_address[9:0] !== block_write_count[9:0])
                $fatal(1, "non-sequential block RAM write address");
            staged_block[block_write_address] = block_write_data;
            block_write_count = block_write_count + 1;
        end
    end

    always @(posedge clk) if (flash_busy > 0) flash_busy <= flash_busy - 1;
    integer flash_step;
    integer flash_offset;
    reg [15:0] expected_flash_address;
    reg [7:0] expected_flash_data;
    always @(posedge cart_write_n) if (flash_model && !reset) begin
        if (!cart_data_oe || !cart_cs_n || !cart_read_n)
            $fatal(1, "flash write bus direction/CS/RD");
        if (flash_busy != 0) $fatal(1, "new write before flash completed");
        flash_step = flash_writes % (flash_buffer_model ? (flash_page_size + 5) : 4);
        flash_offset = flash_buffer_model ? (flash_writes / (flash_page_size + 5)) * flash_page_size : flash_writes / 4;
        expected_flash_address = 16'h4000 + flash_offset;
        case (flash_step)
            0: begin expected_flash_address = 16'h0aaa; expected_flash_data = 8'haa; end
            1: begin expected_flash_address = 16'h0555; expected_flash_data = 8'h55; end
            2: begin
                expected_flash_data = flash_buffer_model ? 8'h25 : 8'ha0;
                if (!flash_buffer_model) expected_flash_address = 16'h0aaa;
            end
            default: begin
                if (flash_buffer_model && flash_step == 3)
                    expected_flash_data = flash_page_size - 1;
                else if (flash_buffer_model && flash_step == flash_page_size + 4) begin
                    expected_flash_data = 8'h29;
                    flash_busy <= 16;
                end else begin
                    if (flash_buffer_model) flash_offset = flash_offset + flash_step - 4;
                    expected_flash_address = 16'h4000 + flash_offset;
                    expected_flash_data = staged_block[flash_offset];
                    flash_memory[flash_offset] = expected_flash_data;
                    flash_last = flash_offset;
                    if (!flash_buffer_model) flash_busy <= 16;
                end
            end
        endcase
        if (cart_address !== expected_flash_address || cart_data_out !== expected_flash_data)
            $fatal(1, "flash write %0d: got %04x/%02x expected %04x/%02x",
                   flash_writes, cart_address, cart_data_out, expected_flash_address, expected_flash_data);
        flash_writes = flash_writes + 1;
    end

    task automatic exercise_flash(input bit buffered_mode, input integer page_size);
    begin
        for (integer i=0; i<1024; i=i+1) begin
            staged_block[i] = i[7:0] ^ 8'h6c;
            flash_memory[i] = 8'hff;
        end
        flash_model = 1;
        flash_buffer_model = buffered_mode;
        flash_page_size = page_size;
        flash_writes = 0;
        flash_busy = 0;
        send_request(OP_READ_RANGE, 8'h60, 16'h4000, buffered_mode ? (page_size == 256 ? 8'h85 : 8'h83) : 8'h82);
        expect_response(OP_READ_RANGE, 8'h60, STATUS_OK, 0, 0);
        if (flash_writes != (buffered_mode ? (1024 + 5 * (1024 / page_size)) : 4096))
            $fatal(1, "flash command count %0d", flash_writes);
        for (integer i=0; i<1024; i=i+1)
            if (flash_memory[i] !== staged_block[i]) $fatal(1, "flash data %0d", i);
        flash_model = 0;
        expect_safe_bus();
    end
    endtask

    initial begin
        $dumpfile("/tmp/cart_maintenance_engine_tb.vcd");
        $dumpvars(0, cart_maintenance_engine_tb);

        repeat (3) @(posedge clk);
        reset = 1'b0;
        @(posedge clk);
        expect_safe_bus();
        if (active !== 1'b0) $fatal(1, "active after reset");

        send_request(OP_PING, 8'h01, 16'd0, 8'd0);
        while (!response_valid) @(posedge clk);
        repeat (3) begin
            @(posedge clk);
            if (!response_valid) $fatal(1, "response did not hold under back-pressure");
            if (request_ready) $fatal(1, "request accepted with response pending");
            if (response_tag !== 8'h01) $fatal(1, "held response changed");
        end
        expect_response(OP_PING, 8'h01, STATUS_OK, 3'd4, 32'h0a030200);

        send_request(OP_READ_BLOCK, 8'h10, 16'h0100, 8'd0);
        expect_response(OP_READ_BLOCK, 8'h10, STATUS_NOT_ACTIVE, 3'd0, 32'd0);

        cart_present = 1'b0;
        send_request(OP_ENTER, 8'h11, 16'd0, 8'd0);
        expect_response(OP_ENTER, 8'h11, STATUS_NO_CARTRIDGE, 3'd0, 32'd0);
        cart_present = 1'b1;

        send_request(OP_ENTER, 8'h12, 16'd0, 8'd1);
        expect_response(OP_ENTER, 8'h12, STATUS_OK, 3'd0, 32'd0);
        if (active !== 1'b1) $fatal(1, "acquire did not assert active");
        if (pc_usb_mode !== 1'b1) $fatal(1, "PC USB mode did not latch");
        expect_safe_bus();

        send_request(OP_ENTER, 8'h12, 16'd0, 8'd0);
        expect_response(OP_ENTER, 8'h12, STATUS_OK, 3'd0, 32'd0);
        send_request(OP_ENTER, 8'h13, 16'd0, 8'd0);
        expect_response(OP_ENTER, 8'h13, STATUS_ALREADY_ACTIVE, 3'd0, 32'd0);

        send_request(OP_READ_BLOCK, 8'h14, 16'hfc01, 8'd0);
        expect_response(OP_READ_BLOCK, 8'h14, STATUS_ADDRESS_WRAP, 3'd0, 32'd0);
        expect_safe_bus();

        block_write_count = 0;
        send_request(OP_READ_BLOCK, 8'h20, 16'h0100, 8'd0);
        setup_cycles = 0;
        while (cart_read_n) begin
            setup_cycles = setup_cycles + 1;
            @(posedge clk);
        end
        if (setup_cycles < 2) $fatal(1, "read address setup too short: %0d", setup_cycles);
        if (cart_address !== 16'h0100) $fatal(1, "first read address wrong");
        if (cart_cs_n !== 1'b1) $fatal(1, "ROM read asserted RAM CS");
        if (cart_data_oe !== 1'b0) $fatal(1, "read drove data bus");
        low_cycles = 0;
        while (!cart_read_n) begin
            low_cycles = low_cycles + 1;
            @(posedge clk);
        end
        if (low_cycles < 4) $fatal(1, "read strobe too short: %0d", low_cycles);
        expect_response(OP_READ_BLOCK, 8'h20, STATUS_OK, 3'd4, 32'hd6372151);
        if (block_write_count != 1024) $fatal(1, "wrong staged byte count: %0d", block_write_count);
        if (!block_ready[0] || block_sequence[7:0] !== 8'h20 ||
            block_crc32[31:0] !== 32'hd6372151)
            $fatal(1, "completion metadata mismatch");
        if (staged_block[0] !== 8'ha5 || staged_block[1] !== 8'ha4 ||
            staged_block[1023] !== 8'h5a)
            $fatal(1, "staged block data mismatch");
        expect_safe_bus();

        send_request(OP_READ_BLOCK, 8'h20, 16'h0100, 8'd0);
        expect_response(OP_READ_BLOCK, 8'h20, STATUS_OK, 3'd4, 32'hd6372151);
        if (block_write_count != 1024)
            $fatal(1, "duplicate READ_BLOCK rewrote staging RAM");

        send_request(OP_READ_BLOCK, 8'h21, 16'h0400, 8'd0);
        expect_response(OP_READ_BLOCK, 8'h21, STATUS_BLOCK_BUSY, 3'd0, 32'd0);
        send_request(OP_ACK, 8'h22, 16'd0, 8'h1f);
        expect_response(OP_ACK, 8'h22, STATUS_SEQUENCE, 3'd0, 32'd0);
        if (!block_ready[0]) $fatal(1, "wrong ACK released block");
        send_request(OP_ACK, 8'h23, 16'd0, 8'h20);
        expect_response(OP_ACK, 8'h23, STATUS_OK, 3'd0, 32'd0);
        if (block_ready[0]) $fatal(1, "matching ACK did not release block");
        send_request(OP_ACK, 8'h23, 16'd0, 8'h20);
        expect_response(OP_ACK, 8'h23, STATUS_OK, 3'd0, 32'd0);

        block_write_count = 0;
        send_request(OP_READ_RANGE, 8'h70, 16'h4000, 8'd3);
        expect_response(OP_READ_RANGE, 8'h70, STATUS_OK, 3'd0, 32'd0);
        expect_stream_event(8'h71);
        if (block_write_count != 2048 || block_ready != 2'b11 ||
            block_sequence[7:0] !== 8'h70 ||
            block_sequence[15:8] !== 8'h71)
            $fatal(1, "range did not fill both slots: %0d", block_write_count);
        repeat (50) @(posedge clk);
        if (block_write_count != 2048)
            $fatal(1, "range overwrote an unacknowledged slot");

        send_stream_ack(8'h71);
        if (block_ready != 2'b00)
            $fatal(1, "cumulative ACK did not release both slots");
        expect_stream_event(8'h72);
        if (block_write_count != 3072 || !block_ready[0] ||
            block_sequence[7:0] !== 8'h72)
            $fatal(1, "range did not refill released slot zero");
        send_request(OP_WRITE, 8'h30, 16'h2000, 8'h5a);
        while (!cart_data_oe) @(posedge clk);
        if (cart_address !== 16'h2000) $fatal(1, "write address wrong");
        if (cart_data_out !== 8'h5a) $fatal(1, "write data wrong");
        setup_cycles = 0;
        while (cart_write_n) begin
            setup_cycles = setup_cycles + 1;
            @(posedge clk);
        end
        if (setup_cycles < 2) $fatal(1, "write address setup too short: %0d", setup_cycles);
        if (cart_cs_n !== 1'b1) $fatal(1, "mapper write asserted RAM CS");
        low_cycles = 0;
        saw_clock_high_while_write = 1'b0;
        while (!cart_write_n) begin
            low_cycles = low_cycles + 1;
            if (cart_clock) saw_clock_high_while_write = 1'b1;
            @(posedge clk);
        end
        if (low_cycles < 3) $fatal(1, "write pulse too short: %0d", low_cycles);
        if (!saw_clock_high_while_write) $fatal(1, "CLK did not rise before WR release");
        recovery_cycles = 0;
        while (cart_data_oe) begin
            recovery_cycles = recovery_cycles + 1;
            @(posedge clk);
        end
        if (recovery_cycles < 2) $fatal(1, "write recovery too short: %0d", recovery_cycles);
        expect_response(OP_WRITE, 8'h30, STATUS_OK, 3'd0, 32'd0);
        if (block_ready != 2'b00)
            $fatal(1, "next request did not commit completed range");
        expect_safe_bus();

        for (block_write_count = 0; block_write_count < 512;
             block_write_count = block_write_count + 1)
            staged_block[block_write_count] = block_write_count[7:0] ^ 8'h6c;
        physical_write_count = 0;
        check_staged_write = 1'b1;
        send_request(OP_READ_RANGE, 8'h31, 16'ha000, 8'h80);
        expect_response(OP_READ_RANGE, 8'h31, STATUS_OK, 3'd0, 32'd0);
        check_staged_write = 1'b0;
        if (physical_write_count != 512)
            $fatal(1, "wrong staged physical write count: %0d",
                   physical_write_count);
        expect_safe_bus();

        for (block_write_count = 0; block_write_count < 1024;
             block_write_count = block_write_count + 1)
            staged_block[block_write_count] = block_write_count[7:0] ^ 8'h6c;
        physical_write_count = 0;
        check_staged_write = 1'b1;
        send_request(OP_READ_RANGE, 8'h32, 16'ha000, 8'h81);
        expect_response(OP_READ_RANGE, 8'h32, STATUS_OK, 3'd0, 32'd0);
        check_staged_write = 1'b0;
        if (physical_write_count != 1024)
            $fatal(1, "wrong full staged physical write count: %0d",
                   physical_write_count);
        expect_safe_bus();

        block_write_count = 0;
        send_write_range_request(8'h34, 16'h8000, 8'd1,
                                 16'h2000, 8'h33);
        while (!cart_data_oe) @(posedge clk);
        if (cart_address !== 16'h2000 || cart_data_out !== 8'h33)
            $fatal(1, "combined mapper write fields wrong");
        expect_response(OP_WRITE_READ_RANGE, 8'h34,
                        STATUS_OK, 3'd0, 32'd0);
        expect_stream_event(8'h34);
        if (block_write_count != 1024)
            $fatal(1, "combined request did not stage its range");

        send_request(OP_EXIT, 8'h40, 16'd0, 8'd0);
        if (active !== 1'b0) $fatal(1, "release request did not drop active");
        while (ownership_ack) begin
            @(posedge clk);
            expect_safe_bus();
        end
        expect_response(OP_EXIT, 8'h40, STATUS_OK, 3'd0, 32'd0);
        if (active !== 1'b0) $fatal(1, "release left ownership active");
        if (pc_usb_mode !== 1'b0) $fatal(1, "PC USB mode survived release");
        expect_safe_bus();

        send_request(OP_ENTER, 8'h50, 16'd0, 8'd0);
        expect_response(OP_ENTER, 8'h50, STATUS_OK, 3'd0, 32'd0);
        repeat (80) @(posedge clk);
        if (active !== 1'b0) $fatal(1, "watchdog did not release ownership");
        expect_safe_bus();

        send_request(OP_ENTER, 8'h60, 16'd0, 8'd0);
        expect_response(OP_ENTER, 8'h60, STATUS_OK, 3'd0, 32'd0);
        cart_present = 1'b0;
        while (active) @(posedge clk);
        while (ownership_ack) @(posedge clk);
        if (active !== 1'b0) $fatal(1, "removal did not release ownership");
        expect_safe_bus();
        expect_response(OP_ENTER, 8'h60, STATUS_NO_CARTRIDGE, 3'd0, 32'd0);

        cart_present = 1;
        send_request(OP_ENTER, 8'h5f, 0, 0);
        expect_response(OP_ENTER, 8'h5f, STATUS_OK, 0, 0);
        exercise_flash(0, 32);
        exercise_flash(1, 32);
        exercise_flash(1, 256);
        send_request(OP_READ_RANGE, 8'h61, 16'h4001, 8'h83);
        expect_response(OP_READ_RANGE, 8'h61, 4, 0, 0);
        send_request(OP_READ_RANGE, 8'h62, 16'ha000, 8'h82);
        expect_response(OP_READ_RANGE, 8'h62, 4, 0, 0);
        flash_model = 1;
        flash_buffer_model = 0;
        flash_writes = 0;
        flash_stuck = 1;
        send_request(OP_READ_RANGE, 8'h63, 16'h4000, 8'h82);
        expect_response(OP_READ_RANGE, 8'h63, 10, 0, 0);
        if (flash_writes != 4) $fatal(1, "timeout repeated a flash command");
        expect_safe_bus();
        if (!active) $fatal(1, "flash error released PC ownership");
        flash_model = 0;
        flash_stuck = 0;

        send_request(OP_EXIT, 8'h70, 0, 0);
        expect_response(OP_EXIT, 8'h70, STATUS_OK, 0, 0);
        cart_present = 0;
        send_request(OP_ENTER, 8'h71, 0, 3);
        expect_response(OP_ENTER, 8'h71, STATUS_OK, 0, 0);
        if (!pc_usb_mode) $fatal(1, "SD did not select USB bulk");
        send_request(OP_WRITE, 8'h72, 16'ha000, 8'hff);
        expect_response(OP_WRITE, 8'h72, STATUS_NO_CARTRIDGE, 0, 0);
        send_request(OP_READ_RANGE, 8'h73, 8'hfe, 8'h84);
        expect_response(OP_READ_RANGE, 8'h73, STATUS_OK, 0, 0);
        expect_stream_event(8'hfe);
        expect_safe_bus();
        if (block_ready != 1) $fatal(1, "SD published wrong slot");
        send_request(OP_READ_RANGE, 8'h74, 0, 8'h84);
        expect_response(OP_READ_RANGE, 8'h74, STATUS_BLOCK_BUSY, 0, 0);
        send_request(OP_ACK, 8'h75, 0, 8'hfe);
        expect_response(OP_ACK, 8'h75, STATUS_OK, 0, 0);
        send_request(OP_READ_RANGE, 8'h76, 0, 8'h84);
        expect_response(OP_READ_RANGE, 8'h76, STATUS_OK, 0, 0);
        expect_stream_event(0);
        expect_safe_bus();
        repeat (80) @(posedge clk);
        if (active || pc_usb_mode || block_ready != 0)
            $fatal(1, "SD watchdog did not clean up");
        cart_present = 1;
        send_request(OP_ENTER, 8'h77, 0, 1);
        expect_response(OP_ENTER, 8'h77, STATUS_OK, 0, 0);
        send_request(OP_WRITE, 8'h78, 16'h2000, 1);
        expect_response(OP_WRITE, 8'h78, STATUS_OK, 0, 0);

        $display("PASS: cart_maintenance_engine safety and timing tests");
        $finish;
    end

endmodule

`default_nettype wire
