module framebuffer_capture (
    input hclk,xclk,reset,
    input hwrite,hnewline,hvsync,
    input [22:0] haddress,
    input [15:0] hdata,
    output descriptor_valid,
    input descriptor_pop,
    output [22:0] descriptor_address,
    output [7:0] descriptor_words,
    output [15:0] descriptor_epoch,
    output head_valid,
    input pop,
    output [15:0] head_data,
    output [10:0] available_words,
    output [3:0] available_descriptors,
    output protocol_error
);
    reg previous_vsync,address_pending;
    reg [3:0] tail;
    reg [7:0] words;
    reg [22:0] closing_address;
    reg [15:0] epoch,fragment_epoch;
    reg capture_error;
    wire frame_rise=hvsync && !previous_vsync;
    wire [8:0] including_pixel={1'b0,words}+{8'd0,hwrite};
    wire close_fragment=tail==1 || (frame_rise && words!=0);
    wire [22:0] interrupted_address=haddress+(previous_vsync?23'd0:23'd320);
    wire [22:0] close_address=address_pending?haddress:tail!=0?closing_address:interrupted_address;
    wire [15:0] close_epoch=words!=0?fragment_epoch:epoch+{15'd0,frame_rise};
    wire descriptor_push=close_fragment && including_pixel!=0 && !reset;
    wire descriptor_ready,pixel_ready,pixel_error,descriptor_error;
    stream_fifo pixels (
        .write_clk(hclk),.read_clk(xclk),.reset(reset),.push(hwrite && !reset),.write_data(hdata),
        .write_ready(pixel_ready),.write_count(),.pop(pop),.read_valid(head_valid),.read_data(head_data),
        .read_count(available_words),.protocol_error(pixel_error));
    stream_fifo #(.ADDRESS_WIDTH(3),.DATA_WIDTH(47),.NATIVE_RAM(0)) descriptors (
        .write_clk(hclk),.read_clk(xclk),.reset(reset),.push(descriptor_push),
        .write_data({close_address,including_pixel[7:0],close_epoch}),.write_ready(descriptor_ready),.write_count(),
        .pop(descriptor_pop),.read_valid(descriptor_valid),.read_data({descriptor_address,descriptor_words,descriptor_epoch}),
        .read_count(available_descriptors),.protocol_error(descriptor_error));
    assign protocol_error=capture_error || pixel_error || descriptor_error;
    always @(posedge hclk or posedge reset)begin
        if(reset)begin
            previous_vsync<=0;address_pending<=0;tail<=0;words<=0;closing_address<=23'h010000;
            epoch<=0;fragment_epoch<=0;capture_error<=0;
        end else begin
            previous_vsync<=hvsync;address_pending<=hnewline;
            if(address_pending)closing_address<=haddress;
            if(frame_rise)begin epoch<=epoch+1'b1;tail<=0;end
            else if(tail!=0)tail<=tail-1'b1;
            if(hnewline)begin
                if(tail>1 && words!=0)capture_error<=1;
                tail<=8;
            end
            if(hwrite)begin
                if(!pixel_ready || including_pixel>160)capture_error<=1;
                if(words==0)fragment_epoch<=epoch+{15'd0,frame_rise};
            end
            if(descriptor_push && !descriptor_ready)capture_error<=1;
            words<=close_fragment?8'd0:including_pixel[7:0];
        end
    end
endmodule
