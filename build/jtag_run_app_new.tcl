# JTAG control test with the ENET-enabled XSA: program the new bitstream,
# run the new ps7_init, download the bare-metal renderer and resume.
# Usage: xsdb build/jtag_run_app_new.tcl

set bit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
set ps7init "C:/Users/210/Documents/intcode/123/hub75_display/build/work/vitis_sd/hub75_sd_platform/export/hub75_sd_platform/hw/sdt/ps7_init.tcl"
set elf "C:/Users/210/Documents/intcode/123/hub75_display/build/work/vitis_sd/hub75_renderer/build/hub75_renderer.elf"

connect -url TCP:localhost:3122

set halted 0
if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} {
    if {![catch {stop}]} { set halted 1 }
}
if {!$halted} {
    puts "A9 halt failed; resetting the PS"
    catch {targets 1; rst -system} rsterr
    after 1000
    catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}
}
puts "A9_HALTED"

# The board may be running Linux with the MMU on; ps7_init uses physical
# addresses through the A9 target, so reset the PS first to get a bare A9.
puts "== resetting PS for bare-metal ps7_init =="
catch {targets 1; rst -system} rsterr
after 1500
catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}
puts "PS_RESET"

puts "== programming PL =="
targets -set -filter {name =~ "*xc7z020*"}
fpga -file $bit
puts "FPGA_PROGRAMMED"

catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}

puts "== ps7_init =="
source $ps7init
ps7_init
ps7_post_config
puts "PS7_INIT_DONE"

puts "== SLCR clocks/resets =="
puts "FPGA0_CLK_CTRL   = [mrd 0xF8000170]"
puts "FPGA_RST_CTRL    = [mrd 0xF8000240]"
puts "APER_CLK_CTRL    = [mrd 0xF800012C]"
puts "DDRC_CTRL        = [mrd 0xF8006000]"

puts "== downloading ELF =="
dow $elf
puts "ELF_DOWNLOADED"

puts "== resuming =="
con
puts "APP_RUNNING"
