`timescale 1ns/1ps

// Scheduler checks: power-of-two slot/row derivation, revolution anchoring,
// period latching, and the documented clamps.
//
// Two instances are used so the arithmetic can be observed with small numbers
// while the real MIN_ROW_TICKS clamp is verified separately.
module tb_hub75_sched;
    reg clk = 0;
    reg rst = 1;
    always #10 clk = ~clk;

    // ---------------- instance A: shift arithmetic ----------------
    // MIN_ROW_TICKS is deliberately below the production floor so the shift
    // arithmetic can be exercised with small, fast numbers; CHECK_PARAMS is
    // disabled for this instance only, the floor itself is covered by B.
    reg         rev_a = 0;
    reg         valid_a = 0;
    reg  [31:0] period_a = 0;
    wire [5:0]  slice_a;
    wire [15:0] row_a;
    wire        slot_a;

    hub75_sched #(
        .CLK_HZ(1_000_000), .SLOT_LOG2(6), .ROW_LOG2(5),
        .FALLBACK_RPM(1800), .MIN_ROW_TICKS(8), .CHECK_PARAMS(0)
    ) dut_a (
        .clk(clk), .rst(rst), .revolution_start(rev_a),
        .period_valid(valid_a), .period_ticks(period_a),
        .slice_index(slice_a), .row_ticks(row_a), .slot_start(slot_a)
    );

    // ---------------- instance B: clamps ----------------
    reg         rev_b = 0;
    reg         valid_b = 0;
    reg  [31:0] period_b = 0;
    wire [5:0]  slice_b;
    wire [15:0] row_b;
    wire        slot_b;

    hub75_sched #(
        .CLK_HZ(1_000_000), .SLOT_LOG2(6), .ROW_LOG2(5),
        .FALLBACK_RPM(1800), .MIN_ROW_TICKS(700)
    ) dut_b (
        .clk(clk), .rst(rst), .revolution_start(rev_b),
        .period_valid(valid_b), .period_ticks(period_b),
        .slice_index(slice_b), .row_ticks(row_b), .slot_start(slot_b)
    );

    integer cyc_a = 0, slot_len_a = 0;
    integer cyc_b = 0, slot_len_b = 0;
    always @(posedge clk) begin
        cyc_a = cyc_a + 1;
        if (slot_a) begin slot_len_a = cyc_a; cyc_a = 0; end
        cyc_b = cyc_b + 1;
        if (slot_b) begin slot_len_b = cyc_b; cyc_b = 0; end
    end

    // 1 MHz clock: the 1800 RPM fallback period is 1e6/30 = 33,333 cycles,
    // giving slot_cycles = 520 and row_ticks = 16.
    localparam integer FB_SLOT = 33333 >> 6;   // 520
    localparam integer FB_ROW  = FB_SLOT >> 5; // 16

    task pulse_rev_a; begin
        @(negedge clk); rev_a = 1'b1;
        @(negedge clk); rev_a = 1'b0;
    end endtask
    task pulse_rev_b; begin
        @(negedge clk); rev_b = 1'b1;
        @(negedge clk); rev_b = 1'b0;
    end endtask
    task wait_slot_a; begin
        @(negedge clk);
        while (!slot_a) @(negedge clk);
        // slot_a is a registered one-cycle pulse and the measuring block below
        // samples it one clock later. Wait past that edge and settle, otherwise
        // the previous interval is still readable.
        @(posedge clk); #1;
    end endtask
    task wait_slot_b; begin
        @(negedge clk);
        while (!slot_b) @(negedge clk);
        @(posedge clk); #1;
    end endtask

    integer i;
    integer pulses;
    initial begin
        repeat (4) @(negedge clk);
        rst = 0;
        @(negedge clk);

        // A) fallback rate before any valid estimate.
        wait_slot_a();
        if (row_a !== FB_ROW[15:0]) $fatal(1, "Fallback row_ticks %0d, expected %0d", row_a, FB_ROW);
        wait_slot_a();
        if (slot_len_a !== FB_SLOT) $fatal(1, "Fallback slot %0d cycles, expected %0d", slot_len_a, FB_SLOT);

        // B) a 64,000-cycle revolution must give slot 1,000 and row 31.
        period_a = 32'd64000; valid_a = 1;
        pulse_rev_a();
        repeat (3) @(negedge clk);
        if (slice_a !== 6'd0) $fatal(1, "Slice did not reset to 0 at the trigger");
        if (row_a !== 16'd31) $fatal(1, "row_ticks %0d, expected 31 (64000>>11)", row_a);
        wait_slot_a();
        if (slot_len_a !== 1000) $fatal(1, "Slot %0d cycles, expected 1000", slot_len_a);

        // C) exactly 64 slots per revolution, slice index 0..63 then wrap.
        //    The trigger started slice 0 and the wait above consumed slice 1,
        //    so 62 more boundaries reach slice 63.
        for (i = 2; i < 64; i = i + 1) begin
            wait_slot_a();
            if (slice_a !== i[5:0])
                $fatal(1, "Slice %0d out of sequence, expected %0d", slice_a, i);
        end
        wait_slot_a();
        if (slice_a !== 6'd0) $fatal(1, "Slice counter did not wrap to 0 after 64 slots");

        // D) a trigger inside a revolution drops straight back to slice 0.
        wait_slot_a();
        if (slice_a !== 6'd1) $fatal(1, "Expected slice 1 before the mid-revolution trigger");
        pulse_rev_a();
        repeat (2) @(negedge clk);
        if (slice_a !== 6'd0) $fatal(1, "Trigger did not reset the slice index immediately");
        wait_slot_a();
        if (slot_len_a > 1000) $fatal(1, "Trigger did not restart the slot timer");

        // E) a held-valid but zero period must fall back instead of running free.
        period_a = 32'd0;
        pulse_rev_a();
        repeat (3) @(negedge clk);
        if (row_a !== FB_ROW[15:0]) $fatal(1, "Zero period did not fall back: row %0d", row_a);

        // F) clamps on instance B: 12,800 cycles would need 6 row cycles.
        period_b = 32'd12800; valid_b = 1;
        pulse_rev_b();
        repeat (3) @(negedge clk);
        if (row_b !== 16'd700) $fatal(1, "MIN clamp missing: row %0d", row_b);
        // The trigger closed a partial interval; the next boundary is the first
        // full slot under the clamped budget.
        wait_slot_b();
        if (slot_len_b !== 200) $fatal(1, "Slot %0d cycles, expected 200", slot_len_b);

        // G) maximum period must clamp at the 16-bit row budget.
        period_b = 32'hFFFFFFFF;
        pulse_rev_b();
        repeat (3) @(negedge clk);
        if (row_b !== 16'd65535) $fatal(1, "MAX clamp missing: row %0d", row_b);

        // H) invalid estimate again: fallback 16 cycles still clamps to 700.
        valid_b = 0;
        pulse_rev_b();
        repeat (3) @(negedge clk);
        if (row_b !== 16'd700) $fatal(1, "Fallback not clamped on instance B: row %0d", row_b);

        $display("PASS: 64 slots per revolution, trigger anchor, period latching, clamps, fallback");
        $finish;
    end

    initial begin #5_000_000; $fatal(1, "Timeout"); end
endmodule