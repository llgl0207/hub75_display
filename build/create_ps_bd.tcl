# Create the Zynq-7000 PS block design for the Mizar-Z7 board.
#
# Sourced by build_ps_system.tcl after create_project, so a project and a part
# already exist. Stage 0 is PS-only: UART0, DDR3 and FCLK_CLK0, no PL logic and
# no AXI GPIO/HP0. Stage 1 adds the PS<->PL control and DDR reader path.
#
# Board facts used here (MicroPhase Mizar-Z7, XC7Z020CLG400):
#   PS clock 33.333 MHz, DDR3 2 x SK hynix H5TQ4G63FFR-RD (4Gb x16, 1 GB,
#   32-bit), MIO bank0 3.3 V and bank1 1.8 V. The PS LEDs are MIO50/51
#   (active low).
#
#   Console UART: the vendor table says UART0 on MIO14/15, but on this board
#   the onboard CP2102 is wired to UART1 on MIO48/MIO49 (verified on the board:
#   UART1 MIO48/49 output was received on the CP2102 COM port, UART0 MIO14/15
#   was silent). Both UARTs are enabled here; the renderer console uses UART1.
#
#   SD boot: SD0 is enabled on MIO40..45 (the standard Zynq SD0 mapping; SD1
#   would collide with UART1 on MIO48/49). Card detect, write protect and power
#   are not connected. The BOOT.BIN (FSBL + bitstream + ELF) is built by
#   build/build_sd_boot.py and written to a FAT32 microSD; SW4 selects SD boot.
#
# The DDR part is not in the Xilinx preset list for this board. MT41K256M16RE-125
# is used as the closest 4Gb x16 Micron equivalent; its 1066 timings match the
# hynix part. Start at 400 MHz and raise to 533.333 after memtest passes.

if {![info exists stage]} { set stage 0 }

create_bd_design design_1
current_bd_design design_1

set ps7 [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7:5.5 processing_system7_0]

set_property -dict [list \
    CONFIG.PCW_CRYSTAL_PERIPHERAL_FREQMHZ {33.333333} \
    CONFIG.PCW_APU_PERIPHERAL_FREQMHZ {667} \
    CONFIG.PCW_PRESET_BANK0_VOLTAGE {LVCMOS 3.3V} \
    CONFIG.PCW_PRESET_BANK1_VOLTAGE {LVCMOS 1.8V} \
    CONFIG.PCW_UART0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART0_UART0_IO {MIO 14 .. 15} \
    CONFIG.PCW_UART1_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_UART1_UART1_IO {MIO 48 .. 49} \
    CONFIG.PCW_QSPI_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_SD0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_SD0_SD0_IO {MIO 40 .. 45} \
    CONFIG.PCW_SD0_GRP_CD_ENABLE {0} \
    CONFIG.PCW_SD0_GRP_WP_ENABLE {0} \
    CONFIG.PCW_SD0_GRP_POW_ENABLE {0} \
    CONFIG.PCW_SD1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_ENET0_PERIPHERAL_ENABLE {1} \
    CONFIG.PCW_ENET0_ENET0_IO {MIO 16 .. 27} \
    CONFIG.PCW_ENET0_GRP_MDIO_ENABLE {1} \
    CONFIG.PCW_ENET0_GRP_MDIO_IO {MIO 52 .. 53} \
    CONFIG.PCW_ENET0_PERIPHERAL_FREQMHZ {1000} \
    CONFIG.PCW_ENET1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_USB0_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_USB1_PERIPHERAL_ENABLE {0} \
    CONFIG.PCW_GPIO_MIO_GPIO_ENABLE {1} \
    CONFIG.PCW_UIPARAM_DDR_ENABLE {1} \
    CONFIG.PCW_UIPARAM_DDR_MEMORY_TYPE {DDR 3} \
    CONFIG.PCW_UIPARAM_DDR_PARTNO {MT41K256M16RE-125} \
    CONFIG.PCW_UIPARAM_DDR_BUS_WIDTH {32 Bit} \
    CONFIG.PCW_UIPARAM_DDR_DRAM_WIDTH {16 Bits} \
    CONFIG.PCW_UIPARAM_DDR_DEVICE_CAPACITY {4096 MBits} \
    CONFIG.PCW_UIPARAM_DDR_SPEED_BIN {DDR3_1066F} \
    CONFIG.PCW_UIPARAM_DDR_FREQ_MHZ {400.000000} \
    CONFIG.PCW_UIPARAM_DDR_USE_INTERNAL_VREF {0} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_WRITE_LEVEL {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_READ_GATE {1} \
    CONFIG.PCW_UIPARAM_DDR_TRAIN_DATA_EYE {1} \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ {50} \
    CONFIG.PCW_USE_M_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_HP0 {0} \
    CONFIG.PCW_USE_S_AXI_ACP {0} \
    CONFIG.PCW_USE_S_AXI_GP0 {0} \
    CONFIG.PCW_USE_S_AXI_GP1 {0} \
    CONFIG.PCW_USE_S_AXI_HP1 {0} \
    CONFIG.PCW_USE_S_AXI_HP2 {0} \
    CONFIG.PCW_USE_S_AXI_HP3 {0} \
    CONFIG.PCW_USE_FABRIC_INTERRUPT {0} \
] $ps7

# PS dedicated DDR and MIO pins. These are fixed by the PS7 IP; the wrapper
# exposes them as top-level ports. No user XDC pin assignments are needed.
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:ddrx_rtl:1.0 DDR
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/DDR] [get_bd_intf_ports DDR]

create_bd_intf_port -mode Master -vlnv xilinx.com:display_processing_system7:fixedio_rtl:1.0 FIXED_IO
connect_bd_intf_net [get_bd_intf_pins processing_system7_0/FIXED_IO] [get_bd_intf_ports FIXED_IO]

# Stage 1: PS<->PL control (AXI GP0 + two AXI GPIOs) and the HP0 read path.
# FCLK_CLK0/FCLK_RESET0_N must not be top-level ports in the Stage 0 PS-only
# build; unconstrained/unplaced top-level clock ports fail NSTD-1/UCIO-1 DRC.
if {$stage != 0} {
    set_property -dict [list \
        CONFIG.PCW_USE_M_AXI_GP0 {1} \
        CONFIG.PCW_USE_S_AXI_HP0 {0} \
    ] $ps7

    set axi_ic [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_interconnect_0]
    set_property -dict [list CONFIG.NUM_MI {3} CONFIG.NUM_SI {2}] $axi_ic
    connect_bd_intf_net [get_bd_intf_pins processing_system7_0/M_AXI_GP0] \
                        [get_bd_intf_pins axi_interconnect_0/S00_AXI]

    # The PL frame reader is the second AXI master. It reads the frame BRAM
    # through this interconnect; the PS writes that BRAM through GP0.
    create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 M_AXI_READER
    set_property -dict [list \
        CONFIG.PROTOCOL {AXI3} \
        CONFIG.FREQ_HZ {50000000} \
        CONFIG.ADDR_WIDTH {32} \
        CONFIG.DATA_WIDTH {64} \
        CONFIG.ID_WIDTH {6} \
        CONFIG.HAS_BURST {1} \
        CONFIG.HAS_LOCK {1} \
        CONFIG.HAS_CACHE {1} \
        CONFIG.HAS_PROT {1} \
        CONFIG.HAS_QOS {1} \
        CONFIG.HAS_REGION {0} \
        CONFIG.SUPPORTS_NARROW_BURST {0} \
        CONFIG.MAX_BURST_LENGTH {16} \
    ] [get_bd_intf_ports M_AXI_READER]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/S01_AXI] \
                        [get_bd_intf_ports M_AXI_READER]

    set gpio_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_ctrl]
    set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
        CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_OUTPUTS {1}] $gpio_ctrl
    set gpio_status [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_gpio:2.0 axi_gpio_status]
    set_property -dict [list CONFIG.C_GPIO_WIDTH {32} CONFIG.C_GPIO2_WIDTH {32} \
        CONFIG.C_IS_DUAL {1} CONFIG.C_ALL_INPUTS {1}] $gpio_status
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M00_AXI] \
                        [get_bd_intf_pins axi_gpio_ctrl/S_AXI]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M01_AXI] \
                        [get_bd_intf_pins axi_gpio_status/S_AXI]
    assign_bd_address [get_bd_addr_segs {axi_gpio_ctrl/S_AXI/Reg}]
    assign_bd_address [get_bd_addr_segs {axi_gpio_status/S_AXI/Reg}]

    create_bd_port -dir O -from 31 -to 0 frame_base
    connect_bd_net [get_bd_pins axi_gpio_ctrl/gpio_io_o] [get_bd_ports frame_base]
    create_bd_port -dir O -from 31 -to 0 frame_ctrl
    connect_bd_net [get_bd_pins axi_gpio_ctrl/gpio2_io_o] [get_bd_ports frame_ctrl]
    create_bd_port -dir I -from 31 -to 0 status
    connect_bd_net [get_bd_ports status] [get_bd_pins axi_gpio_status/gpio_io_i]
    create_bd_port -dir I -from 31 -to 0 period
    connect_bd_net [get_bd_ports period] [get_bd_pins axi_gpio_status/gpio2_io_i]

    # 2 x 192 KiB frame BRAM at 0x42000000. The PS writes frames through GP0;
    # the PL reader reads them through its own AXI master port.
    set bram_ctrl [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_bram_ctrl:4.1 axi_bram_ctrl_0]
    # 512 KiB = 131072 32-bit words. Match the PS GP0 data width (32 bits) so
    # the PS's frame writes are native full-width transfers, not narrow bursts
    # into a 64-bit slave (that path hung the PS in the 64-bit build). The PL
    # reader stays 64-bit; the interconnect downsizes its reads.
    set_property -dict [list \
        CONFIG.SINGLE_PORT_BRAM {1} \
        CONFIG.DATA_WIDTH {32} \
        CONFIG.MEM_DEPTH {131072} \
    ] $bram_ctrl
    set frame_bram [create_bd_cell -type ip -vlnv xilinx.com:ip:blk_mem_gen:8.4 blk_mem_gen_0]
    set_property -dict [list \
        CONFIG.Memory_Type {Single_Port_RAM} \
        CONFIG.use_bram_block {BRAM_Controller} \
        CONFIG.Write_Width_A {32} \
        CONFIG.Read_Width_A {32} \
        CONFIG.Write_Depth_A {131072} \
        CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    ] $frame_bram
    connect_bd_intf_net [get_bd_intf_pins axi_bram_ctrl_0/BRAM_PORTA] \
                        [get_bd_intf_pins blk_mem_gen_0/BRAM_PORTA]
    connect_bd_intf_net [get_bd_intf_pins axi_interconnect_0/M02_AXI] \
                        [get_bd_intf_pins axi_bram_ctrl_0/S_AXI]
    assign_bd_address -offset 0x42000000 -range 0x80000 \
        [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0]
    catch {
        assign_bd_address -target_address_space [get_bd_addr_spaces M_AXI_READER] \
                          -offset 0x42000000 -range 0x80000 \
                          [get_bd_addr_segs axi_bram_ctrl_0/S_AXI/Mem0]
    }

    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
        [get_bd_pins processing_system7_0/M_AXI_GP0_ACLK] \
        [get_bd_pins axi_interconnect_0/ACLK] \
        [get_bd_pins axi_interconnect_0/S00_ACLK] \
        [get_bd_pins axi_interconnect_0/S01_ACLK] \
        [get_bd_pins axi_interconnect_0/M00_ACLK] \
        [get_bd_pins axi_interconnect_0/M01_ACLK] \
        [get_bd_pins axi_interconnect_0/M02_ACLK] \
        [get_bd_pins axi_bram_ctrl_0/s_axi_aclk] \
        [get_bd_pins axi_gpio_ctrl/s_axi_aclk] \
        [get_bd_pins axi_gpio_status/s_axi_aclk]

    # FCLK_RESET0_N is an asynchronous PS reset; the AXI fabric needs a reset
    # synchronized to FCLK_CLK0. proc_sys_reset provides peripheral_aresetn.
    set proc_rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]
    # proc_sys_reset aux_reset_in defaults to ACTIVE LOW (C_AUX_RESET_HIGH=0).
    # Tying it to constant 0 then holds peripheral_aresetn low forever, so every
    # AXI slave stays in reset and the first A9 access to 0x41200000 hangs.
    # Make it active high so the const0 tie below means "deasserted".
    set_property -dict [list CONFIG.C_AUX_RESET_HIGH {1}] $proc_rst
    # proc_sys_reset ext_reset_in is active high and C_EXT_RESET_HIGH is
    # read-only in the BD, so invert the active-low FCLK_RESET0_N.
    set rst_inv [create_bd_cell -type ip -vlnv xilinx.com:ip:util_vector_logic:2.0 reset_inv]
    set_property -dict [list CONFIG.C_OPERATION {not} CONFIG.C_SIZE {1}] $rst_inv
    set const0 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const0]
    set_property -dict [list CONFIG.CONST_VAL {0}] $const0
    set const1 [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:1.1 const1]
    set_property -dict [list CONFIG.CONST_VAL {1}] $const1
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] \
        [get_bd_pins proc_sys_reset_0/slowest_sync_clk]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] \
        [get_bd_pins reset_inv/Op1]
    connect_bd_net [get_bd_pins reset_inv/Res] \
        [get_bd_pins proc_sys_reset_0/ext_reset_in]
    # aux_reset_in is now active high; mb_debug_sys_rst is active high.
    # Tie both to 0 to leave them deasserted.
    connect_bd_net [get_bd_pins const0/dout] \
        [get_bd_pins proc_sys_reset_0/aux_reset_in] \
        [get_bd_pins proc_sys_reset_0/mb_debug_sys_rst]
    connect_bd_net [get_bd_pins const1/dout] \
        [get_bd_pins proc_sys_reset_0/dcm_locked]
    connect_bd_net [get_bd_pins proc_sys_reset_0/peripheral_aresetn] \
        [get_bd_pins axi_interconnect_0/ARESETN] \
        [get_bd_pins axi_interconnect_0/S00_ARESETN] \
        [get_bd_pins axi_interconnect_0/S01_ARESETN] \
        [get_bd_pins axi_interconnect_0/M00_ARESETN] \
        [get_bd_pins axi_interconnect_0/M01_ARESETN] \
        [get_bd_pins axi_interconnect_0/M02_ARESETN] \
        [get_bd_pins axi_bram_ctrl_0/s_axi_aresetn] \
        [get_bd_pins axi_gpio_ctrl/s_axi_aresetn] \
        [get_bd_pins axi_gpio_status/s_axi_aresetn]

    create_bd_port -dir O -type clk FCLK_CLK0
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_CLK0] [get_bd_ports FCLK_CLK0]

    create_bd_port -dir O -type rst FCLK_RESET0_N
    set_property CONFIG.POLARITY {ACTIVE_LOW} [get_bd_ports FCLK_RESET0_N]
    connect_bd_net [get_bd_pins processing_system7_0/FCLK_RESET0_N] [get_bd_ports FCLK_RESET0_N]
}

validate_bd_design
save_bd_design

puts "PS_BD_CREATED stage=$stage"
