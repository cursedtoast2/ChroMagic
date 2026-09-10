`default_nettype none

module virtual_cart_rtc_cdc (
    input  wire        gclk,
    input  wire        hclk,
    input  wire        reset_g,
    input  wire        reset_h,

    input  wire        request_g,
    input  wire [1:0]  operation_g,
    input  wire [15:0] write_data_g,
    output reg         busy_g,
    output reg         done_g,
    output wire [28:0] snapshot_g,

    input  wire [28:0] rtc_state_h,
    output reg         bk_rtc_wr_h,
    output reg   [2:0] bk_addr_h,
    output reg  [15:0] bk_data_h
);
    localparam [1:0] OP_RESTORE_LOW = 2'd0;
    localparam [1:0] OP_RESTORE_HIGH_COMMIT = 2'd1;
    localparam [1:0] OP_SNAPSHOT = 2'd2;

    reg request_toggle_g;
    reg [1:0] operation_hold_g;
    (* ASYNC_REG = "TRUE" *) reg ack_g_meta;
    (* ASYNC_REG = "TRUE" *) reg ack_g_sync;

    reg ack_toggle_h;
    (* ASYNC_REG = "TRUE" *) reg request_h_meta;
    (* ASYNC_REG = "TRUE" *) reg request_h_sync;
    reg request_h_seen;
    reg commit_pending_h;
    reg [1:0] low_restore_stage_h;
    wire snapshot_write_h = request_h_sync != request_h_seen &&
        operation_hold_g == OP_SNAPSHOT;

    virtual_cart_rtc_snapshot_ram u_snapshot_ram (
        .write_clock(hclk),
        .write_enable(snapshot_write_h),
        .write_data(rtc_state_h),
        .read_clock(gclk),
        .read_data(snapshot_g));

    always @(posedge gclk or posedge reset_g) begin
        if (reset_g) begin
            request_toggle_g <= 1'b0;
            operation_hold_g <= OP_RESTORE_LOW;
            ack_g_meta <= 1'b0;
            ack_g_sync <= 1'b0;
            busy_g <= 1'b0;
            done_g <= 1'b0;
        end else begin
            ack_g_meta <= ack_toggle_h;
            ack_g_sync <= ack_g_meta;
            done_g <= 1'b0;

            if (request_g && !busy_g) begin
                operation_hold_g <= operation_g;
                request_toggle_g <= ~request_toggle_g;
                busy_g <= 1'b1;
            end

            if (busy_g && ack_g_sync == request_toggle_g) begin
                busy_g <= 1'b0;
                done_g <= 1'b1;
            end
        end
    end

    always @(posedge hclk or posedge reset_h) begin
        if (reset_h) begin
            request_h_meta <= 1'b0;
            request_h_sync <= 1'b0;
            request_h_seen <= 1'b0;
            ack_toggle_h <= 1'b0;
            commit_pending_h <= 1'b0;
            low_restore_stage_h <= 2'd0;
            bk_rtc_wr_h <= 1'b0;
            bk_addr_h <= 3'd0;
            bk_data_h <= 16'd0;
        end else begin
            request_h_meta <= request_toggle_g;
            request_h_sync <= request_h_meta;
            bk_rtc_wr_h <= 1'b0;

            if (low_restore_stage_h != 0) begin
                bk_rtc_wr_h <= 1'b1;
                if (low_restore_stage_h == 2'd1) begin
                    bk_addr_h <= 3'd1;
                    bk_data_h <= 16'd0;
                    low_restore_stage_h <= 2'd2;
                end else begin
                    bk_addr_h <= 3'd2;
                    bk_data_h <= write_data_g;
                    low_restore_stage_h <= 2'd0;
                    ack_toggle_h <= request_h_seen;
                end
            end else if (commit_pending_h) begin
                bk_rtc_wr_h <= 1'b1;
                bk_addr_h <= 3'd4;
                bk_data_h <= 16'd0;
                commit_pending_h <= 1'b0;
                ack_toggle_h <= request_h_seen;
            end else if (request_h_sync != request_h_seen) begin
                request_h_seen <= request_h_sync;
                case (operation_hold_g)
                    OP_RESTORE_LOW: begin
                        bk_rtc_wr_h <= 1'b1;
                        bk_addr_h <= 3'd0;
                        bk_data_h <= 16'd0;
                        low_restore_stage_h <= 2'd1;
                    end
                    OP_RESTORE_HIGH_COMMIT: begin
                        bk_rtc_wr_h <= 1'b1;
                        bk_addr_h <= 3'd3;
                        bk_data_h <= write_data_g;
                        commit_pending_h <= 1'b1;
                    end
                    OP_SNAPSHOT: begin
                        ack_toggle_h <= request_h_sync;
                    end
                    default: ack_toggle_h <= request_h_sync;
                endcase
            end
        end
    end
endmodule

module virtual_cart_rtc_snapshot_ram (
    input  wire        write_clock,
    input  wire        write_enable,
    input  wire [28:0] write_data,
    input  wire        read_clock,
    output wire [28:0] read_data
);
`ifdef __ICARUS__
    reg [28:0] memory;
    reg [28:0] read_data_reg;
    always @(posedge write_clock)
        if (write_enable) memory <= write_data;
    always @(posedge read_clock)
        read_data_reg <= memory;
    assign read_data = read_data_reg;
`else
    wire [35:0] primitive_data_out;
    SDPX9B #(
        .READ_MODE(1'b0),
        .BIT_WIDTH_0(36),
        .BIT_WIDTH_1(36),
        .BLK_SEL_0(3'b000),
        .BLK_SEL_1(3'b000),
        .RESET_MODE("SYNC")
    ) rtc_snapshot_ram (
        .DO(primitive_data_out),
        .DI({7'd0, write_data}),
        .BLKSELA(3'b000),
        .BLKSELB(3'b000),
        .ADA({9'd0, 5'b01111}),
        .ADB(14'd0),
        .CLKA(write_clock),
        .CLKB(read_clock),
        .CEA(write_enable),
        .CEB(1'b1),
        .OCE(1'b0),
        .RESET(1'b0)
    );
    assign read_data = primitive_data_out[28:0];
`endif
endmodule

`default_nettype wire
