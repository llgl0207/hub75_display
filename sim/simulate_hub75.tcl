# Run from an open hub75_display project after sourcing ../build/add_sources.tcl.
set_property top tb_hub75_scan [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 200 ms

