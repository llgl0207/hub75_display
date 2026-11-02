`timescale 1ns/1ps

// Autonomous DDR slice reader for the rotating HUB75 display.
//
// The PS renders complete slices into a DDR frame buffer. This module owns the
// real-time read side: it prefetches one 3072-byte slice per display slot from
// the frame base, unpacks the packed 6-bit pixels and writes the inactive
// ping-pong buffer. The scan reads the active buffer; the buffer select only
// changes at a slot boundary when the other buffer already holds the requested
// slice and frame epoch.
//
// Frame handoff:
//   - The PS writes frame_base, reads it back, then toggles submit.
//   - The new base is latched as pending_base; it becomes active only at
//     revolution_start. The PL never changes the base inside a revolution.
//   - Every slot unconditionally prefetches the slice needed by the NEXT slot
//     (slice_index+1, or slice 0 at the last slot) into the buffer the scan is
//     not reading. At the next slot_start the scan switches to that buffer.
//   - At the last slot of a revolution with a pending frame, the fetch targets
//     slice 0 of the pending base so the next revolution starts seamlessly.
//   - frame_ack / frame_done_toggle change together at the base switch; the PS
//     may reuse the old buffer after seeing the toggle.
//
// Do not make the prefetch target conditional on the current slice already
// being present. That deadlocks the start-up: the first fetch fills the current
// slice, no buffer ever holds the upcoming slice, read_buf never leaves its
// initial buffer and the scan reads an empty BRAM (black panel, buf_ready=0).
//
// AXI: one outstanding AXI3 read burst at a time, 16 x 64-bit beats (128 B),
// 24 bursts = 3072 B. A 16-deep beat FIFO absorbs the burst; the unpacker emits
// one 6-bit word per clock. At 50 MHz a slice takes roughly 100 us, far below
// the 521 us slot at 1800 RPM.
module hub75_ddr_reader #(
    parameter integer SLICE_BITS  = 6,
    parameter integer SLICE_BYTES = 3072,
    parameter integer BURST_BEATS = 16,
    parameter integer BURSTS      = 24,
    // Bench bring-up: without live IR, accept a frame at the scheduler's
    // fallback wrap (slice_index 0). The fallback is suppressed only while the
    // IR input is actually alive (an edge within IR_TIMEOUT_CYCLES), so a
    // floating input during boot cannot disable frame latching for the session.
    parameter integer BENCH_FALLBACK = 1,
    parameter integer IR_TIMEOUT_CYCLES = 10_000_000,  // 200 ms at 50 MHz
    // Only the frame BRAM is mapped on the PL's GP0 interconnect. A submit
    // with any other base (0 at boot, or a stale value when the two AXI GPIO
    // channels arrive out of order) would make the reader issue an AXI read
    // to an unmapped address, which wedges the GP0 fabric and stalls the PS
    // until the watchdog resets it. Reject such submits instead.
    parameter [31:0] FRAME_BASE_MIN = 32'h4200_0000,
    parameter [31:0] FRAME_BASE_MAX = 32'h4207_FFFF
) (
    input  wire                   clk,
    input  wire                   rst,          // active high, synchronized to clk
    input  wire                   enable,
    input  wire [31:0]            frame_base,
    input  wire                   submit_toggle,
    input  wire [SLICE_BITS-1:0]  slice_index,
    input  wire                   slot_start,
    input  wire                   revolution_start,
    // Slice RAM write port (inactive buffer)
    output reg                    wr_en,
    output wire                   wr_buf,
    output reg  [11:0]            wr_addr,
    output reg  [5:0]             wr_data,
    // Status
    output wire [SLICE_BITS-1:0]  active_slice,
    output reg                    reader_busy,
    output reg                    frame_ack,
    output reg                    frame_done_toggle,
    output reg  [7:0]             frame_id,
    output wire                   buf_ready,
    output wire                   rd_buf,       // buffer the scan is reading
    // Debug observability (status GPIO spare bits)
    output wire                   ir_active,
    output reg                    pending_valid,
    output reg                    active_valid,
    output reg  [5:0]             bench_count,   // synthetic revolutions (mod 64)
    // AXI3 read master (S_AXI_HP0: 64-bit data, 32-bit address, 6-bit ID)
    output reg  [31:0]            m_axi_araddr,
    output reg  [3:0]             m_axi_arlen,
    output reg  [2:0]             m_axi_arsize,
    output reg  [1:0]             m_axi_arburst,
    output reg  [1:0]             m_axi_arlock,
    output reg  [3:0]             m_axi_arcache,
    output reg  [2:0]             m_axi_arprot,
    output reg  [5:0]             m_axi_arid,
    output reg                    m_axi_arvalid,
    input  wire                   m_axi_arready,
    input  wire [63:0]            m_axi_rdata,
    input  wire [1:0]             m_axi_rresp,
    input  wire                   m_axi_rlast,
    input  wire [5:0]             m_axi_rid,
    input  wire                   m_axi_rvalid,
    output reg                    m_axi_rready
);
    localparam integer LAST_SLICE = (1 << SLICE_BITS) - 1;

    localparam [2:0] S_IDLE = 3'd0, S_AR = 3'd1, S_R = 3'd2,
                     S_UNPACK = 3'd3, S_DONE = 3'd4;

    // ------------------------------------------------------------------
    // PS submit synchronization / frame base handoff
    // ------------------------------------------------------------------
    reg [2:0] submit_sync;
    always @(posedge clk) begin
        if (rst) submit_sync <= 3'b000;
        else     submit_sync <= {submit_sync[1:0], submit_toggle};
    end
    wire submit_pulse = submit_sync[1] ^ submit_sync[2];

    reg [31:0] active_base;
    reg        active_epoch;
    reg [31:0] pending_base;
    wire       pending_epoch = ~active_epoch;
    wire       frame_base_ok = (frame_base >= FRAME_BASE_MIN) &&
                               (frame_base <= FRAME_BASE_MAX);

    // Bench fallback: the scheduler still wraps slice_index 63->0 at the
    // fallback period even without IR. Use that wrap as a synthetic revolution
    // whenever no IR edge has been seen for IR_TIMEOUT_CYCLES. A permanent
    // ir_seen latch is deliberately avoided: one burst of noise on a floating
    // input at boot used to disable the fallback for the rest of the session,
    // which left the PS unable to submit any frame on the bench.
    reg [31:0] ir_idle;
    assign ir_active = (ir_idle < IR_TIMEOUT_CYCLES);
    wire bench_rev = (BENCH_FALLBACK != 0) && !ir_active &&
                     slot_start && (slice_index == {SLICE_BITS{1'b0}});
    wire rev_event = revolution_start || bench_rev;

    always @(posedge clk) begin
        if (rst)
            ir_idle <= 32'd0;
        else if (revolution_start)
            ir_idle <= 32'd0;
        else if (!ir_active)
            ir_idle <= IR_TIMEOUT_CYCLES;
        else
            ir_idle <= ir_idle + 1'b1;
    end

    always @(posedge clk) begin
        if (rst) begin
            active_base       <= 32'd0;
            active_epoch      <= 1'b0;
            active_valid      <= 1'b0;
            pending_base      <= 32'd0;
            pending_valid     <= 1'b0;
            frame_ack         <= 1'b0;
            frame_done_toggle <= 1'b0;
            frame_id          <= 8'd0;
            bench_count       <= 6'd0;
        end else begin
            if (bench_rev)
                bench_count <= bench_count + 1'b1;
            if (submit_pulse && frame_base_ok) begin
                pending_base  <= frame_base;
                pending_valid <= 1'b1;
            end
            if (rev_event && pending_valid) begin
                active_base       <= pending_base;
                active_epoch      <= ~active_epoch;
                active_valid      <= 1'b1;
                pending_valid     <= 1'b0;
                frame_ack         <= ~frame_ack;
                frame_done_toggle <= ~frame_done_toggle;
                frame_id          <= frame_id + 1'b1;
            end
        end
    end

    // ------------------------------------------------------------------
    // Ping-pong buffer tags. Each tag records slice index and frame epoch;
    // epoch mismatch invalidates old-frame data without clearing the RAM.
    // ------------------------------------------------------------------
    reg        buf_valid [0:1];
    reg [SLICE_BITS-1:0] buf_tag [0:1];
    reg        buf_epoch [0:1];
    reg        read_buf;

    // Fetch target latched by the FSM; declared before the buffer-tag always
    // block that uses them at fetch completion.
    reg        fetch_buf;
    reg [SLICE_BITS-1:0] fetch_slice;
    reg        fetch_epoch;
    reg [2:0]  state;

    wire other_buf = ~read_buf;
    wire current_in_other = buf_valid[other_buf] &&
                            (buf_tag[other_buf] == slice_index) &&
                            (buf_epoch[other_buf] == active_epoch);
    wire next_read = current_in_other ? other_buf : read_buf;
    wire write_buf = ~next_read;

    wire use_pending = (slice_index == LAST_SLICE) && pending_valid;
    wire [31:0] target_base  = use_pending ? pending_base : active_base;
    wire        target_epoch = use_pending ? pending_epoch : active_epoch;
    // Always prefetch the next slot's slice. The scan is consuming slice_index
    // now; slice_index+1 must be in the other buffer before the scheduler
    // advances. At the last slot this rolls over to slice 0 of the pending (or
    // still-active) frame, so the next revolution starts with a valid slice 0.
    wire [SLICE_BITS-1:0] target_slice =
        (slice_index == LAST_SLICE) ? {SLICE_BITS{1'b0}} : (slice_index + 1'b1);
    wire target_present = (buf_valid[0] && (buf_tag[0] == target_slice) &&
                           (buf_epoch[0] == target_epoch)) ||
                          (buf_valid[1] && (buf_tag[1] == target_slice) &&
                           (buf_epoch[1] == target_epoch));
    wire fetch_req = enable && active_valid && slot_start &&
                     !reader_busy && !target_present;

    always @(posedge clk) begin
        if (rst) begin
            read_buf  <= 1'b0;
            buf_valid[0] <= 1'b0; buf_valid[1] <= 1'b0;
            buf_tag[0]   <= {SLICE_BITS{1'b0}};
            buf_tag[1]   <= {SLICE_BITS{1'b0}};
            buf_epoch[0] <= 1'b0; buf_epoch[1] <= 1'b0;
        end else begin
            if (slot_start) read_buf <= next_read;
            if (state == S_DONE) begin
                buf_valid[fetch_buf] <= 1'b1;
                buf_tag[fetch_buf]   <= fetch_slice;
                buf_epoch[fetch_buf] <= fetch_epoch;
            end
        end
    end

    assign active_slice = slice_index;
    assign buf_ready    = buf_valid[0] & buf_valid[1];
    assign rd_buf       = read_buf;

    // ------------------------------------------------------------------
    // Fetch FSM
    // ------------------------------------------------------------------
    reg [31:0] fetch_base;
    reg [4:0]  burst_count;
    reg [11:0] word_count;

    // 3072 = 2048 + 1024 = (slice << 11) + (slice << 10)
    wire [31:0] slice_offset = ({26'd0, fetch_slice} << 11) +
                               ({26'd0, fetch_slice} << 10);
    wire [31:0] fetch_addr   = fetch_base + slice_offset;
    wire [31:0] burst_addr   = fetch_addr + ({27'd0, burst_count} << 7);

    // Beat FIFO: one burst of 16 beats, written in S_R, drained in S_UNPACK.
    reg [63:0] fifo [0:15];
    reg [4:0]  fifo_count;
    reg [3:0]  wptr, rptr;
    reg [69:0] acc;
    reg [6:0]  acc_nbits;
    assign wr_buf = fetch_buf;

    always @(posedge clk) begin
        if (rst) begin
            state          <= S_IDLE;
            wr_en          <= 1'b0;
            wr_addr        <= 12'd0;
            wr_data        <= 6'd0;
            reader_busy    <= 1'b0;
            m_axi_araddr   <= 32'd0;
            m_axi_arlen    <= 4'd15;
            m_axi_arsize   <= 3'd3;
            m_axi_arburst  <= 2'b01;
            m_axi_arlock   <= 2'b00;
            // Normal non-cacheable. The bare-metal tests ran with caches off,
            // so 4'b0011 (cacheable) was harmless there; under Linux the CPU
            // caches are on and a cacheable HP0 read can deadlock the PS.
            m_axi_arcache  <= 4'b0010;
            m_axi_arprot   <= 3'b000;
            m_axi_arid     <= 6'd0;
            m_axi_arvalid  <= 1'b0;
            m_axi_rready   <= 1'b0;
            fetch_buf      <= 1'b0;
            fetch_slice    <= {SLICE_BITS{1'b0}};
            fetch_epoch    <= 1'b0;
            fetch_base     <= 32'd0;
            burst_count    <= 5'd0;
            word_count     <= 12'd0;
            fifo_count     <= 5'd0;
            wptr           <= 4'd0;
            rptr           <= 4'd0;
            acc            <= 70'd0;
            acc_nbits      <= 7'd0;
        end else begin
            case (state)
                S_IDLE: begin
                    wr_en         <= 1'b0;
                    m_axi_arvalid <= 1'b0;
                    m_axi_rready  <= 1'b0;
                    if (fetch_req) begin
                        reader_busy <= 1'b1;
                        fetch_buf   <= write_buf;
                        fetch_slice <= target_slice;
                        fetch_epoch <= target_epoch;
                        fetch_base  <= target_base;
                        burst_count <= 5'd0;
                        word_count  <= 12'd0;
                        fifo_count  <= 5'd0;
                        wptr        <= 4'd0;
                        rptr        <= 4'd0;
                        acc         <= 70'd0;
                        acc_nbits   <= 7'd0;
                        state       <= S_AR;
                    end
                end
                S_AR: begin
                    wr_en         <= 1'b0;
                    m_axi_araddr  <= burst_addr;
                    m_axi_arvalid <= 1'b1;
                    if (m_axi_arvalid && m_axi_arready) begin
                        m_axi_arvalid <= 1'b0;
                        fifo_count    <= 5'd0;
                        wptr          <= 4'd0;
                        rptr          <= 4'd0;
                        state         <= S_R;
                    end
                end
                S_R: begin
                    wr_en        <= 1'b0;
                    m_axi_rready <= 1'b1;
                    if (m_axi_rvalid && m_axi_rready) begin
                        fifo[wptr]  <= m_axi_rdata;
                        wptr        <= wptr + 1'b1;
                        fifo_count  <= fifo_count + 1'b1;
                        if (m_axi_rlast) begin
                            m_axi_rready <= 1'b0;
                            state        <= S_UNPACK;
                        end
                    end
                end
                S_UNPACK: begin
                    if (fifo_count != 0 && acc_nbits < 7'd6) begin
                        rptr         <= rptr + 1'b1;
                        fifo_count   <= fifo_count - 1'b1;
                        acc          <= acc | ({64'd0, fifo[rptr]} << acc_nbits);
                        acc_nbits    <= acc_nbits + 7'd64;
                        wr_en        <= 1'b0;
                    end else if (acc_nbits >= 7'd6) begin
                        wr_en        <= 1'b1;
                        wr_addr      <= word_count;
                        wr_data      <= acc[5:0];
                        word_count   <= word_count + 1'b1;
                        acc          <= acc >> 6;
                        acc_nbits    <= acc_nbits - 7'd6;
                    end else begin
                        wr_en <= 1'b0;
                        if (burst_count == BURSTS-1) begin
                            state <= S_DONE;
                        end else begin
                            burst_count <= burst_count + 1'b1;
                            state       <= S_AR;
                        end
                    end
                end
                S_DONE: begin
                    wr_en       <= 1'b0;
                    reader_busy <= 1'b0;
                    state       <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    initial begin
        if (SLICE_BYTES != BURST_BEATS * BURSTS * 8)
            $error("Slice byte count does not match the AXI burst geometry");
    end
endmodule
