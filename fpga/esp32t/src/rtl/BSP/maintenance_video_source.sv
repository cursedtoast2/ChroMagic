`timescale 1ns/1ps
`default_nettype none

module maintenance_video_source (
    input  wire        hclk,
    input  wire        reset_h,
    input  wire        enable,
    output wire        lcd_clkena,
    output wire [1:0]  lcd_mode,
    output wire        lcd_on,
    output wire        lcd_vsync,
    output wire [14:0] lcd_data
);
    localparam integer H_TOTAL = 456 * 4;
    localparam integer H_MODE2_END = 80 * 4;
    localparam integer H_ACTIVE_START = (80 + 8) * 4;
    localparam integer H_ACTIVE_END = H_ACTIVE_START + (160 * 4);
    localparam integer V_ACTIVE = 144;
    localparam integer V_TOTAL = 154;

    reg [10:0] h_count;
    reg [7:0] v_count;

    always @(posedge hclk or posedge reset_h)
    begin
        if (reset_h)
        begin
            h_count <= 11'd0;
            v_count <= 8'd0;
        end
        else if (!enable)
        begin
            h_count <= 11'd0;
            v_count <= 8'd0;
        end
        else if (h_count == H_TOTAL - 1)
        begin
            h_count <= 11'd0;
            if (v_count == V_TOTAL - 1)
                v_count <= 8'd0;
            else
                v_count <= v_count + 1'b1;
        end
        else
            h_count <= h_count + 1'b1;
    end

    wire active_line = v_count < V_ACTIVE;
    wire active_pixel_time = active_line &&
                             (h_count >= H_ACTIVE_START) &&
                             (h_count < H_ACTIVE_END);

    assign lcd_clkena = enable && active_pixel_time &&
                        (h_count[1:0] == 2'b00);
    assign lcd_mode = !enable ? 2'b00 :
                      !active_line ? 2'b01 :
                      (h_count < H_MODE2_END) ? 2'b10 :
                      (h_count < H_ACTIVE_END) ? 2'b11 : 2'b00;
    assign lcd_on = enable;
    assign lcd_vsync = enable && (v_count == 8'd0);
    assign lcd_data = 15'h0000;
endmodule

`default_nettype wire
