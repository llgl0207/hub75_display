`timescale 1ns/1ps

module hub75_top #(
    parameter integer CLK_HZ = 50_000_000, // must be a multiple of 1 MHz
    // 0: rising edge (current default); 1: falling edge. Rebuild after change.
    parameter integer IR_FALLING_EDGE = 0,
    // 1 ms debounce and 1 ms hold-off at CLK_HZ: one illumination, one trigger.
    // A pulse narrower than IR_DEBOUNCE_US is discarded; both windows must stay
    // far below the revolution period.
    parameter integer IR_DEBOUNCE_US = 1000,
    parameter integer IR_HOLDOFF_US  = 1000,
    // 2^SLOT_LOG2 display slots per revolution, 2^ROW_LOG2 row addresses each.
    parameter integer SLOT_LOG2    = 6,
    parameter integer ROW_LOG2     = 5,
    // Rate used until five complete intervals exist. Must be a multiple of 60.
    parameter integer FALLBACK_RPM = 1800,
    // 0: colour bars + label (verified panel reference), 1: slice sweep pattern,
    // 2: rgb1/rgb2 group-alignment diagnostic.
    parameter integer PATTERN_MODE = 1,
    // Column offset for the rgb2 half only, modulo 128; see hub75_scan.v.
    parameter integer RGB2_COLUMN_OFFSET = 0
) (
    input  wire       clk_in,
    input  wire       reset_n, // Active-low PL_KEY1
    input  wire       ir_in,
    output wire [2:0] rgb1,
    output wire [2:0] rgb2,
    output wire       hub_clk,
    output wire       hub_lat,
    output wire       hub_oe_n,
    output wire [4:0] hub_addr,
    output wire [3:0] debug_led_n,
    output wire       debug_uart_tx
);
    wire reset_sync;
    reg [1:0] reset_pipe = 2'b11;

    always @(posedge clk_in or negedge reset_n) begin
        if (!reset_n) reset_pipe <= 2'b11;
        else reset_pipe <= {reset_pipe[0], 1'b0};
    end
    assign reset_sync = reset_pipe[1];

    // Preserve capture results for later ILA insertion; no extra output pins.
    // ir_level is the filtered level the capture logic accepts; D6 shows the raw
    // synchronised input instead, so a dead sensor and a swallowed pulse stay
    // distinguishable. Swap the two below to observe the filtered level.
    (* MARK_DEBUG = "TRUE" *) wire ir_level;
    (* MARK_DEBUG = "TRUE" *) wire ir_raw_level;
    (* MARK_DEBUG = "TRUE" *) wire revolution_start;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] last_interval_ticks;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] period_ticks;
    (* MARK_DEBUG = "TRUE" *) wire period_valid;
    (* MARK_DEBUG = "TRUE" *) wire period_update;
    (* MARK_DEBUG = "TRUE" *) wire [2:0] interval_count;
    (* MARK_DEBUG = "TRUE" *) wire [SLOT_LOG2-1:0] slice_index;
    (* MARK_DEBUG = "TRUE" *) wire slot_start;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] row_ticks;

    // (CLK_HZ/1_000_000) is done first so the product cannot overflow a 32-bit
    // integer parameter for any clock rate that is a whole number of MHz.
    localparam integer IR_DEBOUNCE_CYCLES = (CLK_HZ / 1_000_000) * IR_DEBOUNCE_US;
    localparam integer IR_HOLDOFF_CYCLES  = (CLK_HZ / 1_000_000) * IR_HOLDOFF_US;

    ir_revolution_sync #(
        .FALLING_EDGE(IR_FALLING_EDGE),
        .COUNTER_BITS(32),
        .DEBOUNCE_CYCLES(IR_DEBOUNCE_CYCLES),
        .HOLDOFF_CYCLES(IR_HOLDOFF_CYCLES)
    ) u_ir_revolution_sync (
        .clk(clk_in),
        .rst(reset_sync),
        .ir_in(ir_in),
        .ir_level(ir_level),
        .ir_raw_level(ir_raw_level),
        .revolution_start(revolution_start),
        .last_interval_ticks(last_interval_ticks),
        .period_ticks(period_ticks),
        .period_valid(period_valid),
        .period_update(period_update),
        .interval_count(interval_count)
    );

    // Rotational time base: one slot per (period/64), one row per (slot/32).
    // The scan engine below never decides when a slot starts.
    hub75_sched #(
        .CLK_HZ(CLK_HZ),
        .SLOT_LOG2(SLOT_LOG2),
        .ROW_LOG2(ROW_LOG2),
        .FALLBACK_RPM(FALLBACK_RPM)
    ) u_sched (
        .clk(clk_in),
        .rst(reset_sync),
        .revolution_start(revolution_start),
        .period_valid(period_valid),
        .period_ticks(period_ticks),
        .slice_index(slice_index),
        .row_ticks(row_ticks),
        .slot_start(slot_start)
    );

    reg [23:0] trigger_visible;
    reg [25:0] heartbeat;
    always @(posedge clk_in) begin
        if (reset_sync) begin trigger_visible<=0; heartbeat<=0; end
        else begin
            heartbeat <= (heartbeat == 49_999_999) ? 0 : heartbeat + 1'b1;
            if (revolution_start) trigger_visible<=5_000_000;
            else if (trigger_visible != 0) trigger_visible<=trigger_visible-1'b1;
        end
    end
    assign debug_led_n = ~{(heartbeat < 25_000_000), period_valid,
                           (trigger_visible != 0), ir_raw_level};
    ir_debug_uart u_debug_uart (
        .clk(clk_in), .rst(reset_sync), .update(period_update),
        .last_ticks(last_interval_ticks), .mean_ticks(period_ticks),
        .tx(debug_uart_tx)
    );

    hub75_scan #(
        .SLICE_BITS(SLOT_LOG2),
        .PATTERN_MODE(PATTERN_MODE),
        .RGB2_COLUMN_OFFSET(RGB2_COLUMN_OFFSET)
    ) u_scan (
        .clk(clk_in),
        .rst(reset_sync),
        .row_ticks(row_ticks),
        .slot_start(slot_start),
        .slice_index(slice_index),
        // PATTERN_MODE 0..2 ignores the slice-RAM interface; tie it off.
        .pix_data(6'b000000),
        .pix_addr(),
        .rgb1(rgb1),
        .rgb2(rgb2),
        .hub_clk(hub_clk),
        .hub_lat(hub_lat),
        .hub_oe_n(hub_oe_n),
        .hub_addr(hub_addr)
    );
endmodule