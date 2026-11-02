# Load the bare-metal diagnostic over JTAG, run it with the CPU (so PL AXI
# accesses are legal), then read the recorded timeline from DDR.
set elf "C:/Users/210/Documents/intcode/123/hub75_display/build/work/jtag_diag.elf"
set RESULT 0x001001f8
set COUNT  0x001001f0
set DONE   0x001001f4

connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
puts "PC_BEFORE=[rrd pc]"

if {[catch {dow $elf} e]} {
    puts "DOW_FAIL: $e"
    return
}
puts "DOWNLOADED"
after 100
catch {con}
after 1500
catch {stop}
after 100
puts "PC_AFTER=[rrd pc]"
puts "DONE_FLAG=[mrd $DONE]"
set cnt 0
catch {set cnt [mrd -value $COUNT]}
puts "RESULT_COUNT=$cnt"
if {$cnt <= 0 || $cnt > 2200} {
    puts "BAD_COUNT"
    return
}
set i 0
while {$i < $cnt} {
    set chunk [expr {($i + 64 <= $cnt) ? 64 : $cnt - $i}]
    set addr [expr {$RESULT + 4 * $i}]
    puts "CHUNK $i $chunk"
    puts [mrd $addr $chunk]
    incr i $chunk
}
puts "BM_DIAG_DONE"
