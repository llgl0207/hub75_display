# The FSBL never reached FabricInit, so the BootROM's PROG_B assertion is
# still holding the PL cleared and JTAG programming fails with DONE low.
# Write DEVCFG CTRL (0xF8007000) with PROG_B released, then program the PL.
set bit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100

puts "DEVCFG_CTRL_INITIAL=[mrd 0xF8007000]"
puts "DEVCFG_STATUS_INITIAL=[mrd 0xF8007014]"
puts "DEVCFG_LOCK=[mrd 0xF8007004]"

set v 0
if {[catch {set v [mrd -value 0xF8007000]} e]} {
    puts "mrd_value_failed: $e"
    set v 0x40000000
}
set nv [expr {($v | 0x1) & 0xFFFFFFFF}]
puts "WRITE_CTRL=[format 0x%08x $nv]"
if {[catch {mwr 0xF8007000 $nv} e]} {
    puts "mwr_failed: $e"
}
after 20
puts "DEVCFG_CTRL_AFTER=[mrd 0xF8007000]"
puts "DEVCFG_STATUS_AFTER=[mrd 0xF8007014]"

targets -set -filter {name =~ "*xc7z020*"}
if {[catch {fpga -file $bit} err]} {
    puts "FPGA_FAIL: $err"
} else {
    puts "FPGA_PROGRAMMED"
}
