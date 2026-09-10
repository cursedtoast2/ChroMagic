module mbc5_adapter (
    input clk, reset, enabled,
    input [7:0] cart_type,
    input has_ram,
    input [8:0] rom_bank_mask,
    input [3:0] ram_bank_mask,
    input [16:0] ram_address_mask,
    input [15:0] address,
    input read_request, write_commit,
    input [7:0] write_data,
    output rom_read, ram_read, ram_write,
    output [22:0] rom_address,
    output [16:0] ram_address,
    output ram_enabled, has_battery,
    output [15:0] mapper_state
);
    wire active = enabled && !reset && cart_type >= 8'h19 && cart_type <= 8'h1e;
    wire rumble_type = cart_type >= 8'h1c && cart_type <= 8'h1e;
    wire [3:0] effective_ram_mask = ram_bank_mask & (rumble_type ? 4'h7 : 4'hf);
    wire [16:0] native_ram_address;
    wire native_ram_enabled;
    wire [7:0] register_data = address[15:13] == 0 ?
                              {4'b0, write_data[3:0]} : write_data;
    mbc5 registers (
        .enable(active), .clk_sys(clk), .ce_cpu(write_commit),
        .savestate_load(1'b0), .savestate_data(16'd0), .savestate_back_b(mapper_state),
        .has_ram(has_ram), .ram_mask(effective_ram_mask), .rom_mask(rom_bank_mask),
        .cart_addr(address[14:0]), .cart_a15(address[15]), .cart_mbc_type(cart_type),
        .cart_wr(write_commit), .cart_di(register_data),
        .cram_di(8'hff), .cram_do_b(), .cram_addr_b(native_ram_address),
        .mbc_addr_b(rom_address), .ram_enabled_b(native_ram_enabled),
        .has_battery_b(has_battery), .rumbling());
    assign ram_address = native_ram_address & ram_address_mask;
    assign ram_enabled = active && native_ram_enabled;
    assign rom_read = active && read_request && !address[15];
    assign ram_read = ram_enabled && read_request && address[15:13] == 3'b101;
    assign ram_write = ram_enabled && write_commit && address[15:13] == 3'b101;
endmodule
