set elf "C:/Users/210/Documents/intcode/123/hub75_display/build/work/jtag_copy_diag2.elf"
set RESULT 0x00100238
set COUNT  0x00100a38
set DONE   0x00100a3c
connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
if {[catch {dow $elf} e]} { puts "DOW_FAIL: $e"; return }
puts "DOWNLOADED"
after 100
catch {con}
after 2500
catch {stop}
after 100
puts "PC_AFTER=[rrd pc]"
puts "DONE_FLAG=[mrd $DONE]"
set cnt 0
catch {set cnt [mrd -value $COUNT]}
puts "RESULT_COUNT=$cnt"
if {$cnt > 0 && $cnt < 500} {
    set i 0
    while {$i < $cnt} {
        set chunk [expr {($i + 64 <= $cnt) ? 64 : $cnt - $i}]
        puts "CHUNK $i $chunk"
        puts [mrd [expr {$RESULT + 4 * $i}] $chunk]
        incr i $chunk
    }
}
puts "COPY2_DONE"
