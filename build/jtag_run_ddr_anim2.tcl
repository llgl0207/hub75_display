set elf "C:/Users/210/Documents/intcode/123/hub75_display/build/work/ddr_anim.elf"
set DBG 0x00100eb8
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 200
if {[catch {set pc [rrd pc]} e]} { puts "PCERR0 $e" } else { puts "PC_BEFORE=$pc" }
if {[catch {dow $elf} e]} { puts "DOW_FAIL: $e"; return }
after 100
if {[catch {set pc [rrd pc]} e]} { puts "PCERR1 $e" } else { puts "PC_AFTER_DOW=$pc" }
catch {rwr pc 0x00100024}
if {[catch {set pc [rrd pc]} e]} { puts "PCERR2 $e" } else { puts "PC_SET=$pc" }
catch {con}
after 3000
catch {stop}
after 150
if {[catch {set pc [rrd pc]} e]} { puts "PCERR3 $e" } else { puts "PC_RUN=$pc" }
if {[catch {set nf [mrd -value [expr {$DBG + 0}]]} e]} { puts "DBGFAIL $e" } else {
  puts [format "frames=%u latches=%u timeouts=%u last_status=0x%08x" \
    $nf [mrd -value [expr {$DBG + 4}]] [mrd -value [expr {$DBG + 8}]] [mrd -value [expr {$DBG + 12}]]]
}
catch {con}
puts "DDR_ANIM_DONE"
