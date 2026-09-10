module cpu_retention #(parameter DMA_ENABLED=0, EXTERNAL_SCHEDULE=0, SHARED_PORT=0) (
    input ram_512_bytes,
    input clk, reset,
    input new_cycle, cycle_read, cycle_store,
    input [5:0] query_roles,
    input [22:0] query_word,
    input store_commit, store_high,
    input [7:0] store_data,
    output [15:0] data_word,
    output data_valid,
    output memory_request, memory_read,
    output [22:0] memory_word,
    output [3:0] memory_words,
    output [15:0] memory_write_data,
    input memory_ready, memory_done,
    input response_valid, response_last,
    input [22:0] response_word,
    input [15:0] response_data,
    input prepare_write,
    input [2:0] prepare_bank,
    input [9:0] prepare_address,
    input [15:0] prepare_data,
    input permit_posts,
    input drain,
    input dma_query_enable,
    input [22:0] dma_query_word,
    input [22:0] dma_next_head_word,
    output dma_next_head_hit,
    output dma_query_hdma_head_hit,dma_next_hdma_head_hit,
    output dma_data_valid,dma_query_hit,dma_block_complete,
    output [2:0] dma_block_missing_offset,
    output [15:0] dma_data_word,
    input dma_fill_begin,
    input [22:0] dma_fill_word,
    input [3:0] dma_fill_words,
    input dma_fill_handoff,dma_fill_handoff_slot,
    output dma_fill_available,
    input dma_response_valid,dma_response_last,
    input [22:0] dma_response_word,
    input [15:0] dma_response_data,
    input aux_read,
    input [9:0] aux_read_address,
    output aux_read_ready,aux_read_valid,
    output [15:0] aux_read_data,
    input aux_write,
    input [9:0] aux_write_address,
    input [15:0] aux_write_data,
    output aux_write_ready,
    output cycle_known,
    output post_available,
    output [1:0] pending_writes,
    output idle,
    output protocol_error
);
    wire small_ram_query = ram_512_bytes && query_word[22];
    wire small_ram_tail = small_ram_query && query_word[7:0]==8'hff;
    wire sparse = query_word[8:0]==9'h1ff || small_ram_tail;
    wire window_hit, allocation_available, fill_begin, fill_busy;
    wire [2:0] hit_bank, hit_offset, allocation_bank, fill_bank;
    wire [22:0] fill_base;
    wire [3:0] fill_count;
    reg [22:0] proposed_base;
    reg [3:0] proposed_count;
    reg [3:0] before_words;
    reg [9:0] row_left;
    reg fill_is_store;
    reg [2:0] fill_peer_offset;
    wire need_fill = new_cycle && (cycle_read || cycle_store) && !sparse && !window_hit;
    wire tags_error, posts_error, data_error;
    reg own_error;
    reg [5:0] age;
    reg service_cycle;
    wire known_cycle = !(cycle_read || cycle_store) || sparse || window_hit;
    assign cycle_known=known_cycle;
    wire post_ready, post_store_ready;
    wire [22:0] post_word;
    wire [15:0] post_data;
    wire [1:0] forward_mask, fill_mask;
    wire [15:0] forward_data, fill_forward;
    wire post_issue = memory_request && !memory_read && memory_ready;
    reg post_active, post_physical_done;
    reg [3:0] replica_index;
    wire replica_hit;
    wire [2:0] replica_offset;
    wire post_retire = post_active && (post_physical_done || memory_done) && replica_index==8;
    assign post_available=!fill_busy && !post_active && post_ready;
    wire service_now = drain || (EXTERNAL_SCHEDULE ? permit_posts :
                       new_cycle ? known_cycle : (service_cycle && age<22));
    assign memory_request = !reset && !prepare_write &&
        (need_fill || (!fill_busy && !post_active && service_now && post_ready && memory_ready &&
                      (!DMA_ENABLED || permit_posts || drain)));
    assign memory_read = need_fill;
    assign memory_word = need_fill ? proposed_base : post_word;
    assign memory_words = need_fill ? proposed_count : 4'd1;
    assign memory_write_data = post_data;
    assign idle = !fill_busy && !post_active && pending_writes==0 && memory_ready;
    wire dma_error;
    assign protocol_error = own_error || tags_error || posts_error || data_error || dma_error;

    always @* begin
        before_words=0;
        if(cycle_store && query_roles[5])
            before_words=query_word[8:0]<7 ? query_word[3:0] : 4'd7;
        else if(cycle_store && query_roles[4])
            before_words=query_word[8:0]<3 ? query_word[3:0] : 4'd3;
        proposed_base=query_word-before_words;
        row_left=small_ram_query ? 10'd256-{2'd0,proposed_base[7:0]} : 10'd512-{1'b0,proposed_base[8:0]};
        proposed_count=row_left<8 ? row_left[3:0] : 4'd8;
        if(cycle_store && query_roles[5]) proposed_count=before_words+1'b1;
    end

    wire response_owned = fill_busy && response_word>=fill_base &&
                          response_word-fill_base<fill_count;
    retention_tags tags (
        .clk(clk),.reset(reset),
        .query_commit(new_cycle && (cycle_read || cycle_store)),
        .query_roles(query_roles),.query_word(query_word),.sparse_hit(sparse),
        .fill_start(proposed_base),.fill_words(proposed_count),
        .window_hit(window_hit),.hit_bank(hit_bank),.hit_offset(hit_offset),
        .allocation_available(allocation_available),.allocation_bank(allocation_bank),
        .fill_begin(fill_begin),.fill_busy(fill_busy),.fill_bank(fill_bank),
        .fill_base(fill_base),.fill_count(fill_count),
        .response_valid(response_valid && response_owned),
        .response_offset(3'(response_word-fill_base)),.response_last(response_last),
        .replica_bank(replica_index[2:0]),.replica_word(post_word),
        .replica_hit(replica_hit),.replica_offset(replica_offset),.protocol_error(tags_error));

    wire payload_valid;
    wire [15:0] payload_data;
    reg [22:0] payload_word;
    reg previous_dma_read;
    reg previous_aux_read;
    reg held_valid;
    reg [22:0] held_word;
    reg [15:0] held_data;
    wire direct_valid=payload_valid && !previous_dma_read && !previous_aux_read &&
                      payload_word==query_word && (sparse || window_hit);
    wire held_hit=SHARED_PORT && held_valid && held_word==query_word && (sparse || window_hit);
    wire retained_valid = direct_valid || held_hit;
    wire raw_valid = response_valid && response_owned && response_word==query_word;
    wire base_valid = retained_valid || raw_valid;
    wire [15:0] base_data = raw_valid ? response_data : direct_valid ? payload_data : held_data;
    assign data_word = {forward_mask[1] ? forward_data[15:8] : base_data[15:8],
                        forward_mask[0] ? forward_data[7:0] : base_data[7:0]};
    assign data_valid = base_valid || forward_mask==2'b11;
    wire dma_reply=DMA_ENABLED && dma_response_valid;
    wire [22:0] any_response_word=dma_reply?dma_response_word:response_word;
    wire [15:0] any_response_data=dma_reply?dma_response_data:response_data;
    wire [15:0] merged_response = {
        fill_mask[1] ? fill_forward[15:8] : any_response_data[15:8],
        fill_mask[0] ? fill_forward[7:0] : any_response_data[7:0]};
    wire [1:0] dma_forward_mask;
    wire [15:0] dma_forward_data;
    posted_writes posts (
        .clk(clk),.reset(reset),.store_valid(store_commit),.store_word(query_word),
        .store_high(store_high),.store_data(store_data),.peer_valid(base_valid),
        .peer_data(base_data),.store_ready(post_store_ready),
        .peer_reply_valid((response_valid && response_owned) || dma_reply),
        .peer_reply_word(any_response_word),.peer_reply_data(any_response_data),
        .issue_valid(post_ready),.issue_word(post_word),.issue_data(post_data),
        .issue_accept(post_issue),.retire(post_retire),
        .lookup_word(query_word),.forward_mask(forward_mask),.forward_data(forward_data),
        .response_word(any_response_word),.response_mask(fill_mask),.response_data(fill_forward),
        .dma_word(dma_query_word),.dma_mask(dma_forward_mask),.dma_data(dma_forward_data),
        .count(pending_writes),.protocol_error(posts_error));

    reg write_enable;
    reg [2:0] write_bank;
    reg [9:0] write_address;
    reg [15:0] write_data;
    wire dma_ram_read,dma_ram_write,dma_replica_ready;
    wire [9:0] dma_ram_read_address,dma_ram_write_address;
    wire [15:0] dma_ram_write_data;
    wire replica_slot = post_active && replica_index<8 && !response_valid && !dma_reply && !prepare_write &&
                        (replica_index!=7 || !DMA_ENABLED || dma_replica_ready);
    wire dma_replica_valid=post_active && replica_index==7 && !response_valid && !dma_reply && !prepare_write;
    wire dma_read_grant=DMA_ENABLED && dma_ram_read && !prepare_write;
    generate if(DMA_ENABLED)begin: dma
        dma_retention #(.HOLD_READ(SHARED_PORT)) buffer (
            .clk(clk),.reset(reset),.query_enable(dma_query_enable),.query_word(dma_query_word),
            .data_valid(dma_data_valid),.data_word(dma_data_word),.query_hit(dma_query_hit),
            .next_head_word(dma_next_head_word),.next_head_hit(dma_next_head_hit),
            .query_hdma_head_hit(dma_query_hdma_head_hit),.next_hdma_head_hit(dma_next_hdma_head_hit),
            .block_complete(dma_block_complete),.forward_mask(dma_forward_mask),.forward_data(dma_forward_data),
            .block_missing_offset(dma_block_missing_offset),.fill_handoff(dma_fill_handoff),.fill_handoff_slot(dma_fill_handoff_slot),
            .fill_begin(dma_fill_begin),.fill_word(dma_fill_word),.fill_words(dma_fill_words),
            .fill_available(dma_fill_available),.response_valid(dma_reply),.response_last(dma_response_last),
            .response_word(dma_response_word),.response_data(merged_response),
            .replica_valid(dma_replica_valid),.replica_word(post_word),.replica_data(post_data),
            .replica_ready(dma_replica_ready),.ram_read(dma_ram_read),.ram_read_address(dma_ram_read_address),
            .ram_read_ready(dma_read_grant),
            .ram_read_valid(payload_valid && previous_dma_read),.ram_read_data(payload_data),
            .ram_write(dma_ram_write),.ram_write_address(dma_ram_write_address),.ram_write_data(dma_ram_write_data),
            .protocol_error(dma_error));
    end else begin
        assign dma_ram_read=0,dma_ram_write=0,dma_replica_ready=1,dma_error=0;
        assign dma_ram_read_address=0,dma_ram_write_address=0,dma_ram_write_data=0;
        assign dma_data_valid=0,dma_data_word=0,dma_query_hit=0,dma_block_complete=0,dma_fill_available=0;
        assign dma_next_head_hit=0;
        assign dma_query_hdma_head_hit=0,dma_next_hdma_head_hit=0;
        assign dma_block_missing_offset=0;
    end endgenerate
    always @* begin
        write_enable=0;write_bank=4;write_address=0;write_data=post_data;
        if(replica_slot) begin
            if(replica_index<6 && replica_hit) begin
                write_enable=1;write_address=10'd129+{4'd0,replica_index[2:0],3'b000}+replica_offset;
            end else if(replica_index==6 && (post_word[8:0]==9'h1ff || (ram_512_bytes && post_word[22] && post_word[7:0]==8'hff))) begin
                write_enable=1;write_address=ram_512_bytes && post_word[22] ? 10'd128 : {3'd0,post_word[15:9]};
            end
        end
        if(dma_ram_write)begin
            write_enable=1;write_bank=4;write_address=dma_ram_write_address;write_data=dma_ram_write_data;
        end
        if(response_valid && response_owned &&
           !(SHARED_PORT && fill_is_store && response_word-fill_base==fill_peer_offset)) begin
            write_enable=1;write_bank=4;
            write_address=10'd129+{4'd0,fill_bank,3'b000}+10'(response_word-fill_base);
            write_data=merged_response;
        end
        if(prepare_write) begin
            write_enable=1;write_bank=prepare_bank;write_address=prepare_address;write_data=prepare_data;
        end
    end
    wire [2:0] read_bank = !sparse ? 3'd4 : (query_word[22] ? 3'd4 : {1'b0,query_word[20:19]});
    wire [9:0] read_address = sparse ?
        (small_ram_tail ? 10'd128 : query_word[22] ? {3'd0,query_word[15:9]} : query_word[18:9]) :
        10'd129+{4'd0,hit_bank,3'b000}+hit_offset;
    wire cpu_read_grant=(sparse || window_hit) && !dma_read_grant && !prepare_write &&
                        (!SHARED_PORT || !(direct_valid || held_hit || raw_valid));
    assign aux_read_ready=SHARED_PORT && !reset && !prepare_write && !dma_read_grant && !cpu_read_grant;
    assign aux_write_ready=SHARED_PORT && !reset && !write_enable;
    wire aux_read_grant=aux_read && aux_read_ready && aux_read_address>=185 && aux_read_address<825;
    wire aux_write_grant=aux_write && aux_write_ready && aux_write_address>=185 && aux_write_address<825;
    assign aux_read_valid=payload_valid && previous_aux_read;
    assign aux_read_data=payload_data;
    retention_data payload (
        .clk(clk),.reset(reset),.read_enable(dma_read_grant || cpu_read_grant || aux_read_grant),
        .read_bank((dma_read_grant || aux_read_grant)?3'd4:read_bank),
        .read_address(dma_read_grant?dma_ram_read_address:aux_read_grant?aux_read_address:read_address),
        .read_valid(payload_valid),.read_data(payload_data),
        .write_enable(write_enable || aux_write_grant),.write_bank(aux_write_grant?3'd4:write_bank),
        .write_address(aux_write_grant?aux_write_address:write_address),.write_data(aux_write_grant?aux_write_data:write_data),
        .maintenance_read(1'b0),.maintenance_address(10'd0),.maintenance_valid(),.maintenance_data(),
        .protocol_error(data_error));

    always @(posedge clk) begin
        if(reset) begin
            own_error<=0;age<=63;service_cycle<=0;payload_word<=0;
            post_active<=0;post_physical_done<=0;replica_index<=0;
            previous_dma_read<=0;
            previous_aux_read<=0;held_valid<=0;held_word<=0;held_data<=0;
            fill_is_store<=0;fill_peer_offset<=0;
        end else begin
            if(need_fill)begin fill_is_store<=cycle_store;fill_peer_offset<=before_words[2:0];end
            previous_dma_read<=dma_read_grant;
            previous_aux_read<=aux_read_grant;
            if(cpu_read_grant)payload_word<=query_word;
            if(SHARED_PORT)begin
                if(payload_valid && !previous_dma_read && !previous_aux_read)begin
                    held_valid<=1;held_word<=payload_word;held_data<=payload_data;
                end
                if(raw_valid)begin held_valid<=1;held_word<=query_word;held_data<=response_data;end
                if(post_retire && held_valid && held_word==post_word)held_data<=post_data;
                if(prepare_write)held_valid<=0;
                if((aux_read && (aux_read_address<185 || aux_read_address>=825)) ||
                   (aux_write && (aux_write_address<185 || aux_write_address>=825)))own_error<=1;
            end
            if(new_cycle) begin age<=0;service_cycle<=known_cycle;end
            else if(age!=63) age<=age+1'b1;
            if(need_fill && (!memory_ready || !allocation_available)) own_error<=1;
            if(response_valid && !response_owned) own_error<=1;
            if(response_valid && dma_reply)own_error<=1;
            if(prepare_write && (!idle || new_cycle || store_commit || response_valid)) own_error<=1;
            if(store_commit && (!query_word[22] || !post_store_ready)) own_error<=1;
            if(post_issue) begin
                post_active<=1;post_physical_done<=0;replica_index<=0;
            end
            if(replica_slot) replica_index<=replica_index+1'b1;
            if(memory_done && post_active) post_physical_done<=1;
            if(post_retire) post_active<=0;
        end
    end
endmodule
