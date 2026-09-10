`timescale 1ns/1ps
`default_nettype none

module virtual_cart_session_cdc (
    input  wire       gclk,
    input  wire       hclk,
    input  wire       reset_g,
    input  wire       reset_h,
    input  wire       prepare_g,
    input  wire       start_g,
    input  wire       stop_g,
    input  wire       quiesce_g,
    input  wire       resume_g,
    input  wire       core_quiesced_h,
    input  wire       core_reset_h,
    input  wire       boot_rom_enabled_h,
    input  wire       core_frame_valid_h,
    output reg        enable_g,
    output reg        enable_h,
    output wire       attempt_reset_h,
    output wire       quiesce_h,
    output wire       quiesced_g,
    output reg        start_pending_g,
    output reg        prepared_g,
    output wire [5:0] lifecycle_g
);
    reg reset_request_g;

    (* ASYNC_REG = "TRUE" *) reg enable_h_meta;
    (* ASYNC_REG = "TRUE" *) reg request_h_meta;
    (* ASYNC_REG = "TRUE" *) reg request_h_sync;
    reg request_h_d;

    wire reset_ack_h = request_h_sync && !enable_h && core_reset_h;
    wire quiesce_ack_h = request_h_sync && enable_h && core_quiesced_h;
    (* ASYNC_REG = "TRUE" *) reg quiesce_ack_g_meta;
    (* ASYNC_REG = "TRUE" *) reg quiesce_ack_g_sync;
    (* ASYNC_REG = "TRUE" *) reg ack_g_meta;
    (* ASYNC_REG = "TRUE" *) reg ack_g_sync;

    reg [5:0] lifecycle_h;
    (* ASYNC_REG = "TRUE" *) reg [5:0] lifecycle_g_meta;
    (* ASYNC_REG = "TRUE" *) reg [5:0] lifecycle_g_sync;

    assign attempt_reset_h = request_h_sync && !enable_h;
    assign quiesce_h = request_h_sync && enable_h;
    assign quiesced_g = reset_request_g && enable_g && quiesce_ack_g_sync;
    assign lifecycle_g = lifecycle_g_sync;

    always @(posedge gclk or posedge reset_g)
    begin
        if (reset_g)
        begin
            enable_g <= 1'b0;
            reset_request_g <= 1'b0;
            start_pending_g <= 1'b0;
            prepared_g <= 1'b0;
            ack_g_meta <= 1'b0;
            quiesce_ack_g_meta <= 1'b0;
            quiesce_ack_g_sync <= 1'b0;
            ack_g_sync <= 1'b0;
            lifecycle_g_meta <= 6'd0;
            lifecycle_g_sync <= 6'd0;
        end
        else
        begin
            ack_g_meta <= reset_ack_h;
            quiesce_ack_g_meta <= quiesce_ack_h;
            quiesce_ack_g_sync <= quiesce_ack_g_meta;
            ack_g_sync <= ack_g_meta;
            lifecycle_g_meta <= lifecycle_h;
            lifecycle_g_sync <= lifecycle_g_meta;

            if (stop_g)
            begin
                enable_g <= 1'b0;
                reset_request_g <= 1'b0;
                start_pending_g <= 1'b0;
                prepared_g <= 1'b0;
            end
            else if (prepare_g)
            begin
                enable_g <= 1'b0;
                reset_request_g <= 1'b1;
                start_pending_g <= 1'b1;
                prepared_g <= 1'b0;
            end
            else if (start_pending_g && ack_g_sync)
            begin
                enable_g <= 1'b0;
                reset_request_g <= 1'b1;
                start_pending_g <= 1'b0;
                prepared_g <= 1'b1;
            end
            else if (quiesce_g && enable_g)
            begin
                reset_request_g <= 1'b1;
            end
            else if (resume_g && enable_g)
            begin
                reset_request_g <= 1'b0;
            end
            else if (start_g && prepared_g)
            begin
                enable_g <= 1'b1;
                reset_request_g <= 1'b0;
                prepared_g <= 1'b0;
            end
        end
    end

    always @(posedge hclk or posedge reset_h)
    begin
        if (reset_h)
        begin
            enable_h_meta <= 1'b0;
            enable_h <= 1'b0;
            request_h_meta <= 1'b0;
            request_h_sync <= 1'b0;
            request_h_d <= 1'b0;
            lifecycle_h <= 6'd0;
        end
        else
        begin
            enable_h_meta <= enable_g;
            enable_h <= enable_h_meta;
            request_h_meta <= reset_request_g;
            request_h_sync <= request_h_meta;
            request_h_d <= request_h_sync;

            if (request_h_sync && !request_h_d)
            begin
                lifecycle_h <= 6'd0;
            end
            else
            begin
                if (request_h_sync && !enable_h)
                    lifecycle_h[0] <= 1'b1;
                if (lifecycle_h[0] && core_reset_h)
                    lifecycle_h[1] <= 1'b1;
                if (lifecycle_h[1] && enable_h && !core_reset_h)
                    lifecycle_h[2] <= 1'b1;
                if (lifecycle_h[2] && boot_rom_enabled_h)
                    lifecycle_h[3] <= 1'b1;
                if (lifecycle_h[3] && !boot_rom_enabled_h)
                    lifecycle_h[4] <= 1'b1;
                if (lifecycle_h[4] && core_frame_valid_h)
                    lifecycle_h[5] <= 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
