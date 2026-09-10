module pin_publication (
    input clk,reset,initialize,
    input [5:0] reader_leases,
    input request,request_pin,
    input [7:0] request_offset,request_words,
    output ready,
    output [3:0] published_versions,
    output [3:0] selectable_versions,
    output reg busy,stage_pin,
    output reg [1:0] stage_version,source_version,
    output [5:0] reserved_versions,
    output copy_request,
    input copy_accept,copy_word,copy_done,
    input [7:0] copy_index,
    output payload_ready,
    input payload_word,
    input [7:0] payload_index,
    input logical_done,physical_drained,
    output reg published,
    output reg protocol_error
);
    reg initialized;
    reg [1:0] front [0:1];
    reg [2:0] baseline [0:1];
    reg needs_copy,copy_active,finishing;
    reg [7:0] first,words,written,copied;
    reg available;
    reg [1:0] choice;
    wire full_overwrite=request_offset==0 && request_words==160;
    wire valid_descriptor=request_words!=0 && {1'b0,request_offset}+{1'b0,request_words}<=160;
    wire [2:0] pin_leases=request_pin?reader_leases[5:3]:reader_leases[2:0];
    assign ready=!reset && !protocol_error && initialized && !busy && available && valid_descriptor;
    assign published_versions={front[1],front[0]};
    assign reserved_versions=busy ? (6'b1 << (stage_pin*3+stage_version)) |
         ((needs_copy || copy_active)?(6'b1 << (stage_pin*3+source_version)):6'b0) : 6'b0;
    assign copy_request=!protocol_error && busy && needs_copy && !copy_active;
    assign payload_ready=!protocol_error && busy && !needs_copy && !copy_active && !finishing && written<words;
    wire accepted_payload=payload_word && payload_ready && payload_index==first+written;
    wire payload_complete=written==words || (accepted_payload && written+1'b1==words);
    wire publishing=!protocol_error && (finishing || logical_done) && busy &&
                    !needs_copy && !copy_active && payload_complete && physical_drained;
    assign selectable_versions={publishing && stage_pin?stage_version:front[1],
                                publishing && !stage_pin?stage_version:front[0]};
    always @*begin
        available=0;choice=0;
        for(integer n=2;n>=0;n=n-1)begin
            if(n!=front[request_pin] && !pin_leases[n])begin available=1;choice=2'(n);end
        end
        if(!full_overwrite)begin
            for(integer n=2;n>=0;n=n-1)begin
                if(n!=front[request_pin] && !pin_leases[n] && baseline[request_pin][n])begin available=1;choice=2'(n);end
            end
        end
    end
    always @(posedge clk)begin
        if(reset)begin
            initialized<=0;busy<=0;stage_pin<=0;stage_version<=0;source_version<=0;
            needs_copy<=0;copy_active<=0;finishing<=0;first<=0;words<=0;written<=0;copied<=0;
            front[0]<=0;front[1]<=0;baseline[0]<=0;baseline[1]<=0;published<=0;protocol_error<=0;
        end else begin
            published<=0;
            if(initialize)begin
                if(busy || reader_leases!=0)protocol_error<=1;
                else begin initialized<=1;front[0]<=0;front[1]<=0;baseline[0]<=7;baseline[1]<=7;end
            end
            if(request)begin
                if(!ready)protocol_error<=1;
                else begin
                    busy<=1;stage_pin<=request_pin;stage_version<=choice;source_version<=front[request_pin];
                    first<=request_offset;words<=request_words;written<=0;copied<=0;finishing<=0;
                    needs_copy<=!full_overwrite && !baseline[request_pin][choice];copy_active<=0;
                    baseline[request_pin][choice]<=0;
                end
            end
            if(copy_accept)begin
                if(!copy_request)protocol_error<=1;else copy_active<=1;
            end
            if(copy_word)begin
                if(!busy || !copy_active || copied>=160 || copy_index!=copied)protocol_error<=1;
                else copied<=copied+1'b1;
            end
            if(copy_done)begin
                if(!copy_active || !(copied==160 || (copy_word && copied==159 && copy_index==159)))protocol_error<=1;
                else begin copy_active<=0;needs_copy<=0;end
            end
            if(payload_word)begin
                if(!payload_ready || payload_index!=first+written)protocol_error<=1;
                else written<=written+1'b1;
            end
            if(logical_done)begin
                if(!busy || needs_copy || copy_active || !payload_complete)protocol_error<=1;
                else finishing<=1;
            end
            if(publishing)begin
                front[stage_pin]<=stage_version;baseline[stage_pin]<=3'b1 << stage_version;
                busy<=0;finishing<=0;published<=1;
            end
            if(busy && reader_leases[stage_pin*3+stage_version] && !publishing)protocol_error<=1;
        end
    end
endmodule
