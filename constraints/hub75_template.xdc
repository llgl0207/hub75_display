# Fill in package pins and I/O standard from the MIZAR R7 schematic.
# Do not program the FPGA with guessed pin assignments.
# set_property PACKAGE_PIN <PIN> [get_ports clk_in]
# set_property IOSTANDARD <IOSTANDARD> [get_ports clk_in]
# create_clock -name sys_clk -period 10.000 [get_ports clk_in]

# Example template for HUB75 outputs; replace every placeholder before use.
# set_property PACKAGE_PIN <PIN> [get_ports {rgb1[2]}]
# set_property IOSTANDARD <IOSTANDARD> [get_ports {rgb1[2]}]
# Repeat for rgb1[1:0], rgb2[2:0], hub_clk, hub_lat, hub_oe_n, hub_addr[4:0].
