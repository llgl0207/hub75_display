connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
puts "SAMPLER_START"
for {set i 0} {$i < 460} {incr i} {
    catch {stop}
    after 12
    if {[catch {set pc [rrd pc]}]} {
        puts "S$i HALT_LOST"
    } else {
        if {[catch {set cs [rrd cpsr]}]} { set cs "?" }
        puts "S$i $pc $cs"
    }
    catch {con}
    after 80
}
puts "SAMPLER_DONE"
