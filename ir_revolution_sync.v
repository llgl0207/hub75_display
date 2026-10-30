`timescale 1ns/1ps

// Stable-clock capture only: no debounce, outlier rejection or timeout recovery.
// period_valid is asserted only after FIVE complete intervals (six triggers).
// Consumers decide how to operate before then; no startup speed is invented here.
module ir_revolution_sync #(
    parameter integer FALLING_EDGE = 0, // 0: rising, 1: falling
    parameter integer COUNTER_BITS = 32
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    ir_in,
    output wire                    ir_level,
    output wire                    revolution_start,
    output reg [COUNTER_BITS-1:0]   last_interval_ticks,
    output reg [COUNTER_BITS-1:0]   period_ticks,
    output reg                     period_valid,
    output reg                     period_update,
    output reg [2:0]                interval_count
);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg ir_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg ir_sync;
    reg ir_previous;
    reg [2:0] sync_ready;
    reg [COUNTER_BITS-1:0] timestamp;
    reg [COUNTER_BITS-1:0] previous_timestamp;
    reg have_reference;
    reg [COUNTER_BITS-1:0] history [0:4];
    reg [2:0] write_index;
    reg [COUNTER_BITS+2:0] interval_sum;
    reg average_pending;
    integer i;

    wire selected_edge = FALLING_EDGE ? (ir_previous && !ir_sync)
                                      : (!ir_previous && ir_sync);
    wire [COUNTER_BITS-1:0] elapsed = timestamp - previous_timestamp;
    wire [COUNTER_BITS+2:0] elapsed_wide = {{3{1'b0}}, elapsed};
    wire [COUNTER_BITS+2:0] oldest_wide = {{3{1'b0}}, history[write_index]};
    wire [COUNTER_BITS+2:0] next_sum = interval_sum + elapsed_wide
                         - ((interval_count == 5) ? oldest_wide : 0);
    assign ir_level = ir_sync;
    // This pulse is in clk's domain. Never use it as a clock or async reset.
    assign revolution_start = !rst && (&sync_ready) && selected_edge;

    always @(posedge clk) begin
        if (rst) begin
            ir_meta <= (FALLING_EDGE != 0);
            ir_sync <= (FALLING_EDGE != 0);
            ir_previous <= (FALLING_EDGE != 0);
            sync_ready <= 0;
            timestamp <= 0;
            previous_timestamp <= 0;
            have_reference <= 0;
            last_interval_ticks <= 0;
            interval_sum <= 0;
            write_index <= 0;
            interval_count <= 0;
            period_ticks <= 0;
            period_valid <= 0;
            period_update <= 0;
            average_pending <= 0;
            for (i=0; i<5; i=i+1) history[i] <= 0;
        end else begin
            ir_meta <= ir_in;
            ir_sync <= ir_meta;
            ir_previous <= ir_sync;
            sync_ready <= {sync_ready[1:0], 1'b1};
            timestamp <= timestamp + 1'b1;
            period_update <= 0;
            average_pending <= 0;
            // Separate averaging from the capture/sum path. New estimate is
            // published one clk after its interval is recorded, rounded down.
            if (average_pending) begin
                period_ticks <= interval_sum / 5;
                period_valid <= 1;
                period_update <= 1;
            end
            if (revolution_start) begin
                previous_timestamp <= timestamp;
                have_reference <= 1;
                if (have_reference) begin
                    last_interval_ticks <= elapsed;
                    history[write_index] <= elapsed;
                    write_index <= (write_index == 4) ? 0 : write_index + 1'b1;
                    interval_sum <= next_sum;
                    if (interval_count < 5) interval_count <= interval_count + 1'b1;
                    if (interval_count >= 4) average_pending <= 1;
                end
            end
        end
    end
endmodule
