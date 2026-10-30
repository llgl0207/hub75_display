# MIZAR-Z7 / XC7Z020-2CLG400C
# PL clock: 50 MHz on H16. JP1/JP2 I/O default to 3.3 V per board manual.
set_property PACKAGE_PIN H16 [get_ports clk_in]
set_property IOSTANDARD LVCMOS33 [get_ports clk_in]
create_clock -name pl_clk_50m -period 20.000 [get_ports clk_in]

# PL_KEY1 is active-low when pressed (board manual: R19).
set_property PACKAGE_PIN R19 [get_ports reset_n]
set_property IOSTANDARD LVCMOS33 [get_ports reset_n]

# JP1 pin 33: GPIO1_14P (Mizar-Z7 reference manual), FPGA package pin U13.
# Input must not exceed the selected 3.3 V bank voltage.
set_property PACKAGE_PIN U13 [get_ports ir_in]
set_property IOSTANDARD LVCMOS33 [get_ports ir_in]
# Asynchronous sensor input: cut ONLY the path into the first capture stage.
# Keep the ir_meta -> ir_sync path timed. Resolve cells after synthesis.
set_false_path -from [get_ports ir_in] -to [get_pins -hier -filter {NAME =~ *u_ir_revolution_sync/ir_meta_reg/D}]

# Active-low PL LEDs D6..D9, per Mizar-Z7 manual.
set_property PACKAGE_PIN G14 [get_ports {debug_led_n[0]}]
set_property PACKAGE_PIN C20 [get_ports {debug_led_n[1]}]
set_property PACKAGE_PIN B20 [get_ports {debug_led_n[2]}]
set_property PACKAGE_PIN H17 [get_ports {debug_led_n[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {debug_led_n[*]}]
# External 3.3 V USB-UART receiver: JP1-35 GPIO1_15P = V12.
set_property PACKAGE_PIN V12 [get_ports debug_uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports debug_uart_tx]

# HUB75 outputs assigned only to JP1 P-side signals, on pins 1,3,5,...,27.
# Verify the external adapter/ribbon wiring follows this signal map.
set_property PACKAGE_PIN N18 [get_ports {rgb1[2]}]
set_property PACKAGE_PIN N17 [get_ports {rgb1[1]}]
set_property PACKAGE_PIN N20 [get_ports {rgb1[0]}]
set_property PACKAGE_PIN T17 [get_ports {rgb2[2]}]
set_property PACKAGE_PIN T20 [get_ports {rgb2[1]}]
set_property PACKAGE_PIN V20 [get_ports {rgb2[0]}]
set_property PACKAGE_PIN Y18 [get_ports hub_clk]
set_property PACKAGE_PIN Y16 [get_ports hub_lat]
set_property PACKAGE_PIN W18 [get_ports hub_oe_n]
set_property PACKAGE_PIN U18 [get_ports {hub_addr[0]}]
set_property PACKAGE_PIN V16 [get_ports {hub_addr[1]}]
set_property PACKAGE_PIN V15 [get_ports {hub_addr[2]}]
set_property PACKAGE_PIN W14 [get_ports {hub_addr[3]}]
set_property PACKAGE_PIN U14 [get_ports {hub_addr[4]}]

set_property IOSTANDARD LVCMOS33 [get_ports {rgb1[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports {rgb2[*]}]
set_property IOSTANDARD LVCMOS33 [get_ports hub_clk]
set_property IOSTANDARD LVCMOS33 [get_ports hub_lat]
set_property IOSTANDARD LVCMOS33 [get_ports hub_oe_n]
set_property IOSTANDARD LVCMOS33 [get_ports {hub_addr[*]}]
