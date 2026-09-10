`timescale 1ns/1ps
`default_nettype none

module cart_maintenance_cdc (
    input  wire gclk,
    input  wire hclk,
    input  wire reset_g,
    input  wire reset_h,
    input  wire ownership_request_g,
    output wire ownership_ack_g,
    output wire maintenance_active_h,
    output wire maintenance_reset_h
);
    (* ASYNC_REG = "TRUE" *) reg request_h_meta;
    (* ASYNC_REG = "TRUE" *) reg request_h_sync;
    (* ASYNC_REG = "TRUE" *) reg ack_g_meta;
    (* ASYNC_REG = "TRUE" *) reg ack_g_sync;

    always @(posedge hclk or posedge reset_h)
    begin
        if (reset_h)
        begin
            request_h_meta <= 1'b0;
            request_h_sync <= 1'b0;
        end
        else
        begin
            request_h_meta <= ownership_request_g;
            request_h_sync <= request_h_meta;
        end
    end

    always @(posedge gclk or posedge reset_g)
    begin
        if (reset_g)
        begin
            ack_g_meta <= 1'b0;
            ack_g_sync <= 1'b0;
        end
        else
        begin
            ack_g_meta <= request_h_sync;
            ack_g_sync <= ack_g_meta;
        end
    end

    assign ownership_ack_g = ack_g_sync;
    assign maintenance_active_h = request_h_sync;
    assign maintenance_reset_h = request_h_sync;
endmodule

`default_nettype wire
