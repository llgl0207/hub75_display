connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
puts "PC=[rrd pc]"
puts "RESULT_HEAD:"
puts [mrd 0x00100180 24]
puts "COUNT=[mrd 0x00100178]"
puts "DONE=[mrd 0x0010017c]"
