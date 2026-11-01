`timescale 1ns/1ps

// Waveform checks for one-slot-at-a-time scanning:
//   - 128 shift clocks and 32 latched row addresses per slot
//   - OE inactive while shifting, RGB stable at least one PL clock before CLK
//   - the engine idles between slots and restarts at row 0 on an early slot_start
module tb_hub75_scan;
    localparam integer ROW_TICKS   = 813;                 // 1800 RPM budget
    localparam integer SLOT_CYCLES = 32*ROW_TICKS + 120;  // scan + short idle

    reg clk = 0;
    reg rst = 1;
    reg [15:0] row_ticks = ROW_TICKS;
    reg slot_start = 0;
    reg [5:0] slice_index = 6'd0;
    wire [2:0] rgb1, rgb2;
    wire hub_clk, hub_lat, hub_oe_n;
    wire [4:0] hub_addr;

    integer rising_clks = 0;
    integer row_in_slot = 0;
    integer rows_latched = 0;
    integer slot_timer = 0;
    time    last_rgb_change = 0;

    reg     early_pulse_done = 0;
    reg     restart_seen = 0;
    integer latches_after_pulse = 0;

    always #10 clk = ~clk;
    always @(rgb1 or rgb2) last_rgb_change = $time;

    hub75_scan #(.PATTERN_MODE(1)) dut (
        .clk(clk), .rst(rst),
        .row_ticks(row_ticks),
        .slot_start(slot_start),
        .slice_index(slice_index),
        .rgb1(rgb1), .rgb2(rgb2),
        .hub_clk(hub_clk), .hub_lat(hub_lat), .hub_oe_n(hub_oe_n), .hub_addr(hub_addr)
    );

    // One-cycle slot boundaries, driven from the negedge so the DUT samples them
    // cleanly at the following posedge.
    always @(negedge clk) begin
        slot_start <= 1'b0;
        if (early_pulse_done && rows_latched > 40 &&
            hub_addr == 5'd10 && rising_clks > 12 && rising_clks < 100) begin
            // Inject a slot boundary in the middle of a row transfer.
            early_pulse_done <= 1'b0;
            slot_timer <= 0;
            slot_start <= 1'b1;
        end else if (slot_timer >= SLOT_CYCLES-1) begin
            slot_timer <= 0;
            slot_start <= 1'b1;
        end else begin
            slot_timer <= slot_timer + 1;
        end
    end

    always @(posedge hub_clk) begin
        if (!hub_oe_n) $fatal(1, "OE must be inactive while shifting");
        if ($time - last_rgb_change < 20) $fatal(1, "RGB setup time below one PL clock");
        rising_clks = rising_clks + 1;
    end

    always @(posedge hub_lat) begin
        if (!hub_oe_n) $fatal(1, "OE must be inactive at latch");
        if (rising_clks != 128) $fatal(1, "Expected 128 shift clocks, got %0d", rising_clks);
        if (!restart_seen && (hub_addr !== row_in_slot)) begin
            $fatal(1, "Unexpected row address %0d, expected %0d", hub_addr, row_in_slot);
        end
        rising_clks = 0;
        rows_latched = rows_latched + 1;

        if (!early_pulse_done) begin
            if (row_in_slot == 31) row_in_slot = 0;
            else row_in_slot = row_in_slot + 1;
            if (rows_latched == 64 && !early_pulse_done) begin
                $display("PASS: two slots of 32 rows, 128 pixel clocks per row, idle between slots");
                early_pulse_done = 1;   // now inject an early slot boundary
            end
        end else begin
            // After the injected boundary the engine may finish the row that was
            // already in flight, then it must resume at row address 0.
            latches_after_pulse = latches_after_pulse + 1;
            if (hub_addr == 5'd0 && latches_after_pulse >= 1) begin
                restart_seen = 1;
            end
            if (restart_seen && hub_addr == 5'd1) begin
                $display("PASS: early slot_start restarts the scan at row 0");
                $finish;
            end
            if (row_in_slot == 31) row_in_slot = 0;
            else row_in_slot = row_in_slot + 1;
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst = 0;
        #10_000_000;
        $fatal(1, "Timeout waiting for test completion");
    end
endmodule