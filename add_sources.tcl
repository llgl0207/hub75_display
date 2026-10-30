# Run from Vivado Tcl Console with this project open:
# source ./add_sources.tcl
set proj_dir [get_property DIRECTORY [current_project]]
if {[file tail [get_property NAME [current_project]]] ne "hub75_display"} {
    puts "Warning: current project is not named hub75_display; continuing with its directory."
}
set design_files [get_files -quiet [file join $proj_dir hub75_scan.v]]
if {[llength $design_files] == 0} { add_files -norecurse [file join $proj_dir hub75_scan.v] }
set top_files [get_files -quiet [file join $proj_dir hub75_top.v]]
if {[llength $top_files] == 0} { add_files -norecurse [file join $proj_dir hub75_top.v] }
set ir_files [get_files -quiet [file join $proj_dir ir_revolution_sync.v]]
if {[llength $ir_files] == 0} { add_files -norecurse [file join $proj_dir ir_revolution_sync.v] }
if {[llength [get_files -quiet [file join $proj_dir ir_debug_uart.v]]] == 0} { add_files -norecurse [file join $proj_dir ir_debug_uart.v] }
set_property top hub75_top [get_filesets sources_1]
update_compile_order -fileset sources_1
set sim_files [get_files -quiet -of_objects [get_filesets sim_1] [file join $proj_dir tb_hub75_scan.v]]
if {[llength $sim_files] == 0} { add_files -fileset sim_1 -norecurse [file join $proj_dir tb_hub75_scan.v] }
set ir_sim_files [get_files -quiet -of_objects [get_filesets sim_1] [file join $proj_dir tb_ir_revolution_sync.v]]
if {[llength $ir_sim_files] == 0} { add_files -fileset sim_1 -norecurse [file join $proj_dir tb_ir_revolution_sync.v] }
set_property top tb_hub75_scan [get_filesets sim_1]
update_compile_order -fileset sim_1
set xdc_file [get_files -quiet -of_objects [get_filesets constrs_1] [file join $proj_dir constraints hub75_mizar_z7.xdc]]
if {[llength $xdc_file] == 0} { add_files -fileset constrs_1 -norecurse [file join $proj_dir constraints hub75_mizar_z7.xdc] }
