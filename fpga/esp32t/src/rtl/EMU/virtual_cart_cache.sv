module virtual_cart_cache (
    input         hclk,
    input         hreset,
    input         henable,
    input         hquiesced,
    input         haccess,
    input         hwrite,
    input         hram,
    input  [22:0] haddress,
    input   [7:0] hwritedata,
    output  [7:0] hreaddata,
    output        hready,
    output        hdirty,
    output        hinitialized,

    input         xclk,
    input         xreset,
    output reg        xrequest,
    output reg        xread,
    output reg [22:0] xaddress,
    output reg [15:0] xwritedata,
    output reg [10:0] xlength,
    input             xwrite_next,
    input             xdone,
    input             xread_valid,
    input      [15:0] xreaddata,

    input             xsnapshot_request_toggle,
    input       [6:0] xsnapshot_block,
    input      [15:0] xsnapshot_sequence,
    output reg        xsnapshot_ready,
    output reg [15:0] xsnapshot_ready_sequence,
    input             qclk,
    input       [9:0] qsnapshot_address,
    output      [7:0] qsnapshot_data
);
    localparam [10:0] LINE_BYTES = 11'd64;
    localparam [22:0] SAVE_BASE = 23'h420000;

    wire [15:0] tag_way0_data;
    wire [15:0] tag_way1_data;
    reg  [15:0] tag_way0_write_data;
    reg  [15:0] tag_way1_write_data;
    reg   [5:0] tag_address;
    reg         tag_way0_write;
    reg         tag_way1_write;
    reg         init_active;
    reg   [5:0] init_index;
    reg         dirty_seen;
    reg   [1:0] lookup_rearm;

    reg  [22:0] lookup_address;
    reg         lookup_ram;
    reg         lookup_access;
    reg         write_armed;
    reg   [7:0] write_data_latched;

    localparam [1:0] FLUSH_IDLE=0, FLUSH_READ=1, FLUSH_CHECK=2,
                     FLUSH_WAIT=3;
    reg [1:0] flush_state;
    reg [5:0] flush_index;
    reg       request_flush_h;
    reg       flush_request_meta_h;
    reg       flush_request_sync_h;
    reg       flush_request_seen_h;
    reg       flush_done_toggle_h;
    reg       flush_request_toggle_x;
    reg       flush_claim_h;
    reg       flush_port_selected_h;
    reg       dirty_during_flush;
    wire [5:0] flush_set = {1'b1, flush_index[5:1]};
    wire       flush_way = flush_index[0];

    wire [5:0] lookup_set = {lookup_ram, lookup_address[10:6]};
    wire [11:0] lookup_tag = lookup_address[22:11];
    wire lookup_matches_bus = lookup_address == haddress &&
                              lookup_ram == hram;
    wire hit0 = tag_way0_data[12] && tag_way0_data[11:0] == lookup_tag;
    wire hit1 = tag_way1_data[12] && tag_way1_data[11:0] == lookup_tag;
    wire hit = hit0 || hit1;
    wire hit_way = hit1;

    reg pending;
    reg request_toggle_h;
    reg request_way_h;
    reg [5:0] request_set_h;
    reg [11:0] request_new_tag_h;
    reg [11:0] request_old_tag_h;
    reg request_old_dirty_h;

    reg complete_meta_h;
    reg complete_sync_h;
    reg complete_seen_h;
    reg complete_toggle_x;

    reg [5:0] fill_words_x;
    reg [5:0] fill_gray_x;
    (* ASYNC_REG = "TRUE" *) reg [5:0] fill_gray_meta_h;
    (* ASYNC_REG = "TRUE" *) reg [5:0] fill_gray_sync_h;
    reg fill_phase_h;
    wire [5:0] fill_words_next_x = fill_words_x + 1'b1;
    wire [5:0] fill_words_h;
    assign fill_words_h[5] = fill_gray_sync_h[5];
    for (genvar bit_index = 0; bit_index < 5; bit_index = bit_index + 1) begin
        assign fill_words_h[bit_index] =
            ^fill_gray_sync_h[5:bit_index];
    end
    wire fill_full_h = fill_words_h[5] != fill_phase_h;

    wire [5:0] hset = {hram, haddress[10:6]};
    wire [11:0] htag = haddress[22:11];
    wire [10:0] hram_address = {hset, haddress[5:1]};
    wire flush_port_owned = flush_state != FLUSH_IDLE &&
                            (!haccess || hquiesced || flush_claim_h);
    wire flush_blocks_bus = pending && request_flush_h &&
                            (hset == request_set_h || flush_claim_h);
    wire port_ready = !flush_port_owned && flush_state != FLUSH_CHECK &&
                      !init_active && (!pending || request_flush_h) &&
                      !flush_blocks_bus && lookup_rearm == 0 && lookup_access &&
                      lookup_matches_bus && hit;
    wire direct_write = henable && haccess && hwrite &&
                        !write_armed && port_ready;
    wire replay_write = henable && write_armed && port_ready;
    wire cache_write = direct_write || replay_write;
    wire [7:0] cache_write_data = replay_write
        ? write_data_latched : hwritedata;
    wire hwrite0_even = cache_write && hit0 && !haddress[0];
    wire hwrite0_odd  = cache_write && hit0 &&  haddress[0];
    wire hwrite1_even = cache_write && hit1 && !haddress[0];
    wire hwrite1_odd  = cache_write && hit1 &&  haddress[0];

    wire [10:0] xram_address;
    reg [4:0] xword;
    reg [5:0] xset;
    reg xway;
    wire [4:0] xram_word_address = xword +
                                   (xwrite_next ? 5'd1 : 5'd0);
    assign xram_address = {xset, xram_word_address};

    wire [7:0] q0_even_h, q0_odd_h, q1_even_h, q1_odd_h;
    wire [7:0] q0_even_x, q0_odd_x, q1_even_x, q1_odd_x;
    wire xfill_write;

    localparam [2:0] X_IDLE=0, X_WB_PRELOAD=1, X_WB_REQUEST=2,
                     X_WB_WAIT=3, X_FILL_REQUEST=4, X_FILL_WAIT=5,
                     X_SNAPSHOT_REQUEST=6, X_SNAPSHOT_WAIT=7;
    reg [2:0] xstate;

    reg [3:0] snapshot_chunk_x;
    wire [8:0] snapshot_word_address_x = {snapshot_chunk_x, xword};
    wire [15:0] snapshot_word_q;
    wire snapshot_ram_write = xread_valid && xstate == X_SNAPSHOT_WAIT;
    reg snapshot_high_q;

    gowin_dpb_snapshot ram_save_snapshot (
        .write_clock(xclk),
        .write_enable(snapshot_ram_write),
        .write_address(snapshot_word_address_x),
        .write_data(xreaddata),
        .read_clock(qclk),
        .read_address(qsnapshot_address[9:1]),
        .read_data(snapshot_word_q));
    always @(posedge qclk)
        snapshot_high_q <= qsnapshot_address[0];
    assign qsnapshot_data = snapshot_high_q
        ? snapshot_word_q[15:8] : snapshot_word_q[7:0];

    gowin_sdpb_tag_way ram_tag_way0 (
        .clock(hclk), .write_enable(tag_way0_write),
        .address(tag_address), .write_data(tag_way0_write_data),
        .read_data(tag_way0_data));
    gowin_sdpb_tag_way ram_tag_way1 (
        .clock(hclk), .write_enable(tag_way1_write),
        .address(tag_address), .write_data(tag_way1_write_data),
        .read_data(tag_way1_data));

    gowin_dpb_cache_byte ram_way0_even (
        .clock_a(hclk), .address_a(hram_address), .data_a(cache_write_data),
        .wren_a(hwrite0_even), .q_a(q0_even_h),
        .clock_b(xclk), .address_b(xram_address), .data_b(xreaddata[7:0]),
        .wren_b(xfill_write && !xway), .q_b(q0_even_x));
    gowin_dpb_cache_byte ram_way0_odd (
        .clock_a(hclk), .address_a(hram_address), .data_a(cache_write_data),
        .wren_a(hwrite0_odd), .q_a(q0_odd_h),
        .clock_b(xclk), .address_b(xram_address), .data_b(xreaddata[15:8]),
        .wren_b(xfill_write && !xway), .q_b(q0_odd_x));
    gowin_dpb_cache_byte ram_way1_even (
        .clock_a(hclk), .address_a(hram_address), .data_a(cache_write_data),
        .wren_a(hwrite1_even), .q_a(q1_even_h),
        .clock_b(xclk), .address_b(xram_address), .data_b(xreaddata[7:0]),
        .wren_b(xfill_write && xway), .q_b(q1_even_x));
    gowin_dpb_cache_byte ram_way1_odd (
        .clock_a(hclk), .address_a(hram_address), .data_a(cache_write_data),
        .wren_a(hwrite1_odd), .q_a(q1_odd_h),
        .clock_b(xclk), .address_b(xram_address), .data_b(xreaddata[15:8]),
        .wren_b(xfill_write && xway), .q_b(q1_odd_x));

    wire rom_prefix_ready = (pending || lookup_rearm != 0) &&
        !init_active && (flush_state == FLUSH_IDLE ||
                        flush_state == FLUSH_READ) && !request_flush_h &&
        !request_set_h[5] && !hram && !hwrite &&
        lookup_access && lookup_matches_bus &&
        hset == request_set_h && htag == request_new_tag_h &&
        (fill_full_h || fill_words_h[4:0] > lookup_address[5:1]);
    wire read_way = rom_prefix_ready ? request_way_h : hit_way;
    assign hreaddata = read_way
        ? (lookup_address[0] ? q1_odd_h : q1_even_h)
        : (lookup_address[0] ? q0_odd_h : q0_even_h);
    assign hready = !henable || !haccess ||
                    ((port_ready || rom_prefix_ready) && !write_armed);
    assign hdirty = dirty_seen;
    assign hinitialized = henable && !init_active;

    wire complete_event_h = pending &&
                            complete_sync_h != complete_seen_h &&
                            (!request_flush_h ||
                             (flush_port_owned && flush_port_selected_h));
    wire dirty_event_h = cache_write;
    wire flush_start_h = flush_request_sync_h != flush_request_seen_h &&
                         flush_state == FLUSH_IDLE && !init_active &&
                         !pending && (!haccess || hquiesced);

    always @* begin
        tag_address = hset;
        tag_way0_write_data = tag_way0_data;
        tag_way1_write_data = tag_way1_data;
        tag_way0_write = 1'b0;
        tag_way1_write = 1'b0;
        if (init_active) begin
            tag_address = init_index;
            tag_way0_write_data = 16'd0;
            tag_way1_write_data = 16'd0;
            tag_way0_write = 1'b1;
            tag_way1_write = 1'b1;
        end else if (complete_event_h) begin
            tag_address = request_set_h;
            if (request_flush_h) begin
                if (request_way_h) begin
                    tag_way1_write_data[13] = 1'b0;
                    tag_way1_write = 1'b1;
                end else begin
                    tag_way0_write_data[13] = 1'b0;
                    tag_way0_write = 1'b1;
                end
            end else begin
                tag_way0_write_data[14] = !request_way_h;
                tag_way0_write = 1'b1;
                if (request_way_h) begin
                    tag_way1_write_data[11:0] = request_new_tag_h;
                    tag_way1_write_data[12] = 1'b1;
                    tag_way1_write_data[13] = 1'b0;
                    tag_way1_write = 1'b1;
                end else begin
                    tag_way0_write_data[11:0] = request_new_tag_h;
                    tag_way0_write_data[12] = 1'b1;
                    tag_way0_write_data[13] = 1'b0;
                end
            end
        end else if (dirty_event_h) begin
            tag_address = lookup_set;
            if (hit_way) begin
                tag_way1_write_data[13] = 1'b1;
                tag_way1_write = 1'b1;
            end else begin
                tag_way0_write_data[13] = 1'b1;
                tag_way0_write = 1'b1;
            end
        end else if (pending && (!request_flush_h || flush_port_owned)) begin
            tag_address = request_set_h;
        end else if (flush_port_owned) begin
            tag_address = flush_set;
        end
    end

    always @(posedge hclk) begin
        complete_meta_h <= complete_toggle_x;
        complete_sync_h <= complete_meta_h;
        fill_gray_meta_h <= fill_gray_x;
        fill_gray_sync_h <= fill_gray_meta_h;
        flush_request_meta_h <= flush_request_toggle_x;
        flush_request_sync_h <= flush_request_meta_h;
        lookup_address <= haddress;
        lookup_ram <= hram;
        lookup_access <= haccess && !init_active && !flush_port_owned &&
                         (!pending || request_flush_h || hset == request_set_h);
        flush_port_selected_h <= pending && request_flush_h && flush_port_owned;
        if (hreset || !henable) begin
            init_active <= 1'b1;
            init_index <= 6'd0;
            dirty_seen <= 1'b0;
            lookup_rearm <= 2'd2;
            pending <= 1'b0;
            request_toggle_h <= 1'b0;
            complete_seen_h <= 1'b0;
            fill_phase_h <= 1'b0;
            fill_gray_meta_h <= 6'd0;
            fill_gray_sync_h <= 6'd0;
            write_armed <= 1'b0;
            write_data_latched <= 8'd0;
            flush_state <= FLUSH_IDLE;
            flush_index <= 6'd0;
            request_flush_h <= 1'b0;
            flush_request_meta_h <= 1'b0;
            flush_request_sync_h <= 1'b0;
            flush_request_seen_h <= 1'b0;
            flush_done_toggle_h <= 1'b0;
            flush_claim_h <= 1'b0;
            flush_port_selected_h <= 1'b0;
            dirty_during_flush <= 1'b0;
        end else begin
            if (!pending || !request_flush_h) begin
                flush_claim_h <= 1'b0;
            end else if (haccess && lookup_access && lookup_matches_bus &&
                         (!hit || hset == request_set_h)) begin
                flush_claim_h <= 1'b1;
            end
            if (init_active) begin
                init_index <= init_index + 1'b1;
                if (init_index == 6'd63) begin
                    init_active <= 1'b0;
                    lookup_rearm <= 2'd2;
                end
            end else if (lookup_rearm != 0) begin
                lookup_rearm <= lookup_rearm - 1'b1;
            end
            if (dirty_event_h) dirty_seen <= 1'b1;
            if (dirty_event_h && flush_state != FLUSH_IDLE)
                dirty_during_flush <= 1'b1;

            if (replay_write) begin
                write_armed <= 1'b0;
            end else if (!haccess) begin
                write_armed <= 1'b0;
            end else if (haccess && hwrite && !direct_write &&
                         !write_armed) begin
                write_armed <= 1'b1;
                write_data_latched <= hwritedata;
            end

            if (flush_start_h) begin
                flush_request_seen_h <= flush_request_sync_h;
                flush_index <= 6'd0;
                flush_state <= FLUSH_READ;
                dirty_during_flush <= 1'b0;
            end else if (!init_active && !pending &&
                (flush_state == FLUSH_IDLE ||
                 (flush_state == FLUSH_READ && !hquiesced)) &&
                haccess && !flush_port_owned &&
                lookup_rearm == 0 &&
                lookup_access &&
                lookup_matches_bus && !hit) begin
                request_set_h <= lookup_set;
                fill_phase_h <= fill_words_h[5];
                request_new_tag_h <= lookup_tag;
                if (!tag_way0_data[12]) request_way_h <= 1'b0;
                else if (!tag_way1_data[12]) request_way_h <= 1'b1;
                else request_way_h <= tag_way0_data[14];
                if (!tag_way0_data[12] ||
                    (tag_way1_data[12] && !tag_way0_data[14])) begin
                    request_old_tag_h <= tag_way0_data[11:0];
                    request_old_dirty_h <= tag_way0_data[12] &&
                                                   tag_way0_data[13];
                end else begin
                    request_old_tag_h <= tag_way1_data[11:0];
                    request_old_dirty_h <= tag_way1_data[12] &&
                                                   tag_way1_data[13];
                end
                pending <= 1'b1;
                request_flush_h <= 1'b0;
                request_toggle_h <= !request_toggle_h;
            end

            if (complete_event_h) begin
                complete_seen_h <= complete_sync_h;
                pending <= 1'b0;
                lookup_rearm <= 2'd2;
                if (request_flush_h) begin
                    request_flush_h <= 1'b0;
                    flush_claim_h <= 1'b0;
                    if (flush_index == 6'd63) begin
                        flush_state <= FLUSH_IDLE;
                        dirty_seen <= dirty_during_flush || dirty_event_h;
                        flush_done_toggle_h <= !flush_done_toggle_h;
                    end else begin
                        flush_index <= flush_index + 1'b1;
                        flush_state <= FLUSH_READ;
                    end
                end
            end

            case (flush_state)
                FLUSH_READ: if (!pending && flush_port_owned &&
                                lookup_rearm == 0)
                                flush_state <= FLUSH_CHECK;
                FLUSH_CHECK: begin
                    if (!flush_port_owned) begin
                        flush_state <= FLUSH_READ;
                    end else if ((flush_way ? tag_way1_data[12]
                                   : tag_way0_data[12]) &&
                        (flush_way ? tag_way1_data[13]
                                   : tag_way0_data[13])) begin
                        request_set_h <= flush_set;
                        request_way_h <= flush_way;
                        request_old_tag_h <= flush_way
                            ? tag_way1_data[11:0] : tag_way0_data[11:0];
                        request_old_dirty_h <= 1'b1;
                        request_flush_h <= 1'b1;
                        pending <= 1'b1;
                        request_toggle_h <= !request_toggle_h;
                        flush_state <= FLUSH_WAIT;
                    end else if (flush_index == 6'd63) begin
                        flush_state <= FLUSH_IDLE;
                        lookup_rearm <= 2'd2;
                        dirty_seen <= dirty_during_flush || dirty_event_h;
                        flush_done_toggle_h <= !flush_done_toggle_h;
                    end else begin
                        flush_index <= flush_index + 1'b1;
                        flush_state <= FLUSH_READ;
                    end
                end
                default: ;
            endcase
        end
    end

    reg request_meta_x;
    reg request_sync_x;
    reg request_seen_x;
    reg enable_meta_x;
    reg enable_sync_x;
    reg [11:0] new_tag_x;
    reg [11:0] old_tag_x;
    reg old_dirty_x;
    reg request_flush_x;
    reg preload_wait;

    reg snapshot_request_meta_x;
    reg snapshot_request_sync_x;
    reg snapshot_request_seen_x;
    reg snapshot_pending_x;
    reg snapshot_active_x;
    reg flush_done_meta_x;
    reg flush_done_sync_x;
    reg flush_done_seen_x;
    reg [6:0] snapshot_block_x;
    reg [15:0] snapshot_sequence_x;
    assign xfill_write = xread_valid && xstate == X_FILL_WAIT;

    always @* begin
        xwritedata = xway ? {q1_odd_x, q1_even_x}
                          : {q0_odd_x, q0_even_x};
    end

    always @(posedge xclk) begin
        xrequest <= 1'b0;
        if (xreset) begin
            enable_meta_x <= 1'b0;
            enable_sync_x <= 1'b0;
            request_meta_x <= 1'b0;
            request_sync_x <= 1'b0;
            request_seen_x <= 1'b0;
            complete_toggle_x <= 1'b0;
            fill_words_x <= 6'd0;
            fill_gray_x <= 6'd0;
            xstate <= X_IDLE;
            xword <= 5'd0;
            xread <= 1'b1;
            xaddress <= 23'd0;
            xlength <= LINE_BYTES;
            preload_wait <= 1'b0;
            request_flush_x <= 1'b0;
            snapshot_request_meta_x <= 1'b0;
            snapshot_request_sync_x <= 1'b0;
            snapshot_request_seen_x <= 1'b0;
            snapshot_pending_x <= 1'b0;
            snapshot_active_x <= 1'b0;
            flush_request_toggle_x <= 1'b0;
            flush_done_meta_x <= 1'b0;
            flush_done_sync_x <= 1'b0;
            flush_done_seen_x <= 1'b0;
            snapshot_block_x <= 7'd0;
            snapshot_sequence_x <= 16'd0;
            snapshot_chunk_x <= 4'd0;
            xsnapshot_ready <= 1'b0;
            xsnapshot_ready_sequence <= 16'd0;
        end else begin
            enable_meta_x <= henable;
            enable_sync_x <= enable_meta_x;
            request_meta_x <= request_toggle_h;
            request_sync_x <= request_meta_x;
            snapshot_request_meta_x <= xsnapshot_request_toggle;
            snapshot_request_sync_x <= snapshot_request_meta_x;
            flush_done_meta_x <= flush_done_toggle_h;
            flush_done_sync_x <= flush_done_meta_x;
            if (!enable_sync_x) begin
                request_seen_x <= 1'b0;
                complete_toggle_x <= 1'b0;
                fill_words_x <= 6'd0;
                fill_gray_x <= 6'd0;
                xstate <= X_IDLE;
                xword <= 5'd0;
                xread <= 1'b1;
                xaddress <= 23'd0;
                xlength <= LINE_BYTES;
                preload_wait <= 1'b0;
                request_flush_x <= 1'b0;
                snapshot_request_seen_x <= snapshot_request_sync_x;
                snapshot_pending_x <= 1'b0;
                snapshot_active_x <= 1'b0;
                flush_request_toggle_x <= 1'b0;
                flush_done_seen_x <= flush_done_sync_x;
                snapshot_chunk_x <= 4'd0;
                xsnapshot_ready <= 1'b0;
            end else begin
                if (xfill_write) begin
                    fill_words_x <= fill_words_next_x;
                    fill_gray_x <= fill_words_next_x ^
                                   (fill_words_next_x >> 1);
                end
                case (xstate)
                    X_IDLE: begin
                        if (request_sync_x != request_seen_x) begin
                            request_seen_x <= request_sync_x;
                            xset <= request_set_h;
                            xway <= request_way_h;
                            new_tag_x <= request_new_tag_h;
                            old_tag_x <= request_old_tag_h;
                            old_dirty_x <= request_old_dirty_h;
                            request_flush_x <= request_flush_h;
                            xword <= 5'd0;
                            preload_wait <= 1'b0;
                            xstate <= request_old_dirty_h
                                ? X_WB_PRELOAD : X_FILL_REQUEST;
                        end else if (snapshot_pending_x &&
                                     flush_done_sync_x != flush_done_seen_x) begin
                            flush_done_seen_x <= flush_done_sync_x;
                            snapshot_pending_x <= 1'b0;
                            snapshot_active_x <= 1'b1;
                            snapshot_chunk_x <= 4'd0;
                            xstate <= X_SNAPSHOT_REQUEST;
                        end else if (snapshot_active_x) begin
                            xstate <= X_SNAPSHOT_REQUEST;
                        end else if (snapshot_request_sync_x !=
                                     snapshot_request_seen_x) begin
                            snapshot_request_seen_x <=
                                snapshot_request_sync_x;
                            snapshot_block_x <= xsnapshot_block;
                            snapshot_sequence_x <= xsnapshot_sequence;
                            xsnapshot_ready <= 1'b0;
                            if (xsnapshot_block == 0) begin
                                snapshot_pending_x <= 1'b1;
                                flush_request_toggle_x <=
                                    !flush_request_toggle_x;
                            end else begin
                                snapshot_pending_x <= 1'b0;
                                snapshot_active_x <= 1'b1;
                                snapshot_chunk_x <= 4'd0;
                                xstate <= X_SNAPSHOT_REQUEST;
                            end
                        end
                    end
                    X_WB_PRELOAD: begin
                        if (preload_wait) xstate <= X_WB_REQUEST;
                        else preload_wait <= 1'b1;
                    end
                    X_WB_REQUEST: begin
                        xread <= 1'b0;
                        xaddress <= {old_tag_x, xset[4:0], 6'd0};
                        xlength <= LINE_BYTES;
                        xrequest <= 1'b1;
                        xstate <= X_WB_WAIT;
                    end
                    X_WB_WAIT: begin
                        if (xwrite_next) xword <= xword + 1'b1;
                        if (xdone) begin
                            xword <= 5'd0;
                            if (request_flush_x) begin
                                request_flush_x <= 1'b0;
                                complete_toggle_x <= !complete_toggle_x;
                                xstate <= X_IDLE;
                            end else begin
                                xstate <= X_FILL_REQUEST;
                            end
                        end
                    end
                    X_FILL_REQUEST: begin
                        xread <= 1'b1;
                        xaddress <= {new_tag_x, xset[4:0], 6'd0};
                        xlength <= LINE_BYTES;
                        xrequest <= 1'b1;
                        xstate <= X_FILL_WAIT;
                    end
                    X_FILL_WAIT: begin
                        if (xread_valid) begin
                            xword <= xword + 1'b1;
                        end
                        if (xdone) begin
                            complete_toggle_x <= !complete_toggle_x;
                            xstate <= X_IDLE;
                        end
                    end
                    X_SNAPSHOT_REQUEST: begin
                        xread <= 1'b1;
                        xword <= 5'd0;
                        xaddress <= SAVE_BASE +
                            {6'd0, snapshot_block_x,
                             snapshot_chunk_x, 6'd0};
                        xlength <= LINE_BYTES;
                        xrequest <= 1'b1;
                        xstate <= X_SNAPSHOT_WAIT;
                    end
                    X_SNAPSHOT_WAIT: begin
                        if (xread_valid)
                            xword <= xword + 1'b1;
                        if (xdone) begin
                            snapshot_chunk_x <= snapshot_chunk_x + 1'b1;
                            if (&snapshot_chunk_x) begin
                                snapshot_active_x <= 1'b0;
                                xsnapshot_ready_sequence <= snapshot_sequence_x;
                                xsnapshot_ready <= 1'b1;
                            end
                            xstate <= X_IDLE;
                        end
                    end
                    default: xstate <= X_IDLE;
                endcase
            end
        end
    end
endmodule

module gowin_dpb_snapshot (
    input         write_clock,
    input         write_enable,
    input   [8:0] write_address,
    input  [15:0] write_data,
    input         read_clock,
    input   [8:0] read_address,
    output [15:0] read_data
);
`ifdef __ICARUS__
    reg [15:0] memory [0:511];
    reg [15:0] read_data_reg;
    always @(posedge write_clock)
        if (write_enable) memory[write_address] <= write_data;
    always @(posedge read_clock)
        read_data_reg <= memory[read_address];
    assign read_data = read_data_reg;
`else
    wire [15:0] primitive_q_a;
    wire [15:0] primitive_q_b;
    DPB #(
        .READ_MODE0(1'b0),
        .READ_MODE1(1'b0),
        .WRITE_MODE0(2'b00),
        .WRITE_MODE1(2'b00),
        .BIT_WIDTH_0(16),
        .BIT_WIDTH_1(16),
        .BLK_SEL_0(3'b000),
        .BLK_SEL_1(3'b000),
        .RESET_MODE("SYNC")
    ) snapshot_ram (
        .DOA(primitive_q_a),
        .DOB(primitive_q_b),
        .DIA(write_data),
        .DIB(16'd0),
        .BLKSELA(3'b000),
        .BLKSELB(3'b000),
        .ADA({1'b0, write_address, 4'b0011}),
        .ADB({1'b0, read_address, 4'b0000}),
        .WREA(write_enable),
        .WREB(1'b0),
        .CLKA(write_clock),
        .CLKB(read_clock),
        .CEA(1'b1),
        .CEB(1'b1),
        .OCEA(1'b0),
        .OCEB(1'b0),
        .RESETA(1'b0),
        .RESETB(1'b0)
    );
    assign read_data = primitive_q_b;
`endif
endmodule

module gowin_dpb_cache_byte (
    input         clock_a,
    input  [10:0] address_a,
    input   [7:0] data_a,
    input         wren_a,
    output  [7:0] q_a,
    input         clock_b,
    input  [10:0] address_b,
    input   [7:0] data_b,
    input         wren_b,
    output  [7:0] q_b
);
`ifdef __ICARUS__
    reg [7:0] memory [0:2047];
    reg [7:0] q_a_reg;
    reg [7:0] q_b_reg;
    always @(posedge clock_a) begin
        if (wren_a) memory[address_a] <= data_a;
        else q_a_reg <= memory[address_a];
    end
    always @(posedge clock_b) begin
        if (wren_b) memory[address_b] <= data_b;
        else q_b_reg <= memory[address_b];
    end
    assign q_a = q_a_reg;
    assign q_b = q_b_reg;
`else
    wire [15:0] primitive_q_a;
    wire [15:0] primitive_q_b;
    DPB #(
        .READ_MODE0(1'b0),
        .READ_MODE1(1'b0),
        .WRITE_MODE0(2'b00),
        .WRITE_MODE1(2'b00),
        .BIT_WIDTH_0(8),
        .BIT_WIDTH_1(8),
        .BLK_SEL_0(3'b000),
        .BLK_SEL_1(3'b000),
        .RESET_MODE("SYNC")
    ) cache_ram (
        .DOA(primitive_q_a),
        .DOB(primitive_q_b),
        .DIA({8'd0, data_a}),
        .DIB({8'd0, data_b}),
        .BLKSELA(3'b000),
        .BLKSELB(3'b000),
        .ADA({address_a, 3'b000}),
        .ADB({address_b, 3'b000}),
        .WREA(wren_a),
        .WREB(wren_b),
        .CLKA(clock_a),
        .CLKB(clock_b),
        .CEA(1'b1),
        .CEB(1'b1),
        .OCEA(1'b0),
        .OCEB(1'b0),
        .RESETA(1'b0),
        .RESETB(1'b0)
    );
    assign q_a = primitive_q_a[7:0];
    assign q_b = primitive_q_b[7:0];
`endif
endmodule

module gowin_sdpb_tag_way (
    input         clock,
    input         write_enable,
    input   [5:0] address,
    input  [15:0] write_data,
    output [15:0] read_data
);
`ifdef __ICARUS__
    reg [15:0] memory [0:63];
    reg [15:0] read_data_reg;
    always @(posedge clock) begin
        if (write_enable) memory[address] <= write_data;
        else read_data_reg <= memory[address];
    end
    assign read_data = read_data_reg;
`else
    wire [31:0] primitive_data_out;
    SDPB #(
        .READ_MODE(1'b0),
        .BIT_WIDTH_0(16),
        .BIT_WIDTH_1(16),
        .BLK_SEL_0(3'b000),
        .BLK_SEL_1(3'b000),
        .RESET_MODE("SYNC")
    ) tag_ram (
        .DO(primitive_data_out),
        .DI({16'd0, write_data}),
        .BLKSELA(3'b000),
        .BLKSELB(3'b000),
        .ADA({4'd0, address, 4'b0011}),
        .ADB({4'd0, address, 4'd0}),
        .CLKA(clock),
        .CLKB(clock),
        .CEA(write_enable),
        .CEB(1'b1),
        .OCE(1'b0),
        .RESET(1'b0)
    );
    assign read_data = primitive_data_out[15:0];
`endif
endmodule
