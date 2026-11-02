connect -url TCP:localhost:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
puts "PC=[rrd pc]"
puts "LR=[rrd lr]"
puts "CPSR=[rrd cpsr]"
con
puts "PC_DONE"
