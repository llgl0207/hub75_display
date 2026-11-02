# Reconfigure only the PL over JTAG while Linux keeps running on the PS.
# Do NOT reset or halt the A9: this is for testing a rebuilt bitstream against
# an already-booted Linux without reflashing the SD card.
# Usage: xsdb build/jtag_program_pl_only.tcl [bitfile]

set bit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
if {$argc > 0} { set bit [lindex $argv 0] }

connect -url TCP:127.0.0.1:3121
puts "== programming PL only (PS left running) =="
targets -set -filter {name =~ "*xc7z020*"}
fpga -file $bit
puts "FPGA_PROGRAMMED"
