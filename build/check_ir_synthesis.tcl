# Standalone non-project check; leaves the main Vivado project runs untouched.
set build_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $build_dir]
set out_dir [file join $build_dir reports ir_standalone]
file mkdir $out_dir
read_verilog [file join $repo_dir src ir_revolution_sync.v]
synth_design -top ir_revolution_sync -part xc7z020clg400-2
create_clock -name capture_clk -period 20.000 [get_ports clk]
# Cut only the asynchronous input path into the first synchronizer stage.
set meta_d [get_pins -hier -filter {NAME =~ *ir_meta_reg/D}]
if {[llength $meta_d] != 1} { error "Expected one first-stage synchronizer D pin" }
set_false_path -from [get_ports ir_in] -to $meta_d
opt_design
report_utilization -file [file join $out_dir utilization.rpt]
report_timing_summary -file [file join $out_dir timing.rpt]
report_cdc -file [file join $out_dir cdc.rpt]
write_checkpoint -force [file join $out_dir ir_synth.dcp]

