module posted_writes (
    input clk, reset,
    input store_valid,
    input [22:0] store_word,
    input store_high,
    input [7:0] store_data,
    input peer_valid,
    input [15:0] peer_data,
    output reg store_ready,
    input peer_reply_valid,
    input [22:0] peer_reply_word,
    input [15:0] peer_reply_data,
    output issue_valid,
    output [22:0] issue_word,
    output [15:0] issue_data,
    input issue_accept,
    input retire,
    input [22:0] lookup_word,
    output reg [1:0] forward_mask,
    output reg [15:0] forward_data,
    input [22:0] response_word,
    output reg [1:0] response_mask,
    output reg [15:0] response_data,
    input [22:0] dma_word,
    output reg [1:0] dma_mask,
    output reg [15:0] dma_data,
    output reg [1:0] count,
    output reg protocol_error
);
    reg [22:0] tags [0:2];
    reg [15:0] words [0:2];
    reg [1:0] masks [0:2];
    reg [1:0] head;
    reg claimed;
    reg coalesce, retire_ok;
    reg [1:0] tail, destination, index;
    reg [15:0] merged;
    reg [1:0] merged_mask;
    integer i;
    function [1:0] slot(input [1:0] origin, input integer offset);
        integer sum;
        begin sum=int'(origin)+offset;slot=2'((sum>=3)?sum-3:sum);end
    endfunction
    assign issue_valid = count!=0 && !claimed && masks[head]==2'b11;
    assign issue_word = tags[head];
    assign issue_data = words[head];

    always @* begin
        tail=slot(head,count==0?0:int'(count)-1);
        retire_ok=retire && claimed && count!=0;
        coalesce=count!=0 && tags[tail]==store_word &&
                 !(tail==head && (claimed || issue_accept));
        destination=coalesce?tail:slot(head,int'(count));
        store_ready=coalesce || count<3 || retire_ok;
        merged=peer_data;merged_mask=peer_valid?2'b11:2'b00;
        if(peer_reply_valid && peer_reply_word==store_word) begin
            merged=peer_reply_data;merged_mask=2'b11;
        end
        index=0;
        for(integer n=0;n<3;n=n+1) begin
            index=slot(head,n);
            if(n<count) begin
                if(tags[index]==store_word) begin
                    if(masks[index][0]) merged[7:0]=words[index][7:0];
                    if(masks[index][1]) merged[15:8]=words[index][15:8];
                    merged_mask=merged_mask|masks[index];
                end
            end
        end
        if(store_high) begin merged[15:8]=store_data;merged_mask[1]=1;end
        else begin merged[7:0]=store_data;merged_mask[0]=1;end
    end

    always @* begin
        forward_data=0;forward_mask=0;response_data=0;response_mask=0;dma_data=0;dma_mask=0;
        for(integer n=0;n<3;n=n+1) begin
            if(n<count) begin
                if(tags[slot(head,n)]==lookup_word) begin
                    if(masks[slot(head,n)][0]) forward_data[7:0]=words[slot(head,n)][7:0];
                    if(masks[slot(head,n)][1]) forward_data[15:8]=words[slot(head,n)][15:8];
                    forward_mask=forward_mask|masks[slot(head,n)];
                end
                if(tags[slot(head,n)]==response_word) begin
                    if(masks[slot(head,n)][0]) response_data[7:0]=words[slot(head,n)][7:0];
                    if(masks[slot(head,n)][1]) response_data[15:8]=words[slot(head,n)][15:8];
                    response_mask=response_mask|masks[slot(head,n)];
                end
                if(tags[slot(head,n)]==dma_word) begin
                    if(masks[slot(head,n)][0]) dma_data[7:0]=words[slot(head,n)][7:0];
                    if(masks[slot(head,n)][1]) dma_data[15:8]=words[slot(head,n)][15:8];
                    dma_mask=dma_mask|masks[slot(head,n)];
                end
            end
        end
    end

    always @(posedge clk) begin
        if(reset) begin
            head<=0;count<=0;claimed<=0;protocol_error<=0;
            for(i=0;i<3;i=i+1) begin tags[i]<=0;words[i]<=0;masks[i]<=0;end
        end else begin
            if(peer_reply_valid) begin
                for(integer n=0;n<3;n=n+1) begin
                    if(n<count && tags[slot(head,n)]==peer_reply_word) begin
                        if(!masks[slot(head,n)][0]) words[slot(head,n)][7:0]<=peer_reply_data[7:0];
                        if(!masks[slot(head,n)][1]) words[slot(head,n)][15:8]<=peer_reply_data[15:8];
                        masks[slot(head,n)]<=2'b11;
                    end
                end
            end
            if(issue_accept) begin
                if(issue_valid) claimed<=1;
                else protocol_error<=1;
            end
            if(retire) begin
                if(retire_ok) begin head<=slot(head,1);claimed<=0;end
                else protocol_error<=1;
            end
            if(store_valid) begin
                if(store_ready) begin
                    tags[destination]<=store_word;words[destination]<=merged;masks[destination]<=merged_mask;
                end else protocol_error<=1;
            end
            case({store_valid && store_ready && !coalesce,retire_ok})
                2'b10:count<=count+1'b1;
                2'b01:count<=count-1'b1;
                default:begin end
            endcase
        end
    end
endmodule
