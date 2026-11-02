# Run the bare-metal real-time BRAM animation.
# Linux may be running with the MMU on, so reset the PS first (like the
# known-good bare-metal flows), program the PL, run ps7_init, load the app.
set bit    "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
set oldbit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ir_test.bit"
set elf    "C:/Users/210/Documents/intcode/123/hub75_display/build/work/bram_anim.elf"
set DBG    0x00100ee4
set PS7INIT "C:/Users/210/Documents/intcode/123/hub75_display/build/work/vitis_sd/hub75_sd_platform/export/hub75_sd_platform/hw/sdt/ps7_init.tcl"

connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}

puts "== reset PS for a bare A9 =="
catch {targets 1; rst -system}
after 1500
catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}

puts "== program PL =="
targets -set -filter {name =~ "*xc7z020*"}
if {[catch {fpga -file $bit} e1]} {
    puts "FPGA1_FAIL"
    catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}
    catch {mwr 0xF8000008 0xDF0D}
    set d [mrd -value 0xF8007000]
    mwr 0xF8007000 [expr {$d & ~0x40000000}]
    after 20
    mwr 0xF8007000 [expr {$d | 0x40000000}]
    after 20
    targets -set -filter {name =~ "*xc7z020*"}
    if {![catch {fpga -file $oldbit}]} { puts "OLD_PROGRAMMED" }
    after 200
    targets -set -filter {name =~ "*xc7z020*"}
    if {[catch {fpga -file $bit} e3]} { puts "FPGA2_FAIL: $e3" } else { puts "FPGA_PROGRAMMED" }
} else {
    puts "FPGA_PROGRAMMED"
}

catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}
puts "== ps7_init =="
source $PS7INIT
ps7_init
ps7_post_config
puts "PS7_INIT_DONE"

if {[catch {dow $elf} e]} { puts "DOW_FAIL: $e"; return }
puts "DOWNLOADED"
after 100
catch {con}
after 3000
catch {stop}
after 100
puts "PC_AFTER=[rrd pc]"
if {[catch {set f0 [mrd -value [expr {$DBG + 0}]]} e]} {
    puts "DBG_FAIL: $e"
} else {
    puts [format "DBG frames=%u latches=%u timeouts=%u t0=%u last_status=0x%08x status=0x%08x period=%u" \
        $f0 [mrd -value [expr {$DBG + 4}]] \
        [mrd -value [expr {$DBG + 8}]] [mrd -value [expr {$DBG + 12}]] \
        [mrd -value [expr {$DBG + 16}]] [mrd -value [expr {$DBG + 20}]] \
        [mrd -value [expr {$DBG + 24}]]]
}
catch {con}
puts "ANIM_RUNNING"
