# Run with Vivado 2026.1: vivado -mode batch -source sim/run_regression.tcl
#
# A $fatal or $error inside a testbench does NOT raise a Tcl error in batch mode,
# so "run all" returning quietly is not evidence of success. Each testbench prints
# its PASS line only when every assertion held, so the transcript is the verdict:
# require a PASS line and reject any Fatal/Error line.
set sim_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $sim_dir]
set out_dir [file join $sim_dir output regression]
set proj_dir [file join $out_dir project]
file mkdir $out_dir
create_project -force hub75_regression $proj_dir -part xc7z020clg400-2
add_files [list \
    [file join $repo_dir src hub75_sched.v] \
    [file join $repo_dir src hub75_scan.v] \
    [file join $repo_dir src ir_revolution_sync.v] \
    [file join $repo_dir src ir_debug_uart.v]]
add_files -fileset sim_1 [list \
    [file join $sim_dir tb_hub75_scan.v] \
    [file join $sim_dir tb_hub75_sched.v] \
    [file join $sim_dir tb_ir_revolution_sync.v] \
    [file join $sim_dir tb_ir_debounce.v] \
    [file join $sim_dir tb_ir_debug_uart.v]]
update_compile_order -fileset sources_1
set failed 0
foreach test {tb_hub75_scan tb_hub75_sched tb_ir_revolution_sync tb_ir_debounce tb_ir_debug_uart} {
    set_property top $test [get_filesets sim_1]
    update_compile_order -fileset sim_1
    launch_simulation -simset sim_1 -mode behavioral
    run all
    close_sim
    set logs [glob -nocomplain -directory $proj_dir *.sim/sim_1/behav/xsim/simulate.log]
    if {[llength $logs] == 0} {
        puts "FAIL: $test produced no simulation transcript"
        incr failed
        continue
    }
    set fh [open [lindex $logs 0] r]
    set body [read $fh]
    close $fh
    if {[regexp {(?m)^\s*(Fatal|Error|ERROR):} $body]} {
        puts "FAIL: $test tripped a fatal/error assertion"
        incr failed
    } elseif {![regexp {PASS:} $body]} {
        puts "FAIL: $test ended without a PASS line"
        incr failed
    } else {
        puts "PASS: $test"
    }
}
if {$failed > 0} { error "$failed testbench(es) failed; see sim/output/regression" }
puts "REGRESSION_COMPLETE"
