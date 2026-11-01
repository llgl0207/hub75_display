# Build the Zynq PS system for the Mizar-Z7 board.
#
# Usage:
#   vivado -mode batch -source build/build_ps_system.tcl
#   vivado -mode batch -source build/build_ps_system.tcl -tclargs 1
#
# Stage 0 (default): PS-only BD; the wrapper is the top. Purpose: prove PS boot,
#   UART0 console and DDR3 memory before any PL logic is added.
# Stage 1: PS BD (AXI GPIO control/status + S_AXI_HP0) plus the HUB75 RTL top
#   system_top. Not implemented in this script yet; it will be added with the
#   reader/scan-memory RTL.
#
# Outputs:
#   board/output/hub75_ps_stage<stage>.bit
#   board/output/hub75_ps_stage<stage>.xsa
#   build/reports/ps_stage<stage>/timing.rpt, utilization.rpt, drc.rpt, cdc.rpt, io.rpt

set stage 0
if {$argc > 0} { set stage [lindex $argv 0] }

set build_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $build_dir]
set work_dir [file join $build_dir work hub75_ps_stage$stage]
set report_dir [file join $build_dir reports ps_stage$stage]
set board_out [file join $repo_dir board output]
file mkdir $work_dir $report_dir $board_out
set project_dir [file join $work_dir hub75_ps]

create_project -force hub75_ps $project_dir -part xc7z020clg400-2

# create_ps_bd.tcl expects an open project and the stage variable.
source [file join $build_dir create_ps_bd.tcl]

set bd_file [get_files design_1.bd]
set wrapper_files [make_wrapper -files $bd_file -top]
add_files -norecurse $wrapper_files

if {$stage == 0} {
    set_property top design_1_wrapper [current_fileset]
} else {
    # Stage 1 sources are added when the reader/scan-memory path is implemented.
    set rtl_files [list \
        [file join $repo_dir src hub75_scan.v] \
        [file join $repo_dir src hub75_sched.v] \
        [file join $repo_dir src ir_revolution_sync.v] \
        [file join $repo_dir src ir_debug_uart.v] \
        [file join $repo_dir src hub75_ps_top.v] \
        [file join $repo_dir src hub75_slice_ram.v] \
        [file join $repo_dir src hub75_ddr_reader.v] \
        [file join $repo_dir src hub75_system.v] \
        [file join $repo_dir src system_top.v]]
    foreach f $rtl_files {
        if {[llength [get_files -quiet $f]] == 0} { add_files -norecurse $f }
    }
    set xdc [file join $repo_dir board constraints hub75_ps.xdc]
    add_files -fileset constrs_1 -norecurse $xdc
    set_property top system_top [current_fileset]
}
update_compile_order -fileset sources_1

launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis failed" }
open_run synth_1

# Board key reset is asynchronous. The reset synchronizer is inside hub75_top to
# keep the path local; only the async CLR/PRE pins are exempt. Stage 0 has no
# user reset pin at all, so the filter is harmless when it returns nothing.
set reset_pins [get_pins -hier -filter {NAME =~ *reset_pipe_reg*/CLR || NAME =~ *reset_pipe_reg*/PRE}]
if {[llength $reset_pins] > 0} {
    set_false_path -from [get_ports reset_n] -to $reset_pins
}

write_checkpoint -force [file join $report_dir synth.dcp]
opt_design
place_design
phys_opt_design
route_design
if {$stage != 0} {
    # The PS build has a small positive hold slack after route (tens of ps).
    # Post-route hold fixing adds margin without changing the logic.
    phys_opt_design -hold_fix
}
report_timing_summary -file [file join $report_dir timing.rpt]
report_utilization -file [file join $report_dir utilization.rpt]
report_drc -file [file join $report_dir drc.rpt]
report_cdc -file [file join $report_dir cdc.rpt]
report_io -file [file join $report_dir io.rpt]
write_checkpoint -force [file join $report_dir routed.dcp]

set setup [get_timing_paths -delay_type max -max_paths 1]
set hold [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup] > 0} { puts "WNS=[get_property SLACK $setup] ns" } else { puts "WNS: no user timing paths" }
if {[llength $hold] > 0} { puts "WHS=[get_property SLACK $hold] ns" } else { puts "WHS: no user timing paths" }
if {$stage != 0} {
    if {[llength $setup] == 0 || [llength $hold] == 0} { error "No timing paths were reported" }
    if {[get_property SLACK $setup] < 0 || [get_property SLACK $hold] < 0} { error "Internal timing failed" }
}

# ASCII "HUB7" = 0x48554237; same identifier as the PL-only board build.
set_property BITSTREAM.CONFIG.USERID 0x48554237 [current_design]
set bitfile [file join $board_out hub75_ps_stage$stage.bit]
write_bitstream -force $bitfile
# write_hw_platform -include_bit needs a completed impl_1 run; this script uses
# the explicit opt/place/route flow, so export the XSA without the bitstream and
# let Vitis program the .bit separately (the Run Configuration Program FPGA step).
write_hw_platform -fixed -force [file join $board_out hub75_ps_stage$stage.xsa]
puts "PS_SYSTEM_BUILD_COMPLETE stage=$stage USERID=0x48554237 BIT=$bitfile"
puts "NOTE: XSA exported without bitstream; select the .bit in the Vitis run configuration."
