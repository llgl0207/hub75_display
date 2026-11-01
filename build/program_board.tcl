# Program the PL board-test bitstream over JTAG, without the GUI.
#
# Usage: vivado -mode batch -source build/program_board.tcl
# Optional: -tclargs <bitfile> <part-substring>
#
# Writes volatile PL configuration only; never touches QSPI/SD boot media.
# Close any GUI Hardware Manager session on the same device first.
#
# Success criterion: this Vivado version has NO PROGRAM.IS_PROGRAMMED property.
# Use the configuration status register instead - DONE_PIN (BIT14) and EOS (BIT04).

set bitfile [expr {$argc > 0 ? [lindex $argv 0] : ""}]
set partmatch [expr {$argc > 1 ? [lindex $argv 1] : "7z020"}]
set repo_dir [file dirname [file dirname [file normalize [info script]]]]
if {$bitfile eq ""} { set bitfile [file join $repo_dir board output hub75_ir_test.bit] }

if {![file exists $bitfile]} {
    error "Bitstream not found: $bitfile\nRun: vivado -mode batch -source build/build_board_test.tcl"
}

# Read DONE/EOS using whichever property names this tool version exposes.
proc config_state {dev} {
    set state [dict create done "<unreadable>" eos "<unreadable>"]
    foreach {key path} {done REGISTER.CONFIG_STATUS.BIT14_DONE_PIN eos REGISTER.CONFIG_STATUS.BIT04_END_OF_STARTUP_\(EOS\)_STATUS} {
        if {![catch {dict set state $key [get_property $path $dev]}]} {}
    }
    if {[dict get $state done] eq "<unreadable>"} {
        if {![catch {dict set state done [get_property REGISTER.IR.BIT5_DONE $dev]}]} {}
    }
    return $state
}

open_hw_manager
# Vitis 2026.1 may start its hardware server on a dynamic port (observed 3122);
# try the classic 3121 first, then 3122.
if {[catch {connect_hw_server -url localhost:3121} hw_err]} {
    puts "localhost:3121 failed ($hw_err); trying localhost:3122"
    connect_hw_server -url localhost:3122
}
set programmed 0
foreach tgt [get_hw_targets] {
    if {[catch {current_hw_target $tgt; open_hw_target -quiet} err]} {
        puts "Skip target $tgt : $err"
        continue
    }
    foreach dev [get_hw_devices] {
        set part "<none>"
        catch {set part [get_property PART $dev]}
        if {![string match "*$partmatch*" $part]} { continue }
        current_hw_device $dev
        refresh_hw_device -quiet $dev

        set before [config_state $dev]
        puts "DEVICE: $dev  PART=$part"
        puts "BEFORE: done=[dict get $before done] eos=[dict get $before eos]"

        set_property PROGRAM.FILE $bitfile $dev
        set_property PROBES.FILE {} $dev
        set_property FULL_PROBES.FILE {} $dev
        puts "PROGRAMMING: $bitfile"
        program_hw_devices $dev
        refresh_hw_device -quiet $dev

        set after [config_state $dev]
        puts "AFTER : done=[dict get $after done] eos=[dict get $after eos]"
        if {[dict get $after done] == 1} { set programmed 1 }
    }
    close_hw_target
}
close_hw_manager

if {!$programmed} {
    error "Programming did not reach DONE=1. Check bitstream/part match and JTAG connection."
}
puts "PROGRAM_COMPLETE"
