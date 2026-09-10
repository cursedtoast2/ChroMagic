module osd_upload #(
    parameter HIGH_IMAGE=23'h440000
) (
    input xClk,hClk,reset,initialize,
    input block_valid,
    input [22:0] block_address,
    input [9:0] block_words,
    output block_ready,block_accept,
    output [22:0] mapped_address,
    input retired_word,
    input [22:0] retired_address,
    input [15:0] retired_data,
    input block_done,physical_drained,
    output mirror_write,
    output mirror_set,
    output [9:0] mirror_index,
    output [15:0] mirror_data,
    input mirror_ready,
    input hFrameEvent,hQualifiedQuiet,
    input [11:0] reader_leases,
    output reg hFrontSet,
    output hSelectableSet,
    output reg front_set,
    output reg block_ack,
    output upload_pending,
    output reg protocol_error
);
    localparam OPEN=3'd0,PAYLOAD=3'd1,TAIL=3'd2,PUBLISH=3'd3,RETIRE=3'd4;
    reg [2:0] state;
    reg initialized,publish_pending;
    reg [5:0] block_number;
    reg [9:0] received;
    reg [10:0] mirrored;
    reg [22:0] active_address;
    wire back_set=~front_set;
    wire [22:0] back_base=back_set?HIGH_IMAGE:23'd0;
    wire block_ordered=block_address=={7'd0,block_number,10'd0} && block_number<45 && block_words==512;
    assign block_ready=initialized && !reset && !protocol_error && state==OPEN;
    assign block_accept=block_valid && block_ready && block_ordered;
    assign mapped_address=back_base+block_address;
    assign mirror_write=retired_word && state==PAYLOAD && mirrored<960;
    assign mirror_set=back_set;
    assign mirror_index=mirrored[9:0];
    assign mirror_data=retired_data;
    assign upload_pending=state!=OPEN || block_number!=0;
    reg [1:0] hPendingSync,xFrontSync;
    reg hArmed;
    wire hPublish=hPendingSync[1] && hArmed && (hFrameEvent || hQualifiedQuiet);
    assign hSelectableSet=hPublish?~hFrontSet:hFrontSet;
    always @(posedge hClk)begin
        if(reset)begin hPendingSync<=0;hFrontSet<=0;hArmed<=1;end
        else begin
            hPendingSync<={hPendingSync[0],publish_pending};
            if(!hPendingSync[1])hArmed<=1;
            if(hPublish)begin
                hFrontSet<=~hFrontSet;hArmed<=0;
            end
        end
    end
    wire old_readers=front_set ? |reader_leases[5:0] : |reader_leases[11:6];
    always @(posedge xClk)begin
        if(reset)begin
            state<=OPEN;initialized<=0;publish_pending<=0;block_number<=0;received<=0;mirrored<=0;
            active_address<=0;front_set<=0;xFrontSync<=0;block_ack<=0;protocol_error<=0;
        end else begin
            xFrontSync<={xFrontSync[0],hFrontSet};block_ack<=0;
            if(initialize)begin
                if(initialized || state!=OPEN || block_number!=0)protocol_error<=1;
                initialized<=1;
            end
            if(block_valid && block_ready && !block_ordered)protocol_error<=1;
            if(block_accept)begin state<=PAYLOAD;active_address<=mapped_address;received<=0;end
            if(retired_word)begin
                if(state!=PAYLOAD || received>=512 || retired_address!=active_address+{12'd0,received,1'b0})protocol_error<=1;
                received<=received+1'b1;
                if(mirror_write)begin
                    if(!mirror_ready)protocol_error<=1;
                    mirrored<=mirrored+1'b1;
                end
            end
            if(block_done)begin
                if(state!=PAYLOAD || received+{9'd0,retired_word}!=512)protocol_error<=1;
                state<=TAIL;
            end
            if(state==TAIL && physical_drained && !protocol_error)begin
                if(block_number==44)begin
                    if(mirrored!=960)protocol_error<=1;
                    else begin publish_pending<=1;state<=PUBLISH;end
                end else begin block_number<=block_number+1'b1;block_ack<=1;state<=OPEN;end
            end
            if(state==PUBLISH && xFrontSync[1]!=front_set)begin
                front_set<=xFrontSync[1];publish_pending<=0;state<=RETIRE;
            end
            if(state==RETIRE && !old_readers && physical_drained && !protocol_error)begin
                block_number<=0;mirrored<=0;block_ack<=1;state<=OPEN;
            end
        end
    end
endmodule
