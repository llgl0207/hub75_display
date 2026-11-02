# Clear a possibly half-configured PL, then let the JTAG tool configure it.
# Mirrors the FSBL InitDcfg PROG_B pulse (DEVCFG CTRL bit30).
set bit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100

set ctrl [mrd -value 0xF8007000]
puts "CTRL_BEFORE=[format 0x%08x $ctrl]"
# PROG_B active (clear the PL)
mwr 0xF8007000 [expr {$ctrl & ~0x40000000}]
after 10
puts "STATUS_CLEARED=[mrd 0xF8007014]"
# Release PROG_B
mwr 0xF8007000 [expr {$ctrl | 0x40000000}]
after 10
puts "STATUS_RELEASED=[mrd 0xF8007014]"
puts "CTRL_AFTER=[mrd 0xF8007000]"

targets -set -filter {name =~ "*xc7z020*"}
if {[catch {fpga -file $bit} err]} {
    puts "FPGA_FAIL: $err"
} else {
    puts "FPGA_PROGRAMMED"
}
