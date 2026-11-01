# Load Stage 1 bitstream, run ps7_init, then download and start the app.
# Usage: xsdb build/jtag_run_app.tcl [<elf-path>]

if {![info exists argv] || [llength $argv] < 1} {
    set elf "C:/Users/210/Documents/intcode/123/hub75_display/hub75_renderer/build/hub75_renderer.elf"
} else {
    set elf [lindex $argv 0]
}
set bit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
set ps7init "C:/Users/210/Documents/intcode/123/hub75_display/platform/export/platform/hw/ps7_init.tcl"

connect -url TCP:localhost:3122

# Stop the A9 before touching the PL. If the running app has an AXI transaction
# outstanding while the bitstream is replaced, the CPU can hang and hide the
# debug port; program the PL only after the core is halted.
set halted 0
if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}}]} {
    if {![catch {stop}]} { set halted 1 }
}
if {!$halted} {
    # A previous AXI hang can leave the DAP in "APB AP transaction error" and
    # hide the Cortex-A9 targets. A PS system reset clears that state.
    puts "A9 halt failed; resetting the PS"
    catch {targets 1; rst -system} rsterr
    after 1000
    catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}; stop}
}
puts "A9_HALTED"

puts "== programming PL =="
targets -set -filter {name =~ "*xc7z020*"}
fpga -file $bit
puts "FPGA_PROGRAMMED"

# ps7_init runs with the CPU halted.
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
