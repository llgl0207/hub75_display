set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $script_dir]
open_project [file join $repo_dir hub75_display.xpr]
# Keep the GUI project in sync with src/ before validating; the batch build never
# reads the XPR, but a stale file list breaks GUI runs.
source [file join $script_dir add_sources.tcl]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
set expected [list \
    [file join $repo_dir src hub75_top.v] \
    [file join $repo_dir src hub75_sched.v] \
    [file join $repo_dir src hub75_scan.v] \
    [file join $repo_dir src ir_revolution_sync.v] \
    [file join $repo_dir src ir_debug_uart.v] \
    [file join $repo_dir board constraints hub75_mizar_z7.xdc]]
foreach path $expected {
    if {[llength [get_files -quiet $path]] != 1} {error "Project file missing or duplicated: $path"}
}
puts "PROJECT_PATHS_VALIDATED"
close_project
