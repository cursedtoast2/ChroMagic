`timescale 1ns/1ps
`default_nettype none

module cart_maintenance_cdc_tb;
    reg gclk = 1'b0;
    reg hclk = 1'b0;
    reg reset_g = 1'b1;
    reg reset_h = 1'b1;
    reg request_g = 1'b0;
    wire ack_g;
    wire active_h;
    wire core_reset_h;

    always #10 gclk = ~gclk;
    always #6 hclk = ~hclk;

    cart_maintenance_cdc dut (
        .gclk(gclk),
        .hclk(hclk),
        .reset_g(reset_g),
        .reset_h(reset_h),
        .ownership_request_g(request_g),
        .ownership_ack_g(ack_g),
        .maintenance_active_h(active_h),
        .maintenance_reset_h(core_reset_h)
    );

    initial begin
        repeat (3) @(posedge hclk);
        reset_h = 1'b0;
        reset_g = 1'b0;

        @(negedge gclk);
        request_g = 1'b1;
        if (active_h || core_reset_h || ack_g)
            $fatal(1, "request crossed domains combinationally");
        wait (active_h && core_reset_h);
        wait (ack_g);

        @(negedge gclk);
        request_g = 1'b0;
        if (!core_reset_h || !ack_g)
            $fatal(1, "release bypassed synchronized hClk state");
        wait (!active_h && !core_reset_h);
        wait (!ack_g);

        $display("PASS: cartridge ownership CDC request/ack sequencing");
        $finish;
    end

    initial begin
        #2000;
        $fatal(1, "timeout");
    end
endmodule

`default_nettype wire
