// mm_burst_write.v

// Converts QSPI memory mapped transfer into a burst write to PSRAM
module mm_burst_write(
    input           QSPI_CLK,
    input           QSPI_CS,
    input   [31:0]  qAddress,
    input           qDataValid,
    input   [15:0]  qData,
    
    input           xClk,
    input           xReset,
    input           xRdEn,
    input           xRamReady,
    input           xDone,
    output  reg     xMcuReqWrite,
    output  reg     xUploadBusy,
    output  reg [7:0] xUploadCompletionSequence,
    
    output  [15:0]  xDout,
    output  reg [22:0] xAddress
);

    wire fifo_empty;
    wire fifo_full;
    wire fifo_almost_full;
    fifo1k u_fifo1k(
        .Data(qData), //input [15:0] Data
        .WrReset(1'd0), //input WrReset
        .RdReset(1'd0), //input RdReset
        .WrClk(~QSPI_CLK), //input WrClk
        .RdClk(xClk), //input RdClk
        .WrEn(qDataValid), //input WrEn
        .RdEn(xRdEn | xMcuReqWrite), //input RdEn
        .Q(xDout), //output [15:0] Q
        .Almost_Full(fifo_almost_full), //output Almost_Full
        .Empty(fifo_empty), //output Empty
        // Full is on the write clock domain
        // Won't update when QSPI CS is high
        .Full(fifo_full) //output Full
    );
    
    reg [3:0] xCS_sr;
    reg xRequestPending;
    reg [7:0] xActiveSequence;
    always@(posedge xClk)
    begin
        if (xReset) begin
            xCS_sr <= 4'hf;
            xMcuReqWrite <= 1'b0;
            xRequestPending <= 1'b0;
            xUploadBusy <= 1'b0;
            xUploadCompletionSequence <= 8'd0;
            xActiveSequence <= 8'd0;
            xAddress <= 23'd0;
        end else begin
            xCS_sr <= {xCS_sr[2:0], QSPI_CS};
            xMcuReqWrite <= 1'b0;

            if (xUploadBusy && !xRequestPending && xDone) begin
                xUploadCompletionSequence <= xActiveSequence;
                xUploadBusy <= 1'b0;
            end

            if (xRequestPending && xRamReady) begin
                xMcuReqWrite <= 1'b1;
                xRequestPending <= 1'b0;
            end

            if (xCS_sr[3:2] == 2'b01 && !fifo_empty) begin
                xAddress <= qAddress[22:0];
                xActiveSequence <= qAddress[31:24];
                xRequestPending <= 1'b1;
                xUploadBusy <= 1'b1;
            end
        end
    end
    
endmodule
