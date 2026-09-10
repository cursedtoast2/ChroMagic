module memory_clients (
    input clk,reset,
    input request,read_request,
    input [22:0] word_address,
    input [3:0] word_count,
    input [15:0] write_data,
    output ready,done,response_valid,response_last,
    output [22:0] response_word,
    output [15:0] response_data,
    input background_request,background_read,
    input [22:0] background_address,
    input [9:0] background_words,
    input [15:0] background_data,
    output background_ready,background_accept,background_valid,background_last,background_done,
    output background_advance,
    output [15:0] background_result,
    output [9:0] background_index,
    input controller_ready,chip_select_n,
    output [4:0] port_request,port_read,
    output [114:0] port_address,
    output [54:0] port_bytes,
    output [79:0] port_data,
    input [4:0] port_done,port_valid,port_write_next,
    input [15:0] port_result,
    output drained,protocol_error
);
    wire cart_ready,cart_request,cart_read,cart_error,cart_drained;
    wire [22:0] cart_address;
    wire [10:0] cart_bytes;
    wire [15:0] cart_data;
    reg background_owned,active_read;
    reg [22:0] active_address;
    reg [9:0] active_words,received;
    reg background_error;
    wire valid_fragment=background_words!=0 && background_words<=512 && !background_address[0] &&
        ({1'b0,background_address[9:0]}+{background_words,1'b0})<=11'd1024;
    assign ready=cart_ready && !background_owned;
    assign background_ready=ready && !request;
    assign background_accept=background_request && background_ready && valid_fragment;
    assign background_valid=background_owned && active_read && port_valid[3];
    assign background_last=background_valid && port_done[3];
    assign background_done=background_owned && port_done[3];
    assign background_advance=background_owned && !active_read && (port_write_next[3] || port_done[3]);
    assign background_result=port_result;
    assign background_index=received;
    assign port_request={cart_request,background_accept,3'd0};
    assign port_read={cart_read,background_owned?active_read:background_read,3'b111};
    assign port_address={cart_address,background_owned?active_address:background_address,69'd0};
    assign port_bytes={cart_bytes,background_owned?active_words:background_words,1'b0,33'd0};
    assign port_data={cart_data,background_data,48'd0};
    assign drained=cart_drained && !background_owned;
    assign protocol_error=cart_error || background_error;
    controller_port cartridge (
        .clk(clk),.reset(reset),.request(request),.read_request(read_request),
        .word_address(word_address),.word_count(word_count),.write_data(write_data),
        .ready(cart_ready),.done(done),.response_valid(response_valid),.response_last(response_last),
        .response_word(response_word),.response_data(response_data),
        .port_request(cart_request),.port_read(cart_read),.port_address(cart_address),
        .port_bytes(cart_bytes),.port_data(cart_data),
        .controller_ready(controller_ready && !background_owned),.chip_select_n(chip_select_n),
        .port_done(port_done[4]),.port_valid(port_valid[4]),.port_result(port_result),
        .drained(cart_drained),.protocol_error(cart_error));
    always @(posedge clk)begin
        if(reset)begin background_owned<=0;active_read<=0;active_address<=0;active_words<=0;received<=0;background_error<=0;end
        else begin
            if(background_request && (!background_ready || !valid_fragment))background_error<=1;
            if(background_accept)begin
                background_owned<=1;active_read<=background_read;active_address<=background_address;active_words<=background_words;received<=0;
            end
            if(port_valid[3] || port_write_next[3])begin
                if(!background_owned || (active_read?!port_valid[3]:!port_write_next[3]) || received>=active_words)
                    background_error<=1;
            end
            if(background_valid || background_advance)received<=received+1'b1;
            if(port_done[3])begin
                if(!background_owned || (active_read && !port_valid[3]) || received+1'b1!=active_words)background_error<=1;
                background_owned<=0;
            end
        end
    end
endmodule
