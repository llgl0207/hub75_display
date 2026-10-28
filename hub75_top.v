`timescale 1ns/1ps

module hub75_top #(
    // 0:2200 Hz through 20:2400 Hz, in 10 Hz steps
    parameter integer START_RATE_INDEX = 0,
    parameter integer AUTO_TEST = 1,
    parameter integer HOLD_SECONDS = 1
) (
    input  wire       clk_in,
    input  wire       reset_n, // Active-low PL_KEY1
    output wire [2:0] rgb1,
    output wire [2:0] rgb2,
    output wire       hub_clk,
    output wire       hub_lat,
    output wire       hub_oe_n,
    output wire [4:0] hub_addr
);
    wire reset_sync;
    reg [1:0] reset_pipe = 2'b11;

    always @(posedge clk_in or negedge reset_n) begin
        if (!reset_n) reset_pipe <= 2'b11;
        else reset_pipe <= {reset_pipe[0], 1'b0};
    end
    assign reset_sync = reset_pipe[1];

    hub75_scan #(
        .CLK_HZ(50_000_000),
        .START_RATE_INDEX(START_RATE_INDEX),
        .AUTO_TEST(AUTO_TEST),
        .HOLD_SECONDS(HOLD_SECONDS)
    ) u_scan (
        .clk(clk_in),
        .rst(reset_sync),
        .rgb1(rgb1),
        .rgb2(rgb2),
        .hub_clk(hub_clk),
        .hub_lat(hub_lat),
        .hub_oe_n(hub_oe_n),
        .hub_addr(hub_addr)
    );
endmodule
