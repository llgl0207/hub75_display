`timescale 1ns/1ps

module tb_hub75_scan;
    reg clk = 0;
    reg rst = 1;
    wire [2:0] rgb1, rgb2;
    wire hub_clk, hub_lat, hub_oe_n;
    wire [4:0] hub_addr;
    integer rising_clks = 0;
    integer latches = 0;

    always #5 clk = ~clk;

    hub75_scan #(
        .CLK_HZ(50_000_000),
        .START_RATE_INDEX(0),
        .AUTO_TEST(0),
        .HOLD_SECONDS(1)
    ) dut (
        .clk(clk), .rst(rst), .rgb1(rgb1), .rgb2(rgb2),
        .hub_clk(hub_clk), .hub_lat(hub_lat), .hub_oe_n(hub_oe_n), .hub_addr(hub_addr)
    );

    always @(posedge hub_clk) begin
        if (!hub_oe_n) $fatal(1, "OE must be inactive while shifting");
        rising_clks = rising_clks + 1;
    end

    always @(posedge hub_lat) begin
        if (!hub_oe_n) $fatal(1, "OE must be inactive at latch");
        if (rising_clks != 128) $fatal(1, "Expected 128 shift clocks, got %0d", rising_clks);
        if (hub_addr !== latches[4:0]) $fatal(1, "Unexpected row address %0d", hub_addr);
        rising_clks = 0;
        latches = latches + 1;
        if (latches == 32) begin
            $display("PASS: 32 rows latched, 128 pixel clocks per row");
            $finish;
        end
    end

    initial begin
        repeat (5) @(negedge clk);
        rst = 0;
        #10_000_000;
        $fatal(1, "Timeout waiting for test completion");
    end
endmodule
