module osd_reader (
    input hClk,xClk,reset,initialize,quiesce,
    input hVsync,hHsync,hValid,hQualifiedQuiet,hFrontSet,hSelectableSet,
    input prepare,prepare_set,
    input [9:0] prepare_index,
    input [15:0] prepare_data,
    input mirror_write,mirror_set,
    input [9:0] mirror_index,
    input [15:0] mirror_data,
    output mirror_ready,
    output [11:0] reader_leases,
    input [4:0] read_limit,
    input memory_ready,
    output memory_request,
    output [22:0] memory_address,
    output [9:0] memory_words,
    output [7:0] request_row,
    input memory_accept,memory_valid,memory_done,physical_drained,
    input [9:0] memory_index,
    input [15:0] memory_data,
    output [15:0] hPixelData,
    output hPixelReady,hSelect,
    output [22:0] hSelectAddress,
    output [3:0] hPixelBank,
    output [14:0] hPixelIndex,
    output busy,protocol_error
);
    reg initialized,armed,previous_vsync,frame_toggle;
    reg [7:0] h_row;
    reg [1:0] h_ring;
    wire h_frame=hVsync && !previous_vsync;
    wire [7:0] select_row=h_frame?8'd0:h_row+1'b1;
    wire [3:0] set_base=hSelectableSet?4'd6:4'd0;
    wire [3:0] chosen_bank=set_base+(select_row<3?select_row[3:0]:4'd3+{2'd0,h_ring});
    wire [2:0] head_index=(hSelectableSet?3'd3:3'd0)+select_row[2:0];
    always @(posedge hClk)begin
        if(reset)begin armed<=0;previous_vsync<=0;frame_toggle<=0;h_row<=0;h_ring<=0;end
        else begin
            previous_vsync<=hVsync;
            if(h_frame)begin armed<=1;frame_toggle<=~frame_toggle;h_row<=0;h_ring<=0;end
            else if(hSelect)begin
                h_row<=h_row+1'b1;
                if(select_row>=3)h_ring<=h_ring==2?2'd0:h_ring+1'b1;
            end
        end
    end
    reg seen_frame,seen_front,prefix_unused,active_set;
    reg [15:0] epoch;
    wire frame_changed=frame_toggle!=seen_frame;
    wire front_changed=hFrontSet!=seen_front;
    wire new_frame=frame_changed || front_changed;
    always @(posedge xClk)begin
        if(reset)begin initialized<=0;seen_frame<=0;seen_front<=0;prefix_unused<=1;active_set<=0;epoch<=0;end
        else begin
            if(initialize)initialized<=1;
            seen_frame<=frame_toggle;seen_front<=hFrontSet;
            if(front_changed)prefix_unused<=1;
            if(frame_changed)prefix_unused<=0;
            if(new_frame)epoch<=epoch+1'b1;
            if(memory_accept)active_set<=hFrontSet;
        end
    end
    wire [11:0] pixel_leases;
    wire [2:0] ready_rows,inflight_rows;
    assign reader_leases=pixel_leases | (active_set?{inflight_rows,9'd0}:{6'd0,inflight_rows,3'd0});
    wire [95:0] heads;
    wire [5:0] heads_valid;
    wire [11:0] bank_ready={hFrontSet?ready_rows:3'd0,heads_valid[5:3],hFrontSet?3'd0:ready_rows,heads_valid[2:0]};
    wire read_request,read_ready,read_valid,reader_error,store_error,prefetch_error;
    wire [3:0] read_bank;
    wire [7:0] read_index;
    wire [15:0] read_data;
    row_pixel_reader #(.BASE_POINTER(23'd0),.BANK_COUNT(12)) reader (
        .hClk(hClk),.xClk(xClk),.reset(reset),.enabled(initialized && (armed || h_frame) && !quiesce && !hQualifiedQuiet),
        .hVsync(hVsync),.hHsync(hHsync),.hValid(hValid),.hSelect(hSelect),.hSelectAddress(hSelectAddress),
        .selection_valid(select_row<144),.selection_bank(chosen_bank),
        .selection_head_valid(select_row<3 && heads_valid[head_index]),.selection_head(heads[head_index*16+:16]),
        .bank_ready(bank_ready),.leased_banks(pixel_leases),.read_request(read_request),.read_bank(read_bank),.read_index(read_index),
        .read_ready(read_ready),.read_valid(read_valid),.read_data(read_data),
        .hPixelData(hPixelData),.hPixelReady(hPixelReady),.hPixelBank(hPixelBank),.hPixelIndex(hPixelIndex),
        .xRowRequest(),.xRowAddress(),.protocol_error(reader_error));
    wire rolling_write,rolling_ready;
    wire [1:0] rolling_bank;
    wire [7:0] rolling_index;
    wire [15:0] rolling_data;
    rolling_rows #(.PIN_ROWS(3),.BANK_COUNT(3)) prefetch (
        .clk(xClk),.reset(reset),.enabled(initialized && !quiesce && !hQualifiedQuiet),.frame(new_frame),
        .seeded_frame(prefix_unused || front_changed),.epoch(epoch),.image_base(hFrontSet?23'h440000:23'd0),
        .selected_row(hQualifiedQuiet?8'd0:h_row),.reader_leases(hFrontSet?pixel_leases[11:9]:pixel_leases[5:3]),
        .older_writes(1'b0),.read_limit(read_limit),.memory_ready(memory_ready),
        .memory_request(memory_request),.memory_address(memory_address),.memory_words(memory_words),.request_row(request_row),
        .memory_accept(memory_accept),.memory_valid(memory_valid),.memory_done(memory_done),.physical_drained(physical_drained),
        .memory_index(memory_index),.memory_data(memory_data),.rolling_write(rolling_write),.rolling_write_bank(rolling_bank),
        .rolling_write_index(rolling_index),.rolling_write_data(rolling_data),.rolling_write_ready(rolling_ready),
        .ready_banks(ready_rows),.bank_rows(),.inflight_banks(inflight_rows),.snapshotted_through(),.busy(busy),.protocol_error(prefetch_error));
    osd_store storage (
        .clk(xClk),.reset(reset),.prepare(prepare),.prepare_set(prepare_set),.prepare_index(prepare_index),.prepare_data(prepare_data),
        .mirror_write(mirror_write),.mirror_set(mirror_set),.mirror_index(mirror_index),.mirror_data(mirror_data),.mirror_ready(mirror_ready),
        .reader_leases(reader_leases),.rolling_write(rolling_write),.rolling_set(active_set),.rolling_bank(rolling_bank),
        .rolling_index(rolling_index),.rolling_data(rolling_data),.rolling_ready(rolling_ready),
        .read_request(read_request),.read_bank(read_bank),.read_index(read_index),.read_ready(read_ready),.read_valid(read_valid),.read_data(read_data),
        .heads(heads),.heads_valid(heads_valid),.protocol_error(store_error));
    assign protocol_error=reader_error || store_error || prefetch_error;
endmodule
