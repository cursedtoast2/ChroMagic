`timescale 1ns/1ps
`default_nettype none

module audio_boot_monitor #(
    parameter integer REFERENCE_WINDOW_CYCLES = 67109,
    parameter integer SNAPSHOT_WINDOWS = 1024
)(
    input  wire        clk,
    input  wire        reset,
    input  wire        pll_lock,
    input  wire        aud_reset,
    input  wire        aud_mclk,
    input  wire        aud_bclk,
    input  wire        aud_wclk,
    input  wire        i2c_scl,
    input  wire        i2c_sda,
    input  wire [7:0]  volume,
    input  wire        headphones,
    input  wire        mute,
    output reg  [79:0] snapshot_status,
    output reg  [79:0] snapshot_codec,
    output reg         snapshot_toggle,
    output wire        snapshot_ready
);
    localparam [6:0] CODEC_ADDRESS = 7'h18;

    reg mclk_meta, mclk_sync, mclk_d;
    reg bclk_meta, bclk_sync, bclk_d;
    reg wclk_meta, wclk_sync, wclk_d;
    reg scl_meta, scl_sync, scl_d;
    reg sda_meta, sda_sync, sda_d;

    always @(posedge clk or posedge reset)
    begin
        if (reset)
        begin
            mclk_meta <= 1'b0;
            mclk_sync <= 1'b0;
            mclk_d <= 1'b0;
            bclk_meta <= 1'b0;
            bclk_sync <= 1'b0;
            bclk_d <= 1'b0;
            wclk_meta <= 1'b0;
            wclk_sync <= 1'b0;
            wclk_d <= 1'b0;
            scl_meta <= 1'b1;
            scl_sync <= 1'b1;
            scl_d <= 1'b1;
            sda_meta <= 1'b1;
            sda_sync <= 1'b1;
            sda_d <= 1'b1;
        end
        else
        begin
            mclk_meta <= aud_mclk;
            mclk_sync <= mclk_meta;
            mclk_d <= mclk_sync;
            bclk_meta <= aud_bclk;
            bclk_sync <= bclk_meta;
            bclk_d <= bclk_sync;
            wclk_meta <= aud_wclk;
            wclk_sync <= wclk_meta;
            wclk_d <= wclk_sync;
            scl_meta <= i2c_scl;
            scl_sync <= scl_meta;
            scl_d <= scl_sync;
            sda_meta <= i2c_sda;
            sda_sync <= sda_meta;
            sda_d <= sda_sync;
        end
    end

    wire mclk_rising = mclk_sync && !mclk_d;
    wire bclk_rising = bclk_sync && !bclk_d;
    wire wclk_rising = wclk_sync && !wclk_d;
    wire scl_rising = scl_sync && !scl_d;
    wire i2c_start = scl_sync && sda_d && !sda_sync;
    wire i2c_stop = scl_sync && !sda_d && sda_sync;

    reg [16:0] reference_counter;
    reg [15:0] mclk_edges;
    reg [15:0] bclk_edges;
    reg [15:0] wclk_edges;
    localparam integer SNAPSHOT_COUNTER_WIDTH =
        (SNAPSHOT_WINDOWS <= 1) ? 1 : $clog2(SNAPSHOT_WINDOWS);
    reg [SNAPSHOT_COUNTER_WIDTH-1:0] window_counter;
    reg snapshot_captured;
    assign snapshot_ready = snapshot_captured;

    reg i2c_active;
    reg [3:0] i2c_bit_count;
    reg [7:0] i2c_shift;
    reg [7:0] i2c_byte_index;
    reg codec_transaction;
    reg transaction_read;
    reg [7:0] register_address;
    reg [7:0] codec_page;
    reg [7:0] codec_write_count;
    reg [7:0] nack_count;
    reg [7:0] last_nack_context;
    reg codec_init_complete;
    reg [7:0] dac_path;
    reg [7:0] left_dac_volume;
    reg [7:0] right_dac_volume;
    reg [7:0] headphone_driver;
    reg [7:0] speaker_analog_volume;
    reg [7:0] software_powerdown;

    task automatic RecordCodecWrite;
        input [7:0] address_value;
        input [7:0] data_value;
    begin
        if (address_value == 8'h00)
            codec_page <= data_value;
        else if (codec_page == 8'h00)
        begin
            if (address_value == 8'h3f)
                dac_path <= data_value;
            else if (address_value == 8'h40)
                left_dac_volume <= data_value;
            else if (address_value == 8'h41)
                right_dac_volume <= data_value;
        end
        else if (codec_page == 8'h01)
        begin
            if (address_value == 8'h1f)
                headphone_driver <= data_value;
            else if (address_value == 8'h26)
                speaker_analog_volume <= data_value;
            else if (address_value == 8'h2e)
                software_powerdown <= data_value;
        end
    end
    endtask

    always @(posedge clk or posedge reset)
    begin
        if (reset)
        begin
            reference_counter <= 17'd0;
            mclk_edges <= 16'd0;
            bclk_edges <= 16'd0;
            wclk_edges <= 16'd0;
            window_counter <= {SNAPSHOT_COUNTER_WIDTH{1'b0}};
            snapshot_captured <= 1'b0;
            snapshot_status <= 80'd0;
            snapshot_codec <= 80'd0;
            snapshot_toggle <= 1'b0;

            i2c_active <= 1'b0;
            i2c_bit_count <= 4'd0;
            i2c_shift <= 8'd0;
            i2c_byte_index <= 8'd0;
            codec_transaction <= 1'b0;
            transaction_read <= 1'b0;
            register_address <= 8'd0;
            codec_page <= 8'd0;
            codec_write_count <= 8'd0;
            nack_count <= 8'd0;
            last_nack_context <= 8'd0;
            codec_init_complete <= 1'b0;
            dac_path <= 8'd0;
            left_dac_volume <= 8'd0;
            right_dac_volume <= 8'd0;
            headphone_driver <= 8'd0;
            speaker_analog_volume <= 8'd0;
            software_powerdown <= 8'd0;
        end
        else
        begin
            if (mclk_rising && (mclk_edges != 16'hffff))
                mclk_edges <= mclk_edges + 1'b1;
            if (bclk_rising && (bclk_edges != 16'hffff))
                bclk_edges <= bclk_edges + 1'b1;
            if (wclk_rising && (wclk_edges != 16'hffff))
                wclk_edges <= wclk_edges + 1'b1;

            if (reference_counter == REFERENCE_WINDOW_CYCLES - 1)
            begin
                reference_counter <= 17'd0;
                mclk_edges <= 16'd0;
                bclk_edges <= 16'd0;
                wclk_edges <= 16'd0;

                if (!snapshot_captured &&
                    (window_counter == SNAPSHOT_WINDOWS - 1))
                begin
                    snapshot_status <= {
                        8'h01,
                        {mute, (wclk_edges != 0), (bclk_edges != 0),
                         (mclk_edges != 0), (nack_count != 0),
                         codec_init_complete, aud_reset, pll_lock},
                        volume,
                        {headphones, nack_count[6:0]},
                        mclk_edges[15:8], mclk_edges[7:0],
                        bclk_edges[15:8], bclk_edges[7:0],
                        wclk_edges[15:8], wclk_edges[7:0]
                    };
                    snapshot_codec <= {
                        8'h01, codec_write_count, codec_page, dac_path,
                        left_dac_volume, right_dac_volume,
                        headphone_driver, speaker_analog_volume,
                        software_powerdown, last_nack_context
                    };
                    snapshot_toggle <= ~snapshot_toggle;
                    snapshot_captured <= 1'b1;
                end
                else if (!snapshot_captured)
                    window_counter <= window_counter + 1'b1;
            end
            else
                reference_counter <= reference_counter + 1'b1;

            if (i2c_start)
            begin
                i2c_active <= 1'b1;
                i2c_bit_count <= 4'd0;
                i2c_shift <= 8'd0;
                i2c_byte_index <= 8'd0;
                codec_transaction <= 1'b0;
                transaction_read <= 1'b0;
            end
            else if (i2c_stop)
            begin
                i2c_active <= 1'b0;
                i2c_bit_count <= 4'd0;
            end
            else if (i2c_active && scl_rising)
            begin
                if (i2c_bit_count < 8)
                begin
                    i2c_shift <= {i2c_shift[6:0], sda_sync};
                    i2c_bit_count <= i2c_bit_count + 1'b1;
                end
                else
                begin
                    if (sda_sync &&
                        ((i2c_byte_index == 0) || !transaction_read))
                    begin
                        if (nack_count != 8'hff)
                            nack_count <= nack_count + 1'b1;
                        last_nack_context <= {i2c_byte_index[3:0],
                                              i2c_shift[3:0]};
                    end

                    if (i2c_byte_index == 0)
                    begin
                        codec_transaction <=
                            (i2c_shift[7:1] == CODEC_ADDRESS);
                        transaction_read <= i2c_shift[0];
                        if ((i2c_shift[7:1] == CODEC_ADDRESS) &&
                            i2c_shift[0] && !sda_sync)
                            codec_init_complete <= 1'b1;
                    end
                    else if (codec_transaction && !transaction_read &&
                             !sda_sync)
                    begin
                        if (i2c_byte_index == 1)
                            register_address <= i2c_shift;
                        else if (i2c_byte_index == 2)
                        begin
                            RecordCodecWrite(register_address, i2c_shift);
                            if (codec_write_count != 8'hff)
                                codec_write_count <= codec_write_count + 1'b1;
                        end
                    end

                    i2c_byte_index <= i2c_byte_index + 1'b1;
                    i2c_bit_count <= 4'd0;
                    i2c_shift <= 8'd0;
                end
            end
        end
    end
endmodule

`default_nettype wire
