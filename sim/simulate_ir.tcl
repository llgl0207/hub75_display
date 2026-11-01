# From the Vivado Tcl Console with the project open, source this file.
set script_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $script_dir]
set saved_sim_top [get_property top [get_filesets sim_1]]
set saved_runtime [get_property xsim.simulate.runtime [get_filesets sim_1]]
set sim_launched 0
try {
    source [file join $repo_dir build add_sources.tcl]
    set_property top tb_ir_revolution_sync [get_filesets sim_1]
    set_property xsim.simulate.runtime 0ns [get_filesets sim_1]
    launch_simulation -simset sim_1 -mode behavioral
    set sim_launched 1
    run all
} finally {
    if {$sim_launched} { close_sim }
    set_property top $saved_sim_top [get_filesets sim_1]
    set_property xsim.simulate.runtime $saved_runtime [get_filesets sim_1]
}

