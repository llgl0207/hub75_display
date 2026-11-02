`timescale 1ns/1ps

// PL display system with PS control and DDR slice reader.
//
// PS writes frame_base / frame_ctrl through AXI GPIO and reads status/period
// back. This block keeps the real-time path entirely in PL: the scheduler,
// slice RAM ping-pong, DDR reader and HUB75 waveform engine all run on FCLK_CLK0.
module hub75_system (
    input  wire        clk,        // FCLK_CLK0, 50 MHz
    input  wire        rst_n,      // FCLK_RESET0_N & board PL_KEY1
    input  wire        ir_in,
    // PS -> PL (AXI GPIO output channels)
    input  wire [31:0] frame_base,
    input  wire [31:0] frame_ctrl, // bit0 submit toggle, bit1 enable, [15:8] slice count
    // PL -> PS (AXI GPIO input channels)
    output wire [31:0] status,
    output wire [31:0] period,
    // HUB75 panel and diagnostics
    output wire [2:0]  rgb1,
    output wire [2:0]  rgb2,
    output wire        hub_clk,
    output wire        hub_lat,
    output wire        hub_oe_n,
    output wire [4:0]  hub_addr,
    output wire [3:0]  debug_led_n,
    output wire        debug_uart_tx,
    // AXI3 read master to S_AXI_HP0 (64-bit data, 32-bit address, 6-bit ID)
    output wire [31:0] m_axi_araddr,
    output wire [3:0]  m_axi_arlen,
    output wire [2:0]  m_axi_arsize,
    output wire [1:0]  m_axi_arburst,
    output wire [1:0]  m_axi_arlock,
    output wire [3:0]  m_axi_arcache,
    output wire [2:0]  m_axi_arprot,
    output wire [5:0]  m_axi_arid,
    output wire        m_axi_arvalid,
    input  wire        m_axi_arready,
    input  wire [63:0] m_axi_rdata,
    input  wire [1:0]  m_axi_rresp,
    input  wire        m_axi_rlast,
    input  wire [5:0]  m_axi_rid,
    input  wire        m_axi_rvalid,
    output wire        m_axi_rready
);
    // Synchronous active-high reset for the DDR reader. hub75_ps_top keeps its
    // own reset synchronizer for the scan/IR domain.
    reg [1:0] rst_pipe = 2'b11;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rst_pipe <= 2'b11;
        else        rst_pipe <= {rst_pipe[0], 1'b0};
    end
    wire rst_sync = rst_pipe[1];

    wire [5:0]  pix_data;
    wire [12:0] pix_addr;
    wire [5:0]  slice_index;
    wire        slot_start;
    wire        revolution_start;
    wire [31:0] period_ticks;
    wire        period_valid;

    hub75_ps_top #(
        .PATTERN_MODE(3)
    ) u_top (
        .clk_in(clk),
        .reset_n(rst_n),
        .ir_in(ir_in),
        .pix_data(pix_data),
        .pix_addr(pix_addr),
        .slice_index(slice_index),
        .slot_start(slot_start),
        .revolution_start(revolution_start),
        .period_ticks(period_ticks),
        .period_valid(period_valid),
        .rgb1(rgb1),
        .rgb2(rgb2),
        .hub_clk(hub_clk),
        .hub_lat(hub_lat),
        .hub_oe_n(hub_oe_n),
        .hub_addr(hub_addr),
        .debug_led_n(debug_led_n),
        .debug_uart_tx(debug_uart_tx)
    );

    wire        rd_buf;
    wire        wr_en;
    wire        wr_buf;
    wire [11:0] wr_addr;
    wire [5:0]  wr_data;

    hub75_slice_ram u_slice_ram (
        .clk(clk),
        .wr_en(wr_en),
        .wr_buf(wr_buf),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .rd_buf(rd_buf),
        .rd_addr(pix_addr),
        .rd_data(pix_data)
    );

    wire        frame_ack;
    wire        reader_busy;
    wire        frame_done_toggle;
    wire        buf_ready;
    wire [7:0]  frame_id;
    wire [5:0]  active_slice;
    wire        ir_active;
    wire        pending_valid;
    wire        active_valid;
    wire [5:0]  bench_count;

    hub75_ddr_reader u_reader (
        .clk(clk),
        .rst(rst_sync),
        .enable(frame_ctrl[1]),
        .frame_base(frame_base),
        .submit_toggle(frame_ctrl[0]),
        .slice_index(slice_index),
        .slot_start(slot_start),
        .revolution_start(revolution_start),
        .wr_en(wr_en),
        .wr_buf(wr_buf),
        .wr_addr(wr_addr),
        .wr_data(wr_data),
        .active_slice(active_slice),
        .reader_busy(reader_busy),
        .frame_ack(frame_ack),
        .frame_done_toggle(frame_done_toggle),
        .frame_id(frame_id),
        .buf_ready(buf_ready),
        .rd_buf(rd_buf),
        .ir_active(ir_active),
        .pending_valid(pending_valid),
        .active_valid(active_valid),
        .bench_count(bench_count),
        .m_axi_araddr(m_axi_araddr),
        .m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),
        .m_axi_arburst(m_axi_arburst),
        .m_axi_arlock(m_axi_arlock),
        .m_axi_arcache(m_axi_arcache),
        .m_axi_arprot(m_axi_arprot),
        .m_axi_arid(m_axi_arid),
        .m_axi_arvalid(m_axi_arvalid),
        .m_axi_arready(m_axi_arready),
        .m_axi_rdata(m_axi_rdata),
        .m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),
        .m_axi_rid(m_axi_rid),
        .m_axi_rvalid(m_axi_rvalid),
        .m_axi_rready(m_axi_rready)
    );

    // AXI GPIO status word:
    //   [0] frame_ack, [1] reader_busy, [2] buf_ready, [3] frame_done_toggle,
    //   [4] ir_active (IR edge within the timeout), [5] pending_valid,
    //   [6] active_valid, [7] enable (frame_ctrl[1] as seen by the PL),
    //   [15:8] active slice, [23:16] frame id,
    //   [29:24] synthetic revolution count (mod 64), [30] submit_toggle
    //   (frame_ctrl[0] as seen by the PL), [31] period_valid.
    assign status = {period_valid, frame_ctrl[0], bench_count,
                     frame_id,
                     2'b00, active_slice,
                     frame_ctrl[1], active_valid, pending_valid, ir_active,
                     frame_done_toggle, buf_ready, reader_busy, frame_ack};
    assign period = period_ticks;
endmodule
