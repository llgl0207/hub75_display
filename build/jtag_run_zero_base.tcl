# Prepare PL+PS and run the unmapped-frame-base test.
set bit    "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
set oldbit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ir_test.bit"
set elf    "C:/Users/210/Documents/intcode/123/hub75_display/build/work/jtag_zero_base.elf"
set RESULT 0x00100180
set COUNT  0x00100178
set DONE   0x0010017c
set PS7INIT "C:/Users/210/Documents/intcode/123/hub75_display/build/work/vitis_sd/hub75_sd_platform/export/hub75_sd_platform/hw/sdt/ps7_init.tcl"

connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100

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
source $PS7INIT
ps7_init
ps7_post_config
puts "PS7_INIT_DONE"

if {[catch {dow $elf} e]} { puts "DOW_FAIL: $e"; return }
puts "DOWNLOADED"
after 100
catch {con}
after 2500
catch {stop}
after 100
puts "PC_AFTER=[rrd pc]"
puts "DONE_FLAG=[mrd $DONE]"
set cnt 0
catch {set cnt [mrd -value $COUNT]}
puts "RESULT_COUNT=$cnt"
if {$cnt > 0 && $cnt < 1000} {
    set i 0
    while {$i < $cnt} {
        set chunk [expr {($i + 64 <= $cnt) ? 64 : $cnt - $i}]
        puts "CHUNK $i $chunk"
        puts [mrd [expr {$RESULT + 4 * $i}] $chunk]
        incr i $chunk
    }
}
puts "ZERO_BASE_DONE"
