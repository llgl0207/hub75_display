# Read-only probe: list JTAG targets/devices on the running hw_server.
# Does not program, reset or open the device for modification.
# Note: a Zynq-7000 target exposes both arm_dap_0 (PS debug) and xc7z020_1 (PL);
# not every device has PROGRAM.* properties, so all property reads are guarded.
set out_dir [file join [file dirname [file normalize [info script]]] reports]
file mkdir $out_dir
open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets]
if {[llength $targets] == 0} {
    puts "PROBE_RESULT: no_hw_targets"
    close_hw_manager
    return
}
foreach tgt $targets {
    puts "TARGET: $tgt"
    if {[catch {current_hw_target $tgt; open_hw_target -quiet} err]} {
        puts "  OPEN_FAILED: $err"
        continue
    }
    foreach dev [get_hw_devices] {
        set part "<none>"
        catch {set part [get_property PART $dev]}
        set idcode "<none>"
        catch {set idcode [get_property IDCODE $dev]}
        puts "  DEVICE: $dev  PART=$part  IDCODE=$idcode"
        if {![catch {set prog [get_property PROGRAM.IS_PROGRAMMED $dev]}]} {
            puts "    IS_PROGRAMMED: $prog"
        } else {
            puts "    IS_PROGRAMMED: n/a (not a programmable logic device)"
        }
    }
    close_hw_target
}
puts "PROBE_RESULT: complete"
close_hw_manager
