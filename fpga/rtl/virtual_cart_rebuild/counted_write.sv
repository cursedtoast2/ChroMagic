module counted_write #(
    parameter MAX_DESCRIPTOR_WORDS=160,
    parameter COUNT_WIDTH=$clog2(MAX_DESCRIPTOR_WORDS+1)
) (
    input clk,reset,
    input descriptor_valid,
    output descriptor_ready,
    input [22:0] descriptor_address,
    input [COUNT_WIDTH-1:0] descriptor_words,
    input [15:0] descriptor_epoch,
    input next_coalescible,
    input eligible,
    input [10:0] available_words,
    input head_valid,
    input [15:0] head_data,
    output pop,
    input [4:0] write_limit,
    input memory_ready,memory_accept,memory_advance,memory_done,physical_drained,
    input [9:0] memory_index,
    output memory_request,
    output [22:0] memory_address,
    output [9:0] memory_words,
    output [15:0] memory_data,
    output retired_word,
    output [22:0] retired_address,
    output [15:0] retired_data,
    output reg descriptor_done,
    output reg [22:0] completed_address,
    output reg [15:0] completed_epoch,
    output reg busy,
    output [22:0] current_address,
    output [15:0] current_epoch,
    output reg protocol_error
);
    reg owned,finishing;
    reg [22:0] base,cursor,active_address,joined_address;
    reg [15:0] epoch;
    reg [COUNT_WIDTH-1:0] total,remaining;
    reg [9:0] accepted_words,retired,old_remaining;
    reg accepted_join;
    wire valid_descriptor=descriptor_words!=0 && descriptor_words<=MAX_DESCRIPTOR_WORDS && !descriptor_address[0] &&
                          {1'b0,descriptor_address}+(24'(descriptor_words)<<1)<=24'h800000;
    wire join_row=descriptor_valid && valid_descriptor && next_coalescible &&
        total==160 && descriptor_words==160 && descriptor_epoch==epoch &&
        {1'b0,descriptor_address}=={1'b0,base}+24'd320;
    wire [9:0] extent=10'(remaining)+(join_row?10'd160:10'd0);
    wire [9:0] row_left=10'd512-{1'b0,cursor[9:1]};
    wire [9:0] offered=extent<write_limit?extent:{5'd0,write_limit};
    wire [9:0] clamped=offered<row_left?offered:row_left;
    wire [9:0] count=available_words<{1'b0,clamped}?available_words[9:0]:clamped;
    wire crossing=count>10'(remaining);
    assign descriptor_ready=!reset && !protocol_error && valid_descriptor &&
                            (!busy || (memory_accept && crossing));
    assign memory_request=!reset && !protocol_error && busy && !owned && !finishing &&
                           eligible && memory_ready && head_valid && count!=0;
    assign memory_address=cursor;
    assign memory_words=count;
    assign memory_data=head_data;
    assign pop=owned && memory_advance;
    assign retired_word=pop && head_valid;
    assign retired_address=active_address+{retired,1'b0};
    assign retired_data=head_data;
    assign current_address=base;
    assign current_epoch=epoch;
    always @(posedge clk)begin
        if(reset)begin
            owned<=0;finishing<=0;busy<=0;base<=0;cursor<=0;epoch<=0;total<=0;remaining<=0;
            active_address<=0;joined_address<=0;accepted_words<=0;retired<=0;old_remaining<=0;accepted_join<=0;
            descriptor_done<=0;completed_address<=0;completed_epoch<=0;protocol_error<=0;
        end else begin
            descriptor_done<=0;
            if(descriptor_valid && descriptor_ready && !busy)begin
                busy<=1;base<=descriptor_address;cursor<=descriptor_address;epoch<=descriptor_epoch;
                total<=descriptor_words;remaining<=descriptor_words;
            end
            if(memory_accept)begin
                if(!memory_request || owned)protocol_error<=1;
                owned<=1;active_address<=cursor;accepted_words<=count;retired<=0;
                accepted_join<=crossing;old_remaining<=10'(remaining);
                if(crossing)joined_address<=descriptor_address;
            end
            if(memory_advance)begin
                if(!owned || !head_valid || available_words==0 || retired>=accepted_words || memory_index!=retired)
                    protocol_error<=1;
                retired<=retired+1'b1;
            end
            if(memory_done)begin
                if(!owned || !memory_advance || retired+1'b1!=accepted_words)protocol_error<=1;
                owned<=0;cursor<=active_address+{accepted_words,1'b0};
                if(accepted_join)begin
                    completed_address<=base;completed_epoch<=epoch;descriptor_done<=1;
                    base<=joined_address;remaining<=COUNT_WIDTH'(10'd160-(accepted_words-old_remaining));total<=160;
                end else begin
                    remaining<=remaining-COUNT_WIDTH'(accepted_words);
                    if(accepted_words==10'(remaining))finishing<=1;
                end
            end
            if(finishing && physical_drained)begin
                completed_address<=base;completed_epoch<=epoch;descriptor_done<=1;
                finishing<=0;busy<=0;
            end
            if(descriptor_valid && !valid_descriptor)protocol_error<=1;
        end
    end
endmodule
