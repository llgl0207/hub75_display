connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
set ok 0
for {set i 0} {$i < 15} {incr i} {
    catch {stop}
    after 60
    if {![catch {set pc [rrd pc]}]} {
        puts "SAMPLE $i $pc"
        incr ok
    }
    catch {con}
    after 300
}
puts "SAMPLES_OK=$ok"
puts "SAMPLES_DONE"
