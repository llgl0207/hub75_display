`timescale 1ns/1ps

// Slice scheduler: converts the measured revolution period into a fixed number
// of display slots per revolution plus a per-row HUB75 time budget.
//
// This module owns the rotational time base. The scanner only produces
// waveforms for one slot at a time; it never decides when a slot starts.
//
// All divisions are by powers of two, so no divider is instantiated:
//   slot_cycles = period_latched >> SLOT_LOG2      (64 slots per revolution)
//   row_ticks   = slot_cycles     >> ROW_LOG2      (32 row addresses per slot)
// At a 50 MHz clock and 1800 RPM: period = 1,666,667 cycles, slot = 26,041,
// row = 813 cycles per row address.
//
// The period is latched at every revolution_start and held for that whole
// revolution, so the timing cannot shift under the scan mid-rotation.
//
// Overspeed limit: when row_ticks would fall below MIN_ROW_TICKS the clamp
// makes 32 rows longer than one slot, so the scanner truncates the last rows
// of each slot. That is the only supported degradation; keep the slot count or
// the RPM within budget.
module hub75_sched #(
    parameter integer CLK_HZ        = 50_000_000,
    parameter integer SLOT_LOG2     = 6,      // 64 slots per revolution
    parameter integer ROW_LOG2      = 5,      // 32 row addresses per slot
    parameter integer FALLBACK_RPM  = 1800,   // must be a multiple of 60
    parameter integer MIN_ROW_TICKS = 700,    // 643 fixed overhead + dwell
    parameter integer MAX_ROW_TICKS = 65535,
    // Parameter sanity checks. Real builds keep this at 1; unit-test instances
    // that deliberately violate the production floor set it to 0.
    parameter integer CHECK_PARAMS  = 1
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     revolution_start,
    input  wire                     period_valid,
    input  wire [31:0]              period_ticks,
    output reg  [SLOT_LOG2-1:0]     slice_index,
    output reg  [15:0]              row_ticks,
    output reg                      slot_start
);
    // (period / 60) would overflow 32 bits for a 50 MHz clock, so divide by
    // RPM/60 instead: 50e6 / 30 = 1,666,667 cycles per revolution at 1800 RPM.
    localparam integer FALLBACK_PERIOD = CLK_HZ / (FALLBACK_RPM / 60);

    reg [31:0] period_latched;
    reg [31:0] slot_count;

    wire [31:0] period_next = period_valid ? period_ticks : FALLBACK_PERIOD[31:0];
    // A held-valid but zero period would otherwise make every cycle a slot.
    wire [31:0] period_safe = (period_next == 0) ? FALLBACK_PERIOD[31:0] : period_next;
    wire [31:0] slot_cycles_l = period_latched >> SLOT_LOG2;
    wire [31:0] row_raw        = slot_cycles_l >> ROW_LOG2;
    wire [15:0] row_clamped    = (row_raw < MIN_ROW_TICKS) ? MIN_ROW_TICKS[15:0]
                               : (row_raw > MAX_ROW_TICKS) ? MAX_ROW_TICKS[15:0]
                               : row_raw[15:0];

    always @(posedge clk) begin
        if (rst) begin
            period_latched <= FALLBACK_PERIOD[31:0];
            slot_count     <= 0;
            slice_index    <= 0;
            row_ticks      <= MIN_ROW_TICKS[15:0];
            slot_start     <= 1'b0;
        end else begin
            slot_start <= 1'b0;
            row_ticks  <= row_clamped;
            if (revolution_start) begin
                // New revolution: adopt the latest estimate, restart at slice 0
                // and give the scanner an immediate slot boundary.
                period_latched <= period_safe;
                slot_count     <= 0;
                slice_index    <= 0;
                slot_start     <= 1'b1;
            end else if (slot_count + 1'b1 >= slot_cycles_l) begin
                slot_count  <= 0;
                slice_index <= slice_index + 1'b1;
                slot_start  <= 1'b1;
            end else begin
                slot_count <= slot_count + 1'b1;
            end
        end
    end

    initial begin
        if (CHECK_PARAMS != 0) begin
            if (FALLBACK_RPM % 60 != 0)
                $error("FALLBACK_RPM must be a multiple of 60 for this integer period");
            if (MIN_ROW_TICKS < 650)
                $error("MIN_ROW_TICKS must cover the 128-pixel shift overhead");
            if (SLOT_LOG2 <= 0 || ROW_LOG2 <= 0)
                $error("SLOT_LOG2 and ROW_LOG2 must be positive");
        end
    end
endmodule