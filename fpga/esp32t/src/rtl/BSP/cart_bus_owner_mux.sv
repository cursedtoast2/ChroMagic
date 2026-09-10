`default_nettype none

module cart_bus_owner_mux
(
    input  wire        maintenance_active,

    input  wire [15:0] core_address,
    input  wire        core_clock,
    input  wire        core_cs_n,
    input  wire        core_read_n,
    input  wire        core_write_n,
    input  wire [7:0]  core_data_out,
    input  wire        core_data_oe,

    input  wire [15:0] maintenance_address,
    input  wire        maintenance_clock,
    input  wire        maintenance_cs_n,
    input  wire        maintenance_read_n,
    input  wire        maintenance_write_n,
    input  wire [7:0]  maintenance_data_out,
    input  wire        maintenance_data_oe,

    output wire [15:0] physical_address,
    output wire        physical_clock,
    output wire        physical_cs_n,
    output wire        physical_read_n,
    output wire        physical_write_n,
    output wire [7:0]  physical_data_out,
    output wire        physical_data_oe
);

    assign physical_address  = maintenance_active ? maintenance_address  : core_address;
    assign physical_clock    = maintenance_active ? maintenance_clock    : core_clock;
    assign physical_cs_n     = maintenance_active ? maintenance_cs_n     : core_cs_n;
    assign physical_read_n   = maintenance_active ? maintenance_read_n   : core_read_n;
    assign physical_write_n  = maintenance_active ? maintenance_write_n  : core_write_n;
    assign physical_data_out = maintenance_active ? maintenance_data_out : core_data_out;
    assign physical_data_oe  = maintenance_active ? maintenance_data_oe  : core_data_oe;

endmodule

`default_nettype wire
