# Run after sourcing add_sources.tcl in the open hub75_display project.
set_property top tb_hub75_scan [get_filesets sim_1]
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
run 200 ms
