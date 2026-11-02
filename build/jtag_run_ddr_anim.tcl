set elf "C:/Users/210/Documents/intcode/123/hub75_display/build/work/ddr_anim.elf"
set DBG 0x00100eb8
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
if {[catch {dow $elf} e]} { puts "DOW_FAIL: $e"; return }
puts "DOWNLOADED"
after 100
catch {con}
after 3000
catch {stop}
after 100
if {[catch {set pc [rrd pc]} e]} { puts "PCERR $e" } else { puts "PC=$pc" }
if {[catch {set nf [mrd -value [expr {$DBG + 0}]]} e]} { puts "DBGFAIL $e" } else {
  puts [format "frames=%u latches=%u timeouts=%u last_status=0x%08x" \
    $nf [mrd -value [expr {$DBG + 4}]] [mrd -value [expr {$DBG + 8}]] [mrd -value [expr {$DBG + 12}]]]
}
catch {con}
puts "DDR_ANIM_RUNNING"
