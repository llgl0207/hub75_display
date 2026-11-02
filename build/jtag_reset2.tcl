connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
foreach {a name} {0xF8000250 RESET_REASON 0xF8000254 RESET_REASON_CLR 0xF8000258 REBOOT_STATUS 0xF8005000 SWDT_CR 0xF8005004 SWDT_SR 0xF8005008 SWDT_RST 0xF800500C SWDT_?} {
  if {[catch {set v [mrd -value $a]} e]} { puts "ERR $name" } else { puts [format "%s = %08x" $name $v] }
}
puts "R2_DONE"
