`timescale 1ns/1ps

// PS-integrated HUB75 top. This is the hub75_top scan/IR/scheduler core plus the
// pixel-RAM interface and the scheduler observability ports the DDR reader and
// AXI status block need. The PL-only hub75_top stays untouched so the verified
// JTAG board-test build is unaffected.
//
// PATTERN_MODE=3: hub75_scan reads a 6-bit slice word from the external slice
// RAM. [2:0] = rgb1 (upper half), [5:3] = rgb2 (lower half). The PS renderer
// pre-shifts rgb2 if the panel wiring needs a column offset.
module hub75_ps_top #(
    parameter integer CLK_HZ = 50_000_000, // must be a multiple of 1 MHz
    parameter integer IR_FALLING_EDGE = 0,
    parameter integer IR_DEBOUNCE_US = 1000,
    parameter integer IR_HOLDOFF_US  = 1000,
    parameter integer SLOT_LOG2    = 6,
    parameter integer ROW_LOG2     = 5,
    parameter integer FALLBACK_RPM = 1800,
    parameter integer PATTERN_MODE = 3,
    parameter integer RGB2_COLUMN_OFFSET = 0
) (
    input  wire       clk_in,
    input  wire       reset_n,
    input  wire       ir_in,
    // Slice RAM read port (BRAM output is one cycle behind pix_addr).
    input  wire [5:0]  pix_data,
    output wire [12:0] pix_addr,
    // Scheduler observations for the DDR reader and AXI status block.
    output wire [SLOT_LOG2-1:0] slice_index,
    output wire       slot_start,
    output wire       revolution_start,
    output wire [31:0] period_ticks,
    output wire       period_valid,
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

    (* MARK_DEBUG = "TRUE" *) wire ir_level;
    (* MARK_DEBUG = "TRUE" *) wire ir_raw_level;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] last_interval_ticks;
    (* MARK_DEBUG = "TRUE" *) wire period_update;
    (* MARK_DEBUG = "TRUE" *) wire [2:0] interval_count;
    (* MARK_DEBUG = "TRUE" *) wire [15:0] row_ticks;

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
        .pix_data(pix_data),
        .pix_addr(pix_addr),
        .rgb1(rgb1),
        .rgb2(rgb2),
        .hub_clk(hub_clk),
        .hub_lat(hub_lat),
        .hub_oe_n(hub_oe_n),
        .hub_addr(hub_addr)
    );
endmodule
