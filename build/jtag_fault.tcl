connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
foreach r {pc cpsr dfsr dfar ifsr ifar} {
  if {[catch {set v [rrd $r]} e]} { puts "$r ERR: $e" } else { puts "$r = $v" }
}
puts "FAULT_DONE"
