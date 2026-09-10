`timescale 1ns/1ps

module audio_filter_deterministic_tb;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg [15:0] core_l = 16'd0;
    reg [15:0] core_r = 16'd0;
    wire [15:0] filter_l;
    wire [15:0] filter_r;

    always #5 clk = ~clk;

    audio_filter_deterministic dut (
        .reset(reset),
        .clk(clk),
        .core_l(core_l),
        .core_r(core_r),
        .filter_l(filter_l),
        .filter_r(filter_r)
    );

    task automatic require_zero_state;
    begin
        if (dut.div !== 8'd0 || dut.sample_ce !== 1'b0 ||
            dut.cnt !== 32'd0 || dut.flt_ce !== 1'b0 ||
            dut.cl !== 16'd0 || dut.cr !== 16'd0 ||
            dut.u_iir_filter.ch !== 1'b0 ||
            dut.u_iir_filter.out !== 32'd0 ||
            dut.u_iir_filter.u_tap_0.intreg[0] !== 40'd0 ||
            dut.u_iir_filter.u_tap_0.intreg[1] !== 40'd0 ||
            dut.u_dcb_l.x1 !== 40'd0 || dut.u_dcb_l.y !== 40'd0 ||
            dut.u_dcb_r.x1 !== 40'd0 || dut.u_dcb_r.y !== 40'd0 ||
            filter_l !== 16'd0 || filter_r !== 16'd0) begin
            $display("FAIL: reset did not clear every filter state");
            $fatal;
        end
    end
    endtask

    integer i;
    initial begin
        repeat (4) @(posedge clk);
        #1 require_zero_state();
        reset = 1'b0;

        for (i = 0; i < 20000; i = i + 1) begin
            @(negedge clk);
            core_l = i[15:0] ^ 16'h2468;
            core_r = ~i[15:0] ^ 16'h1357;
        end

        @(negedge clk);
        dut.div = 8'h9d;
        dut.sample_ce = 1'b1;
        dut.cnt = 32'hdeadbeef;
        dut.flt_ce = 1'b1;
        dut.cl = 16'haaaa;
        dut.cr = 16'h5555;
        dut.u_iir_filter.ch = 1'b1;
        dut.u_iir_filter.out = 32'h7fff8000;
        dut.u_iir_filter.u_tap_0.intreg[0] = 40'h7fffffffff;
        dut.u_iir_filter.u_tap_0.intreg[1] = 40'h8000000000;
        dut.u_dcb_l.x1 = 40'h123456789a;
        dut.u_dcb_l.y = 40'h7fffffffff;
        dut.u_dcb_r.x1 = 40'habcdef0123;
        dut.u_dcb_r.y = 40'h8000000000;

        #1 reset = 1'b1;
        #1 require_zero_state();
        repeat (4) @(posedge clk);
        #1 require_zero_state();

        reset = 1'b0;
        repeat (32) @(posedge clk);
        if ($isunknown({filter_l, filter_r})) begin
            $display("FAIL: unknown output after deterministic restart");
            $fatal;
        end

        $display("PASS: deterministic audio filter clears all startup state");
        $finish;
    end
endmodule
