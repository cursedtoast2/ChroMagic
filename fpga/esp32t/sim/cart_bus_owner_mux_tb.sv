`timescale 1ns/1ps

module cart_bus_owner_mux_tb;
    reg maintenance_active;
    reg [15:0] core_address;
    reg core_clock;
    reg core_cs_n;
    reg core_read_n;
    reg core_write_n;
    reg [7:0] core_data_out;
    reg core_data_oe;
    reg [15:0] maintenance_address;
    reg maintenance_clock;
    reg maintenance_cs_n;
    reg maintenance_read_n;
    reg maintenance_write_n;
    reg [7:0] maintenance_data_out;
    reg maintenance_data_oe;
    wire [15:0] physical_address;
    wire physical_clock;
    wire physical_cs_n;
    wire physical_read_n;
    wire physical_write_n;
    wire [7:0] physical_data_out;
    wire physical_data_oe;

    cart_bus_owner_mux dut(.*);

    initial begin
        core_address = 16'h1234;
        core_clock = 1'b0;
        core_cs_n = 1'b1;
        core_read_n = 1'b0;
        core_write_n = 1'b1;
        core_data_out = 8'ha5;
        core_data_oe = 1'b1;
        maintenance_address = 16'habcd;
        maintenance_clock = 1'b1;
        maintenance_cs_n = 1'b0;
        maintenance_read_n = 1'b1;
        maintenance_write_n = 1'b0;
        maintenance_data_out = 8'h5a;
        maintenance_data_oe = 1'b0;

        maintenance_active = 1'b0;
        #1;
        if ({physical_address, physical_clock, physical_cs_n,
             physical_read_n, physical_write_n, physical_data_out,
             physical_data_oe} !==
            {core_address, core_clock, core_cs_n, core_read_n,
             core_write_n, core_data_out, core_data_oe})
            $fatal(1, "idle path differs from core path");

        maintenance_active = 1'b1;
        #1;
        if ({physical_address, physical_clock, physical_cs_n,
             physical_read_n, physical_write_n, physical_data_out,
             physical_data_oe} !==
            {maintenance_address, maintenance_clock, maintenance_cs_n,
             maintenance_read_n, maintenance_write_n,
             maintenance_data_out, maintenance_data_oe})
            $fatal(1, "maintenance path was not selected exactly");

        $display("PASS: cart bus has one exact selected owner");
        $finish;
    end
endmodule
