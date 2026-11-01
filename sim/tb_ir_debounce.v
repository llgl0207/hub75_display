`timescale 1ns/1ps
// Input conditioning checks for ir_revolution_sync: one physical illumination
// must produce exactly one revolution_start, and the filter delay must not
// enter the period estimate.
//
// DEBOUNCE_CYCLES/HOLDOFF_CYCLES are scaled down from the 1 ms board values so
// the test runs quickly; the mechanism under test is identical at 50_000.
module tb_ir_debounce;
    localparam integer DB = 8;  // scaled stand-in for 1 ms at 50 MHz
    localparam integer HO = 8;  // scaled stand-in for 1 ms at 50 MHz

    reg clk = 0;
    reg rst = 1;
    reg ir_in = 0;
    always #5 clk = ~clk;

    wire        start, valid, update, level, raw_level;
    wire [15:0] last_ticks, period;
    wire [2:0]  count;
    integer     starts = 0;
    integer     base;
    integer     i;
    reg         raw_seen_high = 0;

    ir_revolution_sync #(
        .FALLING_EDGE(0), .COUNTER_BITS(16),
        .DEBOUNCE_CYCLES(DB), .HOLDOFF_CYCLES(HO)
    ) dut (
        .clk(clk), .rst(rst), .ir_in(ir_in), .ir_level(level),
        .ir_raw_level(raw_level),
        .revolution_start(start), .last_interval_ticks(last_ticks),
        .period_ticks(period), .period_valid(valid),
        .period_update(update), .interval_count(count)
    );
    always @(posedge clk) if (start) starts = starts + 1;
    always @(posedge clk) if (raw_level) raw_seen_high = 1;

    // Second instance: narrow debounce window but a wide hold-off, so a second
    // arrival can be placed unambiguously inside the hold-off window.
    reg  rst2 = 1;
    reg  ir_in2 = 1;
    wire start2, valid2, update2, level2;
    wire [15:0] last2, period2;
    wire [2:0]  count2;
    integer     starts2 = 0;

    ir_revolution_sync #(
        .FALLING_EDGE(1), .COUNTER_BITS(16),
        .DEBOUNCE_CYCLES(4), .HOLDOFF_CYCLES(40)
    ) dut2 (
        .clk(clk), .rst(rst2), .ir_in(ir_in2), .ir_level(level2),
        .revolution_start(start2), .last_interval_ticks(last2),
        .period_ticks(period2), .period_valid(valid2),
        .period_update(update2), .interval_count(count2)
    );
    always @(posedge clk) if (start2) starts2 = starts2 + 1;

    task tick(input integer n);
        begin repeat (n) @(negedge clk); end
    endtask

    initial begin
        tick(10);
        rst = 0;
        tick(10);
        if (starts != 0 || level != 0) $fatal(1, "Spurious event after reset release");

        // A) Contact chatter on the leading edge must never reach the filter.
        for (i = 0; i < 12; i = i + 1) begin
            ir_in = 1; tick(1 + (i % 3));
            ir_in = 0; tick(1);
            if (level != 0) $fatal(1, "Chatter reached the accepted level at glitch %0d", i);
        end
        if (starts != 0) $fatal(1, "Glitch train produced a revolution_start");
        // The chatter must be visible on the raw input but invisible to the filter.
        if (!raw_seen_high) $fatal(1, "Raw input never carried the chatter stimulus");

        // One solid illumination is accepted exactly once.
        ir_in = 1; tick(DB + 8);
        if (level != 1 || starts != 1)
            $fatal(1, "Clean pulse not accepted once: level %0d starts %0d", level, starts);
        tick(40);
        if (starts != 1) $fatal(1, "One illumination produced %0d triggers", starts);

        // B) A dropout shorter than the window must not split the pulse.
        ir_in = 0; tick(2); ir_in = 1; tick(20);
        if (starts != 1) $fatal(1, "Short dropout created a second trigger");
        if (level != 1) $fatal(1, "Short dropout dropped the accepted level");
        ir_in = 0; tick(30);
        if (starts != 1 || level != 0) $fatal(1, "Falling edge mishandled");

        // C) A pulse narrower than the window is discarded by design.
        tick(20);
        ir_in = 1; tick(DB - 3); ir_in = 0; tick(30);
        if (starts != 1) $fatal(1, "Under-width pulse was accepted");
        if (level != 0) $fatal(1, "Under-width pulse raised the accepted level");

        // D) Seven identical illuminations: one trigger each and an unchanged
        //    period, because the timestamp is taken at the edge itself.
        rst = 1; tick(4);
        ir_in = 0; rst = 0; tick(10);
        base = starts;
        for (i = 0; i < 7; i = i + 1) begin
            ir_in = 1; tick(20);
            ir_in = 0; tick(80);
        end
        tick(10);
        if (starts - base != 7) $fatal(1, "Expected 7 triggers, saw %0d", starts - base);
        if (!valid || count != 5)
            $fatal(1, "Period estimate invalid: valid %0d count %0d", valid, count);
        if (last_ticks != 100 || period != 100)
            $fatal(1, "Filter delay corrupted the period: last %0d mean %0d", last_ticks, period);

        // E) Hold-off: an arrival inside the window is swallowed, one after the
        //    window is not (active-low instance, 40-cycle window).
        ir_in2 = 1; tick(6);
        rst2 = 0; tick(12);
        base = starts2;
        ir_in2 = 0; tick(10);   // illumination 1 -> trigger
        ir_in2 = 1; tick(10);   // release inside the hold-off window
        ir_in2 = 0; tick(5);    // bounce attempt, still inside the window
        ir_in2 = 1; tick(60);   // back to idle, window expires
        if (starts2 - base != 1)
            $fatal(1, "Hold-off window produced %0d triggers", starts2 - base);
        ir_in2 = 0; tick(10);   // illumination 2, outside the window
        ir_in2 = 1; tick(60);
        if (starts2 - base != 2)
            $fatal(1, "Illumination after the window was lost: %0d", starts2 - base);

        // F) Releasing reset with the input held active must not invent an edge.
        rst = 1; tick(4);
        ir_in = 1;
        base = starts;
        rst = 0; tick(20);
        if (starts != base) $fatal(1, "Held-active input invented a trigger after reset");
        if (level != 1) $fatal(1, "Filter did not adopt the held-active level");

        $display("PASS: debounce, hold-off, width rejection, period accuracy, reset seeding");
        $finish;
    end

    initial begin #2_000_000; $fatal(1, "Timeout"); end
endmodule
