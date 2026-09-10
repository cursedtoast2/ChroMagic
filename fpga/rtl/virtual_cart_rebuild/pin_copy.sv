module pin_copy (
    input clk,reset,start,cancel,
    input [2:0] source_version,destination_version,
    output reg busy,done,aborted,
    output reg [2:0] active_source,active_destination,
    input read_ready,
    output read_request,
    output [7:0] read_index,
    input reply_valid,
    input [15:0] reply_data,
    input write_ready,
    output write_request,
    output [7:0] write_index,
    output [15:0] write_data,
    output [3:0] reserved_words,
    output reg protocol_error
);
    reg cancel_pending;
    reg [7:0] issued,returned,written;
    reg [3:0] queued;
    reg [2:0] rdptr,wrptr;
    reg [15:0] queue [0:7];
    wire response_owned=busy && returned<issued;
    wire direct=queued==0 && reply_valid && response_owned;
    assign reserved_words=4'(issued-written);
    assign read_request=!reset && !protocol_error && busy && !cancel_pending && !cancel && issued<160 && reserved_words<8 && read_ready;
    assign read_index=issued;
    assign write_request=!reset && !protocol_error && busy && (queued!=0 || direct) && write_ready;
    assign write_index=written;
    assign write_data=queued!=0?queue[rdptr]:reply_data;
    wire pop=write_request && queued!=0;
    wire push=reply_valid && response_owned && !(direct && write_request);
    wire drain_last=issued==written || (write_request && issued==written+1'b1);
    always @(posedge clk)begin
        if(reset)begin
            busy<=0;done<=0;aborted<=0;active_source<=0;active_destination<=0;cancel_pending<=0;
            issued<=0;returned<=0;written<=0;queued<=0;rdptr<=0;wrptr<=0;protocol_error<=0;
        end else begin
            done<=0;aborted<=0;
            if(start)begin
                if(busy || source_version>5 || destination_version>5 || source_version==destination_version)protocol_error<=1;
                else begin
                    busy<=1;active_source<=source_version;active_destination<=destination_version;
                    cancel_pending<=0;issued<=0;returned<=0;written<=0;queued<=0;rdptr<=0;wrptr<=0;
                end
            end
            if(cancel && busy)cancel_pending<=1;
            if(read_request)issued<=issued+1'b1;
            if(reply_valid)begin
                if(!response_owned)protocol_error<=1;else returned<=returned+1'b1;
            end
            if(push)begin
                if(queued==8 && !pop)protocol_error<=1;
                else begin queue[wrptr]<=reply_data;wrptr<=wrptr+1'b1;end
            end
            if(pop)rdptr<=rdptr+1'b1;
            case({push,pop})
                2'b10:queued<=queued+1'b1;
                2'b01:queued<=queued-1'b1;
                default:begin end
            endcase
            if(write_request)begin
                written<=written+1'b1;
                if(written==159)begin busy<=0;done<=!(cancel_pending || cancel);cancel_pending<=0;end
            end
            if(busy && (cancel_pending || cancel) && drain_last)begin
                busy<=0;aborted<=1;cancel_pending<=0;
            end
            if(reserved_words>8 || returned>issued || written>returned+(reply_valid?1:0))protocol_error<=1;
        end
    end
endmodule
