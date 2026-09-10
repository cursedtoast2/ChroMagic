`timescale 1ns/1ps
`default_nettype none

module usb_cdc_tx_mux_tb;
    reg reset = 1'b1;
    reg pclk = 1'b0;
    reg gclk = 1'b0;
    reg [7:0] uart_data_p = 8'd0;
    reg uart_valid_p = 1'b0;
    integer stream_index = 0;
    wire [7:0] stream_data_g = stream_index[7:0];
    wire stream_valid_g = stream_index < 32;
    wire stream_ready_g;
    reg endpoint_ready_g = 1'b1;
    wire [7:0] endpoint_data_g;
    wire endpoint_valid_g;

    integer endpoint_count = 0;
    integer stream_count = 0;
    integer uart_count = 0;
    integer gcycles = 0;

    always #4 pclk = ~pclk;
    always #7 gclk = ~gclk;

    usb_cdc_tx_mux dut (
        .reset(reset),
        .pclk(pclk),
        .gclk(gclk),
        .uart_data_p(uart_data_p),
        .uart_valid_p(uart_valid_p),
        .stream_data_g(stream_data_g),
        .stream_valid_g(stream_valid_g),
        .stream_ready_g(stream_ready_g),
        .endpoint_ready_g(endpoint_ready_g),
        .endpoint_data_g(endpoint_data_g),
        .endpoint_valid_g(endpoint_valid_g)
    );

    always @(posedge gclk)
    begin
        if (reset)
        begin
            stream_index <= 0;
            endpoint_count <= 0;
            stream_count <= 0;
            uart_count <= 0;
            gcycles <= 0;
            endpoint_ready_g <= 1'b1;
        end
        else
        begin
            gcycles <= gcycles + 1;
            endpoint_ready_g <= (gcycles % 9) != 4;
            if (stream_valid_g && stream_ready_g)
                stream_index <= stream_index + 1;

            if (endpoint_valid_g && endpoint_ready_g)
            begin
                endpoint_count <= endpoint_count + 1;
                if (endpoint_data_g == 8'hee)
                    uart_count <= uart_count + 1;
                else
                begin
                    if (endpoint_data_g !== stream_count[7:0])
                        $fatal(1, "stream order mismatch: got %02x expected %02x",
                               endpoint_data_g, stream_count[7:0]);
                    stream_count <= stream_count + 1;
                end
            end
        end
    end

    initial begin
        repeat (5) @(posedge pclk);
        reset = 1'b0;
        repeat (20) @(posedge pclk);
        uart_data_p = 8'hee;
        uart_valid_p = 1'b1;
        @(posedge pclk);
        uart_valid_p = 1'b0;

        wait (stream_index == 32);
        wait (uart_count == 1);
        repeat (10) @(posedge gclk);
        if (stream_count != 32 || endpoint_count != 33 || uart_count != 1)
            $fatal(1, "mux count mismatch: stream=%0d uart=%0d total=%0d",
                   stream_count, uart_count, endpoint_count);
        $display("PASS: UART control and direct USB stream merge without loss");
        $finish;
    end
endmodule

`default_nettype wire
