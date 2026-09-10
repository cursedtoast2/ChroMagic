module osd_bulk_write (
    input xClk,hClk,reset,initialize,
    input block_valid,
    input [22:0] block_address,
    input [9:0] block_words,
    output block_ready,block_accept,block_ack,
    input [10:0] available_words,
    input head_valid,
    input [15:0] head_data,
    output pop,
    input eligible,
    input [4:0] write_limit,
    input memory_ready,memory_accept,memory_advance,memory_done,physical_drained,
    input [9:0] memory_index,
    output memory_request,
    output [22:0] memory_address,
    output [9:0] memory_words,
    output [15:0] memory_data,
    output mirror_write,mirror_set,
    output [9:0] mirror_index,
    output [15:0] mirror_data,
    input mirror_ready,
    input hFrameEvent,hQualifiedQuiet,
    input [11:0] reader_leases,
    output hFrontSet,hSelectableSet,front_set,upload_pending,busy,
    output protocol_error
);
    wire upload_ready,descriptor_ready,writer_done,writer_busy,writer_error,upload_error;
    wire retired_word;
    wire [22:0] mapped_address,retired_address;
    wire [15:0] retired_data;
    assign block_ready=upload_ready && descriptor_ready;
    assign busy=writer_busy || upload_pending;
    assign protocol_error=writer_error || upload_error;
    osd_upload upload (
        .xClk(xClk),.hClk(hClk),.reset(reset),.initialize(initialize),
        .block_valid(block_valid && descriptor_ready),.block_address(block_address),.block_words(block_words),
        .block_ready(upload_ready),.block_accept(block_accept),.mapped_address(mapped_address),
        .retired_word(retired_word),.retired_address(retired_address),.retired_data(retired_data),
        .block_done(writer_done),.physical_drained(physical_drained),
        .mirror_write(mirror_write),.mirror_set(mirror_set),.mirror_index(mirror_index),.mirror_data(mirror_data),.mirror_ready(mirror_ready),
        .hFrameEvent(hFrameEvent),.hQualifiedQuiet(hQualifiedQuiet),.reader_leases(reader_leases),
        .hFrontSet(hFrontSet),.hSelectableSet(hSelectableSet),.front_set(front_set),.block_ack(block_ack),
        .upload_pending(upload_pending),.protocol_error(upload_error));
    counted_write #(.MAX_DESCRIPTOR_WORDS(512)) writer (
        .clk(xClk),.reset(reset),.descriptor_valid(block_accept),.descriptor_ready(descriptor_ready),
        .descriptor_address(mapped_address),.descriptor_words(10'd512),.descriptor_epoch(16'd0),
        .next_coalescible(1'b0),.eligible(eligible),.available_words(available_words),
        .head_valid(head_valid),.head_data(head_data),.pop(pop),.write_limit(write_limit),
        .memory_ready(memory_ready),.memory_accept(memory_accept),.memory_advance(memory_advance),
        .memory_done(memory_done),.physical_drained(physical_drained),.memory_index(memory_index),
        .memory_request(memory_request),.memory_address(memory_address),.memory_words(memory_words),.memory_data(memory_data),
        .retired_word(retired_word),.retired_address(retired_address),.retired_data(retired_data),
        .descriptor_done(writer_done),.completed_address(),.completed_epoch(),.busy(writer_busy),
        .current_address(),.current_epoch(),.protocol_error(writer_error));
endmodule
