connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
puts "IO_PLL_CTRL=[mrd 0xF8000108]"
puts "PLL_STATUS=[mrd 0xF800010C]"
puts "IO_PLL_CFG=[mrd 0xF8000118]"
puts "FPGA0_CLK_CTRL=[mrd 0xF8000170]"
puts "PLL_DONE"
