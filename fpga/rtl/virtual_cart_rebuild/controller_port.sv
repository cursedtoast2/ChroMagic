module controller_port (
    input clk, reset,
    input request, read_request,
    input [22:0] word_address,
    input [3:0] word_count,
    input [15:0] write_data,
    output ready, done,
    output response_valid, response_last,
    output [22:0] response_word,
    output [15:0] response_data,
    output port_request, port_read,
    output [22:0] port_address,
    output [10:0] port_bytes,
    output [15:0] port_data,
    input controller_ready, chip_select_n,
    input port_done, port_valid,
    input [15:0] port_result,
    output drained,
    output reg protocol_error
);
    localparam [22:0] ROM_BASE=23'h020000, SAVE_BASE=23'h420000;
    reg owned, active_read;
    reg [22:0] active_word;
    reg [3:0] active_count, received;
    wire valid_extent=word_address[22] ? word_address[21:16]==0 : !word_address[21];
    wire valid_request=valid_extent && word_count>=1 && word_count<=8 &&
                      ({1'b0,word_address[8:0]}+{6'd0,word_count})<=10'd512;
    assign ready=controller_ready && !owned && !reset;
    assign drained=ready && chip_select_n;
    assign port_request=request && ready && valid_request;
    assign port_read=read_request;
    assign port_address=(word_address[22]?SAVE_BASE:ROM_BASE)+{word_address[21:0],1'b0};
    assign port_bytes={6'd0,word_count,1'b0};
    assign port_data=write_data;
    assign done=owned && port_done;
    assign response_valid=owned && active_read && port_valid;
    assign response_last=response_valid && port_done;
    assign response_word=active_word+{19'd0,received};
    assign response_data=port_result;
    always @(posedge clk) begin
        if(reset) begin
            owned<=0;active_read<=0;active_word<=0;active_count<=0;received<=0;protocol_error<=0;
        end else begin
            if(request) begin
                if(!ready || !valid_request)protocol_error<=1;
                else begin
                    owned<=1;active_read<=read_request;active_word<=word_address;
                    active_count<=word_count;received<=0;
                end
            end
            if(port_valid) begin
                if(!owned || !active_read || received>=active_count)protocol_error<=1;
                else received<=received+1'b1;
            end
            if(port_done) begin
                if(!owned || (active_read && (!port_valid || received+1'b1!=active_count)))
                    protocol_error<=1;
                owned<=0;
            end
        end
    end
endmodule
