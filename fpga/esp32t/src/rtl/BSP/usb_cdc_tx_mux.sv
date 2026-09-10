`timescale 1ns/1ps
`default_nettype none

module usb_cdc_tx_mux (
    input  wire       reset,
    input  wire       pclk,
    input  wire       gclk,
    input  wire [7:0] uart_data_p,
    input  wire       uart_valid_p,
    input  wire [7:0] stream_data_g,
    input  wire       stream_valid_g,
    output wire       stream_ready_g,
    input  wire       endpoint_ready_g,
    output wire [7:0] endpoint_data_g,
    output wire       endpoint_valid_g
);
    reg [7:0] uart_hold_p;
    reg uart_request_p;
    reg uart_ack_p1;
    reg uart_ack_p2;

    reg uart_request_g1;
    reg uart_request_g2;
    reg uart_ack_g;
    reg uart_pending_g;
    reg [7:0] uart_data_g;

    wire uart_busy_p = uart_request_p != uart_ack_p2;
    wire uart_accept_g = uart_pending_g && endpoint_ready_g;

    assign endpoint_valid_g = uart_pending_g || stream_valid_g;
    assign endpoint_data_g = uart_pending_g ? uart_data_g : stream_data_g;
    assign stream_ready_g = endpoint_ready_g && !uart_pending_g;

    always @(posedge pclk or posedge reset)
    begin
        if (reset)
        begin
            uart_hold_p <= 8'd0;
            uart_request_p <= 1'b0;
            uart_ack_p1 <= 1'b0;
            uart_ack_p2 <= 1'b0;
        end
        else
        begin
            uart_ack_p1 <= uart_ack_g;
            uart_ack_p2 <= uart_ack_p1;
            if (uart_valid_p && !uart_busy_p)
            begin
                uart_hold_p <= uart_data_p;
                uart_request_p <= ~uart_request_p;
            end
        end
    end

    always @(posedge gclk or posedge reset)
    begin
        if (reset)
        begin
            uart_request_g1 <= 1'b0;
            uart_request_g2 <= 1'b0;
            uart_ack_g <= 1'b0;
            uart_pending_g <= 1'b0;
            uart_data_g <= 8'd0;
        end
        else
        begin
            uart_request_g1 <= uart_request_p;
            uart_request_g2 <= uart_request_g1;
            if (!uart_pending_g && uart_request_g2 != uart_ack_g)
            begin
                uart_data_g <= uart_hold_p;
                uart_pending_g <= 1'b1;
            end
            else if (uart_accept_g)
            begin
                uart_pending_g <= 1'b0;
                uart_ack_g <= uart_request_g2;
            end
        end
    end
endmodule

`default_nettype wire
