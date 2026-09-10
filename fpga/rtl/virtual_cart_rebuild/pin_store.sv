module pin_store (
    input clk,reset,initialize,
    input prepare,
    input [2:0] prepare_version,
    input [7:0] prepare_index,
    input [15:0] prepare_data,
    output prepare_ready,
    input [5:0] reader_leases,
    input request,request_pin,
    input [7:0] request_offset,request_words,
    output ready,
    output [3:0] published_versions,selectable_versions,
    output [95:0] selectable_heads,
    output [5:0] selectable_heads_valid,
    output busy,
    input payload_word,
    input [7:0] payload_index,
    input [15:0] payload_data,
    output payload_ready,
    input logical_done,physical_drained,
    output published,
    input read_request,
    input [2:0] read_version,
    input [7:0] read_index,
    output read_ready,read_valid,
    output [15:0] read_data,
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
    output aux_read,
    output [9:0] aux_read_address,
    input aux_read_ready,aux_read_valid,
    input [15:0] aux_read_data,
    output aux_write,
    output [9:0] aux_write_address,
    output [15:0] aux_write_data,
    input aux_write_ready,
    output copying,
    output [3:0] copy_reserved,
    output protocol_error
);
    function automatic is_aux(input [2:0] version);
        is_aux=version!=0 && version!=3;
    endfunction
    function automatic [9:0] base(input [2:0] version);
        case(version)
            0:base=0;1:base=185;2:base=345;
            3:base=160;4:base=505;5:base=665;
            default:base=0;
        endcase
    endfunction
    reg own_error,seeded;
    reg [2:0] seed_version;
    reg [7:0] seed_index;
    reg [15:0] heads[0:5];
    reg [5:0] head_valid;
    wire stage_pin,copy_request,copy_accept,copy_word,copy_done,pub_payload_ready,pub_error;
    wire [1:0] stage_version,source_version;
    wire [5:0] reserved_versions;
    wire [2:0] stage_id=(stage_pin?3'd3:3'd0)+{1'b0,stage_version};
    wire [2:0] source_id=(stage_pin?3'd3:3'd0)+{1'b0,source_version};
    wire [2:0] copy_source,copy_destination;
    wire copy_read,copy_write,copy_read_ready,copy_write_ready,copy_reply_valid,copy_error,copy_aborted;
    wire [7:0] copy_read_index,copy_write_index;
    wire [15:0] copy_write_data,copy_reply_data;
    assign protocol_error=own_error || pub_error || copy_error;
    assign copy_accept=copy_request && !copying && !prepare;
    pin_publication ownership (
        .clk(clk),.reset(reset),.initialize(initialize && seeded),.reader_leases(reader_leases),
        .request(request),.request_pin(request_pin),.request_offset(request_offset),.request_words(request_words),
        .ready(ready),.published_versions(published_versions),.selectable_versions(selectable_versions),.busy(busy),
        .stage_pin(stage_pin),.stage_version(stage_version),.source_version(source_version),.reserved_versions(reserved_versions),
        .copy_request(copy_request),.copy_accept(copy_accept),.copy_word(copy_word),.copy_done(copy_done),.copy_index(copy_write_index),
        .payload_ready(pub_payload_ready),.payload_word(payload_word && payload_ready),.payload_index(payload_index),
        .logical_done(logical_done),.physical_drained(physical_drained),.published(published),.protocol_error(pub_error));
    pin_copy copier (
        .clk(clk),.reset(reset),.start(copy_accept),.cancel(1'b0),.source_version(source_id),.destination_version(stage_id),
        .busy(copying),.done(copy_done),.aborted(copy_aborted),.active_source(copy_source),.active_destination(copy_destination),
        .read_ready(copy_read_ready),.read_request(copy_read),.read_index(copy_read_index),
        .reply_valid(copy_reply_valid),.reply_data(copy_reply_data),
        .write_ready(copy_write_ready),.write_request(copy_write),.write_index(copy_write_index),.write_data(copy_write_data),
        .reserved_words(copy_reserved),.protocol_error(copy_error));

    wire head_read=read_request && read_index==0;
    assign read_ready=!reset && !prepare && read_version<6 && read_index<160 &&
        (head_read?head_valid[read_version]:(!is_aux(read_version) || aux_read_ready));
    wire pixel_accept=read_request && read_ready;
    assign rolling_read_ready=!reset && !prepare && !read_request && rolling_read_index<160;
    wire rolling_accept=rolling_read && rolling_read_ready;
    assign copy_read_ready=!reset && !prepare && !read_request && !rolling_read &&
        (!is_aux(copy_source) || aux_read_ready);
    wire ram_read=pixel_accept && !head_read || copy_read || rolling_accept;
    wire [2:0] ram_read_version=copy_read?copy_source:read_version;
    wire [7:0] ram_read_index=copy_read?copy_read_index:read_index;
    wire [9:0] ram_read_address=rolling_accept ? 10'd320+10'(rolling_read_bank)*10'd160+{2'd0,rolling_read_index} : base(ram_read_version)+{2'd0,ram_read_index};
    assign aux_read=ram_read && !rolling_accept && is_aux(ram_read_version);
    assign aux_read_address=ram_read_address;

    assign prepare_ready=!reset && !busy && !copying && prepare_version<6 &&
        (!is_aux(prepare_version) || aux_write_ready);
    assign payload_ready=pub_payload_ready && !prepare &&
        (!is_aux(stage_id) || aux_write_ready);
    assign rolling_write_ready=!reset && !prepare && !payload_word && rolling_write_index<160;
    wire rolling_write_accept=rolling_write && rolling_write_ready;
    assign copy_write_ready=!reset && !prepare && !payload_word && !rolling_write &&
        (!is_aux(copy_destination) || aux_write_ready);
    wire seed_write=prepare && prepare_ready;
    wire pixel_write=payload_word && payload_ready;
    wire ram_write=seed_write || pixel_write || rolling_write_accept || copy_write;
    wire [2:0] ram_write_version=seed_write?prepare_version:pixel_write?stage_id:copy_destination;
    wire [7:0] ram_write_index=seed_write?prepare_index:pixel_write?payload_index:copy_write_index;
    wire [9:0] ram_write_address=rolling_write_accept ? 10'd320+10'(rolling_write_bank)*10'd160+{2'd0,rolling_write_index} : base(ram_write_version)+{2'd0,ram_write_index};
    wire [15:0] ram_write_data=seed_write?prepare_data:pixel_write?payload_data:rolling_write_accept?rolling_write_data:copy_write_data;
    assign aux_write=ram_write && !rolling_write_accept && is_aux(ram_write_version);
    assign aux_write_address=ram_write_address;
    assign aux_write_data=ram_write_data;
    assign copy_word=copy_write;

    assign selectable_heads_valid=head_valid;
    generate for(genvar v=0;v<6;v=v+1)begin: immediate_heads
        assign selectable_heads[v*16+:16]=ram_write && !rolling_write_accept && ram_write_index==0 &&
            ram_write_version==v ? ram_write_data : heads[v];
    end endgenerate

    wire [15:0] local_data;
    dpramV #(.addr_width(10),.data_width(16)) lines (
        .clock_a(clk),.ce_a(ram_read && (rolling_accept || !is_aux(ram_read_version))),
        .address_a(ram_read_address),.data_a(16'd0),.wren_a(1'b0),.q_a(local_data),
        .clock_b(clk),.address_b(ram_write_address),.data_b(ram_write_data),
        .wren_b(ram_write && (rolling_write_accept || !is_aux(ram_write_version))),.q_b());
    reg previous_pixel,previous_copy,previous_aux,previous_head,previous_rolling,previous_collision;
    reg [15:0] head_data,collision_data;
    wire [15:0] ram_reply=previous_collision?collision_data:previous_aux?aux_read_data:local_data;
    wire reply_valid=!previous_aux || aux_read_valid;
    assign rolling_read_valid=previous_rolling;
    assign rolling_read_data=local_data;
    assign read_valid=previous_pixel && (previous_head || reply_valid);
    assign read_data=previous_head?head_data:ram_reply;
    assign copy_reply_valid=previous_copy && reply_valid;
    assign copy_reply_data=ram_reply;
    always @(posedge clk)begin
        if(reset)begin
            own_error<=0;seeded<=0;seed_version<=0;seed_index<=0;head_valid<=0;
            previous_collision<=0;collision_data<=0;previous_rolling<=0;previous_pixel<=0;previous_copy<=0;previous_aux<=0;previous_head<=0;head_data<=0;
            for(integer n=0;n<6;n=n+1)heads[n]<=0;
        end else begin
            previous_rolling<=rolling_accept;
            previous_pixel<=pixel_accept;previous_copy<=copy_read;
            previous_aux<=aux_read;previous_head<=pixel_accept && head_read;
            previous_collision<=pixel_accept && !head_read && ram_write && !rolling_write_accept &&
                ram_read_version==ram_write_version && ram_read_index==ram_write_index;
            if(ram_write)collision_data<=ram_write_data;
            if(pixel_accept && head_read)head_data<=ram_write && !rolling_write_accept && ram_write_index==0 &&
                ram_write_version==read_version ? ram_write_data : heads[read_version];
            if(ram_write && !rolling_write_accept && ram_write_index==0)begin heads[ram_write_version]<=ram_write_data;head_valid[ram_write_version]<=1;end
            if(seed_write)begin
                if(seeded || prepare_version!=seed_version || prepare_index!=seed_index)own_error<=1;
                else if(seed_index==159)begin
                    seed_index<=0;
                    if(seed_version==5)seeded<=1;else seed_version<=seed_version+1'b1;
                end else seed_index<=seed_index+1'b1;
            end
            if(initialize && !seeded)own_error<=1;
            if(payload_word && !payload_ready)own_error<=1;
            if(read_request && (read_version>=6 || read_index>=160))own_error<=1;
            if(previous_aux && !aux_read_valid)own_error<=1;
            if(aux_read_valid && !previous_aux)own_error<=1;
            if(rolling_write && !rolling_write_ready)own_error<=1;
            if(rolling_read && rolling_read_index>=160)own_error<=1;
            if(copy_aborted)own_error<=1;
        end
    end
endmodule
