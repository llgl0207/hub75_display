# Program the PL through Vivado's hardware manager (hw_server on 3121).
# Does not reset or halt the PS beyond what programming requires.
set bit "C:/Users/210/Documents/intcode/123/hub75_display/board/output/hub75_ps_stage1.bit"

open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets]
puts "TARGETS: $targets"
if {[llength $targets] == 0} {
    puts "PROGRAM_RESULT: no_targets"
    close_hw_manager
    return
}
current_hw_target [lindex $targets 0]
if {[catch {open_hw_target -quiet} err]} {
    puts "OPEN_TARGET_FAILED: $err"
    close_hw_manager
    return
}
set devs [get_hw_devices]
puts "DEVICES: $devs"
set dev ""
foreach d $devs {
    if {[string match "*xc7z020*" $d]} { set dev $d }
}
if {$dev eq ""} {
    puts "PROGRAM_RESULT: no_pl_device"
    close_hw_target
    close_hw_manager
    return
}
puts "PROGRAMMING: $dev <- $bit"
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev
set_property PROGRAM.FILE $bit $dev
if {[catch {program_hw_devices $dev} err]} {
    puts "PROGRAM_RESULT: failed $err"
} else {
    puts "PROGRAM_RESULT: ok"
}
close_hw_target
close_hw_manager
