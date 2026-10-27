`timescale 1ns/1ps

module hub75_scan #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer PIXEL_CLK_HZ = 5_000_000,
    parameter integer FRAME_HZ = 120,
    parameter integer SHIFT_PIXELS = 128,
    parameter integer SCAN_ROWS = 32
) (
    input  wire       clk,
    input  wire       rst,
    output reg  [2:0] rgb1,
    output reg  [2:0] rgb2,
    output reg        hub_clk,
    output reg        hub_lat,
    output reg        hub_oe_n,
    output reg  [4:0] hub_addr
);
    localparam integer HALF_DIV = (CLK_HZ + (2 * PIXEL_CLK_HZ) - 1) / (2 * PIXEL_CLK_HZ);
    localparam integer ROW_TICKS = CLK_HZ / (FRAME_HZ * SCAN_ROWS);
    localparam integer DWELL_TICKS = ROW_TICKS - (SHIFT_PIXELS * 2 * HALF_DIV) - 8;
    localparam integer OE_ON_TICK = (DWELL_TICKS * 7) / 8;
    localparam integer DIV_W = (HALF_DIV <= 1) ? 1 : $clog2(HALF_DIV);
    localparam integer ROW_W = (DWELL_TICKS <= 1) ? 1 : $clog2(DWELL_TICKS);
    localparam integer PIX_W = (SHIFT_PIXELS <= 1) ? 1 : $clog2(SHIFT_PIXELS);

    localparam [2:0] S_SHIFT_LOW = 3'd0,
                     S_SHIFT_HIGH = 3'd1,
                     S_ADDR_SETUP = 3'd2,
                     S_LATCH_HIGH = 3'd3,
                     S_LATCH_LOW = 3'd4,
                     S_DWELL = 3'd5;

    reg [2:0] state;
    reg [DIV_W-1:0] div_count;
    reg [ROW_W-1:0] dwell_count;
    reg [PIX_W-1:0] pixel_count;
    reg [4:0] row_count;
    reg [6:0] anim_phase;

    // Three color bands circulate horizontally. The 7-bit arithmetic wraps at 128.
    function [2:0] test_pixel;
        input [6:0] x;
        input [6:0] phase;
        reg [6:0] pos;
        begin
            pos = x + phase;
            if (pos < 7'd43) test_pixel = 3'b100;
            else if (pos < 7'd86) test_pixel = 3'b010;
            else test_pixel = 3'b001;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_SHIFT_LOW;
            div_count  <= 0;
            dwell_count<= 0;
            pixel_count<= 0;
            row_count  <= 0;
            rgb1       <= 0;
            rgb2       <= 0;
            hub_clk    <= 0;
            hub_lat    <= 0;
            hub_oe_n   <= 1;
            hub_addr   <= 0;
            anim_phase <= 0;
        end else begin
            case (state)
                S_SHIFT_LOW: begin
                    hub_oe_n <= 1;
                    rgb1 <= test_pixel(SHIFT_PIXELS-1-pixel_count, anim_phase);
                    rgb2 <= test_pixel(SHIFT_PIXELS-1-pixel_count, anim_phase);
                    if (div_count == HALF_DIV-1) begin
                        div_count <= 0;
                        hub_clk <= 1;
                        state <= S_SHIFT_HIGH;
                    end else div_count <= div_count + 1'b1;
                end
                S_SHIFT_HIGH: begin
                    hub_clk <= 1;
                    if (div_count == HALF_DIV-1) begin
                        div_count <= 0;
                        hub_clk <= 0;
                        if (pixel_count == SHIFT_PIXELS-1) begin
                            pixel_count <= 0;
                            state <= S_ADDR_SETUP;
                        end else begin
                            pixel_count <= pixel_count + 1'b1;
                            state <= S_SHIFT_LOW;
                        end
                    end else div_count <= div_count + 1'b1;
                end
                S_ADDR_SETUP: begin
                    hub_clk <= 0;
                    hub_addr <= row_count;
                    state <= S_LATCH_HIGH;
                end
                S_LATCH_HIGH: begin
                    hub_lat <= 1;
                    state <= S_LATCH_LOW;
                end
                S_LATCH_LOW: begin
                    hub_lat <= 0;
                    dwell_count <= 0;
                    state <= S_DWELL;
                end
                S_DWELL: begin
                    if (dwell_count < DWELL_TICKS-1) dwell_count <= dwell_count + 1'b1;
                    else begin
                        dwell_count <= 0;
                        hub_oe_n <= 1;
                        if (row_count == SCAN_ROWS-1) begin
                            row_count <= 0;
                            anim_phase <= anim_phase + 7'd1;
                        end else row_count <= row_count + 1'b1;
                        state <= S_SHIFT_LOW;
                    end
                    if (dwell_count == OE_ON_TICK) hub_oe_n <= 0;
                end
                default: state <= S_SHIFT_LOW;
            endcase
        end
    end

    initial begin
        if (CLK_HZ < 2 * PIXEL_CLK_HZ) $error("CLK_HZ must be >= 2*PIXEL_CLK_HZ");
        if (DWELL_TICKS <= 8) $error("Row period is too short for pixel shifting");
        if (DWELL_TICKS <= OE_ON_TICK) $error("Invalid OE brightness interval");
        if (SHIFT_PIXELS != 128 || SCAN_ROWS != 32) $error("Test pattern assumes 128x64 1/32 scan");
    end
endmodule
