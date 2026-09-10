module virtual_cart_runtime (
    input         hclk,
    input         xclk,
    input         hreset,
    input         xreset,
    input         enable,
    input         quiesced,

    input   [2:0] mapper_select,
    input         mbc1m,
    input         mbc30,
    input   [7:0] cart_mbc_type,
    input         has_ram,
    input   [3:0] ram_mask,
    input   [8:0] rom_mask,
    input  [32:0] rtc_time,
    input         rtc_restore_write,
    input   [2:0] rtc_restore_address,
    input  [15:0] rtc_restore_data,

    input         ce_cpu,
    input  [14:0] cart_addr,
    input         cart_a15,
    input         cart_rd,
    input         cart_wr_cycle,
    input         cart_wr_pulse,
    input   [7:0] cart_di,
    input         nCS,
    output  [7:0] cart_do,
    output        cart_oe,
    output        cart_wait,
    output        initialized,
    output        save_dirty,

    output        xrequest,
    output        xread,
    output [22:0] xaddress,
    output [15:0] xwritedata,
    output [10:0] xlength,
    input         xwrite_next,
    input         xdone,
    input         xread_valid,
    input  [15:0] xreaddata,

    input         xsnapshot_request_toggle,
    input   [6:0] xsnapshot_block,
    input  [15:0] xsnapshot_sequence,
    output        xsnapshot_ready,
    output [15:0] xsnapshot_ready_sequence,
    input         qclk,
    input   [9:0] qsnapshot_address,
    output  [7:0] qsnapshot_data,

    output [31:0] rtc_timestamp,
    output [47:0] rtc_saved_time,
    output        rtc_in_use
);
    localparam [22:0] ROM_BASE  = 23'h020000;
    localparam [22:0] SAVE_BASE = 23'h420000;

    reg [8:0] rtc_divider;
    always @(posedge hclk) begin
        if (hreset) rtc_divider <= 9'd0;
        else rtc_divider <= rtc_divider + 1'b1;
    end
    wire ce_32k = &rtc_divider;

    wire [22:0] mapper_rom_address;
    wire [16:0] mapper_ram_address;
    wire [7:0] mapper_ram_data;
    wire mapper_ram_enabled;
    wire mapper_has_battery;
    wire mapper_rumbling;
    wire mapper_cart_oe;
    wire [7:0] cache_read_data;
    wire cache_ready;

    wire [2:0] active_mapper = initialized ? mapper_select : 3'd7;

    virtual_cart_mapper u_mapper (
        .clk_sys(hclk),
        .reset(hreset | !enable),
        .ce_cpu(ce_cpu),
        .ce_32k(ce_32k),
        .mapper_select(active_mapper),
        .mbc1m(mbc1m),
        .mbc30(mbc30),
        .has_ram(has_ram),
        .ram_mask(ram_mask),
        .rom_mask(rom_mask),
        .cart_addr(cart_addr),
        .cart_a15(cart_a15),
        .cart_rd(cart_rd),
        .cart_wr(cart_wr_pulse),
        .nCS(nCS),
        .cart_mbc_type(cart_mbc_type),
        .cart_di(cart_di),
        .cram_di(cache_read_data),
        .RTC_time(rtc_time),
        .bk_wr(1'b0),
        .bk_rtc_wr(rtc_restore_write),
        .bk_addr({14'd0, rtc_restore_address}),
        .bk_data(rtc_restore_data),
        .img_size(64'd0),
        .RTC_timestampOut(rtc_timestamp),
        .RTC_savedtimeOut(rtc_saved_time),
        .RTC_inuse(rtc_in_use),
        .mbc_addr(mapper_rom_address),
        .cram_addr(mapper_ram_address),
        .cram_do(mapper_ram_data),
        .cart_oe(mapper_cart_oe),
        .ram_enabled(mapper_ram_enabled),
        .has_battery(mapper_has_battery),
        .rumbling(mapper_rumbling)
    );

    wire rom_access = enable && cart_rd && !cart_a15;
    wire ram_selected = !nCS && !cart_addr[14];
    wire ram_access = enable && ram_selected && mapper_ram_enabled &&
                      (cart_rd || cart_wr_cycle);
    wire cache_access = rom_access || ram_access;
    wire [16:0] save_address = ram_mask == 4'd1
        ? {6'd0, mapper_ram_address[10:0]} : mapper_ram_address;
    wire [22:0] cache_address = rom_access
        ? ROM_BASE + mapper_rom_address
        : SAVE_BASE + {6'd0, save_address};

    virtual_cart_cache u_cache (
        .hclk(hclk),
        .hreset(hreset),
        .henable(enable),
        .hquiesced(quiesced),
        .haccess(cache_access),
        .hwrite(ram_access && cart_wr_pulse),
        .hram(ram_access),
        .haddress(cache_address),
        .hwritedata(cart_di),
        .hreaddata(cache_read_data),
        .hready(cache_ready),
        .hdirty(save_dirty),
        .hinitialized(initialized),
        .xclk(xclk),
        .xreset(xreset),
        .xrequest(xrequest),
        .xread(xread),
        .xaddress(xaddress),
        .xwritedata(xwritedata),
        .xlength(xlength),
        .xwrite_next(xwrite_next),
        .xdone(xdone),
        .xread_valid(xread_valid),
        .xreaddata(xreaddata),
        .xsnapshot_request_toggle(xsnapshot_request_toggle),
        .xsnapshot_block(xsnapshot_block),
        .xsnapshot_sequence(xsnapshot_sequence),
        .xsnapshot_ready(xsnapshot_ready),
        .xsnapshot_ready_sequence(xsnapshot_ready_sequence),
        .qclk(qclk),
        .qsnapshot_address(qsnapshot_address),
        .qsnapshot_data(qsnapshot_data)
    );

    assign cart_do = !enable ? 8'hff :
                     !cart_a15 ? cache_read_data :
                     ram_selected ? mapper_ram_data : 8'hff;
    assign cart_oe = enable && mapper_cart_oe;
    assign cart_wait = enable && cache_access && !cache_ready;

endmodule
