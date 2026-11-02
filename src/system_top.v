`timescale 1ns/1ps

// Top level for the PS + PL HUB75 system.
//
// design_1_wrapper contains the Zynq PS7, AXI GP0 -> two AXI GPIOs, the frame
// BRAM controller and the external M_AXI_READER master port. hub75_system
// contains the scan/IR/scheduler, the slice RAM ping-pong and the DDR reader;
// the reader now reads the frame BRAM through M_AXI_READER, not PS DDR. The PS
// DDR and MIO pins are dedicated PS pins, constrained by the PS7 IP.
module system_top (
    // Zynq PS DDR / MIO fixed pins (pass-through to the BD wrapper)
    inout  wire [14:0] DDR_addr,
    inout  wire [2:0]  DDR_ba,
    inout  wire        DDR_cas_n,
    inout  wire        DDR_ck_n,
    inout  wire        DDR_ck_p,
    inout  wire        DDR_cke,
    inout  wire        DDR_cs_n,
    inout  wire [3:0]  DDR_dm,
    inout  wire [31:0] DDR_dq,
    inout  wire [3:0]  DDR_dqs_n,
    inout  wire [3:0]  DDR_dqs_p,
    inout  wire        DDR_odt,
    inout  wire        DDR_ras_n,
    inout  wire        DDR_reset_n,
    inout  wire        DDR_we_n,
    inout  wire        FIXED_IO_ddr_vrn,
    inout  wire        FIXED_IO_ddr_vrp,
    inout  wire [53:0] FIXED_IO_mio,
    inout  wire        FIXED_IO_ps_clk,
    inout  wire        FIXED_IO_ps_porb,
    inout  wire        FIXED_IO_ps_srstb,
    // Board PL signals
    input  wire        ir_in,
    input  wire        reset_n,       // PL_KEY1, active low
    output wire [2:0]  rgb1,
    output wire [2:0]  rgb2,
    output wire        hub_clk,
    output wire        hub_lat,
    output wire        hub_oe_n,
    output wire [4:0]  hub_addr,
    output wire [3:0]  debug_led_n,
    output wire        debug_uart_tx
);
    wire        FCLK_CLK0;
    wire        FCLK_RESET0_N;
    wire [31:0] frame_base;
    wire [31:0] frame_ctrl;
    wire [31:0] status;
    wire [31:0] period;

    // AXI3 read channels from the reader to the BRAM-controller interconnect.
    wire [31:0] hp0_araddr;
    wire [3:0]  hp0_arlen;
    wire [2:0]  hp0_arsize;
    wire [1:0]  hp0_arburst;
    wire [1:0]  hp0_arlock;
    wire [3:0]  hp0_arcache;
    wire [2:0]  hp0_arprot;
    wire [5:0]  hp0_arid;
    wire        hp0_arvalid;
    wire        hp0_arready;
    wire [63:0] hp0_rdata;
    wire [1:0]  hp0_rresp;
    wire        hp0_rlast;
    wire [5:0]  hp0_rid;
    wire        hp0_rvalid;
    wire        hp0_rready;

    // The PS reset is active low; the board key is active low too.
    wire sys_rst_n = reset_n & FCLK_RESET0_N;

    design_1_wrapper u_bd (
        .DDR_addr(DDR_addr),
        .DDR_ba(DDR_ba),
        .DDR_cas_n(DDR_cas_n),
        .DDR_ck_n(DDR_ck_n),
        .DDR_ck_p(DDR_ck_p),
        .DDR_cke(DDR_cke),
        .DDR_cs_n(DDR_cs_n),
        .DDR_dm(DDR_dm),
        .DDR_dq(DDR_dq),
        .DDR_dqs_n(DDR_dqs_n),
        .DDR_dqs_p(DDR_dqs_p),
        .DDR_odt(DDR_odt),
        .DDR_ras_n(DDR_ras_n),
        .DDR_reset_n(DDR_reset_n),
        .DDR_we_n(DDR_we_n),
        .FCLK_CLK0(FCLK_CLK0),
        .FCLK_RESET0_N(FCLK_RESET0_N),
        .FIXED_IO_ddr_vrn(FIXED_IO_ddr_vrn),
        .FIXED_IO_ddr_vrp(FIXED_IO_ddr_vrp),
        .FIXED_IO_mio(FIXED_IO_mio),
        .FIXED_IO_ps_clk(FIXED_IO_ps_clk),
        .FIXED_IO_ps_porb(FIXED_IO_ps_porb),
        .FIXED_IO_ps_srstb(FIXED_IO_ps_srstb),
        .M_AXI_READER_araddr(hp0_araddr),
        .M_AXI_READER_arburst(hp0_arburst),
        .M_AXI_READER_arcache(hp0_arcache),
        .M_AXI_READER_arid(hp0_arid),
        .M_AXI_READER_arlen(hp0_arlen),
        .M_AXI_READER_arlock(hp0_arlock),
        .M_AXI_READER_arprot(hp0_arprot),
        .M_AXI_READER_arqos(4'd0),
        .M_AXI_READER_arready(hp0_arready),
        .M_AXI_READER_arsize(hp0_arsize),
        .M_AXI_READER_arvalid(hp0_arvalid),
        // Read-only master: tie off the write channels.
        .M_AXI_READER_awaddr(32'd0),
        .M_AXI_READER_awburst(2'd0),
        .M_AXI_READER_awcache(4'd0),
        .M_AXI_READER_awid(6'd0),
        .M_AXI_READER_awlen(4'd0),
        .M_AXI_READER_awlock(2'd0),
        .M_AXI_READER_awprot(3'd0),
        .M_AXI_READER_awqos(4'd0),
        .M_AXI_READER_awsize(3'd0),
        .M_AXI_READER_awvalid(1'b0),
        .M_AXI_READER_bready(1'b1),
        .M_AXI_READER_rdata(hp0_rdata),
        .M_AXI_READER_rid(hp0_rid),
        .M_AXI_READER_rlast(hp0_rlast),
        .M_AXI_READER_rready(hp0_rready),
        .M_AXI_READER_rresp(hp0_rresp),
        .M_AXI_READER_rvalid(hp0_rvalid),
        .M_AXI_READER_wdata(64'd0),
        .M_AXI_READER_wid(6'd0),
        .M_AXI_READER_wlast(1'b0),
        .M_AXI_READER_wstrb(8'd0),
        .M_AXI_READER_wvalid(1'b0),
        .frame_base(frame_base),
        .frame_ctrl(frame_ctrl),
        .period(period),
        .status(status)
    );

    hub75_system u_system (
        .clk(FCLK_CLK0),
        .rst_n(sys_rst_n),
        .ir_in(ir_in),
        .frame_base(frame_base),
        .frame_ctrl(frame_ctrl),
        .status(status),
        .period(period),
        .rgb1(rgb1),
        .rgb2(rgb2),
        .hub_clk(hub_clk),
        .hub_lat(hub_lat),
        .hub_oe_n(hub_oe_n),
        .hub_addr(hub_addr),
        .debug_led_n(debug_led_n),
        .debug_uart_tx(debug_uart_tx),
        .m_axi_araddr(hp0_araddr),
        .m_axi_arlen(hp0_arlen),
        .m_axi_arsize(hp0_arsize),
        .m_axi_arburst(hp0_arburst),
        .m_axi_arlock(hp0_arlock),
        .m_axi_arcache(hp0_arcache),
        .m_axi_arprot(hp0_arprot),
        .m_axi_arid(hp0_arid),
        .m_axi_arvalid(hp0_arvalid),
        .m_axi_arready(hp0_arready),
        .m_axi_rdata(hp0_rdata),
        .m_axi_rresp(hp0_rresp),
        .m_axi_rlast(hp0_rlast),
        .m_axi_rid(hp0_rid),
        .m_axi_rvalid(hp0_rvalid),
        .m_axi_rready(hp0_rready)
    );

    // The wrapper's write-channel outputs are intentionally unconnected; the
    // reader never issues writes.
endmodule
