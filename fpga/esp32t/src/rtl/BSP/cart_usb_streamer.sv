`timescale 1ns/1ps
`default_nettype none

module cart_usb_streamer (
    input  wire        clk,
    input  wire        reset,
    input  wire        enabled,
    input  wire        event_valid,
    input  wire [7:0]  event_sequence,
    input  wire [1:0]  block_ready,

    output reg  [10:0] ram_address,
    input  wire [7:0]  ram_data,

    output wire        tx_valid,
    input  wire        tx_ready,
    output reg  [7:0]  tx_data,
    output wire        busy,
    output wire        event_complete
);
    localparam [1:0] STATE_IDLE = 2'd0;
    localparam [1:0] STATE_READ = 2'd1;
    localparam [1:0] STATE_DATA = 2'd2;

    reg [1:0] state;
    reg event_seen;
    reg [9:0] data_index;
    reg [1:0] blocks_remaining;
    reg current_slot;

    assign busy = state != STATE_IDLE;
    assign event_complete = event_seen && !busy;
    assign tx_valid = state == STATE_DATA;

    always @(*) tx_data = ram_data;

    always @(posedge clk or posedge reset)
    begin
        if (reset)
        begin
            state              <= STATE_IDLE;
            event_seen         <= 1'b0;
            data_index         <= 10'd0;
            blocks_remaining   <= 2'd0;
            current_slot       <= 1'b0;
            ram_address        <= 11'd0;
        end
        else
        begin
            if (!event_valid)
                event_seen <= 1'b0;

            case (state)
                STATE_IDLE:
                begin
                    if (enabled && event_valid && !event_seen)
                    begin
                        if (block_ready[event_sequence[0] ^ 1'b1])
                        begin
                            current_slot <= ~event_sequence[0];
                            ram_address <= {~event_sequence[0], 10'd0};
                            blocks_remaining <= 2'd2;
                        end
                        else
                        begin
                            current_slot <= event_sequence[0];
                            ram_address <= {event_sequence[0], 10'd0};
                            blocks_remaining <= 2'd1;
                        end
                        data_index <= 10'd0;
                        event_seen <= 1'b1;
                        state <= STATE_READ;
                    end
                end

                STATE_READ:
                    state <= STATE_DATA;

                STATE_DATA:
                begin
                    if (tx_ready)
                    begin
                        if (data_index == 10'd1023)
                        begin
                            if (blocks_remaining == 2'd2)
                            begin
                                current_slot <= ~current_slot;
                                ram_address <= {~current_slot, 10'd0};
                                blocks_remaining <= 2'd1;
                                data_index <= 10'd0;
                                state <= STATE_READ;
                            end
                            else
                            begin
                                blocks_remaining <= 2'd0;
                                state <= STATE_IDLE;
                            end
                        end
                        else
                        begin
                            data_index <= data_index + 1'b1;
                            ram_address <= {current_slot,
                                            data_index + 1'b1};
                            state <= STATE_READ;
                        end
                    end
                end

                default:
                    state <= STATE_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
