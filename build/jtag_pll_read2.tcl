connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
stop
after 200
if {[catch {set v1 [mrd -value 0xF8000108]} e]} { puts "ERR1: $e" } else { puts [format "IO_PLL_CTRL=0x%08x" $v1] }
if {[catch {set v2 [mrd -value 0xF800010C]} e]} { puts "ERR2: $e" } else { puts [format "PLL_STATUS=0x%08x" $v2] }
if {[catch {set v3 [mrd -value 0xF8000170]} e]} { puts "ERR3: $e" } else { puts [format "FPGA0_CLK_CTRL=0x%08x" $v3] }
puts "PLL_DONE"
