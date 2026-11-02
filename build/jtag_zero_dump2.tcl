connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
stop
after 100
if {[catch {set pc [rrd pc]} e]} { puts "PCERR $e" } else { puts "PC=$pc" }
foreach a {0x00100000 0x00100178 0x0010017c 0x00100180 0x00100184 0x00100188 0x0010018c 0x00100190} {
    if {[catch {set v [mrd -value $a]} e]} { puts [format "R %08x ERR %s" $a $e] } else { puts [format "R %08x = %08x" $a $v] }
}
puts "DUMP2_DONE"
