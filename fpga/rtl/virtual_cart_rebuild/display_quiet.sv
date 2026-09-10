module display_quiet (
    input hClk,reset,video_ce,hValid,
    input [2:0] bypass_state,
    input reset_now,vsync_overwrite,
    output qualified_quiet
);
    wire resetting=(bypass_state==3'd2 || bypass_state==3'd3) && reset_now && vsync_overwrite;
    reg [1:0] quiet_edges;
    assign qualified_quiet=resetting && quiet_edges==2 && !hValid && !reset;
    always @(posedge hClk)begin
        if(reset || !resetting)quiet_edges<=0;
        else if(video_ce && quiet_edges<2)quiet_edges<=quiet_edges+1'b1;
    end
endmodule
