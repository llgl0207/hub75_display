# Reproducible PL-only board test build. Generated project stays under build/work.
set build_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $build_dir]
set work_dir [file join $build_dir work]
set report_dir [file join $build_dir reports]
set board_out [file join $repo_dir board output]
file mkdir $work_dir $report_dir $board_out
set project_dir [file join $work_dir ir_board_test]
create_project -force ir_board_test $project_dir -part xc7z020clg400-2
add_files [list \
    [file join $repo_dir src hub75_top.v] \
    [file join $repo_dir src hub75_sched.v] \
    [file join $repo_dir src hub75_scan.v] \
    [file join $repo_dir src ir_revolution_sync.v] \
    [file join $repo_dir src ir_debug_uart.v]]
add_files -fileset constrs_1 [file join $repo_dir board constraints hub75_mizar_z7.xdc]
set_property top hub75_top [current_fileset]
# 64 slots per revolution, 32 row addresses per slot, 1800 RPM fallback.
# PATTERN_MODE=2 selects the rgb1/rgb2 group-alignment diagnostic (rgb1 red,
# rgb2 green); use 1 for the closed-loop slice sweep and 0 for the colour bars.
# RGB2_COLUMN_OFFSET corrects a measured column offset of the rgb2 half.
set_property generic {IR_FALLING_EDGE=0 SLOT_LOG2=6 ROW_LOG2=5 FALLBACK_RPM=1800 PATTERN_MODE=2 RGB2_COLUMN_OFFSET=0} [current_fileset]
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "Synthesis failed"}
open_run synth_1
# Board key is asynchronous; only the reset synchronizer's async pins are exempt.
set reset_pins [get_pins -hier -filter {NAME =~ *reset_pipe_reg*/CLR || NAME =~ *reset_pipe_reg*/PRE}]
if {[llength $reset_pins] > 0} {
    set_false_path -from [get_ports reset_n] -to $reset_pins
}
# BASIC license does not allow ILA insertion; diagnostics use LED and RTL UART.
write_checkpoint -force [file join $report_dir test_synth.dcp]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary -file [file join $report_dir timing.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_cdc -file [file join $report_dir cdc.rpt]
report_io -file [file join $report_dir io.rpt]
write_checkpoint -force [file join $report_dir routed.dcp]
set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup] == 0 || [llength $hold] == 0} {error "No internal timing paths were reported"}
if {[get_property SLACK $setup] < 0 || [get_property SLACK $hold] < 0} {error "Internal timing failed"}
# Embed an identifyable USERID so a programmed board can prove which build it runs.
# ASCII "HUB7" = 0x48554237. Read back with build/verify_bitstream.tcl.
set_property BITSTREAM.CONFIG.USERID 0x48554237 [current_design]
write_bitstream -force [file join $board_out hub75_ir_test.bit]
puts "BOARD_TEST_BUILD_COMPLETE USERID=0x48554237"
