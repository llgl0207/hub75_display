connect -url TCP:127.0.0.1:3121
targets -set -filter {name =~ "*Cortex-A9 MPCore #0*"}
catch {stop}
after 100
puts "PC=[rrd pc]"
puts "SP=[rrd sp]"
catch {puts "BT: [bt]"}
catch {puts "BT4: [bt 4]"}
catch {con}
puts "BT_DONE"
