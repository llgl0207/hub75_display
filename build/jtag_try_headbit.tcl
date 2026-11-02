set bit "C:/Users/210/Documents/intcode/123/hub75_display/build/work/stage1_head.bit"
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
targets -set -filter {name =~ "*xc7z020*"}
if {[catch {fpga -file $bit} err]} { puts "FPGA_FAIL: $err" } else { puts "FPGA_PROGRAMMED" }
