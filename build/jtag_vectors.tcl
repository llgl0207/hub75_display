connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
puts "VECTORS:"
puts [mrd 0x0 8]
puts "VEC_DONE"
