`timescale 1ns/1ps

module audio_filter_equivalence_tb;
    reg clk = 1'b0;
    reg reset = 1'b1;
    reg [15:0] core_l = 16'd0;
    reg [15:0] core_r = 16'd0;
    wire [15:0] stock_l;
    wire [15:0] stock_r;
    wire [15:0] deterministic_l;
    wire [15:0] deterministic_r;

    always #5 clk = ~clk;

    audio_filter stock (
        .reset(reset), .clk(clk), .core_l(core_l), .core_r(core_r),
        .filter_l(stock_l), .filter_r(stock_r)
    );

    audio_filter_deterministic deterministic (
        .reset(reset), .clk(clk), .core_l(core_l), .core_r(core_r),
        .filter_l(deterministic_l), .filter_r(deterministic_r)
    );

    integer i;
    initial begin
        repeat (4) @(posedge clk);
        @(negedge clk);

        stock.sample_ce = 1'b0;
        stock.div = 8'd0;
        stock.flt_ce = 1'b0;
        stock.cnt = 32'd0;
        stock.cl = 16'd0;
        stock.cr = 16'd0;
        stock.cl1 = 16'd0;
        stock.cl2 = 16'd0;
        stock.cr1 = 16'd0;
        stock.cr2 = 16'd0;
        stock.IIR_filter.ch = 1'b0;
        stock.IIR_filter.out_l = 16'd0;
        stock.IIR_filter.out_r = 16'd0;
        stock.IIR_filter.out_m = 16'd0;
        stock.IIR_filter.inp = 16'd0;
        stock.IIR_filter.inp_m = 16'd0;
        stock.IIR_filter.out = 32'd0;
        stock.dcb_l.x1 = 40'd0;
        stock.dcb_l.y = 40'd0;
        stock.dcb_r.x1 = 40'd0;
        stock.dcb_r.y = 40'd0;

        reset = 1'b0;

        stock.a_en1 = 1'b1;
        stock.a_en2 = 1'b1;
        deterministic.a_en1 = 1'b1;
        deterministic.a_en2 = 1'b1;

        for (i = 0; i < 150000; i = i + 1) begin
            @(negedge clk);
            core_l = {i[7:0], i[15:8]} ^ 16'h4210;
            core_r = ~{i[4:0], i[15:5]} ^ 16'h1842;
            @(posedge clk);
            #1;
            if ({stock_l, stock_r} !== {deterministic_l, deterministic_r}) begin
                $display("FAIL: steady-state mismatch cycle=%0d stock=%h/%h deterministic=%h/%h",
                         i, stock_l, stock_r, deterministic_l, deterministic_r);
                $fatal;
            end
        end

        $display("PASS: deterministic filter is cycle-equivalent from equal state");
        $finish;
    end
endmodule
