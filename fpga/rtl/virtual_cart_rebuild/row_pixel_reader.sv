module row_pixel_reader #(
    parameter BASE_POINTER=23'h010000,
    parameter BANK_COUNT=10
) (
    input hClk,xClk,reset,enabled,hVsync,hHsync,hValid,
    output hSelect,
    output [22:0] hSelectAddress,
    input selection_valid,
    input [3:0] selection_bank,
    input selection_head_valid,
    input [15:0] selection_head,
    input [BANK_COUNT-1:0] bank_ready,
    output [BANK_COUNT-1:0] leased_banks,
    output read_request,
    output [3:0] read_bank,
    output [7:0] read_index,
    input read_ready,read_valid,
    input [15:0] read_data,
    output [15:0] hPixelData,
    output hPixelReady,
    output [3:0] hPixelBank,
    output [14:0] hPixelIndex,
    output xRowRequest,
    output [22:0] xRowAddress,
    output protocol_error
);
    wire hStartOfFrame,hStartOfLine,hEndOfLine;
    reader_events #(.BASE_POINTER(BASE_POINTER)) events (
        .hClk(hClk),.xClk(xClk),.reset(reset),.hVsync(hVsync),.hHsync(hHsync),.hValid(hValid),
        .hStartOfFrame(hStartOfFrame),.hStartOfLine(hStartOfLine),.hEndOfLine(hEndOfLine),
        .hPixelIndex(hPixelIndex),.xRowRequest(xRowRequest),.xRowAddress(xRowAddress));
    reg [22:0] requested_address;
    assign hSelect=enabled && (hStartOfFrame || hEndOfLine);
    assign hSelectAddress=hStartOfFrame?BASE_POINTER:requested_address+23'd320;
    reg requested_valid,active_valid,requested_head_valid,active_head_valid;
    reg [3:0] requested_bank,active_bank;
    reg [15:0] requested_head,active_head;
    reg [3:0] tail_hclks;
    reg selection_toggle,active_generation,h_error;
    assign hPixelBank=active_bank;
    always @(posedge hClk)begin
        if(reset)begin
            requested_address<=BASE_POINTER;requested_valid<=0;active_valid<=0;
            requested_head_valid<=0;active_head_valid<=0;requested_bank<=0;active_bank<=0;
            requested_head<=0;active_head<=0;tail_hclks<=0;selection_toggle<=0;active_generation<=0;h_error<=0;
        end else begin
            if(tail_hclks!=0)tail_hclks<=tail_hclks-1'b1;
            if(tail_hclks==1 || (hStartOfLine && !hValid))begin
                active_valid<=requested_valid;active_bank<=requested_bank;
                active_head_valid<=requested_head_valid;active_head<=requested_head;tail_hclks<=0;
                active_generation<=~active_generation;
            end
            if(hSelect)begin
                requested_address<=hSelectAddress;requested_valid<=selection_valid;
                requested_bank<=selection_bank;requested_head_valid<=selection_head_valid;
                requested_head<=selection_head;selection_toggle<=~selection_toggle;
                tail_hclks<=8;
                if(hStartOfFrame)begin
                    active_valid<=selection_valid;active_bank<=selection_bank;
                    active_head_valid<=selection_head_valid;active_head<=selection_head;tail_hclks<=0;
                    active_generation<=~active_generation;
                end
            end
            if(enabled && hValid && !hPixelReady)h_error<=1;
            if(hSelect && selection_valid && selection_bank>=BANK_COUNT)h_error<=1;
            if(!enabled)begin requested_valid<=0;active_valid<=0;tail_hclks<=0;end
        end
    end

    reg pending,held_valid,x_error,seen_selection,seen_active,pending_generation,held_generation;
    reg [3:0] pending_bank,held_bank;
    reg [7:0] pending_index,held_index;
    reg [15:0] held_data;
    wire head=active_head_valid && hPixelIndex==0;
    wire held_matches=held_valid && held_generation==active_generation && held_bank==active_bank && {7'd0,held_index}==hPixelIndex;
    assign hPixelReady=active_valid && hPixelIndex<160 && (head || held_matches);
    assign hPixelData=head?active_head:held_data;
    assign read_request=enabled && active_valid && active_bank<BANK_COUNT && bank_ready[active_bank] &&
        hPixelIndex<160 && !head && !held_matches && !pending;
    assign read_bank=active_bank;
    assign read_index=hPixelIndex[7:0];
    wire accepted=read_request && read_ready;
    wire [BANK_COUNT-1:0] inflight_leases=(pending ? (BANK_COUNT'(1)<<pending_bank):{BANK_COUNT{1'b0}}) |
        (accepted ? (BANK_COUNT'(1)<<read_bank):{BANK_COUNT{1'b0}}) |
        (enabled && requested_valid ? (BANK_COUNT'(1)<<requested_bank):{BANK_COUNT{1'b0}});
    wire lease_error;
    row_leases #(.BANK_COUNT(BANK_COUNT)) leases (
        .clk(xClk),.reset(reset),.select(selection_toggle!=seen_selection),
        .select_valid(requested_valid),.select_bank(requested_bank),
        .release_selection(!enabled),.inflight_leases(inflight_leases),
        .leased_banks(leased_banks),.selected_valid(),.selected_bank(),.protocol_error(lease_error));
    assign protocol_error=h_error || x_error || lease_error;
    always @(posedge xClk)begin
        if(reset)begin
            pending<=0;held_valid<=0;x_error<=0;seen_selection<=0;seen_active<=0;pending_generation<=0;held_generation<=0;
            pending_bank<=0;held_bank<=0;pending_index<=0;held_index<=0;held_data<=0;
        end else begin
            seen_selection<=selection_toggle;
            seen_active<=active_generation;
            if(seen_active!=active_generation)held_valid<=0;
            if(accepted)begin pending<=1;pending_bank<=read_bank;pending_index<=read_index;pending_generation<=active_generation;end
            if(read_valid)begin
                if(!pending)x_error<=1;
                pending<=0;held_valid<=pending_generation==active_generation;held_generation<=pending_generation;
                held_bank<=pending_bank;held_index<=pending_index;held_data<=read_data;
            end
            if(!enabled && !pending)held_valid<=0;
        end
    end
endmodule
