# Run the RTL regression with Vivado 2026.1.
#
#   vivado -mode batch -source sim/run_regression.tcl
#   .\build\vivado.ps1 sim\run_regression.tcl
#
# This driver calls xvlog/xelab/xsim directly by absolute path instead of
# launch_simulation. Vivado 2026.1 on this machine can fail to spawn the
# generated compile.bat when its own bin directory is not on the child PATH;
# direct invocation is deterministic and still uses the same XSim tools.
#
# A $fatal/$error inside a testbench does not necessarily raise a Tcl error, so
# the transcript is the verdict: every testbench must print PASS: and must not
# contain a Fatal/Error line.

set sim_dir [file dirname [file normalize [info script]]]
set repo_dir [file dirname $sim_dir]
set work_dir [file join $sim_dir output regression manual]
file mkdir $work_dir
cd $work_dir

# Locate the Vivado bin from the running executable or XILINX_VIVADO.
set bin_candidates [list]
catch {lappend bin_candidates [file dirname [info nameofexecutable]]}
if {[info exists env(XILINX_VIVADO)]} {
    lappend bin_candidates [file join $env(XILINX_VIVADO) bin]
}
set vivado_bin ""
foreach cand $bin_candidates {
    if {[file exists [file join $cand xvlog.bat]] &&
        [file exists [file join $cand xelab.bat]] &&
        [file exists [file join $cand xsim.bat]]} {
        set vivado_bin $cand
        break
    }
}
if {$vivado_bin eq ""} {
    error "Cannot find xvlog.bat/xelab.bat/xsim.bat; set XILINX_VIVADO or run from Vivado"
}
set xvlog [file join $vivado_bin xvlog.bat]
set xelab [file join $vivado_bin xelab.bat]
set xsim  [file join $vivado_bin xsim.bat]
set cmd_exe "cmd.exe"
if {[info exists env(COMSPEC)]} { set cmd_exe $env(COMSPEC) }

set rtl_srcs [list \
    [file join $repo_dir src hub75_sched.v] \
    [file join $repo_dir src hub75_scan.v] \
    [file join $repo_dir src hub75_slice_ram.v] \
    [file join $repo_dir src hub75_ddr_reader.v] \
    [file join $repo_dir src ir_revolution_sync.v] \
    [file join $repo_dir src ir_debug_uart.v]]
set tb_srcs [list \
    [file join $sim_dir tb_hub75_scan.v] \
    [file join $sim_dir tb_hub75_scan_mem.v] \
    [file join $sim_dir tb_hub75_ddr_reader.v] \
    [file join $sim_dir tb_hub75_sched.v] \
    [file join $sim_dir tb_ir_revolution_sync.v] \
    [file join $sim_dir tb_ir_debounce.v] \
    [file join $sim_dir tb_ir_debug_uart.v]]
set tests [list tb_hub75_scan tb_hub75_scan_mem tb_hub75_ddr_reader \
                tb_hub75_sched tb_ir_revolution_sync tb_ir_debounce tb_ir_debug_uart]

puts "XVLOG = $xvlog"
if {[catch {exec $cmd_exe /c $xvlog --relax {*}$rtl_srcs {*}$tb_srcs 2>@1} compile_out]} {
    puts $compile_out
    error "xvlog compilation failed"
}

set failed 0
foreach test $tests {
    set snap "${test}_snap"
    if {[catch {exec $cmd_exe /c $xelab --debug typical $test -s $snap 2>@1} elab_out]} {
        puts "FAIL: $test elaboration failed"
        puts $elab_out
        incr failed
        continue
    }
    catch {exec $cmd_exe /c $xsim $snap -runall 2>@1} sim_out
    if {[regexp {(?m)^\s*(Fatal|Error|ERROR):} $sim_out]} {
        puts "FAIL: $test tripped a fatal/error assertion"
        puts $sim_out
        incr failed
    } elseif {![regexp {PASS:} $sim_out]} {
        puts "FAIL: $test ended without a PASS line"
        puts $sim_out
        incr failed
    } else {
        puts "PASS: $test"
    }
}
if {$failed > 0} { error "$failed testbench(es) failed; see $work_dir" }
puts "REGRESSION_COMPLETE"
