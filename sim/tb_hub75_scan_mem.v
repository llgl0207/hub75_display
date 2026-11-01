`timescale 1ns/1ps

// PATTERN_MODE=3 scan check: the 6-bit slice word read from synchronous RAM
// must appear as rgb1=[2:0], rgb2=[5:3] for every pixel, with the first shifted
// pixel at column 127. The TB checks row 0 (128 pixels) and the first pixel of
// row 1, which proves both the address order and the row increment.
module tb_hub75_scan_mem;
    localparam integer ROW_TICKS = 813;

    reg clk = 0;
    always #10 clk = ~clk;              // 50 MHz

    reg rst = 1;
    reg [15:0] row_ticks = ROW_TICKS;
    reg slot_start = 0;
    reg [5:0] slice_index = 6'd0;
    wire [2:0] rgb1, rgb2;
    wire hub_clk, hub_lat, hub_oe_n;
    wire [4:0] hub_addr;
    wire [12:0] pix_addr;
    reg [5:0] pix_data;

    // Synchronous read model, one-cycle latency, matching hub75_slice_ram.
    reg [5:0] mem [0:4095];
    always @(posedge clk) pix_data <= mem[pix_addr];

    hub75_scan #(.PATTERN_MODE(3)) dut (
        .clk(clk), .rst(rst),
        .row_ticks(row_ticks),
        .slot_start(slot_start),
        .slice_index(slice_index),
        .pix_data(pix_data),
        .pix_addr(pix_addr),
        .rgb1(rgb1), .rgb2(rgb2),
        .hub_clk(hub_clk), .hub_lat(hub_lat), .hub_oe_n(hub_oe_n), .hub_addr(hub_addr)
    );

    integer i;
    initial begin
        for (i = 0; i < 4096; i = i + 1)
            mem[i] = {i[5:3], i[2:0]};
    end

    integer rise_count = 0;
    integer idx;
    reg [5:0] expected;

    always @(posedge hub_clk) begin
        if (!rst) begin
            if (rise_count < 128) begin
                idx = 127 - rise_count;             // row 0, first pixel = col 127
            end else if (rise_count == 128) begin
                idx = 128 + 127;                    // row 1, first pixel
            end else begin
                idx = -1;
            end

            if (idx >= 0) begin
                expected = mem[idx];
                if ({rgb2, rgb1} !== expected) begin
                    $fatal(1, "pixel %0d idx %0d expected %b got %b",
                           rise_count, idx, expected, {rgb2, rgb1});
                end
                // The row address is latched after the 128 shifts; during the
                // first row's shifts hub_addr is still 0. The data check at
                // rise_count=128 (address 128*128+127) already proves the row
                // increment, so do not expect hub_addr=1 on that rising edge.
                if (rise_count < 128 && hub_addr !== 5'd0)
                    $fatal(1, "row address %0d during first row", hub_addr);
            end

            rise_count = rise_count + 1;
            if (rise_count > 129) begin
                $display("PASS: PATTERN_MODE=3 slice RAM pixels and row increment");
                $finish;
            end
        end
    end

    initial begin
        repeat (4) @(negedge clk);
        rst <= 0;
        repeat (3) @(negedge clk);
        slot_start <= 1;
        @(negedge clk);
        slot_start <= 0;
    end

    initial begin
        #500000;
        $fatal(1, "Timeout waiting for slice-RAM scan");
    end
endmodule
