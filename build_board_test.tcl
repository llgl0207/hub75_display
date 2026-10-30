# Vivado batch build; isolated project, preserves existing GUI project/runs.
set src [file dirname [file normalize [info script]]]
set out [file join $src board_test]
file mkdir $out
create_project -force ir_board_test [file join $out project] -part xc7z020clg400-2
add_files [list [file join $src hub75_top.v] [file join $src hub75_scan.v] [file join $src ir_revolution_sync.v] [file join $src ir_debug_uart.v]]
add_files -fileset constrs_1 [file join $src constraints hub75_mizar_z7.xdc]
set_property top hub75_top [current_fileset]
set_property generic {FIELD_HZ=2280 IR_FALLING_EDGE=0} [current_fileset]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
open_run synth_1
# Board key is asynchronous; only its reset synchronizer is exempted.
set_false_path -from [get_ports reset_n] -to [get_pins -hier -filter {NAME =~ *reset_pipe_reg*/CLR || NAME =~ *reset_pipe_reg*/PRE}]
# BASIC license cannot insert ILA: use RTL UART/LED diagnostics instead.
write_checkpoint -force [file join $out test_synth.dcp]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file [file join $out timing.rpt]
report_utilization -file [file join $out utilization.rpt]
report_drc -file [file join $out drc.rpt]
report_cdc -file [file join $out cdc.rpt]
report_io -file [file join $out io.rpt]
write_checkpoint -force [file join $out routed.dcp]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[get_property SLACK $setup] < 0 || [get_property SLACK $hold] < 0} {error "Internal timing failed"}
write_bitstream -force [file join $out hub75_ir_test.bit]
puts "BOARD_TEST_BUILD_COMPLETE"
