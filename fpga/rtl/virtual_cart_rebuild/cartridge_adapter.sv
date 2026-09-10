module cartridge_adapter (
    input clk, reset, enabled,
    input [7:0] cart_type,
    input has_ram, mbc1m,
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
    output [15:0] mapper_state,
    output nibble_ram, supported
);
    wire active = enabled && !reset;
    wire plain = cart_type==0 || cart_type==8'h08 || cart_type==8'h09;
    wire one = cart_type>=1 && cart_type<=3;
    wire two = cart_type==5 || cart_type==6;
    wire five = cart_type>=8'h19 && cart_type<=8'h1e;
    assign supported = plain || one || two || five;
    wire [22:0] rom1,rom2,rom5;
    wire [16:0] ram1,ram2,ram5;
    wire [15:0] state1,state2,state5;
    wire enable1,enable2,enable5,battery1,battery2,battery5;
    mbc1 registers1 (
        .enable(active && one),.mbc1m(mbc1m),.clk_sys(clk),.ce_cpu(write_commit),
        .savestate_load(1'b0),.savestate_data(16'd0),.savestate_back_b(state1),
        .has_ram(has_ram),.ram_mask(ram_bank_mask[1:0]),.rom_mask(rom_bank_mask[6:0]),
        .cart_addr(address[14:0]),.cart_a15(address[15]),.cart_mbc_type(cart_type),
        .cart_wr(write_commit),.cart_di(write_data),.cram_di(8'hff),.cram_do_b(),
        .cram_addr_b(ram1),.mbc_addr_b(rom1),.ram_enabled_b(enable1),.has_battery_b(battery1));
    mbc2 registers2 (
        .enable(active && two),.clk_sys(clk),.ce_cpu(write_commit),
        .savestate_load(1'b0),.savestate_data(16'd0),.savestate_back_b(state2),
        .ram_mask(2'd0),.rom_mask(rom_bank_mask[6:0]),
        .cart_addr(address[14:0]),.cart_a15(address[15]),.cart_mbc_type(cart_type),
        .cart_wr(write_commit),.cart_di(write_data),.cram_di(8'hff),.cram_do_b(),
        .cram_addr_b(ram2),.mbc_addr_b(rom2),.ram_enabled_b(enable2),.has_battery_b(battery2));
    mbc5_adapter registers5 (
        .clk(clk),.reset(reset),.enabled(enabled),.cart_type(cart_type),.has_ram(has_ram),
        .rom_bank_mask(rom_bank_mask),.ram_bank_mask(ram_bank_mask),.ram_address_mask(ram_address_mask),
        .address(address),.read_request(read_request),.write_commit(write_commit),.write_data(write_data),
        .rom_read(),.ram_read(),.ram_write(),.rom_address(rom5),.ram_address(ram5),
        .ram_enabled(enable5),.has_battery(battery5),.mapper_state(state5));
    assign rom_address = plain ? {8'd0,address[14:0]} : one ? rom1 : two ? rom2 : five ? rom5 : 23'd0;
    assign ram_address = (plain ? {4'd0,address[12:0]} : one ? ram1 : two ? ram2 : five ? ram5 : 17'd0) & ram_address_mask;
    assign ram_enabled = active && (plain ? (cart_type!=0 && has_ram) : one ? enable1 : two ? enable2 : five ? enable5 : 1'b0);
    assign has_battery = active && (plain ? cart_type==8'h09 : one ? battery1 : two ? battery2 : five ? battery5 : 1'b0);
    assign mapper_state = one ? state1 : two ? state2 : five ? state5 : 16'd0;
    assign nibble_ram = two;
    assign rom_read = active && supported && read_request && !address[15];
    assign ram_read = ram_enabled && read_request && address[15:13]==3'b101;
    assign ram_write = ram_enabled && write_commit && address[15:13]==3'b101;
endmodule
