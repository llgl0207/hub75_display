# Standalone non-project check: does not reset or overwrite GUI project runs.
set src_dir [file dirname [file normalize [info script]]]
set out_dir [file join $src_dir ir_test synthesis]
file mkdir $out_dir
read_verilog [file join $src_dir ir_revolution_sync.v]
synth_design -top ir_revolution_sync -part xc7z020clg400-2
create_clock -name capture_clk -period 20.000 [get_ports clk]
# Only the asynchronous external input to the FIRST synchronizer stage is cut.
# The meta -> sync path remains timed for metastability resolution.
set meta_d [get_pins -hier -filter {NAME =~ *ir_meta_reg/D}]
if {[llength $meta_d] != 1} { error "Expected one first-stage synchronizer D pin" }
set_false_path -from [get_ports ir_in] -to $meta_d
opt_design
report_utilization -file [file join $out_dir utilization.rpt]
report_timing_summary -file [file join $out_dir timing.rpt]
report_cdc -file [file join $out_dir cdc.rpt]
write_checkpoint -force [file join $out_dir ir_synth.dcp]
