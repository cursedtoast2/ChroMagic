// QSPI_Slave.v

module QSPI_Slave(
    input               QSPI_CLK,
    input               QSPI_CS,
    inout               QSPI_MOSI,
    inout               QSPI_MISO,
    inout               QSPI_WP,
    inout               QSPI_HD,

    input       [1:0]   cartBlockReady,
    input       [15:0]  cartBlockSequence,
    input       [63:0]  cartBlockCRC32,
    input       [7:0]   qCartReadData,
    output  reg [10:0]  qCartReadAddress = 'd0,
    output      [10:0]  qCartWriteAddress,
    output      [7:0]   qCartWriteData,
    output              qCartWriteEnable,

    input               virtualBlockReady,
    input       [15:0]  virtualBlockSequence,
    input       [7:0]   qVirtualReadData,

    input               qUploadBusy,
    input       [7:0]   qUploadCompletionSequence,
    
    output              qMenuInit,
    output              qDataValid,
    output      [15:0]  qData,
    output  reg [31:0]  qAddress = 'd0,
    output  reg [9:0]   qLength = 'd0,
    output  reg         qCommand = 'd0
);

    reg qAddReady = 'd0;
    reg qLenReady = 'd0;

    reg [3:0] qPins_r1 = 'd0;
    reg [7:0] qDataByte = 'd0;
    reg qCyclePhase = 'd0;

    reg qValid = 'd0;
    wire [3:0] qPins = {
                    QSPI_HD,
                    QSPI_WP,
                    QSPI_MISO,
                    QSPI_MOSI};

    reg [7:0] qCycleCount = 'd0;

    reg qMenuInit1 = 1'd0;
    reg qMenuInit2 = 1'd0;
    assign qMenuInit = qMenuInit2;

    always@(posedge QSPI_CLK or posedge QSPI_CS)
    begin
        if(QSPI_CS)
        begin
            qCyclePhase <= 1'd0;
            qValid      <= 1'd0;
            qCycleCount <= 1'd0;
            qCommand    <= 1'd0;
            qAddReady   <= 1'd0;
            qLenReady   <= 1'd0;
        end
        else
        begin
            if(qCycleCount <= 50)
                qCycleCount   <= qCycleCount + 1'd1;
            
            // Command
            if(qCycleCount == 0)
                qCommand <= QSPI_MOSI;

            if((qCycleCount >= 1) && (qCycleCount <= 10))
                qLength <= {qLength[8:0], QSPI_MOSI};
            else if(qCartWriteEnable)
                qLength <= qLength - 1'b1;
                
            if((qCycleCount >= 11) && (qCycleCount <= 42))
                qAddress <= {qAddress[30:0], QSPI_MOSI};
                
            if(qCycleCount == 11)
                qLenReady <= 1'd1;
            else
                qLenReady <= 1'd0;

            if(qCycleCount == 43)
            begin
                qAddReady <= 1'd1;
                if(qCommand && qAddress == 0)
                begin
                    qMenuInit1  <=  1'd1;
                    if(qMenuInit1)
                        qMenuInit2 <= 1'd1;
                end
            end
            else
                qAddReady <= 1'd0;
                
            // QSPI data
            if(qCycleCount >= 46)
            begin
                qCyclePhase      <= ~qCyclePhase;
                if(qCyclePhase)
                begin
                    qDataByte   <= {qPins_r1,qPins};
                    qValid      <= 1'd1;
                end
                else
                begin
                    qPins_r1    <= qPins;
                    qValid      <= 1'd0;
                end
            end
        end
    end

    reg [7:0] qDataByte_r1 = 'd0;
    reg QSPI_VALID_phase = 'd0;
    always@(posedge QSPI_CLK or posedge QSPI_CS)
        if(QSPI_CS)
            QSPI_VALID_phase <= 'd0;
        else
            if(qValid)
            begin
                qDataByte_r1 <= qDataByte;
                QSPI_VALID_phase <= ~QSPI_VALID_phase;
            end

    wire cartWriteSelected = qCommand && qAddress[31];

    assign qDataValid = qCommand & qValid & QSPI_VALID_phase &
                        ~cartWriteSelected;
    assign qData = {qDataByte,qDataByte_r1};

    assign qCartWriteAddress = {1'b0, ~qLength};
    assign qCartWriteData = {qPins_r1, qPins};
    assign qCartWriteEnable = cartWriteSelected &&
                              (qCycleCount >= 46) && qCyclePhase;

    localparam [9:0] CART_READ_TOKEN = 10'h155;
    localparam [15:0] CART_READ_MAGIC = 16'h4342;
    localparam [11:0] CART_RESPONSE_NIBBLES = 12'd2072;

    reg [1:0] cartBlockReady_s1 = 2'b00;
    reg [1:0] cartBlockReady_s2 = 2'b00;
    reg uploadBusy_s1 = 1'b0;
    reg uploadBusy_s2 = 1'b0;
    reg virtualBlockReady_s1 = 1'b0;
    reg virtualBlockReady_s2 = 1'b0;
    always @(posedge QSPI_CLK)
    begin
        cartBlockReady_s1    <= cartBlockReady;
        cartBlockReady_s2    <= cartBlockReady_s1;
        uploadBusy_s1         <= qUploadBusy;
        uploadBusy_s2         <= uploadBusy_s1;
        virtualBlockReady_s1  <= virtualBlockReady;
        virtualBlockReady_s2  <= virtualBlockReady_s1;
    end

    wire cartReadSelected = !qCommand &&
                            (qLength == CART_READ_TOKEN) &&
                            (qAddress[31:16] == CART_READ_MAGIC);
    wire virtualReadSelected = cartReadSelected && qAddress[12];
    wire uploadStatusSelected = cartReadSelected && !qAddress[12] &&
                                qAddress[11];

    reg [11:0] qResponseNibbleIndex = 12'd0;
    reg [3:0] qReadNibble = 4'd0;
    reg qReadOutputEnable = 1'b0;
    reg qReadySnapshot = 1'b0;
    reg [15:0] qSequenceSnapshot = 16'd0;
    reg [7:0] qResponseByte;
    wire [31:0] qSelectedCRC32 =
        cartBlockCRC32[qAddress[10] * 32 +: 32];

    always @(*)
    begin
        case (qResponseNibbleIndex[11:1])
            11'd0:  qResponseByte = 8'h43;
            11'd1:  qResponseByte = 8'h42;
            11'd2:  qResponseByte = 8'h01;
            11'd3:  qResponseByte = {7'd0, qReadySnapshot};
            11'd4:  qResponseByte = qSequenceSnapshot[7:0];
            11'd5:  qResponseByte = qSequenceSnapshot[15:8];
            11'd6:  qResponseByte = 8'h00;
            11'd7:  qResponseByte = 8'h04;
            11'd8:  qResponseByte = qSelectedCRC32[7:0];
            11'd9:  qResponseByte = qSelectedCRC32[15:8];
            11'd10: qResponseByte = qSelectedCRC32[23:16];
            11'd11: qResponseByte = qSelectedCRC32[31:24];
            default: qResponseByte = virtualReadSelected
                ? qVirtualReadData : qCartReadData;
        endcase
    end

    always @(negedge QSPI_CLK or posedge QSPI_CS)
    begin
        if (QSPI_CS)
        begin
            qResponseNibbleIndex <= 12'd0;
            qReadNibble          <= 4'd0;
            qReadOutputEnable    <= 1'b0;
            qReadySnapshot       <= 1'b0;
            qSequenceSnapshot    <= 16'd0;
            qCartReadAddress     <= 11'd0;
        end
        else if (cartReadSelected && (qCycleCount >= 46) &&
                     (qResponseNibbleIndex < CART_RESPONSE_NIBBLES))
        begin
            qReadOutputEnable <= 1'b1;
            if (qResponseNibbleIndex == 0)
            begin
                qReadySnapshot    <= virtualReadSelected
                    ? virtualBlockReady_s2
                    : uploadStatusSelected
                        ? ~uploadBusy_s2
                        : cartBlockReady_s2[qAddress[10]];
                qSequenceSnapshot <= virtualReadSelected
                    ? virtualBlockSequence
                    : uploadStatusSelected
                        ? {8'd0, qUploadCompletionSequence}
                        : {8'd0,
                           cartBlockSequence[qAddress[10] * 8 +: 8]};
                qCartReadAddress  <= qAddress[10:0];
            end
            qReadNibble <= qResponseNibbleIndex[0]
                ? qResponseByte[3:0] : qResponseByte[7:4];
            if (qResponseNibbleIndex[0] &&
                (qResponseNibbleIndex[11:1] >= 11'd12))
                qCartReadAddress <= qCartReadAddress + 1'b1;
            qResponseNibbleIndex <= qResponseNibbleIndex + 1'b1;
        end
        else
            qReadOutputEnable <= 1'b0;
    end

    assign QSPI_HD   = qReadOutputEnable ? qReadNibble[3] : 1'bz;
    assign QSPI_WP   = qReadOutputEnable ? qReadNibble[2] : 1'bz;
    assign QSPI_MISO = qReadOutputEnable ? qReadNibble[1] : 1'bz;
    assign QSPI_MOSI = qReadOutputEnable ? qReadNibble[0] : 1'bz;

endmodule
