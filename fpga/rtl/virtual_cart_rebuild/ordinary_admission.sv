module ordinary_admission (
    input clk,reset,new_cycle,double_speed,
    input cycle_known,cycle_store,
    input [1:0] pending_writes,
    input reserved_cycle,owner_hold,priority_request,
    input prepared_stop,
    input memory_ready,post_available,
    output reg permit_post,
    output reg [4:0] read_words,write_words
);
    reg [6:0] age;
    reg known,store,normal,reserved,second_shortened;
    reg [1:0] entry_posts,second_posts;
    wire [6:0] phase=new_cycle?7'd0:age;
    wire use_known=new_cycle?cycle_known:known;
    wire use_store=new_cycle?cycle_store:store;
    wire use_normal=new_cycle?!double_speed:normal;
    wire excluded=(new_cycle?reserved_cycle:reserved) || reserved_cycle || owner_hold || priority_request;
    wire [1:0] q=new_cycle?pending_writes:entry_posts;
    wire second_half=use_normal && phase>=32;
    wire [6:0] half_phase=second_half?phase-32:phase;
    wire [1:0] free_posts=second_half?(phase==32?pending_writes:second_posts):q;
    wire shortened=phase==32?prepared_stop:second_shortened;
    reg post_slot;
    always @* begin
        permit_post=0;read_words=0;write_words=0;post_slot=0;
        if(!reset && memory_ready && !excluded && phase<(use_normal?64:32))begin
            if(use_store && use_known)begin
                if(use_normal && !second_half)begin
                    if(phase==0)begin
                        if(q==3)post_slot=1;
                        else begin read_words=9;write_words=23;end
                    end
                end else begin
                    if(q==0)begin
                        if(half_phase==0)write_words=13;
                        if(half_phase==22)post_slot=1;
                    end else if(q==1)begin
                        if(half_phase==0 || half_phase==22)post_slot=1;
                        if(half_phase==10)write_words=3;
                    end else if(use_normal && q==3)begin
                        if(half_phase==0 || half_phase==22)post_slot=1;
                    end else if(half_phase==0 || half_phase==10 || half_phase==20)post_slot=1;
                end
            end else if(second_half || use_known)begin
                if(free_posts<2)begin
                    if(half_phase==0)begin
                        read_words=(second_half && shortened)?1:9;
                        write_words=(second_half && shortened)?15:23;
                    end
                end else begin
                    if(half_phase==0 || half_phase==10)post_slot=1;
                    if(half_phase==20 && !(second_half && shortened))begin
                        if(free_posts==3)post_slot=1;else write_words=3;
                    end
                end
            end
            permit_post=post_slot && post_available;
        end
    end
    always @(posedge clk)begin
        if(reset)begin age<=127;known<=0;store<=0;normal<=0;reserved<=1;entry_posts<=0;second_posts<=0;second_shortened<=0;end
        else begin
            if(new_cycle)begin
                age<=1;known<=cycle_known;store<=cycle_store;normal<=!double_speed;
                reserved<=reserved_cycle;entry_posts<=pending_writes;second_shortened<=0;
            end else if(age!=127)age<=age+1'b1;
            if(phase==32)begin second_posts<=pending_writes;second_shortened<=prepared_stop;end
        end
    end
endmodule
