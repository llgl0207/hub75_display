# Read the Zynq reset reason and CPU state after an IR-triggered event.
# Usage: xsdb build/read_reset_state.tcl
connect -url TCP:localhost:3122

set t [targets]
puts "NTARGETS=[llength $t]"
foreach x $t { puts "TGT: $x" }

if {![catch {targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}} e]} {
    puts "A9_SELECTED"
    set r [catch {stop} stop_msg]
    puts "STOP rc=$r msg=$stop_msg"
    if {$r == 0} {
        puts "PC=[rrd pc]"
    }
    catch {puts "RESET_REASON=[mrd 0xF8000250]"}
    catch {puts "REBOOT_STATUS=[mrd 0xF8000258]"}
    catch {puts "SWDT_CTRL=[mrd 0xF8001000]"}
    catch {puts "SWDT_STATUS=[mrd 0xF8001010]"}
    if {$r == 0} { catch {con} }
} else {
    puts "A9_SELECT_FAILED: $e"
}
