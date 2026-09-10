module retention_tags (
    input clk, reset,
    input query_commit,
    input [5:0] query_roles,
    input [22:0] query_word,
    input sparse_hit,
    input [22:0] fill_start,
    input [3:0] fill_words,
    output reg window_hit,
    output reg [2:0] hit_bank, hit_offset,
    output reg allocation_available,
    output reg [2:0] allocation_bank,
    output reg fill_begin,
    output reg fill_busy,
    output reg [2:0] fill_bank,
    output reg [22:0] fill_base,
    output reg [3:0] fill_count,
    input response_valid,
    input [2:0] response_offset,
    input response_last,
    input [2:0] replica_bank,
    input [22:0] replica_word,
    output reg replica_hit,
    output reg [2:0] replica_offset,
    output reg protocol_error
);
    reg [22:0] base [0:5];
    reg [7:0] valid_words [0:5];
    reg [5:0] owners [0:5];
    reg [3:0] lengths [0:5];
    reg [7:0] received;
    integer b;
    reg [22:0] delta;
    reg found_hit, found_free;
    reg [7:0] expected_mask;
    reg valid_allocation;

    always @* begin
        window_hit=0;hit_bank=0;hit_offset=0;
        allocation_available=0;allocation_bank=0;
        found_hit=0;found_free=0;delta=0;
        for(integer i=0;i<6;i=i+1) begin
            delta=query_word-base[i];
            if(!found_hit && query_word>=base[i] && delta<lengths[i] &&
               delta<8 && valid_words[i][delta[2:0]]) begin
                found_hit=1;window_hit=1;hit_bank=i;hit_offset=delta[2:0];
            end
            if(!found_free && (owners[i] & ~query_roles)==0 &&
               !(fill_busy && fill_bank==i)) begin
                found_free=1;allocation_bank=i;
            end
        end
        allocation_available=found_free && !fill_busy;
        replica_hit=0;replica_offset=0;
        if(replica_bank<6 && replica_word>=base[replica_bank] &&
           replica_word-base[replica_bank]<lengths[replica_bank] &&
           replica_word-base[replica_bank]<8) begin
            replica_offset=replica_word-base[replica_bank];
            replica_hit=valid_words[replica_bank][replica_offset];
        end
        expected_mask=(9'h001 << fill_count)-1'b1;
        valid_allocation=(query_roles!=0 && fill_words>=1 && fill_words<=8 &&
            fill_start<=query_word && query_word-fill_start<fill_words &&
            ({1'b0,fill_start[8:0]}+fill_words)<=512);
    end

    always @(posedge clk) begin
        if(reset) begin
            fill_begin<=0;fill_busy<=0;fill_bank<=0;fill_base<=0;fill_count<=0;
            protocol_error<=0;received<=0;
            for(b=0;b<6;b=b+1) begin
                base[b]<=0;valid_words[b]<=0;owners[b]<=0;lengths[b]<=0;
            end
        end else begin
            fill_begin<=0;
            if(response_valid) begin
                if(!fill_busy || response_offset>=fill_count || received[response_offset])
                    protocol_error<=1;
                else begin
                    valid_words[fill_bank][response_offset]<=1;
                    received[response_offset]<=1;
                    if(response_last) begin
                        if((received | (8'h01 << response_offset))!=expected_mask)
                            protocol_error<=1;
                        else fill_busy<=0;
                    end
                end
            end else if(response_last) protocol_error<=1;

            if(query_commit && !sparse_hit) begin
                if(query_roles==0) protocol_error<=1;
                else if(window_hit) begin
                    for(b=0;b<6;b=b+1)
                        owners[b] <= (owners[b] & ~query_roles) |
                                     (b==hit_bank ? query_roles : 6'd0);
                end else if(allocation_available && valid_allocation) begin
                    for(b=0;b<6;b=b+1)
                        owners[b] <= (owners[b] & ~query_roles) |
                                     (b==allocation_bank ? query_roles : 6'd0);
                    base[allocation_bank]<=fill_start;
                    lengths[allocation_bank]<=fill_words;
                    valid_words[allocation_bank]<=0;
                    fill_begin<=1;fill_busy<=1;fill_bank<=allocation_bank;
                    fill_base<=fill_start;fill_count<=fill_words;received<=0;
                end else protocol_error<=1;
            end
        end
    end
endmodule
