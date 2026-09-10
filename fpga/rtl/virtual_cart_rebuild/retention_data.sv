module retention_data (
    input clk, reset,
    input read_enable,
    input [2:0] read_bank,
    input [9:0] read_address,
    output reg read_valid,
    output [15:0] read_data,
    input write_enable,
    input [2:0] write_bank,
    input [9:0] write_address,
    input [15:0] write_data,
    input maintenance_read,
    input [9:0] maintenance_address,
    output reg maintenance_valid,
    output [15:0] maintenance_data,
    output reg protocol_error
);
    wire [79:0] port_a, port_b;
    reg [2:0] selected_bank;
    reg collision;
    reg [15:0] collision_data;
    wire valid_read = read_bank<5 && (read_bank!=4 || read_address<827);
    wire valid_write = write_bank<5 && (write_bank!=4 || write_address<827);
    assign read_data = collision ? collision_data : port_a[16*selected_bank+:16];
    assign maintenance_data = port_b[64+:16];
    genvar b;
    generate for(b=0;b<5;b=b+1) begin: banks
        localparam integer BANK=b;
        dpramV #(.addr_width(10),.data_width(16)) storage (
            .clock_a(clk),.ce_a(read_enable && valid_read && read_bank==BANK && !reset),
            .address_a(read_address),.data_a(16'd0),.wren_a(1'b0),.q_a(port_a[16*BANK+:16]),
            .clock_b(clk),
            .address_b(write_enable && write_bank==BANK ? write_address : maintenance_address),
            .data_b(write_data),
            .wren_b(write_enable && valid_write && write_bank==BANK && !reset),.q_b(port_b[16*BANK+:16]));
    end endgenerate
    always @(posedge clk) begin
        if(reset) begin
            read_valid<=0;maintenance_valid<=0;selected_bank<=0;
            collision<=0;collision_data<=0;protocol_error<=0;
        end else begin
            read_valid<=read_enable && valid_read;
            maintenance_valid<=maintenance_read && maintenance_address<827 &&
                               !(write_enable && write_bank==4);
            if(read_enable && valid_read) begin
                selected_bank<=read_bank;
                collision<=write_enable && valid_write && write_bank==read_bank &&
                           write_address==read_address;
                collision_data<=write_data;
            end
            if((read_enable && !valid_read) || (write_enable && !valid_write) ||
               (maintenance_read && (maintenance_address>=827 ||
                                    (write_enable && write_bank==4))))
                protocol_error<=1;
        end
    end
endmodule
