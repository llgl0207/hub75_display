connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
puts "HELP_BEGIN"
catch {puts [help memmap]}
puts "HELP_END"
