# Read back USERCODE from the programmed PL to prove which build is running.
# Expected value is produced by build/build_board_test.tcl (BITSTREAM.CONFIG.USERID).
# No ILA is required: this works on a BASIC license.
set expected 0x48554237
open_hw_manager
connect_hw_server -url localhost:3121
set found 0
set mismatch 0
foreach tgt [get_hw_targets] {
    if {[catch {current_hw_target $tgt; open_hw_target -quiet} err]} { continue }
    foreach dev [get_hw_devices] {
        set part "<none>"
        catch {set part [get_property PART $dev]}
        if {![string match "*7z020*" $part]} { continue }
        current_hw_device $dev
        refresh_hw_device -quiet $dev
        set usercode "<unreadable>"
        catch {set usercode [get_property REGISTER.USERCODE $dev]}
        set done "<unreadable>"
        catch {set done [get_property REGISTER.CONFIG_STATUS.BIT14_DONE_PIN $dev]}
        puts "DEVICE: $dev  USERCODE=$usercode  DONE=$done"
        if {$usercode ne "<unreadable>"} {
            set found 1
            if {[expr {"$usercode" == "$expected"}]} {
                puts "USERCODE_MATCH: $usercode"
            } else {
                set mismatch 1
                puts "USERCODE_MISMATCH: got $usercode expected $expected"
            }
        }
    }
    close_hw_target
}
close_hw_manager
if {!$found} { error "Could not read USERCODE; device not reachable" }
if {$mismatch} { error "Board is running a different bitstream than this build" }
puts "BITSTREAM_VERIFIED"
