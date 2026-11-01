# Run from the Vivado Tcl Console with hub75_display.xpr open.
set project_dir [get_property DIRECTORY [current_project]]
set rtl_dir [file join $project_dir src]
set sim_dir [file join $project_dir sim]
set constr_dir [file join $project_dir board constraints]
foreach source_file {hub75_scan.v hub75_sched.v hub75_top.v ir_revolution_sync.v ir_debug_uart.v} {
    set path [file join $rtl_dir $source_file]
    if {[llength [get_files -quiet $path]] == 0} { add_files -norecurse $path }
}
set_property top hub75_top [get_filesets sources_1]
update_compile_order -fileset sources_1
foreach test_file {tb_hub75_scan.v tb_hub75_sched.v tb_ir_revolution_sync.v tb_ir_debounce.v tb_ir_debug_uart.v} {
    set path [file join $sim_dir $test_file]
    if {[llength [get_files -quiet -of_objects [get_filesets sim_1] $path]] == 0} {
        add_files -fileset sim_1 -norecurse $path
    }
}
set_property top tb_hub75_scan [get_filesets sim_1]
update_compile_order -fileset sim_1
set xdc [file join $constr_dir hub75_mizar_z7.xdc]
if {[llength [get_files -quiet -of_objects [get_filesets constrs_1] $xdc]] == 0} {
    add_files -fileset constrs_1 -norecurse $xdc
}

