module mbc5_lookup (
    input enabled,has_ram,
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
    reg [8:0] rom_bank;
    reg [3:0] ram_bank;
    reg ram_enable;
    wire active=enabled && cart_type>=8'h19 && cart_type<=8'h1e;
    always @*begin
        rom_bank=native_state[8:0];ram_bank=native_state[12:9];ram_enable=native_state[15];
        if(preview_write && !write_address[15])begin
            case(write_address[14:13])
                2'b00:ram_enable=write_data[3:0]==4'ha;
                2'b01:if(write_address[12])rom_bank[8]=write_data[0];else rom_bank[7:0]=write_data;
                2'b10:ram_bank=write_data[3:0];
                default:begin end
            endcase
        end
    end
    wire [8:0] effective_rom=(address[14]?rom_bank:9'd0)&rom_bank_mask;
    wire [3:0] effective_ram=ram_bank&ram_bank_mask&((cart_type>=8'h1c)?4'h7:4'hf);
    wire [16:0] ram_byte={effective_ram,address[12:0]}&ram_address_mask;
    assign mapped=active && (!address[15] || (address[15:13]==3'b101 && has_ram && ram_enable));
    assign word_address=address[15] ? {1'b1,6'd0,ram_byte[16:1]} : {1'b0,effective_rom,address[13:1]};
endmodule
