`timescale 1ns/1ps

// DDR reader unit test. A behavioral AXI3 slave serves three packed 3072-byte
// slices. The TB checks:
//   - the 6-bit unpacker writes every word to the slice RAM in the right order
//     for the prefetched slices 1 and 2;
//   - the ping-pong handoff actually alternates read_buf when the next slice
//     arrives, so the scan never reads the initial empty buffer;
//   - buf_ready only asserts after both buffers hold data.
module tb_hub75_ddr_reader;
    localparam [31:0] FRAME_BASE = 32'h4200_0000;  // must be inside the frame BRAM window
    localparam integer SLICE_BYTES = 3072;
    localparam integer NSLICES = 3;

    reg clk = 0;
    always #10 clk = ~clk;              // 50 MHz

    reg rst = 1;
    reg enable = 1;
    reg [31:0] frame_base = FRAME_BASE;
    reg submit_toggle = 0;
    reg [5:0] slice_index = 0;
    reg slot_start = 0;
    reg revolution_start = 0;

    wire wr_en;
    wire wr_buf;
    wire [11:0] wr_addr;
    wire [5:0] wr_data;
    wire reader_busy;
    wire [5:0] active_slice;
    wire frame_ack;
    wire frame_done_toggle;
    wire [7:0] frame_id;
    wire buf_ready;
    wire rd_buf;

    // AXI master side
    wire [31:0] araddr;
    wire [3:0]  arlen;
    wire [2:0]  arsize;
    wire [1:0]  arburst;
    wire [1:0]  arlock;
    wire [3:0]  arcache;
    wire [2:0]  arprot;
    wire [5:0]  arid;
    wire        arvalid;
    reg         arready = 1;
    reg  [63:0] rdata;
    reg  [1:0]  rresp = 2'b00;
    reg         rlast;
    reg  [5:0]  rid = 6'd0;
    reg         rvalid;
    wire        rready;

    hub75_ddr_reader #(
        // Short IR timeout so the sim can observe the bench fallback re-arm.
        .IR_TIMEOUT_CYCLES(50)
    ) dut (
        .clk(clk), .rst(rst), .enable(enable),
        .frame_base(frame_base), .submit_toggle(submit_toggle),
        .slice_index(slice_index), .slot_start(slot_start),
        .revolution_start(revolution_start),
        .wr_en(wr_en), .wr_buf(wr_buf), .wr_addr(wr_addr), .wr_data(wr_data),
        .active_slice(active_slice), .reader_busy(reader_busy),
        .frame_ack(frame_ack), .frame_done_toggle(frame_done_toggle),
        .frame_id(frame_id), .buf_ready(buf_ready), .rd_buf(rd_buf),
        .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize),
        .m_axi_arburst(arburst), .m_axi_arlock(arlock),
        .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arid(arid),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast),
        .m_axi_rid(rid), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    // ----------------------------------------------------------------
    // Data model: NSLICES slices, each 4096 packed 6-bit words.
    // ----------------------------------------------------------------
    reg [5:0] word [0:NSLICES-1][0:4095];
    reg [7:0] ddr_mem [0:NSLICES*SLICE_BYTES-1];
    reg [5:0] captured [0:1][0:4095];  // the two prefetched slices

    integer s, i, bitpos, byteidx, bitoff;
    reg [15:0] shifted;

    initial begin
        for (i = 0; i < NSLICES*SLICE_BYTES; i = i + 1) ddr_mem[i] = 8'h00;
        for (s = 0; s < NSLICES; s = s + 1)
            for (i = 0; i < 4096; i = i + 1)
                word[s][i] = (s * 6'h11 + i[5:0] + 6'd7) & 6'h3F;
        for (s = 0; s < NSLICES; s = s + 1)
            for (i = 0; i < 4096; i = i + 1) begin
                bitpos = i * 6;
                byteidx = bitpos >> 3;
                bitoff = bitpos & 7;
                shifted = {10'd0, word[s][i]} << bitoff;
                ddr_mem[s*SLICE_BYTES+byteidx] =
                    ddr_mem[s*SLICE_BYTES+byteidx] | shifted[7:0];
                if (bitoff > 2)
                    ddr_mem[s*SLICE_BYTES+byteidx+1] =
                        ddr_mem[s*SLICE_BYTES+byteidx+1] | shifted[15:8];
            end
    end

    // ----------------------------------------------------------------
    // Behavioral AXI3 read slave, one 16-beat burst at a time.
    // ----------------------------------------------------------------
    reg [31:0] burst_base;
    reg [4:0]  beat;
    wire [31:0] byte_off = (burst_base - FRAME_BASE) + (beat << 3);

    always @(*) begin
        rdata = {ddr_mem[byte_off+7], ddr_mem[byte_off+6],
                 ddr_mem[byte_off+5], ddr_mem[byte_off+4],
                 ddr_mem[byte_off+3], ddr_mem[byte_off+2],
                 ddr_mem[byte_off+1], ddr_mem[byte_off]};
        rlast = (beat == 5'd15);
    end

    always @(posedge clk) begin
        if (rst) begin
            rvalid <= 1'b0;
            beat   <= 5'd0;
            burst_base <= 32'd0;
        end else begin
            if (arvalid && arready) begin
                burst_base <= araddr;
                beat       <= 5'd0;
                rvalid     <= 1'b1;
            end
            if (rvalid && rready) begin
                if (beat == 5'd15) rvalid <= 1'b0;
                else               beat   <= beat + 1'b1;
            end
        end
    end

    // ----------------------------------------------------------------
    // Capture writes per fetch. With the fixed prefetch policy the first fetch
    // after slot 0 is slice 1 and the second is slice 2.
    // ----------------------------------------------------------------
    integer fetch_num = 0;
    always @(posedge clk) if (slot_start) fetch_num <= fetch_num + 1;

    always @(posedge clk) begin
        if (wr_en) begin
            if (fetch_num == 1)      captured[0][wr_addr] <= wr_data;
            else if (fetch_num == 2) captured[1][wr_addr] <= wr_data;
            // Later fetches (bench-fallback test) are not content-checked.
        end
    end

    // ----------------------------------------------------------------
    // Stimulus
    // ----------------------------------------------------------------
    initial begin
        repeat (4) @(negedge clk);
        rst <= 0;
        frame_base <= FRAME_BASE;
        repeat (5) @(negedge clk);
        submit_toggle <= 1;
        repeat (5) @(negedge clk);
        revolution_start <= 1;
        @(negedge clk);
        revolution_start <= 0;
        repeat (3) @(negedge clk);

        // Slot 0 (slice 0): the empty start-up buffer is displayed for one slot,
        // but the reader must prefetch slice 1 into the other buffer.
        slice_index <= 0;
        slot_start <= 1;
        @(negedge clk);
        slot_start <= 0;
        wait (reader_busy);
        wait (!reader_busy);

        // Slot 1 (slice 1): read_buf must switch to the buffer just filled.
        // Assert at a negedge so slot_start covers exactly one posedge; sample
        // rd_buf immediately after that posedge.
        @(negedge clk);
        slice_index <= 1;
        slot_start <= 1;
        @(posedge clk); #1;
        if (rd_buf !== 1'b1) begin
            $display("DBG rd_buf=%b buf_ready=%b fetch_num=%0d state=%0d",
                     rd_buf, buf_ready, fetch_num, dut.state);
            $display("DBG valid=%b%b tag=%0d/%0d epoch=%b%b active_epoch=%b read_buf=%b fetch_slice=%0d busy=%b",
                     dut.buf_valid[0], dut.buf_valid[1],
                     dut.buf_tag[0], dut.buf_tag[1],
                     dut.buf_epoch[0], dut.buf_epoch[1],
                     dut.active_epoch, dut.read_buf, dut.fetch_slice,
                     reader_busy);
            $fatal(1, "read_buf did not switch to the prefetched slice 1");
        end
        @(negedge clk);
        slot_start <= 0;
        wait (reader_busy);
        wait (!reader_busy);
        if (buf_ready !== 1'b1)
            $fatal(1, "buf_ready did not assert after both buffers were filled");

        // Slot 2 (slice 2): read_buf must switch back to buffer 0.
        @(negedge clk);
        slice_index <= 2;
        slot_start <= 1;
        @(posedge clk); #1;
        if (rd_buf !== 1'b0)
            $fatal(1, "read_buf did not switch back to the prefetched slice 2");
        @(negedge clk);
        slot_start <= 0;

        for (i = 0; i < 4096; i = i + 1) begin
            if (captured[0][i] !== word[1][i])
                $fatal(1, "slice1 word %0d expected %b got %b",
                       i, word[1][i], captured[0][i]);
            if (captured[1][i] !== word[2][i])
                $fatal(1, "slice2 word %0d expected %b got %b",
                       i, word[2][i], captured[1][i]);
        end
        if (frame_ack !== 1'b1)
            $fatal(1, "frame_ack did not toggle after base latching");

        // Bench fallback re-arm: submit another frame, stay silent on the IR
        // (like a grounded sensor) longer than IR_TIMEOUT_CYCLES, then let the
        // scheduler wrap to slice 0. The wrap must act as a revolution.
        @(negedge clk);
        submit_toggle <= ~submit_toggle;
        repeat (5) @(negedge clk);
        if (!dut.pending_valid)
            $fatal(1, "second submit did not become pending");
        repeat (200) @(negedge clk);      // IR silent > 50-cycle timeout
        if (dut.ir_active !== 1'b0)
            $fatal(1, "IR timeout did not re-arm the bench fallback");
        slice_index <= 0;
        slot_start <= 1;
        @(negedge clk);
        slot_start <= 0;
        repeat (3) @(negedge clk);
        if (frame_ack !== 1'b0)
            $fatal(1, "bench fallback wrap did not latch the pending frame");
        if (frame_id !== 8'd2)
            $fatal(1, "bench fallback latch incremented frame_id to %0d", frame_id);

        // A submit whose frame_base is outside the frame BRAM window must be
        // ignored: latching it would make the reader read an unmapped GP0
        // address and wedge the AXI fabric.
        frame_base <= 32'd0;
        @(negedge clk);
        submit_toggle <= ~submit_toggle;
        repeat (5) @(negedge clk);
        if (dut.pending_valid !== 1'b0)
            $fatal(1, "submit with out-of-window frame_base was accepted");
        if (frame_id !== 8'd2)
            $fatal(1, "frame_id changed on a rejected submit");

        $display("PASS: DDR reader burst, 6-bit unpack, slice handoff, buf_ready, bench fallback, base check");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "Timeout waiting for DDR reader");
    end
endmodule
