# Reproduce the original working bare-metal 3D setup:
#   committed HP0 bitstream + matching ps7_init + the old renderer ELF.
set bit    "C:/Users/210/Documents/intcode/123/hub75_display/build/work/stage1_head.bit"
set fallback "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ir_test.bit"
set elf    "C:/Users/210/Documents/intcode/123/hub75_display/build/work/vitis_sd/hub75_renderer/build/hub75_renderer.elf"
set PS7INIT "C:/Users/210/Documents/intcode/123/hub75_display/build/work/old_xsa/ps7_init.tcl"

connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}

puts "== reset PS =="
catch {targets 1; rst -system}
after 1500
catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}

puts "== program HP0 PL =="
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
    if {![catch {fpga -file $fallback}]} { puts "FALLBACK_PROGRAMMED" }
    after 200
    targets -set -filter {name =~ "*xc7z020*"}
    if {[catch {fpga -file $bit} e3]} { puts "FPGA2_FAIL: $e3" } else { puts "FPGA_PROGRAMMED" }
} else {
    puts "FPGA_PROGRAMMED"
}

catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}
puts "== ps7_init (HP0 XSA) =="
source $PS7INIT
ps7_init
ps7_post_config
puts "PS7_INIT_DONE"

if {[catch {dow $elf} e]} { puts "DOW_FAIL: $e"; return }
puts "DOWNLOADED"
after 100
catch {con}
puts "RENDERER_RUNNING"
