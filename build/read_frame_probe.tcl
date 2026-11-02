# Verify the row-address mapping fix in the static two-ball frame.
# row0: upper (physical y=31) + lower (physical y=32) should both contain balls
# row20/row31: should now be zero (they were the misplaced upper half before).
connect -url TCP:localhost:3122
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
puts "ROW0:"
for {set i 0} {$i < 32} {incr i} {
    set a [expr {0x10000000 + 4*$i}]
    puts [format "%08x %s" $a [mrd -size w $a]]
}
puts "ROW20:"
for {set i 0} {$i < 32} {incr i} {
    set a [expr {0x10000780 + 4*$i}]
    puts [format "%08x %s" $a [mrd -size w $a]]
}
puts "ROW31:"
for {set i 0} {$i < 32} {incr i} {
    set a [expr {0x10000BA0 + 4*$i}]
    puts [format "%08x %s" $a [mrd -size w $a]]
}
catch {con}
