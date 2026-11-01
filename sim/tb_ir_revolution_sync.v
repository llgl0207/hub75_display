`timescale 1ns/1ps
module tb_ir_revolution_sync;
    reg clk=0, rst=1, ir_in=1;
    wire start, valid, update;
    wire [15:0] last_ticks, period;
    wire [2:0] count;
    integer starts=0;
    integer updates=0;
    always #5 clk=~clk;
    // Legacy active-low stimulus tests falling-edge override; mirrored input
    // simultaneously tests the default rising-edge implementation.
    wire rising_start, rising_valid, rising_update;
    wire [15:0] rising_last, rising_period;
    wire [2:0] rising_count;
    // Legacy measurement test: the input conditioning windows are scaled down
    // to one clock so this stimulus (four-clock pulses) is still accepted.
    // Debounce/hold-off behaviour at realistic widths is covered by
    // tb_ir_debounce.v.
    ir_revolution_sync #(.COUNTER_BITS(16), .DEBOUNCE_CYCLES(1), .HOLDOFF_CYCLES(1)) rising_dut (
        .clk(clk), .rst(rst), .ir_in(~ir_in), .ir_level(),
        .revolution_start(rising_start), .last_interval_ticks(rising_last),
        .period_ticks(rising_period), .period_valid(rising_valid),
        .period_update(rising_update), .interval_count(rising_count)
    );
    always @(negedge clk) begin
        #1;
        if ({start, valid, update, last_ticks, period, count} !==
            {rising_start, rising_valid, rising_update, rising_last, rising_period, rising_count})
            $fatal(1,"Rising/falling polarity mismatch");
    end
    ir_revolution_sync #(.FALLING_EDGE(1), .COUNTER_BITS(16),
                         .DEBOUNCE_CYCLES(1), .HOLDOFF_CYCLES(1)) dut (
        .clk(clk), .rst(rst), .ir_in(ir_in), .ir_level(),
        .revolution_start(start), .last_interval_ticks(last_ticks),
        .period_ticks(period), .period_valid(valid),
        .period_update(update), .interval_count(count)
    );
    always @(posedge clk) if (start) starts=starts+1;
    always @(negedge clk) if (update) updates=updates+1;

    // Enter/leave at falling-edge stimulus time, with input active low.
    // Each call places the next falling IR edge exactly ticks clocks later.
    task next_edge;
        input integer ticks;
        begin
            repeat(4) @(negedge clk);
            ir_in=1;
            repeat(ticks-4) @(negedge clk);
            ir_in=0;
        end
    endtask
    task settle;
        begin repeat(8) @(negedge clk); end
    endtask

    initial begin
        repeat(4) @(negedge clk);
        rst=0;
        settle();
        if (starts != 0 || valid) $fatal(1,"Spurious startup event");
        ir_in=0;
        next_edge(100);
        next_edge(200);
        next_edge(300);
        next_edge(400);
        // Fourth interval: no five-sample estimate yet.
        settle();
        if (valid || count != 4) $fatal(1,"Early period validity");
        // settle already consumed eight clocks from the last edge.
        repeat(4) @(negedge clk); ir_in=1;
        repeat(488) @(negedge clk); ir_in=0;
        settle();
        if (!valid || count != 5 || period != 300 || last_ticks != 500)
            $fatal(1,"Initial average failed: %0d last %0d",period,last_ticks);
        repeat(4) @(negedge clk); ir_in=1;
        repeat(588) @(negedge clk); ir_in=0;
        settle();
        if (period != 400 || last_ticks != 600 || starts != 7 || updates != 2)
            $fatal(1,"Rolling eviction failed: period %0d starts %0d updates %0d",period,starts,updates);
        // Counter wraps during the next interval; modular subtraction holds.
        repeat(4) @(negedge clk); ir_in=1;
        repeat(64988) @(negedge clk); ir_in=0;
        settle();
        if (last_ticks != 65000 || period != 13360)
            $fatal(1,"Counter wrap/extended sum failed: %0d %0d",last_ticks,period);
        rst=1;
        settle();
        if (valid || count != 0 || start) $fatal(1,"Reset failed");
        // Held-active input on release must not invent an edge.
        rst=0;
        settle();
        if (start || count != 0) $fatal(1,"Held-active startup failed");
        $display("PASS: five-interval warmup, rolling eviction, counter wrap, reset");
        $finish;
    end
    initial begin #2_000_000; $fatal(1,"Timeout"); end
endmodule
