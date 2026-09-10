module stream_fifo #(
    parameter ADDRESS_WIDTH=10, DATA_WIDTH=16, NATIVE_RAM=1
) (
    input write_clk,read_clk,reset,
    input push,
    input [DATA_WIDTH-1:0] write_data,
    output write_ready,
    output [ADDRESS_WIDTH:0] write_count,
    input pop,
    output read_valid,
    output [DATA_WIDTH-1:0] read_data,
    output [ADDRESS_WIDTH:0] read_count,
    output protocol_error
);
    localparam POINTER_WIDTH=ADDRESS_WIDTH+1;
    reg [1:0] write_reset,read_reset;
    always @(posedge write_clk or posedge reset)
        if(reset)write_reset<=3;else write_reset<={write_reset[0],1'b0};
    always @(posedge read_clk or posedge reset)
        if(reset)read_reset<=3;else read_reset<={read_reset[0],1'b0};
    reg [ADDRESS_WIDTH:0] write_binary,read_binary,write_gray,read_gray;
    (* async_reg="true" *) reg [ADDRESS_WIDTH:0] read_gray_w1,read_gray_w2,write_gray_r1,write_gray_r2;
    reg write_error,read_error;
    function automatic [ADDRESS_WIDTH:0] binary(input [ADDRESS_WIDTH:0] gray);
        binary[ADDRESS_WIDTH]=gray[ADDRESS_WIDTH];
        for(integer i=ADDRESS_WIDTH-1;i>=0;i=i-1)binary[i]=binary[i+1]^gray[i];
    endfunction
    wire full=write_gray=={~read_gray_w2[ADDRESS_WIDTH:ADDRESS_WIDTH-1],read_gray_w2[ADDRESS_WIDTH-2:0]};
    wire empty=read_gray==write_gray_r2;
    assign write_ready=!write_reset[1] && !full;
    assign read_valid=!read_reset[1] && !empty;
    assign write_count=write_binary-binary(read_gray_w2);
    assign read_count=binary(write_gray_r2)-read_binary;
    assign protocol_error=write_error || read_error;
    wire write_word=push && write_ready;
    wire read_word=pop && read_valid;
    wire [ADDRESS_WIDTH:0] next_write=write_binary+1'b1;
    wire [ADDRESS_WIDTH:0] next_read=read_binary+1'b1;
    wire [ADDRESS_WIDTH-1:0] next_head=read_word?next_read[ADDRESS_WIDTH-1:0]:read_binary[ADDRESS_WIDTH-1:0];
    generate if(NATIVE_RAM)begin: ram
        dpramV #(.addr_width(ADDRESS_WIDTH),.data_width(DATA_WIDTH)) storage (
            .clock_a(write_clk),.ce_a(write_word),.address_a(write_binary[ADDRESS_WIDTH-1:0]),
            .data_a(write_data),.wren_a(write_word),.q_a(),
            .clock_b(read_clk),.address_b(next_head),.data_b({DATA_WIDTH{1'b0}}),.wren_b(1'b0),.q_b(read_data));
    end else begin: registers
        reg [DATA_WIDTH-1:0] storage[0:(1<<ADDRESS_WIDTH)-1];
        always @(posedge write_clk)if(write_word)storage[write_binary[ADDRESS_WIDTH-1:0]]<=write_data;
        assign read_data=storage[read_binary[ADDRESS_WIDTH-1:0]];
    end endgenerate
    always @(posedge write_clk or posedge reset)begin
        if(reset)begin write_binary<=0;write_gray<=0;read_gray_w1<=0;read_gray_w2<=0;write_error<=0;end
        else if(write_reset[1])begin write_binary<=0;write_gray<=0;read_gray_w1<=0;read_gray_w2<=0;write_error<=0;end
        else begin
            read_gray_w1<=read_gray;read_gray_w2<=read_gray_w1;
            if(push && !write_ready)write_error<=1;
            if(write_word)begin write_binary<=next_write;write_gray<=(next_write>>1)^next_write;end
        end
    end
    always @(posedge read_clk or posedge reset)begin
        if(reset)begin read_binary<=0;read_gray<=0;write_gray_r1<=0;write_gray_r2<=0;read_error<=0;end
        else if(read_reset[1])begin read_binary<=0;read_gray<=0;write_gray_r1<=0;write_gray_r2<=0;read_error<=0;end
        else begin
            write_gray_r1<=write_gray;write_gray_r2<=write_gray_r1;
            if(pop && !read_valid)read_error<=1;
            if(read_word)begin read_binary<=next_read;read_gray<=(next_read>>1)^next_read;end
        end
    end
endmodule
