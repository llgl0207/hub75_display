# Try programming the PL over JTAG WITHOUT resetting the PS (the FSBL is
# currently stuck reading the SD, so the PCAP should be idle). Halts the A9
# first so the BootROM/FSBL stops touching the SD/PCAP.
set bit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"
connect -url TCP:127.0.0.1:3122
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 300
puts "A9_STOPPED"
targets -set -filter {name =~ "*xc7z020*"}
puts "TARGET_OK"
if {[catch {fpga -file $bit} err]} {
    puts "FPGA_FAIL: $err"
} else {
    puts "FPGA_PROGRAMMED"
}
