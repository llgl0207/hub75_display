connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
foreach a {0xF8000258 0xF8000240 0xF8005000 0xF8005004} {
  if {[catch {set v [mrd -value $a]} e]} { puts "ERR $a $e" } else { puts [format "REG %08x = %08x" $a $v] }
}
puts "RS_DONE"
