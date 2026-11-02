# Pulse PROG_B, then reconnect the JTAG chain so the PL TAP node is fresh,
# then configure the PL.
set bit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100

set ctrl [mrd -value 0xF8007000]
puts "CTRL_BEFORE=[format 0x%08x $ctrl]"
mwr 0xF8007000 [expr {$ctrl & ~0x40000000}]
after 10
mwr 0xF8007000 [expr {$ctrl | 0x40000000}]
after 10
puts "STATUS_RELEASED=[mrd 0xF8007014]"

catch {disconnect}
after 500
connect -url TCP:127.0.0.1:3121
after 500
puts [targets]

targets -set -filter {name =~ "*xc7z020*"}
if {[catch {fpga -file $bit} err]} {
    puts "FPGA_FAIL: $err"
} else {
    puts "FPGA_PROGRAMMED"
}
