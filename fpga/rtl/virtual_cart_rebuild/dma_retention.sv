module dma_retention #(parameter HOLD_READ=0) (
    input clk, reset,
    input query_enable,
    input [22:0] query_word,
    output data_valid,
    output [15:0] data_word,
    output query_hit,
    output block_complete,
    output reg [2:0] block_missing_offset,
    input [22:0] next_head_word,
    output next_head_hit,
    output query_hdma_head_hit,next_hdma_head_hit,
    input [1:0] forward_mask,
    input [15:0] forward_data,

    input fill_begin,
    input [22:0] fill_word,
    input [3:0] fill_words,
    input fill_handoff,fill_handoff_slot,
    output fill_available,
    input response_valid, response_last,
    input [22:0] response_word,
    input [15:0] response_data,

    input replica_valid,
    input [22:0] replica_word,
    input [15:0] replica_data,
    output replica_ready,

    output ram_read,
    input ram_read_ready,
    output [9:0] ram_read_address,
    input ram_read_valid,
    input [15:0] ram_read_data,
    output ram_write,
    output [9:0] ram_write_address,
    output [15:0] ram_write_data,
    output reg protocol_error
);
    localparam [9:0] BASE=10'd177;
    localparam [9:0] HANDOFF_BASE=10'd825;
    reg [19:0] block_tag;
    reg [19:0] ahead_tag;
    reg ahead_valid,pending_ahead;
    reg [7:0] valid_words;
    reg busy;
    reg [22:0] pending_word,read_word;
    reg [3:0] pending_count,received;
    reg read_requested;
    reg [22:0] handoff_tag[0:1];
    reg [1:0] handoff_valid;
    reg pending_handoff,pending_handoff_slot;
    reg [7:0] available_words;
    integer i;
    always @*begin
        available_words=query_word[22:3]==block_tag?valid_words:8'd0;
        if(ahead_valid && query_word[22:3]==ahead_tag)available_words[0]=1;
        for(integer p=0;p<2;p=p+1)
            if(handoff_valid[p] && query_word[22:3]==handoff_tag[p][22:3])
                available_words[handoff_tag[p][2:0]]=1;
        block_missing_offset=query_word[2:0];
        for(i=7;i>=0;i=i-1)
            if(i>=query_word[2:0] && !available_words[i])block_missing_offset=3'(i);
    end
    wire hit=available_words[query_word[2:0]];
    wire primary_hit=(query_word[22:3]==block_tag && valid_words[query_word[2:0]]) ||
                     (ahead_valid && query_word[2:0]==0 && query_word[22:3]==ahead_tag);
    wire handoff_hit0=handoff_valid[0] && query_word==handoff_tag[0];
    assign query_hdma_head_hit=handoff_hit0;
    assign next_hdma_head_hit=handoff_valid[0] && next_head_word==handoff_tag[0];
    assign next_head_hit=(next_head_word[22:3]==block_tag && valid_words[next_head_word[2:0]]) ||
                        (ahead_valid && next_head_word[2:0]==0 && next_head_word[22:3]==ahead_tag) ||
                        (handoff_valid[0] && next_head_word==handoff_tag[0]) ||
                        (handoff_valid[1] && next_head_word==handoff_tag[1]);
    assign query_hit=hit;
    assign block_complete=&(available_words | (8'hff >> (8-query_word[2:0])));
    wire owned_response=busy && response_word==pending_word+{19'd0,received} && received<pending_count;
    wire raw_hit=response_valid && owned_response && response_word==query_word;
    reg held_valid;
    reg [22:0] held_word;
    reg [15:0] held_data;
    wire direct_hit=hit && ram_read_valid && read_requested && read_word==query_word;
    wire held_hit=HOLD_READ && held_valid && held_word==query_word && hit;
    wire retained_hit=direct_hit || held_hit;
    wire [15:0] base_data=raw_hit?response_data:direct_hit?ram_read_data:held_data;
    assign data_valid=query_enable && (raw_hit || retained_hit || forward_mask==2'b11);
    assign data_word={forward_mask[1]?forward_data[15:8]:base_data[15:8],
                      forward_mask[0]?forward_data[7:0]:base_data[7:0]};
    assign fill_available=!busy && !reset;
    assign ram_read=query_enable && hit && !reset && (!HOLD_READ || !(raw_hit || retained_hit));
    assign ram_read_address=primary_hit?BASE+{7'd0,query_word[2:0]}:
                            HANDOFF_BASE+{9'd0,!handoff_hit0};
    wire replica_hit=(replica_word[22:3]==block_tag && valid_words[replica_word[2:0]]) ||
                     (ahead_valid && replica_word[2:0]==0 && replica_word[22:3]==ahead_tag);
    reg [2:0] replica_written;
    wire [2:0] replica_matches={handoff_valid[1] && replica_word==handoff_tag[1],
                                handoff_valid[0] && replica_word==handoff_tag[0],replica_hit};
    wire [2:0] replica_remaining=replica_matches & ~replica_written;
    wire [2:0] replica_selected=replica_remaining & (~replica_remaining+3'd1);
    wire replica_last=(replica_remaining & (replica_remaining-3'd1))==0;
    wire replica_slot=!response_valid && !fill_begin && !reset;
    assign replica_ready=replica_slot && replica_last;
    assign ram_write=!reset && ((response_valid && owned_response) ||
                                (replica_valid && replica_slot && |replica_remaining));
    assign ram_write_address=response_valid ?
        (pending_handoff?HANDOFF_BASE+{9'd0,pending_handoff_slot}:BASE+{7'd0,response_word[2:0]}) :
        replica_selected[0]?BASE+{7'd0,replica_word[2:0]}:
        HANDOFF_BASE+{9'd0,replica_selected[2]};
    assign ram_write_data=response_valid?response_data:replica_data;
    always @(posedge clk) begin
        if(reset)begin
            block_tag<=0;valid_words<=0;busy<=0;pending_word<=0;
            pending_count<=0;received<=0;read_word<=0;read_requested<=0;protocol_error<=0;
            ahead_tag<=0;ahead_valid<=0;pending_ahead<=0;
            handoff_valid<=0;handoff_tag[0]<=0;handoff_tag[1]<=0;
            pending_handoff<=0;pending_handoff_slot<=0;replica_written<=0;
            held_valid<=0;held_word<=0;held_data<=0;
        end else begin
            read_requested<=ram_read && (!HOLD_READ || ram_read_ready);
            if(ram_read && (!HOLD_READ || ram_read_ready))read_word<=query_word;
            if(HOLD_READ)begin
                if(ram_read_valid && read_requested)begin
                    held_valid<=1;held_word<=read_word;held_data<=ram_read_data;
                end
                if(raw_hit)begin held_valid<=1;held_word<=query_word;held_data<=response_data;end
                if(replica_valid && held_valid && replica_word==held_word)held_data<=replica_data;
            end
            if(replica_valid && replica_slot)
                replica_written<=replica_last?3'd0:replica_written|replica_selected;
            if(fill_begin)begin
                if(busy || fill_words==0 || fill_words>8 ||
                   {1'b0,fill_word[2:0]}+fill_words>8 || (fill_handoff && fill_words!=1))protocol_error<=1;
                else begin
                    busy<=1;pending_word<=fill_word;pending_count<=fill_words;received<=0;
                    pending_handoff<=fill_handoff;pending_handoff_slot<=fill_handoff_slot;
                    pending_ahead<=fill_words==1 && fill_word[2:0]==0 && block_tag!=fill_word[22:3];
                    if(fill_handoff)begin
                        handoff_tag[fill_handoff_slot]<=fill_word;
                        handoff_valid[fill_handoff_slot]<=0;
                    end else if(fill_words==1 && fill_word[2:0]==0 && block_tag!=fill_word[22:3])begin
                        valid_words[0]<=0;ahead_valid<=0;ahead_tag<=fill_word[22:3];
                    end else begin
                        if(block_tag!=fill_word[22:3])
                            valid_words<=(ahead_valid && ahead_tag==fill_word[22:3])?8'h01:8'h00;
                        block_tag<=fill_word[22:3];ahead_valid<=0;
                    end
                end
            end
            if(response_valid)begin
                if(!owned_response || response_last!=(received+1'b1==pending_count))protocol_error<=1;
                else begin
                    if(pending_handoff)handoff_valid[pending_handoff_slot]<=1;
                    else if(pending_ahead)ahead_valid<=1;else valid_words[response_word[2:0]]<=1;
                    received<=received+1'b1;
                    if(response_last)busy<=0;
                end
            end
        end
    end
endmodule
