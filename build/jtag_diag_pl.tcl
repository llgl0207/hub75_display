# UART-free PL bring-up test (known-good reset/program sequence).
#
# The SD boot is currently stuck in the FSBL, so this script bypasses the OS:
# reset the PS the same way jtag_run_app_new.tcl did, program the new
# bitstream, run ps7_init, then drive the AXI GPIO and sample status through
# the DAP. The CPU stays halted; no ELF or UART is needed.
#
# Usage: xsdb build/jtag_diag_pl.tcl

set bit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
set ps7init "C:/Users/210/Documents/intcode/123/hub75_display/build/work/vitis_sd/hub75_sd_platform/export/hub75_sd_platform/hw/sdt/ps7_init.tcl"

connect -url TCP:127.0.0.1:3121

set halted 0
if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} {
    if {![catch {stop}]} { set halted 1 }
}
puts "A9_HALTED=$halted"

puts "== reset PS =="
catch {targets 1; rst -system}
after 1500
catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}

puts "== program PL =="
targets -set -filter {name =~ "*xc7z020*"}
fpga -file $bit
puts "FPGA_PROGRAMMED"

catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}
puts "== ps7_init =="
source $ps7init
ps7_init
ps7_post_config
puts "PS7_INIT_DONE"

targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}

puts "== AXI GPIO probe =="
mwr 0x41200004 0
mwr 0x4120000C 0
mwr 0x41200000 0x42000000
puts "CTRL_FRAME_BASE=[mrd 0x41200000]"
puts "CTRL_FRAME_CTRL=[mrd 0x41200008]"
puts "STATUS=[mrd 0x41210000]"
puts "PERIOD=[mrd 0x41210008]"

puts "== scheduler cadence (20 x 5 ms) =="
for {set i 0} {$i < 20} {incr i} {
    puts "S$i [mrd 0x41210000]"
    after 5
}

puts "== submit toggle =="
catch {set c2 [mrd -value 0x41200008]}
if {![info exists c2]} { set c2 0 }
puts "ctrl2_before=[format 0x%08x $c2]"
set w [expr {($c2 ^ 1) | 2}]
mwr 0x41200008 $w
puts "ctrl2_after=[format 0x%08x $w]"
puts "CTRL2_READBACK=[mrd 0x41200008]"

puts "== poll after submit (40 x 50 ms) =="
for {set i 0} {$i < 40} {incr i} {
    puts "P$i [mrd 0x41210000]"
    after 50
}
puts "FINAL_STATUS=[mrd 0x41210000]"
puts "FINAL_PERIOD=[mrd 0x41210008]"
puts "JTAG_DIAG_DONE"
