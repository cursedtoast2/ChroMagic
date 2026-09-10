`timescale 1ns/1ps
`default_nettype none

module maintenance_video_mux (
    input  wire        hclk,
    input  wire        reset_h,
    input  wire        maintenance_active_h,

    input  wire        core_lcd_clkena,
    input  wire [1:0]  core_lcd_mode,
    input  wire        core_lcd_on,
    input  wire        core_lcd_vsync,
    input  wire [14:0] core_lcd_data,
    input  wire        core_display_ready,

    output wire        lcd_clkena,
    output wire [1:0]  lcd_mode,
    output wire        lcd_on,
    output wire        lcd_vsync,
    output wire [14:0] lcd_data,
    output wire        maintenance_selected,
    output wire        core_frame_valid
);
    localparam [14:0] MIN_VALID_PIXELS = 15'd16;

    wire maintenance_lcd_clkena;
    wire [1:0] maintenance_lcd_mode;
    wire maintenance_lcd_on;
    wire maintenance_lcd_vsync;
    wire [14:0] maintenance_lcd_data;

    reg select_maintenance;
    reg core_vsync_d;
    reg core_frame_started;
    reg [14:0] core_valid_pixels;

    wire core_vsync_rising = core_lcd_vsync && !core_vsync_d;
    assign core_frame_valid = core_lcd_on && core_display_ready &&
                              core_vsync_rising && core_frame_started &&
                              (core_valid_pixels >= MIN_VALID_PIXELS);

    maintenance_video_source u_maintenance_video_source (
        .hclk(hclk),
        .reset_h(reset_h),
        .enable(select_maintenance),
        .lcd_clkena(maintenance_lcd_clkena),
        .lcd_mode(maintenance_lcd_mode),
        .lcd_on(maintenance_lcd_on),
        .lcd_vsync(maintenance_lcd_vsync),
        .lcd_data(maintenance_lcd_data)
    );

    always @(posedge hclk or posedge reset_h)
    begin
        if (reset_h)
        begin
            select_maintenance <= 1'b0;
            core_vsync_d <= 1'b0;
            core_frame_started <= 1'b0;
            core_valid_pixels <= 15'd0;
        end
        else
        begin
            core_vsync_d <= core_lcd_vsync;

            if (maintenance_active_h)
                select_maintenance <= 1'b1;
            else if (select_maintenance && core_frame_valid)
                select_maintenance <= 1'b0;

            if (!core_lcd_on || !core_display_ready)
            begin
                core_frame_started <= 1'b0;
                core_valid_pixels <= 15'd0;
            end
            else if (core_vsync_rising)
            begin
                core_frame_started <= 1'b1;
                core_valid_pixels <= 15'd0;
            end
            else if (core_frame_started && core_lcd_clkena &&
                     core_lcd_data != 15'h7fff &&
                     (core_valid_pixels != 15'h7fff))
                core_valid_pixels <= core_valid_pixels + 1'b1;
        end
    end

    assign lcd_clkena = select_maintenance ? maintenance_lcd_clkena :
                                             core_lcd_clkena;
    assign lcd_mode = select_maintenance ? maintenance_lcd_mode :
                                           core_lcd_mode;
    assign lcd_on = select_maintenance ? maintenance_lcd_on : core_lcd_on;
    assign lcd_vsync = select_maintenance ? maintenance_lcd_vsync :
                                           core_lcd_vsync;
    assign lcd_data = select_maintenance ? maintenance_lcd_data :
                                           core_lcd_data;
    assign maintenance_selected = select_maintenance;
endmodule

`default_nettype wire
