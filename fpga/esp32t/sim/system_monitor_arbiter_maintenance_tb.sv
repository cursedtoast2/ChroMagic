`timescale 1ns/1ps
module system_monitor_arbiter_maintenance_tb;
    reg clk=0, reset=1, write_done=0;
    reg [13:0] valid=0;
    wire [3:0] channel;
    wire write;
    wire disabled;
    wire [6:0] address;
    always #5 clk=~clk;
    system_monitor_arbiter #(.NUM_CH(14)) dut(
        .clk(clk),.reset(reset),.channelsNewDataValid(valid),
        .menuDisabled(1'b0),.uart_tx_busy(1'b0),.write_done(write_done),
        .uartDisabled(disabled),.tx_channel(channel),.tx_address(address),.write(write));
    task automatic complete_packet;
        begin
            @(negedge clk); write_done=1;
            @(negedge clk); write_done=0;
        end
    endtask
    task automatic await_packet(input integer expected_channel);
        integer cycles;
        begin
            cycles=0;
            while (!write && cycles<100) begin @(negedge clk); cycles=cycles+1; end
            if (!write || channel != expected_channel)
                $fatal(1,"packet channel %0d expected %0d",channel,expected_channel);
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);
        reset=0;
        valid[0]=1; valid[2]=1;
        await_packet(0);
        valid[10]=1; valid[13]=1;
        repeat(3) @(negedge clk);
        complete_packet();
        await_packet(10);
        complete_packet(); valid[10]=0;
        await_packet(13);
        complete_packet(); valid[13]=0;
        repeat(100) begin
            @(negedge clk);
            if(write) begin
                if(channel==10 || channel==13)
                    $fatal(1,"acknowledged maintenance packet repeated");
                complete_packet();
            end
        end
        $display("PASS: block completion priority and one-time ready/valid consumption");
        $finish;
    end
    initial begin #100000; $fatal(1,"arbiter timeout"); end
endmodule
