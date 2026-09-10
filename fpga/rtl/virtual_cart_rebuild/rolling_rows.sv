module rolling_rows #(
    parameter PIN_ROWS=2,
    parameter BANK_COUNT=4
) (
    input clk,reset,enabled,frame,seeded_frame,
    input [22:0] image_base,
    input [15:0] epoch,
    input [7:0] selected_row,
    input [BANK_COUNT-1:0] reader_leases,
    input older_writes,
    input [4:0] read_limit,
    input memory_ready,
    output memory_request,
    output [22:0] memory_address,
    output [9:0] memory_words,
    input memory_accept,memory_valid,memory_done,physical_drained,
    input [9:0] memory_index,
    input [15:0] memory_data,
    output rolling_write,
    output [1:0] rolling_write_bank,
    output [7:0] rolling_write_index,
    output [15:0] rolling_write_data,
    input rolling_write_ready,
    output reg [BANK_COUNT-1:0] ready_banks,
    output [BANK_COUNT*8-1:0] bank_rows,
    output [BANK_COUNT-1:0] inflight_banks,
    output [7:0] request_row,
    output reg [7:0] snapshotted_through,
    output busy,
    output reg protocol_error
);
    reg [7:0] cursor_row,cursor_index,tags[0:BANK_COUNT-1];
    reg [1:0] cursor_bank;
    reg [22:0] previous_base;
    reg [6:0] barrier;
    reg owned,finishing;
    reg [1:0] active_bank;
    reg [7:0] active_row,active_index;
    reg [9:0] active_words,received;
    reg [15:0] active_epoch;
    wire [8:0] target_row=selected_row<PIN_ROWS?9'(PIN_ROWS+BANK_COUNT-1):{1'b0,selected_row}+9'(BANK_COUNT-1);
    wire [9:0] row_left=10'd160-{2'd0,cursor_index};
    assign memory_address=image_base+23'(cursor_row)*23'd320+{14'd0,cursor_index,1'b0};
    assign request_row=cursor_row;
    wire [9:0] physical_left=10'd512-{1'b0,memory_address[9:1]};
    wire [9:0] count=row_left<read_limit?row_left:{5'd0,read_limit};
    assign memory_words=count<physical_left?count:physical_left;
    wire bank_available=cursor_index!=0 || !reader_leases[cursor_bank];
    assign memory_request=!reset && enabled && !frame && barrier==0 && !owned &&
        !older_writes && cursor_row<144 && {1'b0,cursor_row}<=target_row &&
        bank_available && memory_words!=0 && memory_ready;
    assign busy=owned;
    assign inflight_banks=owned?(BANK_COUNT'(1)<<active_bank):{BANK_COUNT{1'b0}};
    assign rolling_write=memory_valid && owned && !finishing && enabled && !frame && active_epoch==epoch;
    assign rolling_write_bank=active_bank;
    assign rolling_write_index=active_index+8'(memory_index);
    assign rolling_write_data=memory_data;
    generate for(genvar b=0;b<BANK_COUNT;b=b+1)begin: row_tags
        assign bank_rows[b*8+:8]=tags[b];
    end endgenerate
    always @(posedge clk)begin
        if(reset)begin
            cursor_row<=8'(PIN_ROWS);cursor_bank<=0;cursor_index<=0;barrier<=64;owned<=0;finishing<=0;previous_base<=image_base;
            active_bank<=0;active_row<=0;active_index<=0;active_words<=0;received<=0;active_epoch<=0;
            ready_banks<=0;snapshotted_through<=8'(PIN_ROWS-1);protocol_error<=0;
            for(integer b=0;b<BANK_COUNT;b=b+1)tags[b]<=255;
        end else begin
            previous_base<=image_base;
            if(enabled && image_base!=previous_base && !frame)protocol_error<=1;
            if(barrier!=0)barrier<=barrier-1'b1;
            if(memory_accept)begin
                if(!memory_request || owned)protocol_error<=1;
                owned<=1;finishing<=0;active_bank<=cursor_bank;active_row<=cursor_row;
                active_index<=cursor_index;active_words<=memory_words;received<=0;active_epoch<=epoch;
                if(cursor_index==0)begin ready_banks[cursor_bank]<=0;tags[cursor_bank]<=cursor_row;end
            end
            if(memory_valid)begin
                if(!owned || finishing || memory_index!=received || received>=active_words)protocol_error<=1;
                received<=received+1'b1;
                if(rolling_write && !rolling_write_ready)protocol_error<=1;
            end
            if(memory_done)begin
                if(!owned || finishing || !memory_valid || received+1'b1!=active_words)protocol_error<=1;
                finishing<=1;
            end
            if(finishing && physical_drained)begin
                owned<=0;finishing<=0;
                if(enabled && active_epoch==epoch)begin
                    if({2'd0,active_index}+active_words==160)begin
                        ready_banks[active_bank]<=1;snapshotted_through<=active_row;
                        cursor_row<=active_row+1'b1;cursor_index<=0;
                        cursor_bank<=active_bank==BANK_COUNT-1?2'd0:active_bank+1'b1;
                    end else cursor_index<=active_index+8'(active_words);
                end
            end
            if(frame)begin
                cursor_row<=seeded_frame?8'(PIN_ROWS+BANK_COUNT):8'(PIN_ROWS);cursor_bank<=0;cursor_index<=0;barrier<=64;
                ready_banks<=seeded_frame?{BANK_COUNT{1'b1}}:{BANK_COUNT{1'b0}};
                snapshotted_through<=seeded_frame?8'(PIN_ROWS+BANK_COUNT-1):8'(PIN_ROWS-1);
                for(integer b=0;b<BANK_COUNT;b=b+1)tags[b]<=seeded_frame?8'(PIN_ROWS+b):8'd255;
            end
            if(!enabled)ready_banks<=0;
        end
    end
endmodule
