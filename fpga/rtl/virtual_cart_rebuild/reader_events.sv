module reader_events #(
    parameter BASE_POINTER=23'h010000
) (
    input hClk,xClk,reset,hVsync,hHsync,hValid,
    output hStartOfFrame,hStartOfLine,hEndOfLine,
    output reg [14:0] hPixelIndex,
    output reg xRowRequest,
    output reg [22:0] xRowAddress
);
    reg hVsync_r1,hHsync_r1;
    always @(posedge hClk)begin
        if(reset)begin hVsync_r1<=0;hHsync_r1<=0;end
        else begin hVsync_r1<=hVsync;hHsync_r1<=hHsync;end
    end
    assign hStartOfFrame=~hVsync_r1 & hVsync;
    assign hStartOfLine=~hHsync_r1 & hHsync;
    assign hEndOfLine=hHsync_r1 & ~hHsync;
    always @(posedge hClk)begin
        if(reset || hStartOfFrame)hPixelIndex<=0;
        else if(hValid)begin
            if(hPixelIndex<160)hPixelIndex<=hPixelIndex+1'b1;
        end else if(hStartOfLine)hPixelIndex<=0;
    end
    reg [3:0] xHsync_sr,xVsync_sr;
    always @(posedge xClk)begin
        if(reset)begin xHsync_sr<=0;xVsync_sr<=0;end
        else begin xHsync_sr<={xHsync_sr[2:0],hHsync};xVsync_sr<={xVsync_sr[2:0],hVsync};end
    end
    wire xEndOfLine=xHsync_sr[3:2]==2'b10;
    wire xStartOfFrame=xVsync_sr[3:2]==2'b01;
    always @(posedge xClk)begin
        if(reset)begin xRowRequest<=0;xRowAddress<=BASE_POINTER;end
        else begin
            xRowRequest<=xEndOfLine || xStartOfFrame;
            if(xStartOfFrame)xRowAddress<=BASE_POINTER;
            else if(xEndOfLine)xRowAddress<=xRowAddress+23'd320;
        end
    end
endmodule
