`timescale 1ns/1ps

// Stable-clock capture with fixed input conditioning. No outlier rejection,
// no timeout recovery and no adaptive filtering: every limit below is a fixed
// synthesis parameter.
//
// Conditioning chain: 2-FF synchroniser -> debounce -> hold-off -> edge select.
//   DEBOUNCE_CYCLES: the synchronised level must keep its new value for that
//                    many consecutive clk cycles before the change is
//                    accepted. Shorter pulses and contact chatter are dropped.
//   HOLDOFF_CYCLES : after an accepted change the input is ignored for that
//                    many clk cycles, so chatter that outlives the debounce
//                    window cannot turn one illumination into several edges.
// One physical illumination is expected to produce exactly one
// revolution_start. A pulse narrower than DEBOUNCE_CYCLES is discarded, so the
// illuminated pulse at maximum speed must stay wider than that window.
//
// Interval measurement uses the timestamp of the accepted EDGE, not of the
// acceptance, so the filter delay never enters period_ticks. The acceptance
// pulse itself is delayed by the filter, which is a constant phase offset for
// the scan scheduler and is calibrated there, not here.
//
// period_valid is asserted only after FIVE complete intervals (six triggers).
module ir_revolution_sync #(
    parameter integer FALLING_EDGE    = 0,      // 0: rising, 1: falling
    parameter integer COUNTER_BITS    = 32,
    parameter integer DEBOUNCE_CYCLES = 50_000, // 1 ms at 50 MHz
    parameter integer HOLDOFF_CYCLES  = 50_000  // 1 ms at 50 MHz, 0 disables
) (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    ir_in,
    output wire                    ir_level,
    output wire                    ir_raw_level,
    output wire                    revolution_start,
    output reg [COUNTER_BITS-1:0]   last_interval_ticks,
    output reg [COUNTER_BITS-1:0]   period_ticks,
    output reg                     period_valid,
    output reg                     period_update,
    output reg [2:0]                interval_count
);
    function integer bit_width;
        input integer value;
        integer remaining;
        begin
            remaining = value;
            bit_width = 1;
            while (remaining > 1) begin
                remaining = remaining >> 1;
                bit_width = bit_width + 1;
            end
        end
    endfunction

    localparam integer DEBOUNCE_WIDTH = bit_width((DEBOUNCE_CYCLES > 2) ? DEBOUNCE_CYCLES : 3);
    localparam integer HOLDOFF_WIDTH  = bit_width((HOLDOFF_CYCLES  > 2) ? HOLDOFF_CYCLES  : 3);
    localparam         IDLE_LEVEL     = (FALLING_EDGE != 0);

    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg ir_meta;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg ir_sync;
    reg [2:0] sync_ready;

    // Input conditioning state.
    reg                         seeded;
    reg                         db_level;
    reg                         db_pending;
    reg [DEBOUNCE_WIDTH-1:0]    db_count;
    reg                         holdoff;
    reg [HOLDOFF_WIDTH-1:0]     ho_count;
    reg [COUNTER_BITS-1:0]      edge_timestamp;
    reg                         accepted;
    reg                         accepted_level;

    // Measurement state.
    reg [COUNTER_BITS-1:0] timestamp;
    reg [COUNTER_BITS-1:0] previous_timestamp;
    reg have_reference;
    reg [COUNTER_BITS-1:0] history [0:4];
    reg [2:0] write_index;
    reg [COUNTER_BITS+2:0] interval_sum;
    reg average_pending;
    integer i;

    wire selected_edge = accepted && (FALLING_EDGE ? !accepted_level
                                                    :  accepted_level);
    wire [COUNTER_BITS-1:0] elapsed = edge_timestamp - previous_timestamp;
    wire [COUNTER_BITS+2:0] elapsed_wide = {{3{1'b0}}, elapsed};
    wire [COUNTER_BITS+2:0] oldest_wide = {{3{1'b0}}, history[write_index]};
    wire [COUNTER_BITS+2:0] next_sum = interval_sum + elapsed_wide
                         - ((interval_count == 5) ? oldest_wide : 0);
    assign ir_level = db_level;   // filtered: what the capture logic accepts
    assign ir_raw_level = ir_sync;// synchronised input, before any filtering
    // This pulse is in clk's domain. Never use it as a clock or async reset.
    assign revolution_start = !rst && (&sync_ready) && selected_edge;

    always @(posedge clk) begin
        if (rst) begin
            ir_meta <= IDLE_LEVEL;
            ir_sync <= IDLE_LEVEL;
            sync_ready <= 0;
            seeded <= 1'b0;
            db_level <= IDLE_LEVEL;
            db_pending <= 1'b0;
            db_count <= 0;
            holdoff <= 1'b0;
            ho_count <= 0;
            edge_timestamp <= 0;
            accepted <= 1'b0;
            accepted_level <= IDLE_LEVEL;
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
            sync_ready <= {sync_ready[1:0], 1'b1};
            timestamp <= timestamp + 1'b1;
            accepted <= 1'b0;
            period_update <= 0;
            average_pending <= 0;

            // Separate averaging from the capture/sum path. New estimate is
            // published one clk after its interval is recorded, rounded down.
            if (average_pending) begin
                period_ticks <= interval_sum / 5;
                period_valid <= 1;
                period_update <= 1;
            end

            // Adopt the real idle level after reset without inventing an edge,
            // so a held-active power-up input is not reported as a revolution.
            if (!seeded) begin
                if (&sync_ready) begin
                    db_level <= ir_sync;
                    db_pending <= 1'b0;
                    db_count <= 0;
                    holdoff <= 1'b0;
                    ho_count <= 0;
                    seeded <= 1'b1;
                end
            end else if (holdoff) begin
                if (ho_count + 1 >= HOLDOFF_CYCLES) begin
                    holdoff <= 1'b0;
                    ho_count <= 0;
                    db_level <= ir_sync; // silent re-seed: no edge inside hold-off
                    db_pending <= 1'b0;
                    db_count <= 0;
                end else begin
                    ho_count <= ho_count + 1'b1;
                end
            end else if (ir_sync != db_level) begin
                if (!db_pending) begin
                    db_pending <= 1'b1;
                    db_count <= 0;
                    edge_timestamp <= timestamp;
                end else if (db_count + 1 >= DEBOUNCE_CYCLES) begin
                    db_pending <= 1'b0;
                    db_count <= 0;
                    db_level <= ir_sync;
                    accepted <= 1'b1;
                    accepted_level <= ir_sync;
                    holdoff <= (HOLDOFF_CYCLES > 0);
                    ho_count <= 0;
                end else begin
                    db_count <= db_count + 1'b1;
                end
            end else begin
                db_pending <= 1'b0;
                db_count <= 0;
            end

            if (revolution_start) begin
                previous_timestamp <= edge_timestamp;
                have_reference <= 1'b1;
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
