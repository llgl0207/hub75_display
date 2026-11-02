connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 150
if {[catch {set pc [rrd pc]} e]} { puts "PCERR $e" } else { puts "PC=$pc" }
foreach {off name} {0 frames 4 latches 8 timeouts 12 t0 16 last_status 20 status 24 period} {
    if {[catch {set v [mrd -value [expr {0x00100ee4 + $off}]]} e]} { puts "$name ERR" } else { puts [format "%s = 0x%08x" $name $v] }
}
puts "ANIMDUMP_DONE"
