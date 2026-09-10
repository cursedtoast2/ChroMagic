module dma_admission (
    input clk,reset,new_cycle,new_t2,
    input cpu_write_cycle,cpu_known, cpu_store,
    input [1:0] pending_writes,
    input [15:0] cpu_address,
    input [7:0] cpu_data,
    input hdma_enabled,hdma_mode,hdma_active,hdma_running,hdma_read,oam_read,
    input double_speed,hdma_releases_block,
    input late_ppu_tail,
    input [15:0] hdma_source,oam_source,
    output reg [15:0] lookup_address,
    output preview_mapper,
    input lookup_mapped,
    input [22:0] lookup_word,
    input next_head_mapped,next_head_hit,
    input query_hdma_head_hit,next_hdma_head_hit,
    input [22:0] next_head_word,
    output [15:0] next_head_address,
    input query_hit,block_complete,fill_available,memory_ready,
    input [2:0] block_missing_offset,
    output permit_posts,
    output ordinary_blocked,background_safe,
    output request,
    output [22:0] request_word,
    output [3:0] request_words,
    output request_handoff,request_handoff_slot,
    output query_enable,
    output reg protocol_error
);
    wire source_register=cpu_address==16'hff51 || cpu_address==16'hff52 ||
                         cpu_address==16'hff55 || cpu_address==16'hff46;
    wire map_write=!cpu_address[15] && hdma_enabled && !oam_read;
    wire lcd_release=cpu_address==16'hff40 && hdma_enabled;
    wire reserved_write=cpu_write_cycle && (source_register || map_write || lcd_release);
    wire preview=new_t2 && reserved_write;
    assign preview_mapper=preview && map_write;
    always @*begin
        lookup_address=hdma_read?hdma_source:oam_read?oam_source:{hdma_source[15:4],4'd0};
        if(preview)begin
            case(cpu_address)
                16'hff51:lookup_address={cpu_data,hdma_source[7:4],4'd0};
                16'hff52:lookup_address={hdma_source[15:8],cpu_data[7:4],4'd0};
                16'hff46:lookup_address={cpu_data,8'd0};
                default:lookup_address={hdma_source[15:4],4'd0};
            endcase
        end
    end
    wire active=hdma_read || oam_read;
    reg tail_seen;
    reg [1:0] handoff_remaining;
    reg [15:0] handoff_base;
    reg guard_satisfied;
    reg [11:0] guard_source;
    wire guard_probe=hdma_enabled && hdma_mode && late_ppu_tail && !hdma_read &&
                     (!guard_satisfied || guard_source!=hdma_source[15:4]);
    wire tail_start=hdma_read && oam_read && hdma_releases_block &&
                    hdma_source[3:0]==4'he && !tail_seen;
    wire [15:0] prospective_oam=oam_source+(double_speed?16'd2:16'd1);
    wire [1:0] handoff_count=tail_start?2'd2:handoff_remaining;
    wire [15:0] handoff_first=tail_start?{prospective_oam[15:1],1'b0}:handoff_base;
    wire handoff_active=handoff_count!=0;
    assign next_head_address=handoff_active ? handoff_first+(handoff_count==1?16'd2:16'd0) :
                             guard_probe?{hdma_source[15:4],4'd0}:
                             {lookup_address[15:4]+12'd1,4'd0};
    wire preview_hdma=preview && cpu_address!=16'hff46;
    wire preview_miss=preview && lookup_mapped && !(preview_hdma?query_hdma_head_hit:query_hit);
    wire guard_due=guard_probe && next_head_mapped && !next_hdma_head_hit;
    wire guard_slot=guard_due && new_cycle && cpu_known && !cpu_store && !reserved_write && pending_writes<2;
    wire active_due=active && lookup_mapped && !block_complete && !new_cycle && !preview;
    wire next_due=active && lookup_word[2:0]==7 && query_hit && next_head_mapped && !next_head_hit && !new_cycle && !preview &&
                  !guard_probe && !(hdma_read && oam_read && hdma_releases_block);
    wire oam_handoff_request=!reset && handoff_active && next_head_mapped && !next_head_hit &&
                             fill_available && memory_ready && !new_cycle;
    assign request_handoff=oam_handoff_request || (request && (guard_slot || (preview_miss && preview_hdma)));
    assign request_handoff_slot=oam_handoff_request && handoff_count==1;
    wire handoff_step=handoff_active && (!next_head_mapped || next_head_hit || oam_handoff_request);
    assign request=oam_handoff_request || (!reset && !handoff_active && fill_available && memory_ready &&
                                      (preview_miss || guard_slot || active_due || next_due));
    wire head_only=preview_miss || guard_slot;
    assign request_word=(oam_handoff_request || guard_slot)?next_head_word:head_only?lookup_word:next_due?next_head_word:
                        {lookup_word[22:3],block_missing_offset};
    assign request_words=(request_handoff || head_only || next_due)?4'd1:4'd8-{1'b0,block_missing_offset};
    assign permit_posts=!reserved_write && !active && !hdma_active && !guard_slot && !handoff_active;
    assign ordinary_blocked=reserved_write || hdma_active || guard_slot || handoff_active ||
        (oam_read && (!block_complete || (oam_source[3:0]>=14 && !next_head_hit)));
    wire source_resident=hdma_read ? (!lookup_mapped || block_complete) :
        (!oam_read || (block_complete && oam_source[3:0]<=11));
    assign background_safe=hdma_running && source_resident && hdma_source[3:0]<=11 &&
        !new_cycle && !preview && !handoff_active && !request;
    assign query_enable=active || preview || guard_due;
    always @(posedge clk)begin
        if(reset)begin protocol_error<=0;tail_seen<=0;handoff_remaining<=0;handoff_base<=0;guard_satisfied<=0;guard_source<=0;end
        else begin
            guard_source<=hdma_source[15:4];
            if(guard_probe && (next_hdma_head_hit || (request && guard_slot)))guard_satisfied<=1;
            if(guard_source!=hdma_source[15:4] || preview_mapper ||
               (oam_handoff_request && !request_handoff_slot) || (preview_miss && preview_hdma))guard_satisfied<=0;
            if(!hdma_read || hdma_source[3:0]!=4'he)tail_seen<=0;
            if(tail_start)begin tail_seen<=1;handoff_base<={prospective_oam[15:1],1'b0};end
            if(tail_start || handoff_step)handoff_remaining<=handoff_count-(handoff_step?2'd1:2'd0);
            if(preview_miss && (!fill_available || !memory_ready || new_cycle || handoff_active))protocol_error<=1;
            if(handoff_active && !hdma_read)protocol_error<=1;
        end
    end
endmodule
