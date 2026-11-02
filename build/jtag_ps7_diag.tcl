# The PS was reset and never reached ps7_init, so FCLK0 is off and the PL
# resets are asserted. Run ps7_init from the debugger, then exercise the
# AXI GPIO/submit path with the CPU halted.
set ps7init "C:/Users/210/Documents/intcode/123/hub75_display/build/work/vitis_sd/hub75_sd_platform/export/hub75_sd_platform/hw/sdt/ps7_init.tcl"

connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100

puts "== ps7_init =="
source $ps7init
ps7_init
ps7_post_config
puts "PS7_INIT_DONE"

puts "SLCR_FPGA0_CLK_CTRL=[mrd 0xF8000170]"
puts "SLCR_FPGA_RST_CTRL=[mrd 0xF8000240]"
puts "SLCR_APER_CLK_CTRL=[mrd 0xF800012C]"

mwr 0x41200004 0
mwr 0x4120000C 0
mwr 0x41200000 0x42000000
puts "CTRL_FRAME_BASE=[mrd 0x41200000]"
puts "CTRL_FRAME_CTRL=[mrd 0x41200008]"
puts "STATUS0=[mrd 0x41210000]"
puts "PERIOD0=[mrd 0x41210008]"

puts "== scheduler cadence (20 x 5 ms) =="
for {set i 0} {$i < 20} {incr i} {
    puts "S$i [mrd 0x41210000]"
    after 5
}

puts "== submit toggle =="
set c2 [mrd -value 0x41200008]
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
