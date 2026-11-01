# GUI version: paste into the Vivado Tcl Console with the project open.
#
# Unlike build/program_board.tcl this does not assume a fresh hardware manager:
# it reuses an already-open target and only connects when nothing is open. It
# also prints DONE/EOS/USERCODE so the result is visible in the console.
#
# Rebuild in a separate shell first (do not run create_project inside the GUI):
#   .\build\vivado.ps1 build\build_board_test.tcl

set bitfile [file join [file dirname [file dirname [file dirname [file normalize [info script]]]]] \
                         board output hub75_ir_test.bit]
if {![file exists $bitfile]} { error "Bitstream not found: $bitfile" }
puts "BITSTREAM: $bitfile"

open_hw_manager
if {[llength [get_hw_targets -quiet]] == 0} {
    connect_hw_server -url localhost:3121
}
foreach tgt [get_hw_targets -quiet] {
    catch {current_hw_target $tgt}
    catch {open_hw_target -quiet}
}

set dev ""
foreach candidate [get_hw_devices -quiet] {
    set part "<none>"
    catch {set part [get_property PART $candidate]}
    if {[string match "*7z020*" $part]} { set dev $candidate }
}
if {$dev eq ""} { error "No 7z020 device found; check the JTAG cable and board power" }
current_hw_device $dev
refresh_hw_device -quiet $dev
puts "DEVICE: $dev"

# This Vivado version has no PROGRAM.IS_PROGRAMMED; use the config status bits.
puts "BEFORE: done=[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"

set_property PROGRAM.FILE $bitfile $dev
set_property PROBES.FILE {} $dev
set_property FULL_PROBES.FILE {} $dev
program_hw_devices $dev
refresh_hw_device -quiet $dev

puts "AFTER : done=[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]"
catch {puts "AFTER : eos=[get_property REGISTER.CONFIG_STATUS.BIT04_END_OF_STARTUP_(EOS)_STATUS $dev]"}
catch {puts "USERCODE=[get_property REGISTER.USERCODE $dev]"}

if {[get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev] != 1} {
    error "Programming did not reach DONE=1"
}
puts "PROGRAM_COMPLETE"
