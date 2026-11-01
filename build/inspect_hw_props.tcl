# Inspect actual property names available on the PL device (read-only).
open_hw_manager
connect_hw_server -url localhost:3121
foreach tgt [get_hw_targets] {
    if {[catch {current_hw_target $tgt; open_hw_target -quiet} err]} { continue }
    foreach dev [get_hw_devices] {
        set part "<none>"
        catch {set part [get_property PART $dev]}
        if {![string match "*7z020*" $part]} { continue }
        current_hw_device $dev
        refresh_hw_device -quiet $dev
        puts "DEVICE: $dev PART=$part"
        foreach prop [lsort [list_property $dev]] {
            if {[string match -nocase "*program*" $prop] || [string match -nocase "*register*" $prop]} {
                if {![catch {set val [get_property $prop $dev]}]} {
                    puts "  $prop = $val"
                } else {
                    puts "  $prop = <unreadable>"
                }
            }
        }
    }
    close_hw_target
}
close_hw_manager
