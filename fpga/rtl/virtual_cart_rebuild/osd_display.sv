module osd_display (
    input hClk,xClk,reset,initialize,quiesce,
    input hVsync,hHsync,hValid,hFrameEvent,video_ce,
    input [2:0] bypass_state,
    input reset_now,vsync_overwrite,
    input prepare,prepare_set,
    input [9:0] prepare_index,
    input [15:0] prepare_data,
    input block_valid,
    input [22:0] block_address,
    input [9:0] block_words,
    output block_ready,block_accept,block_ack,
    input [10:0] available_words,
    input head_valid,
    input [15:0] head_data,
    output pop,
    input [4:0] read_limit,write_limit,
    input write_eligible,read_ready,write_ready,physical_drained,
    output read_request,write_request,
    output [22:0] read_address,write_address,
    output [9:0] read_words,write_words,
    output [15:0] write_data,
    output [7:0] request_row,
    input read_accept,read_valid,read_done,
    input [9:0] read_index,
    input [15:0] read_data,
    input write_accept,write_advance,write_done,
    input [9:0] write_index,
    output [15:0] hPixelData,
    output hPixelReady,hSelect,
    output [22:0] hSelectAddress,
    output [3:0] hPixelBank,
    output [14:0] hPixelIndex,
    output hFrontSet,hSelectableSet,front_set,hQualifiedQuiet,
    output upload_pending,
    output [11:0] reader_leases,
    output busy,protocol_error
);
    wire mirror_write,mirror_set,mirror_ready,writer_busy,reader_busy,writer_error,reader_error;
    wire [9:0] mirror_index;
    wire [15:0] mirror_data;
    display_quiet quiet (
        .hClk(hClk),.reset(reset),.video_ce(video_ce),.hValid(hValid),.bypass_state(bypass_state),
        .reset_now(reset_now),.vsync_overwrite(vsync_overwrite),.qualified_quiet(hQualifiedQuiet));
    osd_bulk_write upload (
        .xClk(xClk),.hClk(hClk),.reset(reset),.initialize(initialize),
        .block_valid(block_valid),.block_address(block_address),.block_words(block_words),
        .block_ready(block_ready),.block_accept(block_accept),.block_ack(block_ack),
        .available_words(available_words),.head_valid(head_valid),.head_data(head_data),.pop(pop),
        .eligible(write_eligible),.write_limit(write_limit),.memory_ready(write_ready),.memory_accept(write_accept),
        .memory_advance(write_advance),.memory_done(write_done),.physical_drained(physical_drained),.memory_index(write_index),
        .memory_request(write_request),.memory_address(write_address),.memory_words(write_words),.memory_data(write_data),
        .mirror_write(mirror_write),.mirror_set(mirror_set),.mirror_index(mirror_index),.mirror_data(mirror_data),.mirror_ready(mirror_ready),
        .hFrameEvent(hFrameEvent),.hQualifiedQuiet(hQualifiedQuiet),.reader_leases(reader_leases),
        .hFrontSet(hFrontSet),.hSelectableSet(hSelectableSet),.front_set(front_set),.upload_pending(upload_pending),
        .busy(writer_busy),.protocol_error(writer_error));
    osd_reader reader (
        .hClk(hClk),.xClk(xClk),.reset(reset),.initialize(initialize),.quiesce(quiesce),
        .hVsync(hVsync),.hHsync(hHsync),.hValid(hValid),.hQualifiedQuiet(hQualifiedQuiet),.hFrontSet(hFrontSet),.hSelectableSet(hSelectableSet),
        .prepare(prepare),.prepare_set(prepare_set),.prepare_index(prepare_index),.prepare_data(prepare_data),
        .mirror_write(mirror_write),.mirror_set(mirror_set),.mirror_index(mirror_index),.mirror_data(mirror_data),.mirror_ready(mirror_ready),
        .reader_leases(reader_leases),.read_limit(read_limit),.memory_ready(read_ready),.memory_request(read_request),
        .memory_address(read_address),.memory_words(read_words),.request_row(request_row),
        .memory_accept(read_accept),.memory_valid(read_valid),.memory_done(read_done),.physical_drained(physical_drained),
        .memory_index(read_index),.memory_data(read_data),.hPixelData(hPixelData),.hPixelReady(hPixelReady),
        .hSelect(hSelect),.hSelectAddress(hSelectAddress),.hPixelBank(hPixelBank),.hPixelIndex(hPixelIndex),
        .busy(reader_busy),.protocol_error(reader_error));
    assign busy=writer_busy || reader_busy || (|reader_leases);
    assign protocol_error=writer_error || reader_error;
endmodule
