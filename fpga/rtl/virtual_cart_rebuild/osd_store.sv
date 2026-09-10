module osd_store (
    input clk,reset,
    input prepare,
    input prepare_set,
    input [9:0] prepare_index,
    input [15:0] prepare_data,
    input mirror_write,mirror_set,
    input [9:0] mirror_index,
    input [15:0] mirror_data,
    output mirror_ready,
    input [11:0] reader_leases,
    input rolling_write,rolling_set,
    input [1:0] rolling_bank,
    input [7:0] rolling_index,
    input [15:0] rolling_data,
    output rolling_ready,
    input read_request,
    input [3:0] read_bank,
    input [7:0] read_index,
    output read_ready,read_valid,
    output [15:0] read_data,
    output [95:0] heads,
    output reg [5:0] heads_valid,
    output reg protocol_error
);
    wire read_set=read_bank>=6;
    wire [3:0] local_bank=read_set?read_bank-4'd6:read_bank;
    wire [9:0] read_address=10'(local_bank)*10'd160+{2'd0,read_index};
    assign read_ready=!reset && read_bank<12 && read_index<160;
    wire read_accept=read_request && read_ready;
    assign mirror_ready=!reset && !prepare && mirror_index<960 && !(mirror_set ? |reader_leases[11:6] : |reader_leases[5:0]);
    assign rolling_ready=!reset && rolling_bank<3 && rolling_index<160 &&
        !(prepare && prepare_set==rolling_set) && !(mirror_write && mirror_set==rolling_set);
    wire [9:0] rolling_address=10'd480+10'(rolling_bank)*10'd160+{2'd0,rolling_index};
    wire [31:0] ram_data;
    reg [15:0] held_heads[0:5];
    reg previous_read,previous_set;
    assign read_valid=previous_read;
    assign read_data=ram_data[previous_set*16+:16];
    generate for(genvar s=0;s<2;s=s+1)begin: sets
        localparam integer SET_ID=s;
        wire seed=!reset && prepare && prepare_index<960 && prepare_set==SET_ID;
        wire mirror=mirror_write && mirror_ready && mirror_set==SET_ID;
        wire rolling=rolling_write && rolling_ready && rolling_set==SET_ID;
        wire write_enable=seed || mirror || rolling;
        wire [9:0] write_address=seed?prepare_index:mirror?mirror_index:rolling_address;
        wire [15:0] write_data=seed?prepare_data:mirror?mirror_data:rolling_data;
        dpramV #(.addr_width(10),.data_width(16)) rows (
            .clock_a(clk),.ce_a(read_accept && read_set==SET_ID),.address_a(read_address),.data_a(16'd0),.wren_a(1'b0),.q_a(ram_data[SET_ID*16+:16]),
            .clock_b(clk),.address_b(write_address),.data_b(write_data),.wren_b(write_enable),.q_b());
        for(genvar r=0;r<3;r=r+1)begin: pin_heads
            localparam integer HEAD_ID=SET_ID*3+r;
            assign heads[HEAD_ID*16+:16]=held_heads[HEAD_ID];
            always @(posedge clk)begin
                if(reset)begin held_heads[HEAD_ID]<=0;heads_valid[HEAD_ID]<=0;end
                else if(write_enable && write_address==r*160)begin held_heads[HEAD_ID]<=write_data;heads_valid[HEAD_ID]<=1;end
            end
        end
    end endgenerate
    always @(posedge clk)begin
        if(reset)begin previous_read<=0;previous_set<=0;protocol_error<=0;end
        else begin
            previous_read<=read_accept;previous_set<=read_set;
            if(read_request && !read_ready)protocol_error<=1;
            if(prepare && prepare_index>=960)protocol_error<=1;
            if(mirror_write && !mirror_ready)protocol_error<=1;
            if(rolling_write && !rolling_ready)protocol_error<=1;
            if(prepare && mirror_write)protocol_error<=1;
        end
    end
endmodule
