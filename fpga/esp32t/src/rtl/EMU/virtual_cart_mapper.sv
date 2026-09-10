module virtual_cart_mapper (
    input clk_sys, reset, ce_cpu, ce_32k,
    input [2:0] mapper_select,
    input mbc1m, mbc30, has_ram,
    input [3:0] ram_mask,
    input [8:0] rom_mask,
    input [14:0] cart_addr,
    input cart_a15, cart_rd, cart_wr, nCS,
    input [7:0] cart_mbc_type, cart_di, cram_di,
    input [32:0] RTC_time,
    input bk_wr, bk_rtc_wr,
    input [16:0] bk_addr,
    input [15:0] bk_data,
    input [63:0] img_size,
    output [31:0] RTC_timestampOut,
    output [47:0] RTC_savedtimeOut,
    output RTC_inuse,
    output [22:0] mbc_addr,
    output [16:0] cram_addr,
    output [7:0] cram_do,
    output cart_oe, ram_enabled, has_battery, rumbling
);
    wire en_mbc1 = mapper_select == 3'd1;
    wire en_mbc2 = mapper_select == 3'd2;
    wire en_mbc3 = mapper_select == 3'd3;
    wire en_mbc5 = mapper_select == 3'd4;
    wire en_huc1 = mapper_select == 3'd5;
    wire no_mapper = mapper_select == 3'd0;

    tri0 [22:0] mbc_addr_b;
    tri0 [16:0] cram_addr_b;
    tri1  [7:0] cram_do_b;
    tri0        ram_enabled_b;
    tri0        has_battery_b;
    tri0        cart_oe_b;
    tri0 [15:0] savestate_back_b;
    tri0 [31:0] RTC_timestampOut_b;
    tri0 [47:0] RTC_savedtimeOut_b;
    tri0        RTC_inuse_b;
    wire mbc5_rumbling;

    mbc1 map_mbc1 (
        .enable(en_mbc1), .mbc1m(mbc1m), .clk_sys(clk_sys), .ce_cpu(ce_cpu),
        .savestate_load(1'b0), .savestate_data(16'd0), .savestate_back_b(savestate_back_b),
        .has_ram(has_ram), .ram_mask(ram_mask[1:0]), .rom_mask(rom_mask[6:0]),
        .cart_addr(cart_addr), .cart_a15(cart_a15), .cart_mbc_type(cart_mbc_type),
        .cart_wr(cart_wr), .cart_di(cart_di), .cram_di(cram_di),
        .cram_do_b(cram_do_b), .cram_addr_b(cram_addr_b), .mbc_addr_b(mbc_addr_b),
        .ram_enabled_b(ram_enabled_b), .has_battery_b(has_battery_b));

    mbc2 map_mbc2 (
        .enable(en_mbc2), .clk_sys(clk_sys), .ce_cpu(ce_cpu),
        .savestate_load(1'b0), .savestate_data(16'd0), .savestate_back_b(savestate_back_b),
        .ram_mask(ram_mask[1:0]), .rom_mask(rom_mask[6:0]),
        .cart_addr(cart_addr), .cart_a15(cart_a15), .cart_mbc_type(cart_mbc_type),
        .cart_wr(cart_wr), .cart_di(cart_di), .cram_di(cram_di),
        .cram_do_b(cram_do_b), .cram_addr_b(cram_addr_b), .mbc_addr_b(mbc_addr_b),
        .ram_enabled_b(ram_enabled_b), .has_battery_b(has_battery_b));

    mbc3 map_mbc3 (
        .enable(en_mbc3), .reset(reset), .mbc30(mbc30), .clk_sys(clk_sys), .ce_cpu(ce_cpu),
        .savestate_load(1'b0), .savestate_data(16'd0), .savestate_back_b(savestate_back_b),
        .ce_32k(ce_32k), .RTC_time(RTC_time), .RTC_timestampOut_b(RTC_timestampOut_b),
        .RTC_savedtimeOut_b(RTC_savedtimeOut_b), .RTC_inuse_b(RTC_inuse_b),
        .bk_wr(bk_wr), .bk_rtc_wr(bk_rtc_wr), .bk_addr(bk_addr), .bk_data(bk_data),
        .img_size(img_size), .has_ram(has_ram), .ram_mask(ram_mask[2:0]),
        .rom_mask(rom_mask[7:0]), .cart_addr(cart_addr), .cart_a15(cart_a15),
        .cart_mbc_type(cart_mbc_type), .cart_rd(cart_rd), .cart_wr(cart_wr),
        .cart_di(cart_di), .cart_oe_b(cart_oe_b), .nCS(nCS), .cram_di(cram_di),
        .cram_do_b(cram_do_b), .cram_addr_b(cram_addr_b), .mbc_addr_b(mbc_addr_b),
        .ram_enabled_b(ram_enabled_b), .has_battery_b(has_battery_b));

    mbc5 map_mbc5 (
        .enable(en_mbc5), .clk_sys(clk_sys), .ce_cpu(ce_cpu),
        .savestate_load(1'b0), .savestate_data(16'd0), .savestate_back_b(savestate_back_b),
        .has_ram(has_ram), .ram_mask(ram_mask), .rom_mask(rom_mask),
        .cart_addr(cart_addr), .cart_a15(cart_a15), .cart_mbc_type(cart_mbc_type),
        .cart_wr(cart_wr), .cart_di(cart_di), .cram_di(cram_di),
        .cram_do_b(cram_do_b), .cram_addr_b(cram_addr_b), .mbc_addr_b(mbc_addr_b),
        .ram_enabled_b(ram_enabled_b), .has_battery_b(has_battery_b),
        .rumbling(mbc5_rumbling));

    huc1 map_huc1 (
        .enable(en_huc1), .clk_sys(clk_sys), .ce_cpu(ce_cpu),
        .savestate_load(1'b0), .savestate_data(16'd0), .savestate_back_b(savestate_back_b),
        .has_ram(has_ram), .ram_mask(ram_mask), .rom_mask(rom_mask),
        .cart_addr(cart_addr), .cart_a15(cart_a15), .cart_mbc_type(cart_mbc_type),
        .cart_rd(cart_rd), .cart_wr(cart_wr), .cart_di(cart_di),
        .cart_oe_b(cart_oe_b), .cram_rd(cart_rd & ~nCS & ~cart_addr[14]),
        .cram_di(cram_di), .cram_do_b(cram_do_b), .cram_addr_b(cram_addr_b),
        .mbc_addr_b(mbc_addr_b), .ram_enabled_b(ram_enabled_b),
        .has_battery_b(has_battery_b));

    assign mbc_addr = no_mapper ? {8'd0, cart_addr} : mbc_addr_b;
    assign cram_addr = no_mapper ? {4'd0, cart_addr[12:0]} : cram_addr_b;
    assign cram_do = no_mapper ? (has_ram ? cram_di : 8'hff) : cram_do_b;
    assign ram_enabled = no_mapper ? has_ram : ram_enabled_b;
    assign has_battery = no_mapper ? (cart_mbc_type == 8'h09) : has_battery_b;
    assign cart_oe = (en_mbc3 | en_huc1) ? cart_oe_b :
        ((cart_rd & ~cart_a15) |
         (cart_rd & ~nCS & ~cart_addr[14] & ram_enabled));
    assign rumbling = en_mbc5 & mbc5_rumbling;
    assign RTC_timestampOut = RTC_timestampOut_b;
    assign RTC_savedtimeOut = RTC_savedtimeOut_b;
    assign RTC_inuse = RTC_inuse_b;
endmodule
