`timescale 1ns/1ps

module hub75_scan #(
    parameter integer CLK_HZ = 50_000_000,
    parameter integer START_RATE_INDEX = 0,
    parameter integer AUTO_TEST = 1,
    parameter integer HOLD_SECONDS = 1,
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
    localparam integer RATE_COUNT = 21;
    localparam integer HOLD_TICKS = CLK_HZ * HOLD_SECONDS;
    localparam integer HOLD_W = 28;
    localparam [2:0] S_SHIFT_LOW=3'd0, S_SHIFT_HIGH=3'd1,
                     S_ADDR_SETUP=3'd2, S_LATCH_HIGH=3'd3,
                     S_LATCH_LOW=3'd4, S_DWELL=3'd5;

    reg [2:0] state;
    reg [15:0] row_ticks;
    reg [15:0] pixel_half_div;
    reg [15:0] dwell_count;
    reg [15:0] div_count;
    reg [7:0] pixel_count;
    reg [4:0] row_count;
    reg [6:0] pattern_phase;
    reg [3:0] rate_index;
    reg [15:0] current_rate;
    reg [HOLD_W-1:0] hold_count;
    integer dwell_limit;

    function integer rate_value;
        input integer index;
        begin rate_value = 2200 + (index * 10); end
    endfunction

    function integer row_ticks_value;
        input integer index;
        integer rate;
        begin
            rate = rate_value(index);
            row_ticks_value = CLK_HZ / (rate * SCAN_ROWS);
        end
    endfunction

    // Use about 75% of each row for shifting. As the field rate rises,
    // the divider decreases and HUB75 CLK rises with it.
    function integer half_div_value;
        input integer index;
        integer rt;
        begin
            rt = row_ticks_value(index);
            half_div_value = (rt * 3) / (4 * SHIFT_PIXELS * 2);
            if (half_div_value < 1) half_div_value = 1;
        end
    endfunction

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

    always @* begin
        dwell_limit = row_ticks - (SHIFT_PIXELS * 2 * pixel_half_div) - 8;
        if (dwell_limit < 8) dwell_limit = 8;
    end

    always @(posedge clk) begin
        if (rst) begin
            state <= S_SHIFT_LOW;
            row_count <= 0; pixel_count <= 0; pattern_phase <= 0;
            div_count <= 0; dwell_count <= 0; hold_count <= 0;
            rate_index <= (START_RATE_INDEX < RATE_COUNT) ? START_RATE_INDEX : 0;
            row_ticks <= row_ticks_value((START_RATE_INDEX < RATE_COUNT) ? START_RATE_INDEX : 0);
            pixel_half_div <= half_div_value((START_RATE_INDEX < RATE_COUNT) ? START_RATE_INDEX : 0);
            current_rate <= rate_value((START_RATE_INDEX < RATE_COUNT) ? START_RATE_INDEX : 0);
            rgb1 <= 0; rgb2 <= 0; hub_clk <= 0; hub_lat <= 0; hub_oe_n <= 1; hub_addr <= 0;
        end else begin
            if (hold_count < HOLD_TICKS-1) hold_count <= hold_count + 1'b1;
            case (state)
                S_SHIFT_LOW: begin
                    hub_oe_n <= 1;
                    rgb1 <= pixel_value(7'd127-pixel_count, row_count, current_rate, pattern_phase);
                    rgb2 <= pixel_value(7'd127-pixel_count, row_count, current_rate, pattern_phase);
                    if (div_count >= pixel_half_div-1) begin div_count<=0; hub_clk<=1; state<=S_SHIFT_HIGH; end
                    else div_count<=div_count+1'b1;
                end
                S_SHIFT_HIGH: begin
                    hub_clk <= 1;
                    if (div_count >= pixel_half_div-1) begin
                        div_count<=0; hub_clk<=0;
                        if (pixel_count==127) begin pixel_count<=0; state<=S_ADDR_SETUP; end
                        else begin pixel_count<=pixel_count+1'b1; state<=S_SHIFT_LOW; end
                    end else div_count<=div_count+1'b1;
                end
                S_ADDR_SETUP: begin hub_clk<=0; hub_addr<=row_count; state<=S_LATCH_HIGH; end
                S_LATCH_HIGH: begin hub_lat<=1; state<=S_LATCH_LOW; end
                S_LATCH_LOW: begin hub_lat<=0; dwell_count<=0; state<=S_DWELL; end
                S_DWELL: begin
                    if (dwell_count < dwell_limit-1) dwell_count<=dwell_count+1'b1;
                    else begin
                        dwell_count<=0; hub_oe_n<=1;
                        if (row_count==31) begin
                            row_count<=0;
                            if (AUTO_TEST && hold_count >= HOLD_TICKS-1) begin
                                hold_count<=0;
                                if (rate_index==RATE_COUNT-1) rate_index<=0;
                                else rate_index<=rate_index+1'b1;
                                row_ticks<=row_ticks_value((rate_index==RATE_COUNT-1)?0:rate_index+1'b1);
                                pixel_half_div<=half_div_value((rate_index==RATE_COUNT-1)?0:rate_index+1'b1);
                                current_rate<=rate_value((rate_index==RATE_COUNT-1)?0:rate_index+1'b1);
                                pattern_phase<=pattern_phase+7'd1;
                            end
                        end else row_count<=row_count+1'b1;
                        state<=S_SHIFT_LOW;
                    end
                    if (dwell_count >= (dwell_limit*7)/8) hub_oe_n<=0;
                end
                default: state<=S_SHIFT_LOW;
            endcase
        end
    end

    initial begin
        if (SHIFT_PIXELS != 128 || SCAN_ROWS != 32) $error("Test pattern assumes 128x64 1/32 scan");
        if (HOLD_SECONDS < 1) $error("HOLD_SECONDS must be >= 1");
    end
endmodule
