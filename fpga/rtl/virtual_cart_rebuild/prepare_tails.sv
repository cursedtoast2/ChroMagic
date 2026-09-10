module prepare_tails (
    input clk,reset,begin_prepare,
    input [22:0] rom_bytes,
    input [17:0] save_bytes,
    input block_start,
    input [22:0] block_address,
    input retired_word,
    input [22:0] retired_address,
    input [15:0] retired_data,
    input block_done,physical_drained,
    output block_ready,
    output seed_write,
    output [2:0] seed_bank,
    output [9:0] seed_address,
    output [15:0] seed_data,
    output reg block_ack,prepared,
    output reg protocol_error
);
    localparam OFF=3'd0,OPEN=3'd1,PAYLOAD=3'd2,TAIL=3'd3,COMPLETE=3'd4;
    localparam [22:0] ROM_BASE=23'h020000,SAVE_BASE=23'h420000;
    reg [2:0] state;
    reg save_phase,small_save;
    reg [12:0] remaining_rom;
    reg [7:0] remaining_save;
    reg [22:0] next_address;
    reg [9:0] received;
    wire valid_rom=rom_bytes>=32768 && rom_bytes<=4194304 && (rom_bytes & (rom_bytes-1'b1))==0;
    wire valid_save=save_bytes==0 || save_bytes==512 || save_bytes==2048 || save_bytes==8192 ||
                    save_bytes==32768 || save_bytes==65536 || save_bytes==131072;
    wire [22:0] offset=retired_address-(save_phase?SAVE_BASE:ROM_BASE);
    wire correct_word=state==PAYLOAD && received<512 && retired_address==next_address+{12'd0,received,1'b0};
    wire half_save_tail=save_phase && offset==23'h0001fe;
    wire row_tail=offset[9:0]==10'h3fe && !(save_phase && small_save);
    assign block_ready=state==OPEN && !reset && !protocol_error && physical_drained;
    assign seed_write=retired_word && correct_word && !reset && !protocol_error && (row_tail || half_save_tail);
    assign seed_bank=save_phase?3'd4:{1'b0,offset[21:20]};
    assign seed_address=half_save_tail?10'd128:offset[19:10];
    assign seed_data=retired_data;
    always @(posedge clk)begin
        if(reset)begin
            state<=OFF;save_phase<=0;small_save<=0;remaining_rom<=0;remaining_save<=0;
            next_address<=ROM_BASE;received<=0;block_ack<=0;prepared<=0;protocol_error<=0;
        end else begin
            block_ack<=0;
            if(begin_prepare)begin
                if(state!=OFF || !physical_drained || !valid_rom || !valid_save)protocol_error<=1;
                else begin
                    state<=OPEN;remaining_rom<=rom_bytes[22:10];
                    remaining_save<=save_bytes==512 ? 8'd1 : save_bytes[17:10];
                    small_save<=save_bytes==512;
                end
            end
            if(block_start)begin
                if(!block_ready || block_address!=next_address)protocol_error<=1;
                else begin state<=PAYLOAD;received<=0;end
            end
            if(retired_word)begin
                if(!correct_word)protocol_error<=1;
                else received<=received+1'b1;
            end
            if(block_done)begin
                if(state!=PAYLOAD || received+{9'd0,retired_word}!=512)protocol_error<=1;
                else state<=TAIL;
            end
            if(state==TAIL && physical_drained && !protocol_error)begin
                block_ack<=1;state<=OPEN;
                if(save_phase)begin
                    remaining_save<=remaining_save-1'b1;
                    if(remaining_save==1)begin state<=COMPLETE;prepared<=1;end
                    else next_address<=next_address+23'd1024;
                end else begin
                    remaining_rom<=remaining_rom-1'b1;
                    if(remaining_rom==1)begin
                        if(remaining_save==0)begin state<=COMPLETE;prepared<=1;end
                        else begin save_phase<=1;next_address<=SAVE_BASE;end
                    end else next_address<=next_address+23'd1024;
                end
            end
        end
    end
endmodule
