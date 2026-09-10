module cartridge_lookup (
    input enabled,has_ram,mbc1m,
    input [7:0] cart_type,
    input [15:0] native_state,
    input [8:0] rom_bank_mask,
    input [3:0] ram_bank_mask,
    input [16:0] ram_address_mask,
    input [15:0] address,
    input preview_write,
    input [15:0] write_address,
    input [7:0] write_data,
    output mapped,
    output [22:0] word_address
);
    wire plain=cart_type==0 || cart_type==8'h08 || cart_type==8'h09;
    wire one=cart_type>=1 && cart_type<=3;
    wire two=cart_type==5 || cart_type==6;
    wire five=cart_type>=8'h19 && cart_type<=8'h1e;
    wire mapped5;
    wire [22:0] word5;
    mbc5_lookup lookup5(.enabled(enabled),.has_ram(has_ram),.cart_type(cart_type),
        .native_state(native_state),.rom_bank_mask(rom_bank_mask),.ram_bank_mask(ram_bank_mask),
        .ram_address_mask(ram_address_mask),.address(address),.preview_write(preview_write),
        .write_address(write_address),.write_data(write_data),.mapped(mapped5),.word_address(word5));
    reg [4:0] low_bank;
    reg [1:0] upper_bank;
    reg mode,ram_enable;
    always @* begin
        low_bank=two ? {1'b0,native_state[3:0]} : native_state[4:0];
        upper_bank=native_state[10:9];mode=native_state[13];ram_enable=native_state[15];
        if(preview_write && !write_address[15]) begin
            if(one)case(write_address[14:13])
                0:ram_enable=write_data[3:0]==4'ha;
                1:low_bank=write_data[4:0]==0 ? 5'd1 : write_data[4:0];
                2:upper_bank=write_data[1:0];
                3:mode=write_data[0];
            endcase
            if(two && !write_address[14])begin
                if(write_address[8])low_bank=write_data[3:0]==0 ? 5'd1 : {1'b0,write_data[3:0]};
                else ram_enable=write_data[3:0]==4'ha;
            end
        end
    end
    wire [1:0] bank2=upper_bank & {2{address[14] || mode}};
    wire [4:0] bank1=address[14] ? low_bank : 5'd0;
    wire [6:0] rom_bank=(two ? {3'd0,bank1[3:0]} : mbc1m ? {1'b0,bank2,bank1[3:0]} : {bank2,bank1}) & rom_bank_mask[6:0];
    wire [1:0] ram_bank=bank2 & ram_bank_mask[1:0];
    wire [16:0] ram_byte=(two ? {8'd0,address[8:0]} : plain ? {4'd0,address[12:0]} : {2'd0,ram_bank,address[12:0]}) & ram_address_mask;
    wire ram_selected=plain ? (cart_type!=0 && has_ram) : ram_enable && (two || (one && has_ram));
    assign mapped=five ? mapped5 : enabled && (plain || one || two) &&
        (!address[15] || (address[15:13]==3'b101 && ram_selected));
    assign word_address=five ? word5 : address[15] ? {1'b1,6'd0,ram_byte[16:1]} :
        plain ? {9'd0,address[14:1]} : {3'd0,rom_bank,address[13:1]};
endmodule
