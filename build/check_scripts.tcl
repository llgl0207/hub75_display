# Tcl syntax-only check for the build and board scripts (no hardware, no projects).
set repo_dir [file dirname [file dirname [file normalize [info script]]]]
set failures 0
set scripts [list]
foreach name {program_board.tcl probe_hw.tcl check_project.tcl build_board_test.tcl check_ir_synthesis.tcl add_sources.tcl verify_bitstream.tcl create_ps_bd.tcl build_ps_system.tcl} {
    lappend scripts [list $name [file join $repo_dir build $name]]
}
foreach name {gui_program.tcl} {
    lappend scripts [list $name [file join $repo_dir board tcl $name]]
}
foreach entry $scripts {
    lassign $entry name path
    if {![file exists $path]} {
        puts "MISSING: $name"
        incr failures
        continue
    }
    set fh [open $path r]
    set body [read $fh]
    close $fh
    # Parse every command line without executing hardware/project commands.
    if {[catch {info complete $body}]} {
        puts "INCOMPLETE: $name"
        incr failures
        continue
    }
    puts "SYNTAX_OK: $name"
}
if {$failures > 0} { error "$failures script(s) failed the syntax check" }
puts "SCRIPT_SYNTAX_ALL_OK"
