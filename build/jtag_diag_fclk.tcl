# ps7_init has run, the new bitstream is loaded. Two missing pieces:
#   - FCLK0 is gated (CLKACT0=0); U-Boot/Linux normally enables it.
#     SLCR writes need the unlock key first.
#   - the debug memory map does not allow the PL AXI slave range.
# Then exercise the AXI GPIO / submit / revolution path with the CPU halted.
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100

mwr 0xF8000008 0xDF0D
after 5
set clk [mrd -value 0xF8000170]
puts "FCLK_CTRL_BEFORE=[format 0x%08x $clk]"
mwr 0xF8000170 [expr {($clk | 0x1) & 0xFFFFFFFF}]
after 10
puts "FCLK_CTRL_AFTER=[mrd 0xF8000170]"
puts "FPGA_RST_CTRL=[mrd 0xF8000240]"

memmap -addr 0x40000000 -size 0x20000000
puts "MEMMAP_ADDED"
puts "MEMMAP_LIST:"
catch {puts [memmap -list]}

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
