module row_leases #(
    parameter BANK_COUNT=10
) (
    input clk,reset,
    input select,select_valid,release_selection,
    input [3:0] select_bank,
    input [BANK_COUNT-1:0] inflight_leases,
    output reg [BANK_COUNT-1:0] leased_banks,
    output reg selected_valid,
    output reg [3:0] selected_bank,
    output reg protocol_error
);
    reg [3:0] tail_bank[0:1];
    reg [5:0] tail_left[0:1];
    reg tail_available,tail_slot;
    wire replacing=select || release_selection;
    always @*begin
        tail_available=0;tail_slot=0;
        for(integer i=1;i>=0;i=i-1)begin
            if(tail_left[i]<=1)begin tail_available=1;tail_slot=1'(i);end
        end
        for(integer i=1;i>=0;i=i-1)begin
            if(tail_left[i]!=0 && tail_bank[i]==selected_bank)begin tail_available=1;tail_slot=1'(i);end
        end
        leased_banks=inflight_leases;
        for(integer i=0;i<2;i=i+1)if(tail_left[i]!=0)leased_banks[tail_bank[i]]=1;
        if(selected_valid)leased_banks[selected_bank]=1;
        if(select && select_valid && select_bank<BANK_COUNT)leased_banks[select_bank]=1;
    end
    always @(posedge clk)begin
        if(reset)begin
            selected_valid<=0;selected_bank<=0;protocol_error<=0;
            for(integer i=0;i<2;i=i+1)begin tail_left[i]<=0;tail_bank[i]<=0;end
        end else begin
            for(integer i=0;i<2;i=i+1)if(tail_left[i]!=0)tail_left[i]<=tail_left[i]-1'b1;
            if(replacing)begin
                if(selected_valid)begin
                    if(!tail_available)protocol_error<=1;
                    else begin tail_bank[tail_slot]<=selected_bank;tail_left[tail_slot]<=32;end
                end
                selected_valid<=select && select_valid;
                if(select && select_valid)begin
                    if(select_bank>=BANK_COUNT)begin selected_valid<=0;protocol_error<=1;end
                    else selected_bank<=select_bank;
                end
            end
        end
    end
endmodule
