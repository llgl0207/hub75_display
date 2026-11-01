`timescale 1ns/1ps

// Ping-pong slice buffer: two 4096 x 6-bit simple dual-port BRAMs.
//
// One buffer is read by hub75_scan while the DDR reader fills the other. A
// 6-bit word contains rgb1 in [2:0] and rgb2 in [5:3]. The read port is
// synchronous: rd_data is valid one clock after rd_addr.
//
// Each memory has one write port and one unconditional read port so Vivado
// infers one BRAM36 per buffer (4096 x 6 fits the 4096 x 9 native mode). The
// read-buffer mux is outside the memories.
module hub75_slice_ram (
    input  wire        clk,
    // write side (DDR reader)
    input  wire        wr_en,
    input  wire        wr_buf,     // 0: buffer A, 1: buffer B
    input  wire [11:0] wr_addr,    // 0..4095
    input  wire [5:0]  wr_data,
    // read side (hub75_scan)
    input  wire        rd_buf,     // 0: buffer A, 1: buffer B
    input  wire [12:0] rd_addr,    // 0..4095; bit 12 must be 0
    output wire [5:0]  rd_data
);
    (* ram_style = "block" *) reg [5:0] mem_a [0:4095];
    (* ram_style = "block" *) reg [5:0] mem_b [0:4095];
    reg [5:0] rd_a;
    reg [5:0] rd_b;

    always @(posedge clk) begin
        if (wr_en && !wr_buf) mem_a[wr_addr] <= wr_data;
    end
    always @(posedge clk) begin
        if (wr_en && wr_buf) mem_b[wr_addr] <= wr_data;
    end
    always @(posedge clk) rd_a <= mem_a[rd_addr[11:0]];
    always @(posedge clk) rd_b <= mem_b[rd_addr[11:0]];

    assign rd_data = rd_buf ? rd_b : rd_a;
endmodule
