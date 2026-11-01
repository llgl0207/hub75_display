`timescale 1ns/1ps

// HUB75 waveform engine for one slot (one complete 128x64 1/32 panel scan).
//
// The rotational time base lives in hub75_sched. This module owns only the
// waveform: it is paced by row_ticks, starts on slot_start and returns to IDLE
// between slots. It never stalls inside a row waiting for anything.
//
// Pixel colour is a function of (slice_index, column, row, group). group=0 is
// the rgb1 bus, group=1 is the rgb2 bus.
// PATTERN_MODE=1 is the closed-loop bring-up pattern: slice 0 is a full white
// plane (the angular zero anchor) and every other slice is a narrow red bar
// whose column follows the slice index, so a restart at slice 0 is visible at
// every trigger.
// PATTERN_MODE=0 keeps the previously verified colour bars plus the label, as a
// known-good panel reference image.
// PATTERN_MODE=2 is the group-alignment diagnostic: both groups draw exactly
// the same columns, only the colour differs (rgb1 red, rgb2 green), so any
// offset, mirror or row step seen on the panel is a property of the panel or
// its wiring rather than of the pattern.
// PATTERN_MODE=3 reads a 6-bit slice word from BRAM: [2:0] = rgb1 (upper),
// [5:3] = rgb2 (lower). The word is addressed by (row_count, column); the PS
// renderer pre-shifts the rgb2 half if the panel wiring needs a column offset.
// The address is launched in S_SHIFT_LOW and the BRAM output is registered into
// rgb1/rgb2 one cycle later in S_PIXEL_SETUP, still before CLK can rise.
module hub75_scan #(
    parameter integer SHIFT_PIXELS    = 128,
    parameter integer SCAN_ROWS       = 32,
    parameter integer SLICE_BITS      = 6,
    parameter integer PIXEL_HALF_DIV  = 2,   // 10 MHz pixel clock at 50 MHz
    parameter integer PATTERN_MODE    = 1,   // 0: bars+label, 1: sweep, 2: group diagnostic, 3: slice RAM
    parameter integer LABEL_VALUE     = 2280,
    // Column offset applied to the rgb2 bus only, modulo 128. Positive values
    // make the rgb2 half show columns that the rgb1 half shows N pixels later.
    // Keep at 0 unless the PATTERN_MODE=2 diagnostic proves the halves disagree.
    parameter integer RGB2_COLUMN_OFFSET = 0
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire [15:0]             row_ticks,
    input  wire                    slot_start,
    input  wire [SLICE_BITS-1:0]   slice_index,
    input  wire [5:0]              pix_data,
    output wire [12:0]             pix_addr,
    output reg  [2:0]              rgb1,
    output reg  [2:0]              rgb2,
    output reg                     hub_clk,
    output reg                     hub_lat,
    output reg                     hub_oe_n,
    output reg  [4:0]              hub_addr
);
    // Cycles consumed by everything except the dwell, at PIXEL_HALF_DIV=2:
    // one setup cycle plus two half-period cycles per pixel, then 3 latch cycles.
    localparam integer PIXEL_CYCLES = 1 + 2*PIXEL_HALF_DIV;
    localparam integer ROW_OVERHEAD = SHIFT_PIXELS*PIXEL_CYCLES + 3;
    // Slicing keeps a negative offset usable: -3 becomes 125 and wraps modulo 128.
    localparam [6:0]   RGB2_OFFSET  = RGB2_COLUMN_OFFSET[6:0];

    localparam [2:0] S_SHIFT_LOW=3'd0, S_SHIFT_HIGH=3'd1,
                     S_ADDR_SETUP=3'd2, S_LATCH_HIGH=3'd3,
                     S_LATCH_LOW=3'd4, S_DWELL=3'd5,
                     S_PIXEL_SETUP=3'd6, S_IDLE=3'd7;

    reg [2:0]  state;
    reg [15:0] dwell_count;
    reg [15:0] div_count;
    reg [7:0]  pixel_count;
    reg [4:0]  row_count;
    reg        restart_pending;

    // Combinational slice-RAM address for the current pixel. It must be stable
    // during S_SHIFT_LOW so the synchronous RAM output is ready in S_PIXEL_SETUP
    // (one full clock before CLK can rise).
    assign pix_addr = {1'b0, row_count, 7'd0} +
                      ({5'd0, 8'd127} - {5'd0, pixel_count});

    // Runtime dwell budget and blanking: the OE window follows the same 1/8-of-
    // dwell rule as the verified build, but scaled to the current row budget.
    wire [15:0] dwell_ticks  = (row_ticks > ROW_OVERHEAD) ? (row_ticks - ROW_OVERHEAD) : 16'd0;
    wire [15:0] oe_threshold = dwell_ticks - (dwell_ticks >> 3);

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
        input [6:0]                 x;
        input [4:0]                 y;
        input [SLICE_BITS-1:0]      slice_index;
        input                       group;   // 0: rgb1, 1: rgb2
        integer bar_start;
        begin
            if (PATTERN_MODE == 0) begin
                if (text_pixel(x, y, LABEL_VALUE)) pixel_value = 3'b111;
                else case (x % 3)
                    0: pixel_value = 3'b100;
                    1: pixel_value = 3'b010;
                    default: pixel_value = 3'b001;
                endcase
            end else if (PATTERN_MODE == 1) begin
                // Angular zero slice: full white plane, the anchor to watch on a
                // spinning rig. All other slices: one narrow red bar.
                if (slice_index == 0) begin
                    pixel_value = 3'b111;
                end else begin
                    bar_start = 2*slice_index;
                    if ((x >= bar_start) && (x < bar_start + 4)) pixel_value = 3'b100;
                    else pixel_value = 3'b000;
                end
            end else begin
                // Group-alignment diagnostic. Both groups are told to draw the
                // same columns, so nothing here can create a difference: whatever
                // the panel shows is what the two halves really do.
                //   comb   : a full-height line every 16 columns, a 16-pixel ruler
                //   thin   : a single line at column 8
                //   thick  : five lines at columns 120..124
                // The thin/thick pair on opposite sides makes mirroring obvious.
                if ((x[3:0] == 4'd0) || (x == 7'd8) || (x >= 7'd120 && x <= 7'd124))
                    pixel_value = group ? 3'b010     // rgb2 half: green
                                        : 3'b100;    // rgb1 half: red
                else pixel_value = 3'b000;
            end
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            state           <= S_IDLE;
            row_count       <= 0; pixel_count <= 0;
            div_count       <= 0; dwell_count <= 0;
            restart_pending <= 1'b0;
            rgb1 <= 0; rgb2 <= 0; hub_clk <= 0; hub_lat <= 0; hub_oe_n <= 1; hub_addr <= 0;
        end else begin
            // A slot boundary may arrive in any state: remember it and act at the
            // next row boundary so LAT/OE stay well formed.
            if (slot_start) restart_pending <= 1'b1;

            case (state)
                S_IDLE: begin
                    hub_clk <= 0; hub_lat <= 0; hub_oe_n <= 1;
                    rgb1 <= 0; rgb2 <= 0; hub_addr <= 0;
                    if (slot_start || restart_pending) begin
                        restart_pending <= 1'b0;
                        row_count <= 0; pixel_count <= 0;
                        div_count <= 0; dwell_count <= 0;
                        state <= S_SHIFT_LOW;
                    end
                end
                S_SHIFT_LOW: begin
                    hub_oe_n <= 1;
                    if (PATTERN_MODE != 3) begin
                        rgb1 <= pixel_value(7'd127 - pixel_count, row_count,
                                            slice_index, 1'b0);
                        rgb2 <= pixel_value((7'd127 - pixel_count) + RGB2_OFFSET,
                                            row_count, slice_index, 1'b1);
                    end
                    div_count <= 0;
                    state <= S_PIXEL_SETUP;
                end
                S_PIXEL_SETUP: begin
                    // Data changes one full PL clock before CLK can rise.
                    if (PATTERN_MODE == 3) begin
                        rgb1 <= pix_data[2:0];
                        rgb2 <= pix_data[5:3];
                    end
                    if (div_count >= PIXEL_HALF_DIV-1) begin div_count<=0; hub_clk<=1; state<=S_SHIFT_HIGH; end
                    else div_count<=div_count+1'b1;
                end
                S_SHIFT_HIGH: begin
                    if (div_count >= PIXEL_HALF_DIV-1) begin
                        div_count<=0; hub_clk<=0;
                        if (pixel_count==SHIFT_PIXELS-1) begin pixel_count<=0; state<=S_ADDR_SETUP; end
                        else begin pixel_count<=pixel_count+1'b1; state<=S_SHIFT_LOW; end
                    end else div_count<=div_count+1'b1;
                end
                S_ADDR_SETUP: begin hub_clk<=0; hub_addr<=row_count; state<=S_LATCH_HIGH; end
                S_LATCH_HIGH: begin hub_lat<=1; state<=S_LATCH_LOW; end
                S_LATCH_LOW: begin hub_lat<=0; dwell_count<=0; state<=S_DWELL; end
                S_DWELL: begin
                    if (restart_pending) begin
                        // Abort the remaining dwell so a trigger is honoured
                        // within one row instead of waiting out a long dwell.
                        restart_pending <= 1'b0;
                        dwell_count <= 0;
                        hub_oe_n <= 1;
                        row_count <= 0; pixel_count <= 0; hub_addr <= 0;
                        state <= S_SHIFT_LOW;
                    end else if (dwell_count + 1'b1 >= dwell_ticks) begin
                        dwell_count <= 0;
                        hub_oe_n <= 1;
                        if (row_count == SCAN_ROWS-1) begin
                            row_count <= 0;
                            state <= S_IDLE;
                        end else begin
                            row_count <= row_count + 1'b1;
                            state <= S_SHIFT_LOW;
                        end
                    end else begin
                        dwell_count <= dwell_count + 1'b1;
                        if (dwell_count >= oe_threshold) hub_oe_n <= 0;
                    end
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if (SHIFT_PIXELS != 128 || SCAN_ROWS != 32) $error("Pattern assumes 128x64 1/32 scan");
        if (ROW_OVERHEAD + 8 > 65535) $error("Pixel overhead does not fit a row budget");
    end
endmodule