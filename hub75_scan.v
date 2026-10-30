`timescale 1ns/1ps

module hub75_scan #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer FIELD_HZ = 2280,
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
    localparam integer ROW_TICKS = CLK_HZ / (FIELD_HZ * SCAN_ROWS);
    localparam integer HALF_DIV_RAW = (ROW_TICKS * 3) / (4 * SHIFT_PIXELS * 2);
    localparam integer PIXEL_HALF_DIV = (HALF_DIV_RAW < 1) ? 1 : HALF_DIV_RAW;
    localparam integer DWELL_TICKS = ROW_TICKS - SHIFT_PIXELS*(2*PIXEL_HALF_DIV+1) - 3;
    localparam [2:0] S_SHIFT_LOW=3'd0, S_SHIFT_HIGH=3'd1,
                     S_ADDR_SETUP=3'd2, S_LATCH_HIGH=3'd3,
                     S_LATCH_LOW=3'd4, S_DWELL=3'd5,
                     S_PIXEL_SETUP=3'd6;

    reg [2:0] state;
    reg [15:0] dwell_count;
    reg [15:0] div_count;
    reg [7:0] pixel_count;
    reg [4:0] row_count;

    function [4:0] font_row;
        input integer digit;
        input integer row;
        begin
            case (digit)
                0: case(row) 0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b10011;3:font_row=5'b10101;4:font_row=5'b11001;5:font_row=5'b10001;default:font_row=5'b01110; endcase
                1: case(row) 0:font_row=5'b00100;1:font_row=5'b01100;2:font_row=5'b00100;3:font_row=5'b00100;4:font_row=5'b00100;5:font_row=5'b00100;default:font_row=5'b01110; endcase
                2: case(row) 0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b00001;3:font_row=5'b00010;4:font_row=5'b00100;5:font_row=5'b01000;default:font_row=5'b11111; endcase
                3: case(row) 0:font_row=5'b11110;1:font_row=5'b00001;2:font_row=5'b00001;3:font_row=5'b01110;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b11110; endcase
                4: case(row) 0:font_row=5'b00010;1:font_row=5'b00110;2:font_row=5'b01010;3:font_row=5'b10010;4:font_row=5'b11111;5:font_row=5'b00010;default:font_row=5'b00010; endcase
                5: case(row) 0:font_row=5'b11111;1:font_row=5'b10000;2:font_row=5'b10000;3:font_row=5'b11110;4:font_row=5'b00001;5:font_row=5'b00001;default:font_row=5'b11110; endcase
                6: case(row) 0:font_row=5'b00110;1:font_row=5'b01000;2:font_row=5'b10000;3:font_row=5'b11110;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b01110; endcase
                7: case(row) 0:font_row=5'b11111;1:font_row=5'b00001;2:font_row=5'b00010;3:font_row=5'b00100;4:font_row=5'b01000;5:font_row=5'b01000;default:font_row=5'b01000; endcase
                8: case(row) 0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b01110;4:font_row=5'b10001;5:font_row=5'b10001;default:font_row=5'b01110; endcase
                default: case(row) 0:font_row=5'b01110;1:font_row=5'b10001;2:font_row=5'b10001;3:font_row=5'b01111;4:font_row=5'b00001;5:font_row=5'b00010;default:font_row=5'b11100; endcase
            endcase
        end
    endfunction

    function text_pixel;
        input [6:0] x;
        input [4:0] y;
        input integer value;
        integer digit, glyph_row, glyph_col;
        reg [4:0] bits;
        begin
            text_pixel = 1'b0;
            if ((y >= 4) && (y < 18) && (x >= 8) && (x < 72)) begin
                glyph_row = (y - 4) / 2;
                glyph_col = ((x - 8) % 16) / 2;
                if (glyph_col < 5) begin
                    case ((x - 8) / 16)
                        0: digit=(value/1000)%10;
                        1: digit=(value/100)%10;
                        2: digit=(value/10)%10;
                        default: digit=value%10;
                    endcase
                    bits = font_row(digit, glyph_row);
                    text_pixel = bits[4-glyph_col];
                end
            end
        end
    endfunction

    function [2:0] pixel_value;
        input [6:0] x;
        input [4:0] y;
        input integer value;
        input [6:0] phase;
        begin
            if (text_pixel(x, y, value)) pixel_value = 3'b111;
            else case ((x + phase) % 3)
                0: pixel_value=3'b100;
                1: pixel_value=3'b010;
                default: pixel_value=3'b001;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state <= S_SHIFT_LOW;
            row_count <= 0; pixel_count <= 0;
            div_count <= 0; dwell_count <= 0;
            rgb1 <= 0; rgb2 <= 0; hub_clk <= 0; hub_lat <= 0; hub_oe_n <= 1; hub_addr <= 0;
        end else begin
            case (state)
                S_SHIFT_LOW: begin
                    hub_oe_n <= 1;
                    rgb1 <= pixel_value(7'd127-pixel_count, row_count, FIELD_HZ, 7'd0);
                    rgb2 <= pixel_value(7'd127-pixel_count, row_count, FIELD_HZ, 7'd0);
                    div_count <= 0;
                    state <= S_PIXEL_SETUP;
                end
                S_PIXEL_SETUP: begin
                    // Data changes one full PL clock before CLK can rise,
                    // including the fastest PIXEL_HALF_DIV=1 setting.
                    if (div_count >= PIXEL_HALF_DIV-1) begin div_count<=0; hub_clk<=1; state<=S_SHIFT_HIGH; end
                    else div_count<=div_count+1'b1;
                end
                S_SHIFT_HIGH: begin
                    hub_clk <= 1;
                    if (div_count >= PIXEL_HALF_DIV-1) begin
                        div_count<=0; hub_clk<=0;
                        if (pixel_count==127) begin pixel_count<=0; state<=S_ADDR_SETUP; end
                        else begin pixel_count<=pixel_count+1'b1; state<=S_SHIFT_LOW; end
                    end else div_count<=div_count+1'b1;
                end
                S_ADDR_SETUP: begin hub_clk<=0; hub_addr<=row_count; state<=S_LATCH_HIGH; end
                S_LATCH_HIGH: begin hub_lat<=1; state<=S_LATCH_LOW; end
                S_LATCH_LOW: begin hub_lat<=0; dwell_count<=0; state<=S_DWELL; end
                S_DWELL: begin
                    if (dwell_count < DWELL_TICKS-1) dwell_count<=dwell_count+1'b1;
                    else begin
                        dwell_count<=0; hub_oe_n<=1;
                        if (row_count==31) begin
                            row_count<=0;
                        end else row_count<=row_count+1'b1;
                        state<=S_SHIFT_LOW;
                    end
                    if (dwell_count >= (DWELL_TICKS*7)/8) hub_oe_n<=0;
                end
                default: state<=S_SHIFT_LOW;
            endcase
        end
    end

    initial begin
        if (SHIFT_PIXELS != 128 || SCAN_ROWS != 32) $error("Test pattern assumes 128x64 1/32 scan");
        if (DWELL_TICKS < 8 || ROW_TICKS > 65535) $error("FIELD_HZ outside supported scan budget");
    end
endmodule
