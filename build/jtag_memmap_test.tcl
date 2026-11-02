connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
catch {mwr 0xF8000008 0xDF0D}
after 5
set clk [mrd -value 0xF8000170]
puts "CLK_BEFORE=[format 0x%08x $clk]"
catch {mwr 0xF8000170 [expr {($clk | 1) & 0xFFFFFFFF}]}
after 10
puts "CLK_AFTER=[mrd 0xF8000170]"
catch {memmap -addr 0x41200000 -size 0x1000}
catch {memmap -addr 0x42000000 -size 0x80000}
puts "LIST_A9:"
catch {puts [memmap -list]}
if {[catch {set s [mrd 0x41210000]} e]} { puts "READ_GPIO_ERR: $e" } else { puts "READ_GPIO=$s" }
