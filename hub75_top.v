`timescale 1ns/1ps

module hub75_top #(
    parameter integer FIELD_HZ = 2280,
    // 0: rising edge (current default); 1: falling edge. Rebuild after change.
    parameter integer IR_FALLING_EDGE = 0
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
    // Static scan below intentionally does not yet consume rotational timing.
    (* MARK_DEBUG = "TRUE" *) wire ir_level;
    (* MARK_DEBUG = "TRUE" *) wire revolution_start;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] last_interval_ticks;
    (* MARK_DEBUG = "TRUE" *) wire [31:0] period_ticks;
    (* MARK_DEBUG = "TRUE" *) wire period_valid;
    (* MARK_DEBUG = "TRUE" *) wire period_update;
    (* MARK_DEBUG = "TRUE" *) wire [2:0] interval_count;

    ir_revolution_sync #(
        .FALLING_EDGE(IR_FALLING_EDGE),
        .COUNTER_BITS(32)
    ) u_ir_revolution_sync (
        .clk(clk_in),
        .rst(reset_sync),
        .ir_in(ir_in),
        .ir_level(ir_level),
        .revolution_start(revolution_start),
        .last_interval_ticks(last_interval_ticks),
        .period_ticks(period_ticks),
        .period_valid(period_valid),
        .period_update(period_update),
        .interval_count(interval_count)
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
                           (trigger_visible != 0), ir_level};
    ir_debug_uart u_debug_uart (
        .clk(clk_in), .rst(reset_sync), .update(period_update),
        .last_ticks(last_interval_ticks), .mean_ticks(period_ticks),
        .tx(debug_uart_tx)
    );

    hub75_scan #(
        .CLK_HZ(50_000_000),
        .FIELD_HZ(FIELD_HZ)
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
