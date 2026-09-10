module framebuffer_writer (
    input clk,reset,
    input descriptor_valid,
    output descriptor_ready,
    input [22:0] descriptor_address,
    input [7:0] descriptor_words,
    input [15:0] descriptor_epoch,
    input next_coalescible,eligible,
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
    output busy,
    output [22:0] current_address,
    output [15:0] current_epoch,
    output descriptor_done,
    output [22:0] completed_address,
    output [15:0] completed_epoch,
    input initialize,prepare,
    input [2:0] prepare_version,
    input [7:0] prepare_index,
    input [15:0] prepare_data,
    output prepare_ready,
    input [5:0] reader_leases,
    output [3:0] published_versions,selectable_versions,
    output [95:0] selectable_heads,
    output [5:0] selectable_heads_valid,
    output published,
    input read_request,
    input [2:0] read_version,
    input [7:0] read_index,
    output read_ready,read_valid,
    output [15:0] read_data,
    output aux_read,
    output [9:0] aux_read_address,
    input aux_read_ready,aux_read_valid,
    input [15:0] aux_read_data,
    output aux_write,
    output [9:0] aux_write_address,
    output [15:0] aux_write_data,
    input aux_write_ready,
    input rolling_read,
    input [1:0] rolling_read_bank,
    input [7:0] rolling_read_index,
    output rolling_read_ready,rolling_read_valid,
    output [15:0] rolling_read_data,
    input rolling_write,
    input [1:0] rolling_write_bank,
    input [7:0] rolling_write_index,
    input [15:0] rolling_write_data,
    output rolling_write_ready,
    output copying,
    output protocol_error
);
    wire head_pin=descriptor_address>=23'h010000 && descriptor_address<23'h010280;
    wire which_pin=descriptor_address>=23'h010140;
    wire [22:0] row_base=which_pin?23'h010140:23'h010000;
    wire [7:0] row_offset=8'((descriptor_address-row_base)>>1);
    reg pin_reserved,forwarded,own_error;
    reg [22:0] reserved_address,reserved_base;
    reg [7:0] reserved_words;
    reg [15:0] reserved_epoch;
    wire pool_ready,pool_busy,payload_ready,pool_error,backend_error,backend_busy,backend_ready;
    wire pin_start=descriptor_valid && head_pin && !pin_reserved && !backend_busy && pool_ready;
    wire pass_descriptor=!pin_reserved?!head_pin:!forwarded && payload_ready;
    wire forwarded_valid=descriptor_valid && pass_descriptor;
    assign descriptor_ready=backend_ready && pass_descriptor;
    wire forwarded_accept=forwarded_valid && backend_ready;
    wire retired_word;
    wire [22:0] retired_address;
    wire [15:0] retired_data;
    wire pin_payload=retired_word && pin_reserved && forwarded;
    wire [7:0] payload_index=8'((retired_address-reserved_base)>>1);
    wire pin_done=descriptor_done && pin_reserved && forwarded;
    wire [22:0] backend_address;
    wire [15:0] backend_epoch;
    assign current_address=pin_reserved?reserved_address:backend_address;
    assign current_epoch=pin_reserved?reserved_epoch:backend_epoch;
    assign busy=backend_busy || pin_reserved || pool_busy;
    assign protocol_error=own_error || pool_error || backend_error;
    counted_write backend (
        .clk(clk),.reset(reset),.descriptor_valid(forwarded_valid),.descriptor_ready(backend_ready),
        .descriptor_address(descriptor_address),.descriptor_words(descriptor_words),.descriptor_epoch(descriptor_epoch),
        .next_coalescible(next_coalescible && !head_pin && !pin_reserved),
        .eligible(eligible && (!pin_reserved || (forwarded && payload_ready))),
        .available_words(available_words),.head_valid(head_valid),.head_data(head_data),.pop(pop),
        .write_limit(write_limit),.memory_ready(memory_ready),.memory_accept(memory_accept),
        .memory_advance(memory_advance),.memory_done(memory_done),.physical_drained(physical_drained),
        .memory_index(memory_index),.memory_request(memory_request),.memory_address(memory_address),
        .memory_words(memory_words),.memory_data(memory_data),.retired_word(retired_word),
        .retired_address(retired_address),.retired_data(retired_data),.descriptor_done(descriptor_done),
        .completed_address(completed_address),.completed_epoch(completed_epoch),.busy(backend_busy),
        .current_address(backend_address),.current_epoch(backend_epoch),.protocol_error(backend_error));
    pin_store storage (
        .rolling_read(rolling_read),.rolling_read_bank(rolling_read_bank),.rolling_read_index(rolling_read_index),
        .rolling_read_ready(rolling_read_ready),.rolling_read_valid(rolling_read_valid),.rolling_read_data(rolling_read_data),
        .rolling_write(rolling_write),.rolling_write_bank(rolling_write_bank),.rolling_write_index(rolling_write_index),.rolling_write_data(rolling_write_data),.rolling_write_ready(rolling_write_ready),

        .clk(clk),.reset(reset),.initialize(initialize),.prepare(prepare),.prepare_version(prepare_version),
        .prepare_index(prepare_index),.prepare_data(prepare_data),.prepare_ready(prepare_ready),
        .reader_leases(reader_leases),.request(pin_start),.request_pin(which_pin),.request_offset(row_offset),
        .request_words(descriptor_words),.ready(pool_ready),.published_versions(published_versions),.selectable_versions(selectable_versions),.selectable_heads(selectable_heads),.selectable_heads_valid(selectable_heads_valid),.busy(pool_busy),
        .payload_word(pin_payload),.payload_index(payload_index),.payload_data(retired_data),.payload_ready(payload_ready),
        .logical_done(pin_done),.physical_drained(physical_drained),.published(published),
        .read_request(read_request),.read_version(read_version),.read_index(read_index),
        .read_ready(read_ready),.read_valid(read_valid),.read_data(read_data),
        .aux_read(aux_read),.aux_read_address(aux_read_address),.aux_read_ready(aux_read_ready),
        .aux_read_valid(aux_read_valid),.aux_read_data(aux_read_data),.aux_write(aux_write),
        .aux_write_address(aux_write_address),.aux_write_data(aux_write_data),.aux_write_ready(aux_write_ready),
        .copying(copying),.copy_reserved(),.protocol_error(pool_error));
    always @(posedge clk)begin
        if(reset)begin
            pin_reserved<=0;forwarded<=0;own_error<=0;
            reserved_address<=0;reserved_base<=0;reserved_words<=0;reserved_epoch<=0;
        end else begin
            if(pin_start)begin
                pin_reserved<=1;forwarded<=0;reserved_address<=descriptor_address;reserved_base<=row_base;
                reserved_words<=descriptor_words;reserved_epoch<=descriptor_epoch;
                if(descriptor_address[0] || {1'b0,row_offset}+{1'b0,descriptor_words}>160)own_error<=1;
            end
            if(pin_reserved && !forwarded && (!descriptor_valid || descriptor_address!=reserved_address ||
                descriptor_words!=reserved_words || descriptor_epoch!=reserved_epoch))own_error<=1;
            if(forwarded_accept && pin_reserved)forwarded<=1;
            if(pin_done && (completed_address!=reserved_address || completed_epoch!=reserved_epoch))own_error<=1;
            if(published)begin
                if(!pin_reserved || !forwarded || backend_busy)own_error<=1;
                pin_reserved<=0;forwarded<=0;
            end
        end
    end
endmodule
