
module audio_filter_deterministic
(
    input               reset,
    input               clk,
    input        [15:0] core_l,
    input        [15:0] core_r,
    output       [15:0] filter_l,
    output       [15:0] filter_r
);

localparam integer CLK_RATE = 16777000;
localparam [31:0] FLT_RATE = 32'd7056000;
localparam [39:0] CX = 40'd4258969;
localparam [7:0] CX0 = 8'd3;
localparam [7:0] CX1 = 8'd3;
localparam [7:0] CX2 = 8'd1;
localparam [23:0] CY0 = 24'hA123C9;
localparam [23:0] CY1 = 24'h5DBD9A;
localparam [23:0] CY2 = 24'hE11EA9;

reg sample_ce;
reg [7:0] div;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        sample_ce <= 1'b0;
        div <= 8'd0;
    end else begin
        div <= div + 1'd1;
        if (!div)
            div <= 8'd1;
        sample_ce <= !div;
    end
end

reg flt_ce;
reg [31:0] cnt;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        flt_ce = 1'b0;
        cnt = 32'd0;
    end else begin
        flt_ce = 1'b0;
        cnt = cnt + {FLT_RATE[30:0], 1'b0};
        if (cnt >= CLK_RATE) begin
            cnt = cnt - CLK_RATE;
            flt_ce = 1'b1;
        end
    end
end

reg [15:0] cl;
reg [15:0] cr;
reg [15:0] cl1;
reg [15:0] cl2;
reg [15:0] cr1;
reg [15:0] cr2;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        cl <= 16'd0;
        cr <= 16'd0;
        cl1 <= 16'd0;
        cl2 <= 16'd0;
        cr1 <= 16'd0;
        cr2 <= 16'd0;
    end else begin
        cl1 <= core_l;
        cl2 <= cl1;
        if (cl2 == cl1)
            cl <= cl2;

        cr1 <= core_r;
        cr2 <= cr1;
        if (cr2 == cr1)
            cr <= cr2;
    end
end

reg a_en1;
reg a_en2;
reg [1:0] dly1;
reg [14:0] dly2;
always @(posedge clk or posedge reset) begin
    if (reset) begin
        dly1 <= 2'd0;
        dly2 <= 15'd0;
        a_en1 <= 1'b0;
        a_en2 <= 1'b0;
    end else begin
        if (flt_ce) begin
            if (~&dly1)
                dly1 <= dly1 + 1'd1;
            else
                a_en1 <= 1'b1;
        end

        if (sample_ce) begin
            if (!dly2[13])
                dly2 <= dly2 + 1'd1;
            else
                a_en2 <= 1'b1;
        end
    end
end

wire [15:0] acl;
wire [15:0] acr;
iir_filter_deterministic u_iir_filter (
    .clk(clk),
    .reset(reset),
    .ce(flt_ce & a_en1),
    .sample_ce(sample_ce),
    .cx(CX),
    .cx0(CX0),
    .cx1(CX1),
    .cx2(CX2),
    .cy0(CY0),
    .cy1(CY1),
    .cy2(CY2),
    .input_l(cl),
    .input_r(cr),
    .output_l(acl),
    .output_r(acr)
);

dc_blocker_deterministic u_dcb_l (
    .clk(clk),
    .reset(reset),
    .ce(sample_ce),
    .sample_rate(1'b0),
    .mute(~a_en2),
    .din(acl),
    .dout(filter_l)
);

dc_blocker_deterministic u_dcb_r (
    .clk(clk),
    .reset(reset),
    .ce(sample_ce),
    .sample_rate(1'b0),
    .mute(~a_en2),
    .din(acr),
    .dout(filter_r)
);

endmodule

module iir_filter_deterministic
(
    input               clk,
    input               reset,
    input               ce,
    input               sample_ce,
    input        [39:0] cx,
    input         [7:0] cx0,
    input         [7:0] cx1,
    input         [7:0] cx2,
    input        [23:0] cy0,
    input        [23:0] cy1,
    input        [23:0] cy2,
    input        [15:0] input_l,
    input        [15:0] input_r,
    output       [15:0] output_l,
    output       [15:0] output_r
);

reg ch;
reg [15:0] out_l;
reg [15:0] out_r;
reg [15:0] out_m;
reg [15:0] inp;
reg [15:0] inp_m;

wire [59:0] inp_mul = $signed(inp) * $signed(cx);
wire [39:0] tap0;
wire [39:0] tap1;
wire [39:0] tap2;
wire [39:0] x = inp_mul[59:20];
wire [39:0] y = x + tap0;

iir_filter_tap_deterministic u_tap_0 (
    .clk(clk), .reset(reset), .ce(ce), .ch(ch), .cx(cx0), .cy(cy0),
    .x(x), .y(y), .z(tap1), .tap(tap0)
);
iir_filter_tap_deterministic u_tap_1 (
    .clk(clk), .reset(reset), .ce(ce), .ch(ch), .cx(cx1), .cy(cy1),
    .x(x), .y(y), .z(tap2), .tap(tap1)
);
iir_filter_tap_deterministic u_tap_2 (
    .clk(clk), .reset(reset), .ce(ce), .ch(ch), .cx(cx2), .cy(cy2),
    .x(x), .y(y), .z(40'd0), .tap(tap2)
);

wire [15:0] y_clamp = (~y[39] & |y[38:35]) ? 16'h7fff :
                      ( y[39] & ~&y[38:35]) ? 16'h8000 : y[35:20];

always @(posedge clk or posedge reset) begin
    if (reset) begin
        ch <= 1'b0;
        out_l <= 16'd0;
        out_r <= 16'd0;
        out_m <= 16'd0;
        inp <= 16'd0;
        inp_m <= 16'd0;
    end else if (ce) begin
        ch <= ~ch;
        if (ch) begin
            out_m <= y_clamp;
            inp <= inp_m;
        end else begin
            out_l <= out_m;
            out_r <= y_clamp;
            inp <= input_l;
            inp_m <= input_r;
        end
    end
end

reg [31:0] out;
always @(posedge clk or posedge reset) begin
    if (reset)
        out <= 32'd0;
    else if (sample_ce)
        out <= {out_l, out_r};
end

assign {output_l, output_r} = out;

endmodule

module iir_filter_tap_deterministic
(
    input               clk,
    input               reset,
    input               ce,
    input               ch,
    input         [7:0] cx,
    input        [23:0] cy,
    input        [39:0] x,
    input        [39:0] y,
    input        [39:0] z,
    output       [39:0] tap
);

wire signed [60:0] y_mul = $signed(y[36:0]) * $signed(cy);

function automatic [39:0] x_mul(input [39:0] x_value);
begin
    x_mul = 40'd0;
    if (cx[0]) x_mul = x_mul + {{4{x_value[39]}}, x_value[39:4]};
    if (cx[1]) x_mul = x_mul + {{3{x_value[39]}}, x_value[39:3]};
    if (cx[2]) x_mul = x_mul + {{2{x_value[39]}}, x_value[39:2]};
    if (cx[7]) x_mul = ~x_mul;
end
endfunction

(* ramstyle = "logic" *) reg [39:0] intreg [0:1];
always @(posedge clk or posedge reset) begin
    if (reset)
        {intreg[0], intreg[1]} <= 80'd0;
    else if (ce)
        intreg[ch] <= x_mul(x) - y_mul[60:21] + z;
end

assign tap = intreg[ch];

endmodule

module dc_blocker_deterministic
(
    input               clk,
    input               reset,
    input               ce,
    input               mute,
    input               sample_rate,
    input        [15:0] din,
    output       [15:0] dout
);

reg [39:0] x1;
reg [39:0] y;
wire [39:0] x = {din[15], din, 23'd0};
wire [39:0] x0 = x - (sample_rate ? {{11{x[39]}}, x[39:11]} :
                                    {{10{x[39]}}, x[39:10]});
wire [39:0] y1 = y - (sample_rate ? {{10{y[39]}}, y[39:10]} :
                                    {{9{y[39]}}, y[39:9]});
wire [39:0] y0 = x0 - x1 + y1;

always @(posedge clk or posedge reset) begin
    if (reset) begin
        x1 <= 40'd0;
        y <= 40'd0;
    end else if (ce) begin
        x1 <= x0;
        y <= ^y0[39:38] ? {{2{y0[39]}}, {38{y0[38]}}} : y0;
    end
end

assign dout = mute ? 16'd0 : y[38:23];

endmodule
