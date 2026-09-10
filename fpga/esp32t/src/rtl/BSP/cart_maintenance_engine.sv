`timescale 1ns/1ps
`default_nettype none

module cart_maintenance_engine #(
    parameter integer ADDRESS_SETUP_CYCLES     = 2,
    parameter integer READ_STROBE_CYCLES       = 4,
    parameter integer WRITE_LOW_CYCLES         = 2,
    parameter integer WRITE_CLOCK_HIGH_CYCLES  = 1,
    parameter integer WRITE_RECOVERY_CYCLES    = 2,
    parameter integer READ_RECOVERY_CYCLES     = 1,
    parameter integer WATCHDOG_CYCLES          = 83_886_080,
    parameter integer FLASH_POLL_CYCLES        = 838_861
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        cart_present,

    input  wire        request_valid,
    output wire        request_ready,
    input  wire [2:0]  request_operation,
    input  wire [7:0]  request_tag,
    input  wire [15:0] request_address,
    input  wire [7:0]  request_value,
    input  wire [15:0] request_aux_address,
    input  wire [7:0]  request_aux_value,

    output reg         response_valid,
    input  wire        response_ready,
    output reg  [2:0]  response_operation,
    output reg  [7:0]  response_tag,
    output reg  [3:0]  response_status,
    output reg  [2:0]  response_count,
    output reg  [31:0] response_data,

    output reg         block_write,
    output wire [10:0] block_write_address,
    output reg  [7:0]  block_write_data,
    input  wire [7:0]  block_read_data,
    output reg  [1:0]  block_ready,
    output reg  [15:0] block_sequence,
    output reg  [63:0] block_crc32,

    output reg         pc_usb_mode,

    output reg         stream_event_valid,
    input  wire        stream_event_ready,
    output wire [7:0]  stream_event_sequence,
    output wire [31:0] stream_event_crc32,
    input  wire        stream_ack_valid,
    input  wire [7:0]  stream_ack_sequence,

    output reg         active,
    input  wire        ownership_ack,
    output reg  [15:0] cart_address,
    output reg         cart_clock,
    output reg         cart_cs_n,
    output reg         cart_read_n,
    output reg         cart_write_n,
    output reg  [7:0]  cart_data_out,
    output reg         cart_data_oe,
    input  wire [7:0]  cart_data_in
);

    localparam [2:0] OP_PING       = 3'h0;
    localparam [2:0] OP_ENTER      = 3'h1;
    localparam [2:0] OP_READ_BLOCK = 3'h2;
    localparam [2:0] OP_WRITE      = 3'h3;
    localparam [2:0] OP_EXIT       = 3'h4;
    localparam [2:0] OP_ACK        = 3'h5;
    localparam [2:0] OP_READ_RANGE = 3'h6;
    localparam [2:0] OP_WRITE_READ_RANGE = 3'h7;

    localparam [3:0] STATUS_OK              = 4'h0;
    localparam [3:0] STATUS_INVALID_OP      = 4'h1;
    localparam [3:0] STATUS_NOT_ACTIVE      = 4'h2;
    localparam [3:0] STATUS_ALREADY_ACTIVE  = 4'h3;
    localparam [3:0] STATUS_INVALID_COUNT   = 4'h4;
    localparam [3:0] STATUS_NO_CARTRIDGE    = 4'h5;
    localparam [3:0] STATUS_ADDRESS_WRAP    = 4'h6;
    localparam [3:0] STATUS_BLOCK_BUSY       = 4'h7;
    localparam [3:0] STATUS_SEQUENCE         = 4'h8;
    localparam [3:0] STATUS_NO_BLOCK         = 4'h9;
    localparam [3:0] STATUS_FLASH_TIMEOUT    = 4'ha;

    localparam [7:0] BLOCK_STATUS_READY      = 8'h01;
    localparam [7:0] BLOCK_LENGTH_LOW        = 8'h00;
    localparam [7:0] BLOCK_LENGTH_HIGH       = 8'h04;

    localparam integer WATCHDOG_WIDTH =
        (WATCHDOG_CYCLES <= 1) ? 1 : $clog2(WATCHDOG_CYCLES);

    typedef enum logic [3:0] {
        STATE_IDLE,
        STATE_READ_SETUP,
        STATE_READ_STROBE,
        STATE_READ_RECOVERY,
        STATE_WRITE_SETUP,
        STATE_WRITE_LOW,
        STATE_WRITE_CLOCK_HIGH,
        STATE_WRITE_RECOVERY,
        STATE_ENTER_WAIT,
        STATE_EXIT_WAIT,
        STATE_STREAM_PUBLISH,
        STATE_FLASH_POLL,
        STATE_READ_CRC_INIT
    } state_t;

    state_t state;
    localparam integer WAIT_WIDTH = $clog2(ADDRESS_SETUP_CYCLES +
        READ_STROBE_CYCLES + WRITE_LOW_CYCLES + WRITE_CLOCK_HIGH_CYCLES +
        WRITE_RECOVERY_CYCLES + READ_RECOVERY_CYCLES + 2);
    reg [WAIT_WIDTH-1:0] wait_counter;
    reg [WATCHDOG_WIDTH-1:0] watchdog_counter;
    reg [2:0] current_operation;
    reg [7:0] current_tag;
    reg [9:0] block_index;
    reg [31:0] block_crc_state;
    reg [15:0] block_start_address;
    reg flash_transfer;
    reg flash_dq7_meta;
    reg flash_dq7;
    always @(posedge clk) begin
        flash_dq7_meta <= cart_data_in[7];
        flash_dq7 <= flash_dq7_meta;
    end
    reg        block_slot;
    reg        stream_active;
    reg        sd_session;
    reg [4:0]  stream_blocks_remaining;
    reg [15:0] stream_next_address;
    reg [7:0]  stream_next_sequence;
    reg        stream_event_slot;
    reg        stream_pair_pending;
    reg [7:0] session_enter_tag;
    reg [7:0] last_ack_sequence;
    reg last_ack_valid;
    reg release_response_required;
    reg [3:0] release_response_status;

    wire request_accepted = request_valid && request_ready;
    wire block_address_wraps = request_address > 16'hfc00;
    wire [16:0] range_last_address =
        {1'b0, request_address} + ({9'd0, request_value} << 10) - 1'b1;
    wire range_address_wraps = range_last_address[16];
    wire stream_complete = stream_active &&
                           (stream_blocks_remaining == 0);
    wire [9:0] next_block_index = block_index + 1'b1;
    wire [15:0] next_cart_address = cart_address + 1'b1;
    wire block_low_complete = &block_index[8:0];
    wire block_read_complete = block_low_complete && block_index[9];
    wire block_import_complete = block_low_complete &&
                                 (block_index[9] == stream_pair_pending);
    wire cart_ram_address = (cart_address[15:13] == 3'b101);
    wire flash_buffered = stream_pair_pending;
    wire flash_wide_buffer = stream_next_sequence[0];
    wire [4:0] flash_phase = stream_blocks_remaining;
    wire [15:0] flash_address = {2'b01, block_start_address[13:10], block_index};
    wire [15:0] flash_page_address = {flash_address[15:8],
        flash_wide_buffer ? 3'd0 : flash_address[7:5], 5'd0};
    wire flash_page_complete = (&block_index[4:0]) &&
        (!flash_wide_buffer || (&block_index[7:5]));
    wire watchdog_wait_state = (state == STATE_IDLE) ||
                               (state == STATE_STREAM_PUBLISH);
    wire watchdog_expired = active && watchdog_wait_state &&
                            !request_accepted &&
                            (watchdog_counter == WATCHDOG_CYCLES - 1);

    assign request_ready = (state == STATE_IDLE) && !response_valid;
    assign stream_event_sequence =
        block_sequence[stream_event_slot * 8 +: 8];
    assign stream_event_crc32 =
        block_crc32[stream_event_slot * 32 +: 32];
    assign block_write_address = {block_slot, block_index};

    function automatic [31:0] Crc32Nibble;
        input [31:0] crc;
        integer bit_index;
        reg [31:0] next_crc;
    begin
        next_crc = crc;
        for (bit_index = 0; bit_index < 4; bit_index = bit_index + 1)
            next_crc = next_crc[0]
                ? ((next_crc >> 1) ^ 32'hedb88320)
                : (next_crc >> 1);
        Crc32Nibble = next_crc;
    end
    endfunction

    reg [7:0] crc_input_byte;
    always @* begin
        crc_input_byte = 8'd0;
        if (state == STATE_READ_STROBE)
            crc_input_byte = cart_data_in;
        else if (state == STATE_READ_CRC_INIT) begin
            case (wait_counter)
                7: crc_input_byte = BLOCK_STATUS_READY;
                5: crc_input_byte = current_tag;
                1: crc_input_byte = BLOCK_LENGTH_HIGH;
                default: crc_input_byte = 8'd0;
            endcase
        end
    end
    wire [31:0] next_read_crc = Crc32Nibble(block_crc_state ^ {24'd0, crc_input_byte});

    task automatic SetSafeBus;
    begin
        cart_address  <= 16'hffff;
        cart_clock    <= 1'b1;
        cart_cs_n     <= 1'b1;
        cart_read_n   <= 1'b1;
        cart_write_n  <= 1'b1;
        cart_data_out <= 8'hff;
        cart_data_oe  <= 1'b0;
    end
    endtask

    task automatic SetResponse;
        input [2:0] operation;
        input [7:0] tag;
        input [3:0] status;
        input [2:0] count;
        input [31:0] data;
    begin
        response_operation <= operation;
        response_tag       <= tag;
        response_status    <= status;
        response_count     <= count;
        response_data      <= data;
        response_valid     <= 1'b1;
    end
    endtask

    always @(posedge clk or posedge reset)
    begin
        if (reset)
        begin
            state              <= STATE_IDLE;
            wait_counter       <= 16'd0;
            watchdog_counter   <= 'd0;
            current_operation  <= OP_PING;
            current_tag        <= 8'd0;
            block_index        <= 10'd0;
            block_crc_state    <= 32'hffffffff;
            block_start_address <= 16'd0;
            flash_transfer <= 1'b0;
            block_slot         <= 1'b0;
            stream_active      <= 1'b0;
            stream_blocks_remaining <= 5'd0;
            stream_next_address <= 16'd0;
            stream_next_sequence <= 8'd0;
            stream_event_slot  <= 1'b0;
            stream_pair_pending <= 1'b0;
            session_enter_tag  <= 8'd0;
            last_ack_sequence  <= 8'd0;
            last_ack_valid     <= 1'b0;
            response_valid     <= 1'b0;
            response_operation <= OP_PING;
            response_tag       <= 8'd0;
            response_status    <= STATUS_OK;
            response_count     <= 3'd0;
            response_data      <= 32'd0;
            block_write        <= 1'b0;
            block_write_data   <= 8'd0;
            block_ready        <= 2'b00;
            block_sequence     <= 16'd0;
            block_crc32        <= 64'd0;
            pc_usb_mode         <= 1'b0;
            sd_session          <= 1'b0;
            stream_event_valid <= 1'b0;
            active             <= 1'b0;
            release_response_required <= 1'b0;
            release_response_status <= STATUS_OK;
            SetSafeBus();
        end
        else
        begin
            block_write <= 1'b0;

            if (response_valid && response_ready)
                response_valid <= 1'b0;
            if (stream_event_valid && stream_event_ready)
                stream_event_valid <= 1'b0;

            if (stream_ack_valid && active && stream_active &&
                block_ready[stream_ack_sequence[0]] &&
                block_sequence[stream_ack_sequence[0] * 8 +: 8] ==
                    stream_ack_sequence)
            begin
                block_ready[stream_ack_sequence[0]] <= 1'b0;
                if (block_ready[stream_ack_sequence[0] ^ 1'b1] &&
                    (block_sequence[(stream_ack_sequence[0] ^ 1'b1) * 8 +: 8] ==
                     (stream_ack_sequence - 1'b1)))
                    block_ready[stream_ack_sequence[0] ^ 1'b1] <= 1'b0;
                last_ack_sequence <= stream_ack_sequence;
                last_ack_valid <= 1'b1;
            end

            if (!active || request_accepted || !watchdog_wait_state)
                watchdog_counter <= 'd0;
            else if (!watchdog_expired)
                watchdog_counter <= watchdog_counter + 1'b1;

            if (active && !sd_session && !cart_present && state != STATE_EXIT_WAIT)
            begin
                active            <= 1'b0;
                pc_usb_mode        <= 1'b0;
                state             <= STATE_EXIT_WAIT;
                watchdog_counter  <= 'd0;
                block_ready       <= 2'b00;
                stream_active     <= 1'b0;
                stream_blocks_remaining <= 5'd0;
                stream_pair_pending <= 1'b0;
                stream_event_valid <= 1'b0;
                last_ack_valid    <= 1'b0;
                release_response_required <= 1'b1;
                release_response_status <= STATUS_NO_CARTRIDGE;
                SetSafeBus();
            end
            else if (watchdog_expired)
            begin
                active            <= 1'b0;
                pc_usb_mode        <= 1'b0;
                state             <= STATE_EXIT_WAIT;
                watchdog_counter  <= 'd0;
                block_ready       <= 2'b00;
                stream_active     <= 1'b0;
                stream_blocks_remaining <= 5'd0;
                stream_pair_pending <= 1'b0;
                stream_event_valid <= 1'b0;
                last_ack_valid    <= 1'b0;
                release_response_required <= 1'b0;
                release_response_status <= STATUS_OK;
                SetSafeBus();
            end
            else
            begin
                case (state)
                    STATE_IDLE:
                    begin
                        cart_cs_n    <= 1'b1;
                        cart_read_n  <= 1'b1;
                        cart_write_n <= 1'b1;
                        cart_data_oe <= 1'b0;

                        if (request_accepted)
                        begin
                            flash_transfer <= 1'b0;
                            current_operation <= request_operation;
                            current_tag       <= request_tag;

                            case (request_operation)
                                OP_PING:
                                    SetResponse(request_operation, request_tag,
                                                STATUS_OK, 3'd4,
                                                {8'd10, 8'd3, 6'd0,
                                                 cart_present, active, 8'h00});

                                OP_ENTER:
                                begin
                                    if (!cart_present && !request_value[1])
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NO_CARTRIDGE, 3'd0, 32'd0);
                                    else if (active)
                                    begin
                                        if (request_tag == session_enter_tag)
                                            SetResponse(request_operation, request_tag,
                                                        STATUS_OK, 3'd0, 32'd0);
                                        else
                                            SetResponse(request_operation, request_tag,
                                                        STATUS_ALREADY_ACTIVE, 3'd0, 32'd0);
                                    end
                                    else
                                    begin
                                        active <= 1'b1;
                                        pc_usb_mode <= request_value[0];
                                        sd_session <= request_value[1];
                                        session_enter_tag <= request_tag;
                                        last_ack_valid <= 1'b0;
                                        SetSafeBus();
                                        state <= STATE_ENTER_WAIT;
                                    end
                                end

                                OP_READ_BLOCK:
                                begin
                                    if (!active)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NOT_ACTIVE, 3'd0, 32'd0);
                                    else if (!cart_present || sd_session)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NO_CARTRIDGE, 3'd0, 32'd0);
                                    else if (stream_active && !stream_complete)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_BLOCK_BUSY, 3'd0, 32'd0);
                                    else if (!stream_active && block_ready[0])
                                    begin
                                        if ((request_tag == block_sequence[7:0]) &&
                                            (request_address == block_start_address))
                                            SetResponse(request_operation, request_tag,
                                                        STATUS_OK, 3'd4,
                                                        block_crc32[31:0]);
                                        else
                                            SetResponse(request_operation, request_tag,
                                                        STATUS_BLOCK_BUSY, 3'd0, 32'd0);
                                    end
                                    else if (block_address_wraps)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_ADDRESS_WRAP, 3'd0, 32'd0);
                                    else
                                    begin
                                        if (stream_complete)
                                        begin
                                            block_ready <= 2'b00;
                                            stream_active <= 1'b0;
                                            stream_pair_pending <= 1'b0;
                                        end
                                        block_index     <= 10'd0;
                                        block_start_address <= request_address;
                                        block_slot      <= 1'b0;
                                        last_ack_valid  <= 1'b0;
                                        cart_address    <= request_address;
                                        cart_clock      <= 1'b1;
                                        cart_data_oe    <= 1'b0;
                                        block_crc_state <= 32'hffffffff;
                                        wait_counter    <= 7;
                                        state           <= STATE_READ_CRC_INIT;
                                    end
                                end

                                OP_READ_RANGE:
                                begin
                                    if (!active)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NOT_ACTIVE, 3'd0, 32'd0);
                                    else if (!sd_session && !cart_present)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NO_CARTRIDGE, 3'd0, 32'd0);
                                    else if ((request_value == 0) &&
                                             stream_active)
                                    begin
                                        stream_active <= 1'b0;
                                        stream_blocks_remaining <= 5'd0;
                                        stream_pair_pending <= 1'b0;
                                        stream_event_valid <= 1'b0;
                                        block_ready <= 2'b00;
                                        last_ack_valid <= 1'b0;
                                        SetResponse(request_operation,
                                                    request_tag, STATUS_OK,
                                                    3'd0, 32'd0);
                                    end
                                    else if (sd_session)
                                    begin
                                        if (request_value != 8'h84)
                                            SetResponse(request_operation, request_tag,
                                                        STATUS_INVALID_OP, 0, 0);
                                        else if (block_ready != 0 || stream_event_valid)
                                            SetResponse(request_operation, request_tag,
                                                        STATUS_BLOCK_BUSY, 0, 0);
                                        else begin
                                            block_ready <= 2'b01;
                                            block_sequence[7:0] <= request_address[7:0] & 8'hfe;
                                            stream_event_slot <= 1'b0;
                                            stream_event_valid <= 1'b1;
                                            stream_active <= 1'b1;
                                            stream_blocks_remaining <= 0;
                                            last_ack_valid <= 1'b0;
                                            SetResponse(request_operation, request_tag,
                                                        STATUS_OK, 0, 0);
                                        end
                                    end
                                    else if ((stream_active && !stream_complete) ||
                                             (!stream_active &&
                                              (block_ready != 2'b00)))
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_BLOCK_BUSY, 3'd0, 32'd0);
                                    else if ((request_value[7:1] == 7'h41 || request_value == 8'h85) &&
                                             request_address[15:14] == 2'b01 &&
                                             request_address[9:0] == 0)
                                    begin
                                        block_ready <= 2'b00;
                                        stream_active <= 1'b0;
                                        block_slot <= 1'b0;
                                        block_index <= 10'd0;
                                        block_start_address <= request_address;
                                        flash_transfer <= 1'b1;
                                        stream_pair_pending <= request_value[0];
                                        stream_next_sequence[0] <= request_value[2];
                                        stream_blocks_remaining <= 5'd5;
                                        wait_counter <= ADDRESS_SETUP_CYCLES + 1;
                                        state <= STATE_WRITE_SETUP;
                                    end
                                    else if (request_value[7] &&
                                             request_value[6:1] == 0 &&
                                             request_address[15:13] == 3'b101)
                                    begin
                                        block_ready <= 2'b00;
                                        stream_active <= 1'b0;
                                        block_slot <= 1'b0;
                                        stream_pair_pending <= request_value[0];
                                        block_index <= 10'd0;
                                        flash_transfer <= 1'b0;
                                        cart_address <= request_address;
                                        cart_clock <= 1'b1;
                                        cart_data_oe <= 1'b0;
                                        wait_counter <= ADDRESS_SETUP_CYCLES + 1;
                                        state <= STATE_WRITE_SETUP;
                                    end
                                    else if ((request_value == 0) ||
                                             (request_value > 16))
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_INVALID_COUNT, 3'd0, 32'd0);
                                    else if (range_address_wraps)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_ADDRESS_WRAP, 3'd0, 32'd0);
                                    else
                                    begin
                                        block_ready <= 2'b00;
                                        stream_active <= 1'b1;
                                        stream_blocks_remaining <= request_value[4:0];
                                        stream_next_address <= request_address;
                                        stream_next_sequence <= request_tag;
                                        stream_pair_pending <= 1'b0;
                                        last_ack_valid <= 1'b0;
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_OK, 3'd0, 32'd0);
                                    end
                                end

                                OP_WRITE:
                                begin
                                    if (!active)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NOT_ACTIVE, 3'd0, 32'd0);
                                    else if (!cart_present || sd_session)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NO_CARTRIDGE, 3'd0, 32'd0);
                                    else if ((stream_active && !stream_complete) ||
                                             (!stream_active &&
                                              (block_ready != 2'b00)))
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_BLOCK_BUSY, 3'd0, 32'd0);
                                    else
                                    begin
                                        block_ready <= 2'b00;
                                        stream_active <= 1'b0;
                                        stream_pair_pending <= 1'b0;
                                        cart_address  <= request_address;
                                        cart_clock    <= 1'b1;
                                        cart_data_out <= request_value;
                                        cart_data_oe  <= 1'b1;
                                        wait_counter  <= ADDRESS_SETUP_CYCLES - 1;
                                        state         <= STATE_WRITE_SETUP;
                                    end
                                end

                                OP_WRITE_READ_RANGE:
                                begin
                                    if (!active)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NOT_ACTIVE, 3'd0, 32'd0);
                                    else if (!cart_present || sd_session)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NO_CARTRIDGE, 3'd0, 32'd0);
                                    else if ((stream_active && !stream_complete) ||
                                             (!stream_active &&
                                              (block_ready != 2'b00)))
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_BLOCK_BUSY, 3'd0, 32'd0);
                                    else if ((request_value == 0) ||
                                             (request_value > 16))
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_INVALID_COUNT, 3'd0, 32'd0);
                                    else if (range_address_wraps)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_ADDRESS_WRAP, 3'd0, 32'd0);
                                    else
                                    begin
                                        block_ready <= 2'b00;
                                        stream_active <= 1'b1;
                                        stream_blocks_remaining <=
                                            request_value[4:0];
                                        stream_next_address <= request_address;
                                        stream_next_sequence <= request_tag;
                                        stream_pair_pending <= 1'b0;
                                        last_ack_valid <= 1'b0;
                                        cart_address  <= request_aux_address;
                                        cart_clock    <= 1'b1;
                                        cart_data_out <= request_aux_value;
                                        cart_data_oe  <= 1'b1;
                                        wait_counter  <= ADDRESS_SETUP_CYCLES - 1;
                                        state         <= STATE_WRITE_SETUP;
                                    end
                                end

                                OP_EXIT:
                                begin
                                    if (!active)
                                        SetResponse(request_operation,
                                                    request_tag, STATUS_OK,
                                                    3'd0, 32'd0);
                                    else
                                    begin
                                        active <= 1'b0;
                                        pc_usb_mode <= 1'b0;
                                        block_ready <= 2'b00;
                                        stream_active <= 1'b0;
                                        stream_blocks_remaining <= 5'd0;
                                        stream_pair_pending <= 1'b0;
                                        stream_event_valid <= 1'b0;
                                        last_ack_valid <= 1'b0;
                                        release_response_required <= 1'b1;
                                        release_response_status <= STATUS_OK;
                                        SetSafeBus();
                                        state <= STATE_EXIT_WAIT;
                                    end
                                end

                                OP_ACK:
                                begin
                                    if (!active)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NOT_ACTIVE, 3'd0, 32'd0);
                                    else if (stream_active &&
                                             (request_address == 16'hffff) &&
                                             (stream_blocks_remaining == 0) &&
                                             (request_value ==
                                              (stream_next_sequence - 1'b1)))
                                    begin
                                        block_ready <= 2'b00;
                                        stream_active <= 1'b0;
                                        stream_pair_pending <= 1'b0;
                                        last_ack_sequence <= request_value;
                                        last_ack_valid <= 1'b1;
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_OK, 3'd0, 32'd0);
                                    end
                                    else if (stream_active &&
                                             block_ready[request_value[0]] &&
                                             (block_sequence[request_value[0] * 8 +: 8] ==
                                              request_value))
                                    begin
                                        block_ready[request_value[0]] <= 1'b0;
                                        last_ack_sequence <= request_value;
                                        last_ack_valid <= 1'b1;
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_OK, 3'd0, 32'd0);
                                    end
                                    else if (!stream_active && block_ready[0] &&
                                             (request_value == block_sequence[7:0]))
                                    begin
                                        block_ready[0] <= 1'b0;
                                        last_ack_sequence <= request_value;
                                        last_ack_valid <= 1'b1;
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_OK, 3'd0, 32'd0);
                                    end
                                    else if (last_ack_valid &&
                                             (request_value == last_ack_sequence))
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_OK, 3'd0, 32'd0);
                                    else if (block_ready != 2'b00)
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_SEQUENCE, 3'd0, 32'd0);
                                    else
                                        SetResponse(request_operation, request_tag,
                                                    STATUS_NO_BLOCK, 3'd0, 32'd0);
                                end

                                default:
                                    SetResponse(request_operation, request_tag,
                                                STATUS_INVALID_OP, 3'd0, 32'd0);
                            endcase
                        end
                        else if (stream_active &&
                                 (stream_blocks_remaining != 0) &&
                                 !block_ready[stream_next_sequence[0]])
                        begin
                            current_operation <= OP_READ_RANGE;
                            current_tag       <= stream_next_sequence;
                            block_index       <= 10'd0;
                            block_start_address <= stream_next_address;
                            block_slot        <= stream_next_sequence[0];
                            cart_address      <= stream_next_address;
                            cart_clock        <= 1'b1;
                            cart_data_oe      <= 1'b0;
                            block_crc_state   <= 32'hffffffff;
                            wait_counter      <= 7;
                            state             <= STATE_READ_CRC_INIT;
                        end
                    end

                    STATE_READ_CRC_INIT:
                    begin
                        block_crc_state <= next_read_crc;
                        if (wait_counter != 0)
                            wait_counter <= wait_counter - 1'b1;
                        else begin
                            wait_counter <= ADDRESS_SETUP_CYCLES - 1;
                            state <= STATE_READ_SETUP;
                        end
                    end

                    STATE_READ_SETUP:
                    begin
                        if (wait_counter != 0)
                            wait_counter <= wait_counter - 1'b1;
                        else
                        begin
                            cart_cs_n    <= cart_ram_address ? 1'b0 : 1'b1;
                            cart_read_n  <= 1'b0;
                            wait_counter <= READ_STROBE_CYCLES - 1;
                            state        <= STATE_READ_STROBE;
                        end
                    end

                    STATE_READ_STROBE:
                    begin
                        if (wait_counter != 0)
                            wait_counter <= wait_counter - 1'b1;
                        else
                        begin
                            block_write         <= 1'b1;
                            block_write_data    <= cart_data_in;
                            block_crc_state <= next_read_crc;
                            cart_cs_n    <= 1'b1;
                            cart_read_n  <= 1'b1;
                            wait_counter <= READ_RECOVERY_CYCLES;
                            state        <= STATE_READ_RECOVERY;
                        end
                    end

                    STATE_READ_RECOVERY:
                    begin
                        if (wait_counter == READ_RECOVERY_CYCLES)
                            block_crc_state <= next_read_crc;
                        if (wait_counter != 0)
                            wait_counter <= wait_counter - 1'b1;
                        else if (!block_read_complete)
                        begin
                            block_index   <= next_block_index;
                            cart_address <= next_cart_address;
                            wait_counter <= ADDRESS_SETUP_CYCLES - 1;
                            state        <= STATE_READ_SETUP;
                        end
                        else
                        begin
                            block_ready[block_slot] <= 1'b1;
                            block_sequence[block_slot * 8 +: 8] <= current_tag;
                            block_crc32[block_slot * 32 +: 32] <=
                                ~block_crc_state;
                            if (current_operation == OP_READ_RANGE)
                            begin
                                stream_blocks_remaining <=
                                    stream_blocks_remaining - 1'b1;
                                stream_next_address <= stream_next_address +
                                                       16'd1024;
                                stream_next_sequence <= stream_next_sequence +
                                                        1'b1;
                                if (!stream_pair_pending &&
                                    (stream_blocks_remaining > 1))
                                begin
                                    stream_pair_pending <= 1'b1;
                                    state <= STATE_IDLE;
                                end
                                else
                                begin
                                    stream_pair_pending <= 1'b0;
                                    state <= STATE_STREAM_PUBLISH;
                                end
                            end
                            else
                            begin
                                SetResponse(current_operation, current_tag,
                                            STATUS_OK, 3'd4,
                                            ~block_crc_state);
                                state <= STATE_IDLE;
                            end
                        end
                    end

                    STATE_STREAM_PUBLISH:
                    begin
                        if (!stream_event_valid)
                        begin
                            stream_event_slot <= block_slot;
                            stream_event_valid <= 1'b1;
                            state <= STATE_IDLE;
                        end
                    end

                    STATE_WRITE_SETUP:
                    begin
                        if (current_operation == OP_READ_RANGE &&
                            wait_counter != 0)
                        begin
                            if (flash_transfer)
                            begin
                                cart_address <= flash_address;
                                if (flash_phase == 5 || (flash_phase == 3 && !flash_buffered))
                                    cart_address <= 16'h0aaa;
                                else if (flash_phase == 4)
                                    cart_address <= 16'h0555;
                                else if (flash_phase != 1)
                                    cart_address <= flash_page_address;
                                case (flash_phase)
                                    5: cart_data_out <= 8'haa;
                                    4: cart_data_out <= 8'h55;
                                    3: cart_data_out <= flash_buffered ? 8'h25 : 8'ha0;
                                    2: cart_data_out <= flash_wide_buffer ? 8'd255 : 8'd31;
                                    1: cart_data_out <= block_read_data;
                                    default: cart_data_out <= 8'h29;
                                endcase
                            end
                            else cart_data_out <= block_read_data;
                            cart_data_oe <= 1'b1;
                        end
                        if (wait_counter != 0)
                            wait_counter <= wait_counter - 1'b1;
                        else
                        begin
                            cart_cs_n     <= cart_ram_address ? 1'b0 : 1'b1;
                            cart_clock    <= 1'b0;
                            cart_write_n  <= 1'b0;
                            wait_counter  <= WRITE_LOW_CYCLES - 1;
                            state         <= STATE_WRITE_LOW;
                        end
                    end

                    STATE_WRITE_LOW:
                    begin
                        if (wait_counter != 0)
                            wait_counter <= wait_counter - 1'b1;
                        else
                        begin
                            cart_clock   <= 1'b1;
                            wait_counter <= WRITE_CLOCK_HIGH_CYCLES - 1;
                            state        <= STATE_WRITE_CLOCK_HIGH;
                        end
                    end

                    STATE_WRITE_CLOCK_HIGH:
                    begin
                        if (wait_counter != 0)
                            wait_counter <= wait_counter - 1'b1;
                        else
                        begin
                            cart_cs_n     <= 1'b1;
                            cart_write_n  <= 1'b1;
                            wait_counter  <= WRITE_RECOVERY_CYCLES - 1;
                            state         <= STATE_WRITE_RECOVERY;
                        end
                    end

                    STATE_WRITE_RECOVERY:
                    begin
                        if (wait_counter != 0)
                            wait_counter <= wait_counter - 1'b1;
                        else if (current_operation == OP_READ_RANGE && flash_transfer)
                        begin
                            cart_data_oe <= 1'b0;
                            if ((!flash_buffered && flash_phase == 5'd1) ||
                                flash_phase == 5'd0)
                            begin
                                cart_address <= flash_address;
                                wait_counter <= ADDRESS_SETUP_CYCLES + READ_STROBE_CYCLES;
                                watchdog_counter <= 'd0;
                                state <= STATE_FLASH_POLL;
                            end
                            else
                            begin
                                if (flash_phase == 5'd1 && !flash_page_complete)
                                    block_index <= next_block_index;
                                else if (!flash_buffered && flash_phase == 5'd3)
                                    stream_blocks_remaining <= 5'd1;
                                else
                                    stream_blocks_remaining <= stream_blocks_remaining - 1'b1;
                                wait_counter <= ADDRESS_SETUP_CYCLES + 1;
                                state <= STATE_WRITE_SETUP;
                            end
                        end
                        else if (current_operation == OP_READ_RANGE &&
                                 !block_import_complete)
                        begin
                            block_index <= next_block_index;
                            cart_address <= next_cart_address;
                            cart_data_oe <= 1'b0;
                            wait_counter <= ADDRESS_SETUP_CYCLES + 1;
                            state <= STATE_WRITE_SETUP;
                        end
                        else
                        begin
                            cart_data_oe <= 1'b0;
                            SetResponse(current_operation, current_tag,
                                        STATUS_OK, 3'd0, 32'd0);
                            state <= STATE_IDLE;
                        end
                    end

                    STATE_FLASH_POLL:
                    begin
                        watchdog_counter <= watchdog_counter + 1'b1;
                        if (watchdog_counter == FLASH_POLL_CYCLES - 1)
                        begin
                            cart_read_n <= 1'b1;
                            flash_transfer <= 1'b0;
                            SetResponse(current_operation, current_tag,
                                        STATUS_FLASH_TIMEOUT, 3'd0, 32'd0);
                            state <= STATE_IDLE;
                        end
                        else if (wait_counter != 0)
                        begin
                            wait_counter <= wait_counter - 1'b1;
                            if (wait_counter == READ_STROBE_CYCLES)
                                cart_read_n <= 1'b0;
                        end
                        else if (flash_dq7 == block_read_data[7])
                        begin
                            cart_read_n <= 1'b1;
                            if (block_read_complete)
                            begin
                                flash_transfer <= 1'b0;
                                SetResponse(current_operation, current_tag,
                                            STATUS_OK, 3'd0, 32'd0);
                                state <= STATE_IDLE;
                            end
                            else
                            begin
                                block_index <= next_block_index;
                                stream_blocks_remaining <= 5'd5;
                                wait_counter <= ADDRESS_SETUP_CYCLES + 1;
                                state <= STATE_WRITE_SETUP;
                            end
                        end
                        else
                        begin
                            cart_read_n <= 1'b1;
                            wait_counter <= READ_RECOVERY_CYCLES +
                                ADDRESS_SETUP_CYCLES + READ_STROBE_CYCLES;
                        end
                    end

                    STATE_ENTER_WAIT:
                    begin
                        SetSafeBus();
                        if (ownership_ack)
                        begin
                            SetResponse(current_operation, current_tag,
                                        STATUS_OK, 3'd0, 32'd0);
                            state <= STATE_IDLE;
                        end
                    end

                    STATE_EXIT_WAIT:
                    begin
                        SetSafeBus();
                        if (!ownership_ack)
                        begin
                            state <= STATE_IDLE;
                            if (release_response_required)
                                SetResponse(current_operation, current_tag,
                                            release_response_status, 3'd0,
                                            32'd0);
                            release_response_required <= 1'b0;
                        end
                    end

                    default:
                    begin
                        active <= 1'b0;
                        pc_usb_mode <= 1'b0;
                        state  <= STATE_IDLE;
                        block_ready <= 2'b00;
                        stream_active <= 1'b0;
                        stream_pair_pending <= 1'b0;
                        stream_event_valid <= 1'b0;
                        SetSafeBus();
                    end
                endcase
            end
        end
    end

endmodule

`default_nettype wire
